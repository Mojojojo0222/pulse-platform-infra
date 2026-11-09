# Troubleshooting Runbook — Pulse Platform

Order of attack for any incident: **layer by layer** — Terraform → AWS → nodes → cluster add-ons → ArgoCD → workloads → app.

---

## 0. Quick triage (start here)

```bash
# Identity / region
aws sts get-caller-identity
aws configure get region

# Infrastructure
terraform -chdir=terraform/platform plan    # expect No changes when healthy

# Cluster
aws eks describe-cluster --name pulse-eks --query 'cluster.status'
kubectl get nodes
kubectl get applications.argoproj.io -n argocd
helm list -A
kubectl get pods -A | grep -v Running | grep -v Completed
```

**Healthy baseline (verified 2026-11-10):**
- 2/2 nodes Ready
- `pulse-api` Application = Synced + Healthy
- Helm: `argocd`, `metrics-server`, `monitoring` = deployed
- No CrashLoop/Err/ImagePull pods

---

## 1. Terraform layer

### 1.1 State lock held
```text
Error: Error acquiring the state lock
```
**Cause:** concurrent apply or crashed process left lock.
**Check:** `aws s3api head-object --bucket pulse-platform-tfstate-047090857529-ap-south-1 --key platform/terraform.tfstate.lock`
**Fix:** ensure no other `terraform` process is running; only then delete the lock object. Never delete `terraform.tfstate`.

### 1.2 Plan wants to destroy/replace VPC or EKS unexpectedly
**STOP — do not apply.**
```bash
terraform -chdir=terraform/platform plan -no-color | less
```
Look for `forces replacement` comments. Usual causes: variable drift (`vpc_cidr`, subnet lists), removed resources from config, accidental `terraform state rm`.
**Fix:** restore config/variables; ask before any `state` command.

### 1.3 Backend init fails
```bash
terraform -chdir=terraform/platform init
```
- `NoSuchBucket` → bootstrap layer never run / wrong account.
- `AccessDenied` → credentials ≠ account `047090857529`.
- Config changed → may need `init -migrate-state` (**requires explicit approval**).

### 1.4 fmt/validate failures
```bash
terraform -chdir=terraform/platform fmt -recursive
terraform -chdir=terraform/platform validate
```

---

## 2. AWS / network layer

### 2.1 kubectl: `Unable to connect to the server: dial tcp ... i/o timeout`
1. Public IP changed vs allowlist:
   ```bash
   curl -s https://checkip.amazonaws.com
   aws eks describe-cluster --name pulse-eks \
     --query 'cluster.resourcesVpcConfig.publicAccessCidrs'
   ```
   **Fix:** update `cluster_public_cidrs` in `variables.tf` → plan → apply (no replacement).
2. Cluster deleted → `update-kubeconfig` + rebuild via `platform-up.sh`.

### 2.2 Nodes `NotReady`
```bash
kubectl describe node <name> | sed -n '/Conditions/,$p'
kubectl get pods -n kube-system -l k8s-app=aws-node
kubectl logs -n kube-system -l k8s-app=aws-node --tail=50
```
| Signal | Meaning | Fix |
|--------|---------|-----|
| `aws-node` CrashLoop, no `AWS_ROLE_ARN` | IRSA broken / addon before role | Check `aws_eks_addon.vpc-cni` status + IAM role ARN |
| `aws-node` can't call EC2 API | IAM/Policies | Verify `AmazonEKS_CNI_Policy` attachment on `pulse-eks-vpc-cni-role` |
| kubelet cert / API unreachable | Control plane or network | Check cluster status, NAT healthy, route tables |

**Historical incident (Day 01):** node group created before managed CNI+IRSA → ENI allocation impossible → NotReady → `CREATE_FAILED`. Fixed with `depends_on` ordering.

### 2.3 NAT / private subnet egress broken
```bash
aws ec2 describe-nat-gateways --filter Name=state,Values=available
aws ec2 describe-route-tables --filters Name=vpc-id,Values=<vpc-id>
# From a debug pod in private subnet:
kubectl run net-test --rm -it --image=busybox:1.36 -- sh
wget -qO- https://api.github.com   # should work via NAT
```
No default route `0.0.0.0/0 → nat-...` on private RT → images/DNS/HTTPS fail.

### 2.4 ECR pull failures (`ImagePullBackOff`)
```bash
aws ecr describe-images --repository-name pulse-api \
  --query 'imageDetails[*].imageTags'
kubectl describe pod -n pulse <pod> | grep -A5 Failed
```
Check: tag exists? URI account/region correct? Node role has `AmazonEC2ContainerRegistryPullOnly`? Egress via NAT OK?

---

## 3. ArgoCD layer

### 3.1 Application OutOfSync forever / no refresh
```bash
kubectl annotate applications.argoproj.io pulse-api -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
kubectl get application pulse-api -n argocd -o yaml | sed -n '/status:/,$p'
```
Poll interval lag vs webhook not configured (expected in lab).

### 3.2 Sync errors: “already exists” / ownership
**Cause:** object created outside ArgoCD (manual `kubectl apply` or Helm) without tracking metadata.
**Seen Day 02:** first pulse-api sync — fixed by delete + ArgoCD recreate.
**Prevention:** never `kubectl apply` over GitOps-managed objects; adopt carefully.

### 3.3 Repo access errors
```bash
kubectl exec -n argocd deploy/argocd-repo-server -- \
  git ls-remote https://github.com/Mojojojo0222/pulse-platform.git HEAD
kubectl logs -n argocd deploy/argocd-repo-server --tail=50
```
- Public repos: no Secret needed (this lab).
- Private repos: need `Secret` of type `argocd.argoproj.io/secret-type=repository`.
- `network` / `TLS` errors → cluster egress (NAT) or DNS.

