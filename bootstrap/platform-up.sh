#!/usr/bin/env bash
# =============================================================================
# Pulse Platform — platform-up.sh
# Brings the disposable lab from "empty account resources" (or existing
# infrastructure) to a fully GitOps-managed Kubernetes platform.
#
# Usage:  ./bootstrap/platform-up.sh
#
# Exit codes:
#   0  success
#   1  unexpected error
#   2  missing prerequisite (terraform/aws/kubectl/helm/git)
#   3  AWS identity or region mismatch (refuses to run)
#   4  Terraform init/fmt/validate/plan failed
#   5  user declined confirmation
#   6  Terraform apply failed
#   7  kubeconfig / node readiness failure
#   8  ArgoCD bootstrap failure
#   9  Application sync/health timeout
#  10  verification failure (apps or monitoring not healthy)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants — change these only if the lab itself changes
# ---------------------------------------------------------------------------
readonly EXPECTED_ACCOUNT="047090857529"
readonly EXPECTED_REGION="ap-south-1"
readonly EXPECTED_CLUSTER="pulse-eks"
readonly TF_DIR="terraform/platform"
readonly ROOT_APP_MANIFEST="gitops/root/platform-root.yaml"
readonly ARGOCD_CHART_VERSION="10.17.1"
readonly ARGOCD_RELEASE="argocd"
readonly ARGOCD_NS="argocd"
readonly NODE_TIMEOUT_S=600
readonly APP_TIMEOUT_S=600

# Resolve project root (parent of bootstrap/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()   { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
err()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()   { local code="$1"; shift; err "$@"; exit "$code"; }
step()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
check_prereqs() {
  step "Step 1/18 — Checking prerequisites"
  local missing=0
  local tool
  for tool in terraform aws kubectl helm git; do
    if command -v "$tool" >/dev/null 2>&1; then
      log "found: $tool ($( "$tool" version 2>/dev/null | head -1 || "$tool" --version 2>/dev/null | head -1 ))"
    else
      err "missing required tool: $tool"
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || die 2 "Install missing tools and re-run."
}

# ---------------------------------------------------------------------------
# 2. AWS identity + region guard rails
# ---------------------------------------------------------------------------
check_aws_identity() {
  step "Step 2/18 — Verifying AWS credentials and account"
  local identity account arn region
  if ! identity="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
    die 3 "aws sts get-caller-identity failed — configure credentials (aws configure / SSO / env vars)."
  fi
  account="$(jq -r '.Account' <<<"$identity")"
  arn="$(jq -r '.Arn' <<<"$identity")"
  log "identity: ${arn}"
  if [[ "${account}" != "${EXPECTED_ACCOUNT}" ]]; then
    die 3 "Account mismatch: got ${account}, expected ${EXPECTED_ACCOUNT}. Refusing to continue."
  fi

  region="$(aws configure get region 2>/dev/null || true)"
  [[ -n "${region}" ]] || region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  if [[ "${region}" != "${EXPECTED_REGION}" ]]; then
    die 3 "Region mismatch: got '${region:-unset}', expected ${EXPECTED_REGION}. Refusing to continue."
  fi
  log "region: ${region} (expected match)"

  # Advisory: API endpoint allowlist vs current public IP (does not block)
  local current_ip allowlist
  current_ip="$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  allowlist="$(aws eks describe-cluster --name "${EXPECTED_CLUSTER}" \
    --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text 2>/dev/null || true)"
  if [[ -n "${current_ip}" && -n "${allowlist}" && "${allowlist}" != "None" ]]; then
    if grep -q "${current_ip}" <<<"${allowlist}" 2>/dev/null; then
      log "public IP ${current_ip} is inside EKS API allowlist [${allowlist}]"
    else
      warn "public IP ${current_ip} is NOT in EKS API allowlist [${allowlist}]."
      warn "kubectl may fail until cluster_public_cidrs is updated in terraform."
    fi
  fi
}

