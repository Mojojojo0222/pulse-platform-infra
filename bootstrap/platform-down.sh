#!/usr/bin/env bash
# =============================================================================
# Pulse Platform — platform-down.sh
# Destroys the DISPOSABLE lab infrastructure (VPC, NAT, EKS, nodes, IAM)
# while preserving the Terraform state bucket, ECR repository and GitHub repos.
#
# Usage:  ./bootstrap/platform-down.sh
#
# Safety rails (all must pass before a destroy plan is even generated):
#   1. AWS caller identity == expected account
#   2. AWS region == expected region
#   3. Running from the correct Terraform directory with the expected backend
#   4. Cluster name matches EXPECTED_CLUSTER (when cluster exists)
#   5. User types the exact confirmation string DESTROY-PULSE-PLATFORM
#   6. Only the reviewed plan file is applied (never -auto-approve, never bare destroy)
#
# Exit codes:
#   0  success (destroyed and verified)
#   1  unexpected error
#   2  missing prerequisite
#   3  identity/region/cluster/state guard failed
#   4  destroy plan generation failed
#   5  user declined confirmation
#   6  destroy apply failed
#   7  post-destroy verification failed (resources may remain — re-run plan)
#   8  refused: persistent resources unexpectedly absent/present mismatch
# =============================================================================
set -euo pipefail

readonly EXPECTED_ACCOUNT="047090857529"
readonly EXPECTED_REGION="ap-south-1"
readonly EXPECTED_CLUSTER="pulse-eks"
readonly EXPECTED_STATE_BUCKET="pulse-platform-tfstate-047090857529-ap-south-1"
readonly EXPECTED_STATE_KEY="platform/terraform.tfstate"
readonly TF_DIR="terraform/platform"
readonly CONFIRM_STRING="DESTROY-PULSE-PLATFORM"
readonly ECR_REPO="pulse-api"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