### 3.4 Multi-source value file not found
Typical mistake: `$values/gitops/values/...` vs `$values/values/...` — `$values` is the **repo root** of the `ref: values` source. Compare with `gitops/apps/monitoring.yaml` and repo layout `pulse-platform-infra`.

### 3.5 Root app doesn’t create children
```bash
kubectl get application pulse-platform-root -n argocd -o yaml
kubectl logs -n argocd deploy/argocd-application-controller --tail=100
```
Check: path `gitops/apps`, branch `master` pushed, YAML inside path is `kind: Application`, namespace `argocd`.

### 3.6 Controller / repo-server down
```bash
kubectl get pods -n argocd
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-application-controller
helm status argocd -n argocd
# Reinstall only if release missing (platform-up does this idempotently)
```

---

## 4. Workload layer (pulse-api)

### 4.1 CrashLoopBackOff
```bash
kubectl logs -n pulse deploy/pulse-api --previous
kubectl describe pod -n pulse <pod>
```
App-level: probe paths `/health/live` `/health/ready`; OOM (`OOMKilled` → raise limits); bad release image tag.

### 4.2 Pending pods
```bash
kubectl describe pod -n pulse <pod> | sed -n '/Events/,$p'
```
Insufficient CPU/mem → check `kubectl top nodes`; PDB blocking eviction; no nodes Ready.

### 4.3 Service has no endpoints
```bash
kubectl get endpointslices -n pulse
kubectl get pods -n pulse -o wide   # readiness
```
Unready pods are removed from endpoints by readiness probe — expected.

### 4.4 Rolling update stuck
```bash
kubectl rollout status deploy/pulse-api -n pulse
kubectl rollout history deploy/pulse-api -n pulse
# rollback
kubectl rollout undo deploy/pulse-api -n pulse
# GitOps: revert the commit in pulse-platform.git instead
```

---

## 5. Observability layer

### 5.1 `kubectl top` fails / HPA unknown
```bash
kubectl top nodes || true
kubectl get apiservice v1beta1.metrics.k8s.io -o yaml | grep -A3 status
kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server
```
If `Available: False` → metrics-server pod not ready or kubelet summary stats blocked.

### 5.2 Prometheus targets DOWN
Port-forward Prometheus UI → Status → Targets; or API `query=up==0`.
Fix ServiceMonitor selectors, pod labels, network policies.

### 5.3 Alert not delivered
1. Rule firing? Prometheus → Alerts (or API).
2. Alertmanager receiving? `alertmanager` UI → Alerts.
3. Receiver reachable?
   ```bash
   kubectl get svc monitoring-alert-routing-svc -n monitoring
   kubectl logs -n monitoring deploy/monitoring-alert-validator -f
   ```
4. URL in values uses FQDN `monitoring-alert-routing-svc.monitoring.svc.cluster.local:8089`.

### 5.4 Grafana no data / lost dashboards
Expected without persistence after pod reschedule. Provision dashboards via ConfigMaps if you need durability.

---

## 6. Script failures (platform-up / down)

| Exit code | Meaning | First action |
|-----------|---------|--------------|
| 2 | Missing tool | Install terraform/aws/kubectl/helm/git/jq |
| 3 | Identity/region/state guard | Fix credentials; read exact error — script **refused** on purpose |
| 4 | Terraform init/validate/plan | Read Terraform output above the message |
| 5 | User declined confirmation | Re-run; type `APPLY` or `DESTROY-PULSE-PLATFORM` exactly |
| 6 | Apply failed | `terraform plan` again to see partial progress |
| 7 | Nodes/kubeconfig timeout | §2.1–2.2 |
| 8 | ArgoCD bootstrap failed | §3.6 |
| 9 | App sync/health timeout | §3.1–3.5; script prints controller logs |
| 10 | Verification failed | Script already dumped pod/app status |

**Never** change guards in the script to “make it pass” — they protect the wrong account/cluster.

---

## 7. Destroy-specific issues

```bash
./bootstrap/platform-down.sh
```
- Refuses wrong account/region/bucket/key **before** plan (exit 3).
- Requires exact `DESTROY-PULSE-PLATFORM` (exit 5 on anything else).
- Post-check: cluster & VPC gone; **bucket + ECR must remain** (exit 7/8 if not).
- If destroy fails mid-way: re-run script; Terraform will plan the remainder.

---

## 8. Log & command index

```bash
# AWS
aws eks describe-cluster --name pulse-eks
aws eks describe-nodegroup --cluster-name pulse-eks --nodegroup-name pulse-eks-workers
aws ec2 describe-nat-gateways
aws s3api head-object --bucket pulse-platform-tfstate-047090857529-ap-south-1 --key platform/terraform.tfstate

# Terraform
terraform -chdir=terraform/platform init/validate/plan/show

# Cluster
kubectl get nodes -o wide
kubectl get applications.argoproj.io -n argocd -o wide
kubectl logs -n argocd deploy/argocd-application-controller --tail=100
kubectl logs -n kube-system -l k8s-app=aws-node --tail=50
kubectl get pods -n monitoring

# Helm
helm list -A
helm get values monitoring -n monitoring
helm history monitoring -n monitoring
```

---

## 9. Escalation checklist (when stuck >15 min)

1. Which **layer** failed? (run §0 triage)
2. What **changed last**? (git log, helm history, terraform plan)
3. Capture: `kubectl describe`, controller logs, `terraform plan` output.
4. Is it **reproducible** after `platform-down` + `platform-up`? If yes → bug in automation; if no → live drift.
5. Never apply an unreviewed plan; never `state rm` without showing consequences.