# ---------------------------------------------------------------------------
# 3–7. Terraform lifecycle
# ---------------------------------------------------------------------------
run_terraform_lifecycle() {
  step "Step 3/18 — Entering Terraform directory ${TF_DIR}"
  [[ -d "${TF_DIR}" ]] || die 4 "Terraform directory not found: ${TF_DIR}"
  cd "${PROJECT_ROOT}/${TF_DIR}"

  # Confirm backend before any state-touching command
  if ! grep -q 'use_lockfile' backend.tf 2>/dev/null; then
    warn "backend.tf does not mention use_lockfile — verify backend before apply."
  fi
  log "backend: $(tr -d '\n' < backend.tf | tr -s ' ')"

  step "Step 4/18 — terraform init (remote S3 backend)"
  terraform init -input=false || die 4 "terraform init failed."

  step "Step 5/18 — terraform fmt -check"
  if ! terraform fmt -check -recursive; then
    warn "Formatting issues found — running terraform fmt -recursive to fix."
    terraform fmt -recursive
    warn "Re-run after reviewing fmt changes if this was unexpected."
  else
    log "formatting OK"
  fi

  step "Step 6/18 — terraform validate"
  terraform validate || die 4 "terraform validate failed."

  step "Step 7/18 — terraform plan"
  rm -f platform-up.tfplan
  terraform plan -input=false -no-color -out=platform-up.tfplan \
    || die 4 "terraform plan failed."

  step "Step 8/18 — Planned changes"
  terraform show -no-color platform-up.tfplan

  step "Step 9/18 — Confirmation required"
  echo
  echo "Review the plan above. Apply provisions/updates VPC, subnets, NAT,"
  echo "EKS, IAM and worker nodes in account ${EXPECTED_ACCOUNT} / ${EXPECTED_REGION}."
  echo
  printf 'Type APPLY to continue: '
  local answer
  read -r answer
  if [[ "${answer}" != "APPLY" ]]; then
    die 5 "User declined apply (typed: '${answer}'). Nothing was changed."
  fi

  step "Step 10/18 — terraform apply (approved plan only)"
  terraform apply -input=false -no-color platform-up.tfplan \
    || die 6 "terraform apply failed. Inspect output; state may be partially updated."
  log "Terraform apply completed."
}

# ---------------------------------------------------------------------------
# 11–12. kubeconfig + node readiness
# ---------------------------------------------------------------------------
configure_cluster_access() {
  step "Step 11/18 — Configuring kubeconfig"
  aws eks update-kubeconfig --name "${EXPECTED_CLUSTER}" --region "${EXPECTED_REGION}" \
    || die 7 "aws eks update-kubeconfig failed."
  log "current-context: $(kubectl config current-context)"

  step "Step 12/18 — Waiting for worker nodes Ready (timeout ${NODE_TIMEOUT_S}s)"
  if ! kubectl wait --for=condition=Ready node --all --timeout="${NODE_TIMEOUT_S}s"; then
    kubectl get nodes -o wide || true
    die 7 "Nodes did not become Ready within ${NODE_TIMEOUT_S}s."
  fi
  kubectl get nodes -o wide
  log "all nodes Ready"
}