log()  { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()  { local code="$1"; shift; err "$@"; exit "$code"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# Guard rails
# ---------------------------------------------------------------------------
check_prereqs() {
  step "Step 1/9 — Checking prerequisites"
  local tool
  for tool in terraform aws jq; do
    command -v "$tool" >/dev/null 2>&1 \
      || die 2 "Missing required tool: $tool"
    log "found: $tool"
  done
}

check_aws_identity() {
  step "Step 2/9 — Verifying AWS identity and region"
  local identity account arn region
  identity="$(aws sts get-caller-identity --output json 2>/dev/null)" \
    || die 3 "aws sts get-caller-identity failed — configure credentials first."
  account="$(jq -r '.Account' <<<"$identity")"
  arn="$(jq -r '.Arn' <<<"$identity")"
  log "identity: ${arn}"
  [[ "${account}" == "${EXPECTED_ACCOUNT}" ]] \
    || die 3 "Account mismatch: got ${account}, expected ${EXPECTED_ACCOUNT}. REFUSING destroy."

  region="$(aws configure get region 2>/dev/null || true)"
  [[ -n "${region}" ]] || region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  [[ "${region}" == "${EXPECTED_REGION}" ]] \
    || die 3 "Region mismatch: got '${region:-unset}', expected ${EXPECTED_REGION}. REFUSING destroy."
  log "region ${region} OK"
}

check_terraform_dir_and_state() {
  step "Step 3/9 — Verifying Terraform directory and remote state backend"
  local tf_path="${PROJECT_ROOT}/${TF_DIR}"
  [[ -d "${tf_path}" ]] || die 3 "Terraform directory not found: ${tf_path}"
  cd "${tf_path}"
  [[ -f backend.tf ]] || die 3 "backend.tf missing in ${tf_path}"

  local backend_contents
  backend_contents="$(cat backend.tf)"
  grep -q "${EXPECTED_STATE_BUCKET}" <<<"${backend_contents}" \
    || die 3 "backend.tf bucket != ${EXPECTED_STATE_BUCKET}. REFUSING (wrong state backend)."
  grep -q "${EXPECTED_STATE_KEY}" <<<"${backend_contents}" \
    || die 3 "backend.tf key != ${EXPECTED_STATE_KEY}. REFUSING (wrong state key)."
  log "backend OK: s3://${EXPECTED_STATE_BUCKET}/${EXPECTED_STATE_KEY}"

  # Verify the state object actually exists before planning a destroy
  if ! aws s3api head-object --bucket "${EXPECTED_STATE_BUCKET}" --key "${EXPECTED_STATE_KEY}" >/dev/null 2>&1; then
    die 8 "State object s3://${EXPECTED_STATE_BUCKET}/${EXPECTED_STATE_KEY} not found. REFUSING."
  fi
  log "state object exists in S3"
}

check_cluster_identity_if_present() {
  step "Step 4/9 — Verifying cluster identity (if it exists)"
  local status
  status="$(aws eks describe-cluster --name "${EXPECTED_CLUSTER}" \
    --query 'cluster.status' --output text 2>/dev/null || echo "ABSENT")"
  if [[ "${status}" == "ABSENT" || "${status}" == "None" ]]; then
    warn "Cluster ${EXPECTED_CLUSTER} not found — destroy may be a no-op or partial."
  else
    local arn
    arn="$(aws eks describe-cluster --name "${EXPECTED_CLUSTER}" --query 'cluster.arn' --output text)"
    log "cluster ${EXPECTED_CLUSTER} status=${status}"
    log "arn=${arn}"
    [[ "${arn}" == *":cluster/${EXPECTED_CLUSTER}" ]] \
      || die 3 "Cluster ARN '${arn}' does not end with /${EXPECTED_CLUSTER}. REFUSING."
    [[ "${arn}" == "arn:aws:eks:${EXPECTED_REGION}:${EXPECTED_ACCOUNT}:"* ]] \
      || die 3 "Cluster ARN account/region mismatch: ${arn}. REFUSING."
  fi
}

# ---------------------------------------------------------------------------
# Destroy plan (review only — no apply yet)
# ---------------------------------------------------------------------------
generate_destroy_plan() {
  step "Step 5/9 — terraform init (refresh backend)"
  terraform init -input=false || die 4 "terraform init failed."

  step "Step 6/9 — Generating DESTROY plan"
  rm -f platform-down.tfplan
  terraform plan -input=false -no-color -destroy -out=platform-down.tfplan \
    || die 4 "terraform plan -destroy failed."
  log "plan file: platform-down.tfplan"
}

show_destroy_plan() {
  step "Step 7/9 — DESTROY plan contents (review carefully)"
  terraform show -no-color platform-down.tfplan

  cat <<'BANNER'

================================================================
  WHAT THIS DESTROY WILL REMOVE (disposable lab resources)
================================================================
  • VPC (10.20.0.0/16) and all public/private subnets
  • Internet Gateway, NAT Gateway, Elastic IP
  • Route tables and associations
  • EKS control plane  (pulse-eks)
  • EKS managed node group + EC2 worker instances (2× t3.medium)
  • EBS volumes attached to those nodes
  • EKS IAM roles/policy attachments created by this configuration
  • EKS add-ons (vpc-cni, kube-proxy, coreDNS) as part of cluster delete
  • OIDC provider for IRSA
  • ALL Kubernetes workloads (they live on the nodes/control plane)

================================================================
  WHAT THIS DESTROY WILL PRESERVE
================================================================
  • S3 Terraform state bucket  (lives in terraform/bootstrap layer,
    has prevent_destroy, and is NOT in this state file)
  • ECR repository + images    (created outside Terraform via AWS CLI)
  • GitHub repositories        (pulse-platform, pulse-platform-infra)
  • Local project files        (nothing on your disk is deleted)
  • Bootstrap local state      (terraform/bootstrap/terraform.tfstate)

================================================================
  NOTE: After destroy, re-running platform-up.sh allocates a NEW
  NAT Elastic IP (public IP changes). API allowlist CIDR may need
  updating if your outbound IP also changed.
================================================================

BANNER
}

# ---------------------------------------------------------------------------
# Confirmation + apply
# ---------------------------------------------------------------------------
confirm_and_apply() {
  step "Step 8/9 — Explicit confirmation required"
  echo "A simple 'yes' is NOT accepted."
  echo "Type exactly: ${CONFIRM_STRING}"
  printf '> '
  local answer
  read -r answer
  if [[ "${answer}" != "${CONFIRM_STRING}" ]]; then
    die 5 "Confirmation failed (typed: '${answer}'). Nothing was destroyed."
  fi
  log "confirmation accepted — applying reviewed destroy plan only"
  terraform apply -input=false -no-color platform-down.tfplan \
    || die 6 "terraform destroy apply failed. Re-run plan to see remaining resources."
  log "destroy apply completed."
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
verify_destruction() {
  step "Step 9/9 — Post-destroy verification"
  local failures=0

  # Cluster must be gone
  local status
  status="$(aws eks describe-cluster --name "${EXPECTED_CLUSTER}" \
    --query 'cluster.status' --output text 2>/dev/null || echo "ABSENT")"
  if [[ "${status}" == "ABSENT" || "${status}" == "None" ]]; then
    log "EKS cluster ${EXPECTED_CLUSTER}: ABSENT (correct)"
  else
    err "EKS cluster still present: status=${status}"
    failures=1
  fi

  # VPC with our CIDR must be gone
  local vpc_count
  vpc_count="$(aws ec2 describe-vpcs --filters Name=cidr-block,Values=10.20.0.0/16 \
    --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)"
  if [[ "${vpc_count}" == "0" ]]; then
    log "VPC 10.20.0.0/16: ABSENT (correct)"
  else
    err "VPC 10.20.0.0/16 still present (${vpc_count})"
    failures=1
  fi

  # NAT gateways in default state should be none for our VPC (best-effort)
  local nat_count
  nat_count="$(aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending \
    --query 'length(NatGateways)' --output text 2>/dev/null || echo "?")"
  log "NAT gateways available/pending (account-wide): ${nat_count} (informational)"

  # --- Persistent resources MUST still exist ---
  if aws s3api head-bucket --bucket "${EXPECTED_STATE_BUCKET}" 2>/dev/null; then
    log "PRESERVED: state bucket ${EXPECTED_STATE_BUCKET}"
  else
    err "CRITICAL: state bucket missing after destroy!"
    failures=1
  fi

  if aws ecr describe-repositories --repository-names "${ECR_REPO}" >/dev/null 2>&1; then
    local img_count
    img_count="$(aws ecr describe-images --repository-name "${ECR_REPO}" \
      --query 'length(imageDetails)' --output text 2>/dev/null || echo 0)"
    log "PRESERVED: ECR ${ECR_REPO} (${img_count} images)"
  else
    err "CRITICAL: ECR repository ${ECR_REPO} missing after destroy!"
    failures=1
  fi

  # GitHub repos — local check only (network)
  if [[ -d "${PROJECT_ROOT}/.git" || -d "${PROJECT_ROOT}/application/.git" ]]; then
    log "PRESERVED: local git repositories present"
  fi

  echo
  echo "==================== DESTROY REPORT ===================="
  echo "Disposable infrastructure : DESTROYED (see verification above)"
  echo "State bucket              : PRESERVED"
  echo "ECR ${ECR_REPO}              : PRESERVED"
  echo "GitHub + local files      : PRESERVED"
  echo
  echo "To rebuild:  ./bootstrap/platform-up.sh"
  echo "======================================================="
  echo

  if [[ $failures -ne 0 ]]; then
    die 7 "Verification reported failures — inspect before re-running."
  fi
  log "Destroy complete and verified."
}

main() {
  warn "Pulse Platform — platform-down (DESTROY) starting"
  check_prereqs
  check_aws_identity
  check_terraform_dir_and_state
  check_cluster_identity_if_present
  generate_destroy_plan
  show_destroy_plan
  confirm_and_apply
  verify_destruction
}

main "$@"