# ---------------------------------------------------------------------------
# 13–14. ArgoCD bootstrap (idempotent) + GitHub reachability
# ---------------------------------------------------------------------------
bootstrap_argocd() {
  step "Step 13/18 — Bootstrapping ArgoCD (idempotent)"

  if ! kubectl get ns "${ARGOCD_NS}" >/dev/null 2>&1; then
    kubectl create namespace "${ARGOCD_NS}" \
      || die 8 "Failed to create namespace ${ARGOCD_NS}."
    log "created namespace ${ARGOCD_NS}"
  else
    log "namespace ${ARGOCD_NS} already exists"
  fi

  if helm status "${ARGOCD_RELEASE}" -n "${ARGOCD_NS}" >/dev/null 2>&1; then
    local chart_version
    chart_version="$(helm list -n "${ARGOCD_NS}" -o json \
      | jq -r ".[] | select(.name==\"${ARGOCD_RELEASE}\") | .chart")"
    log "Helm release '${ARGOCD_RELEASE}' already present (chart ${chart_version}) — skipping install."
    if [[ "${chart_version}" != "argo-cd-${ARGOCD_CHART_VERSION}" ]]; then
      warn "Installed chart '${chart_version}' != pinned '${ARGOCD_CHART_VERSION}'."
      warn "Not auto-upgrading; reconcile manually if upgrade is intended."
    fi
  else
    log "installing argo-cd chart ${ARGOCD_CHART_VERSION}..."
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
    helm repo update argo >/dev/null
    helm install "${ARGOCD_RELEASE}" argo/argo-cd \
      --namespace "${ARGOCD_NS}" \
      --version "${ARGOCD_CHART_VERSION}" \
      --set server.service.type=ClusterIP \
      --wait --timeout "${NODE_TIMEOUT_S}s" \
      || die 8 "Helm install of ArgoCD failed."
    log "ArgoCD installed."
  fi

  # Wait for core ArgoCD pods
  local deadline=$((SECONDS + NODE_TIMEOUT_S))
  while (( SECONDS < deadline )); do
    local ready
    ready="$(kubectl get deploy -n "${ARGOCD_NS}" -o name 2>/dev/null | wc -l | tr -d ' ')"
    local avail
    avail="$(kubectl get deploy -n "${ARGOCD_NS}" \
      -o jsonpath='{range .items[*]}{.status.availableReplicas}{"\n"}{end}' 2>/dev/null \
      | awk '{s+=$1} END {print s+0}')"
    local desired
    desired="$(kubectl get deploy -n "${ARGOCD_NS}" \
      -o jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
      | awk '{s+=$1} END {print s+0}')"
    if [[ -n "${desired}" && "${desired}" -gt 0 && "${avail}" -ge "${desired}" ]]; then
      log "ArgoCD deployments available: ${avail}/${desired}"
      break
    fi
    sleep 5
    if (( SECONDS >= deadline )); then
      kubectl get pods -n "${ARGOCD_NS}" || true
      die 8 "ArgoCD pods not ready within ${NODE_TIMEOUT_S}s."
    fi
  done

  step "Step 14/18 — Verifying ArgoCD can reach GitHub from the cluster"
  # repo-server may not have git in PATH on all images; use a best-effort probe.
  if kubectl exec -n "${ARGOCD_NS}" deploy/argocd-repo-server -- \
      git ls-remote https://github.com/Mojojojo0222/pulse-platform.git HEAD >/dev/null 2>&1; then
    log "repo-server can reach pulse-platform.git"
  else
    warn "Could not verify git access from repo-server (image may lack git)."
    warn "Sync errors of type 'authentication/remote access' will confirm or deny this."
  fi
}

# ---------------------------------------------------------------------------
# 15–16. Root App-of-Apps + child sync wait
# ---------------------------------------------------------------------------
apply_root_app() {
  step "Step 15/18 — Applying root App-of-Apps (${ROOT_APP_MANIFEST})"
  [[ -f "${ROOT_APP_MANIFEST}" ]] || die 9 "Missing ${ROOT_APP_MANIFEST}"
  kubectl apply -f "${ROOT_APP_MANIFEST}" \
    || die 9 "Failed to apply root Application."
  log "root Application applied (pulse-platform-root)"
}

wait_for_applications() {
  step "Step 16/18 — Waiting for child Applications Synced+Healthy (timeout ${APP_TIMEOUT_S}s)"
  local expected_apps=(pulse-api metrics-server monitoring)
  local deadline=$((SECONDS + APP_TIMEOUT_S))
  local all_ok=0

  while (( SECONDS < deadline )); do
    all_ok=1
    local app sync health
    for app in "${expected_apps[@]}"; do
      sync="$(kubectl get application "${app}" -n "${ARGOCD_NS}" \
        -o jsonpath='{.status.sync.status}' 2>/dev/null || echo Missing)"
      health="$(kubectl get application "${app}" -n "${ARGOCD_NS}" \
        -o jsonpath='{.status.health.status}' 2>/dev/null || echo Missing)"
      printf '    %-16s sync=%-10s health=%s\n' "${app}" "${sync}" "${health}"
      if [[ "${sync}" != "Synced" || "${health}" != "Healthy" ]]; then
        all_ok=0
      fi
    done
    [[ $all_ok -eq 1 ]] && break
    sleep 10
  done

  if [[ $all_ok -ne 1 ]]; then
    warn "Timed out waiting for Applications."
    kubectl get applications.argoproj.io -n "${ARGOCD_NS}" || true
    # Show recent controller errors for diagnosis
    kubectl logs -n "${ARGOCD_NS}" deploy/argocd-application-controller --tail=40 2>/dev/null || true
    die 9 "Applications not all Synced/Healthy within ${APP_TIMEOUT_S}s."
  fi
  log "all child Applications Synced and Healthy"
}

# ---------------------------------------------------------------------------
# 17–18. Verification + report
# ---------------------------------------------------------------------------
verify_platform() {
  step "Step 17/18 — Verifying workloads and observability"

  local failures=0

  # Pulse
  if kubectl rollout status deployment/pulse-api -n pulse --timeout=120s >/dev/null 2>&1; then
    log "pulse-api Deployment rollout OK ($(kubectl get deploy pulse-api -n pulse -o jsonpath='{.status.readyReplicas}')/$(kubectl get deploy pulse-api -n pulse -o jsonpath='{.spec.replicas}') ready)"
  else
    err "pulse-api Deployment not ready"
    kubectl get pods -n pulse || true
    failures=1
  fi

  # Metrics server
  if kubectl get deploy metrics-server -n kube-system >/dev/null 2>&1; then
    local ms_ready
    ms_ready="$(kubectl get deploy metrics-server -n kube-system -o jsonpath='{.status.readyReplicas}')"
    if [[ "${ms_ready}" -ge 1 ]] 2>/dev/null; then
      log "metrics-server ready (${ms_ready})"
    else
      err "metrics-server not ready"
      failures=1
    fi
  else
    err "metrics-server deployment missing"
    failures=1
  fi

  # Monitoring stack (key pods)
  local mon_ok=1
  local pod
  for pod in \
    "prometheus-monitoring-kube-prometheus-prometheus-0" \
    "monitoring-grafana" \
    "alertmanager-monitoring-kube-prometheus-alertmanager-0" \
    "monitoring-kube-prometheus-operator"; do
    if ! kubectl get pod -n monitoring -l "app.kubernetes.io/name=${pod#monitoring-}" 2>/dev/null | grep -q Running \
       && ! kubectl get pod -n monitoring "${pod}" >/dev/null 2>&1; then
      # Fallback: count running pods matching prefix
      :
    fi
  done
  local running_mon
  running_mon="$(kubectl get pods -n monitoring --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l | tr -d ' ')"
  local total_mon
  total_mon="$(kubectl get pods -n monitoring --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${total_mon}" -gt 0 && "${running_mon}" -eq "${total_mon}" ]]; then
    log "monitoring pods Running: ${running_mon}/${total_mon}"
  else
    err "monitoring pods not all Running: ${running_mon}/${total_mon}"
    kubectl get pods -n monitoring || true
    mon_ok=0
    failures=1
  fi

  # Prometheus targets (via prometheus API through port-forward is heavy;
  # use kubectl exec on prometheus pod for a lightweight query instead)
  local prom_pod
  prom_pod="$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${prom_pod}" ]]; then
    local up_count
    up_count="$(kubectl exec -n monitoring "${prom_pod}" -c prometheus -- \
      wget -qO- 'localhost:9090/api/v1/query?query=up' 2>/dev/null \
      | jq -r '[.data.result[] | select(.value[1]=="1")] | length' 2>/dev/null || echo 0)"
    if [[ "${up_count}" -gt 0 ]] 2>/dev/null; then
      log "Prometheus reports ${up_count} target(s) UP"
    else
      warn "Could not query Prometheus API (or 0 targets up) — check ServiceMonitors."
    fi
  fi

  step "Step 18/18 — Final status report"
  echo
  echo "==================== PULSE PLATFORM STATUS ===================="
  echo "Account/Region : ${EXPECTED_ACCOUNT} / ${EXPECTED_REGION}"
  echo "Cluster        : ${EXPECTED_CLUSTER}"
  echo "Nodes          : $(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')/$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ') Ready"
  echo
  echo "ArgoCD Applications:"
  kubectl get applications.argoproj.io -n "${ARGOCD_NS}" 2>/dev/null || true
  echo
  echo "Pulse namespace:"
  kubectl get deploy,svc,pdb -n pulse 2>/dev/null || true
  echo
  echo "Monitoring namespace:"
  kubectl get pods -n monitoring 2>/dev/null || true
  echo
  echo "Helm releases (should show ArgoCD only for argocd; platform apps via GitOps):"
  helm list -A 2>/dev/null || true
  echo
  echo "Useful next commands:"
  echo "  kubectl port-forward svc/argocd-server -n argocd 8081:443"
  echo "  kubectl port-forward svc/grafana -n monitoring 3000:80"
  echo "  ./bootstrap/platform-down.sh    # destroy disposable infra"
  echo "==============================================================="
  echo

  if [[ $failures -ne 0 ]]; then
    die 10 "Verification finished with failures — see messages above."
  fi
  log "Platform is up and healthy."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "Pulse Platform — platform-up starting (project root: ${PROJECT_ROOT})"
  check_prereqs
  check_aws_identity
  run_terraform_lifecycle
  configure_cluster_access
  bootstrap_argocd
  apply_root_app
  wait_for_applications
  verify_platform
}

main "$@"
