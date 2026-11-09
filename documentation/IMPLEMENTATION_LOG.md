# Implementation Log — Decisions, Steps, Observations

Companion to `docs/IMPLEMENTATION_CHANGELOG.md`: the **why** behind every move, plus raw observations from inspection. Written so you can replay the reasoning in an interview or after a break.

---

## 1. Inspection observations (facts first)

### 1.1 Filesystem
- Root `E:\Platform-Lab` was **not** a git repository.
- `application/` **was** a git repo → `https://github.com/Mojojojo0222/pulse-platform.git`, branch `master`, only untracked `.gitignore` locally.
- GitHub `pulse-platform` contents: `Dockerfile`, `k8s/{deployment,namespace,pdb,service}.yaml`, `pom.xml`, `src/`, **`target/`** (build artifacts committed — hygiene issue noted, not fixed without approval on that repo).
- Existing dirs: `terraform/{bootstrap,platform}`, `gitops/` (single Application file), `observability/` (values + receiver), `documentation/journal/`, `application/`.
- Missing vs mission: `bootstrap/*.sh`, `gitops/{root,apps,values}`, `docs/*`, root `.gitignore`.

### 1.2 Terraform
- `terraform/platform`: S3 backend `pulse-platform-tfstate-047090857529-ap-south-1` / `platform/terraform.tfstate`, `encrypt=true`, `use_lockfile=true` (needs TF ≥1.10; installed 1.14.4).
- `terraform/bootstrap`: **local** state serial 5; creates bucket with `prevent_destroy=true`, versioning, SSE, public access block.
- Modules: `networking` (VPC/subnets/IGW/NAT/EIP/routes) and `eks` (3 IAM roles, OIDC, cluster, node group, 3 pinned add-ons).
- Day-01 dependency bug **already fixed** in code (`vpc_cni` addon before node group).
- `terraform init/validate/fmt -check/plan` → **success / No changes** (serial 33 remote state matches live).
- Stale plan files present → deleted (local artifacts only).

### 1.3 AWS live
- Account `047090857529` (`CLIUSER`), region `ap-south-1`.
- EKS `pulse-eks` ACTIVE, Kubernetes **1.37**, endpoint public + allowlist `103.171.55.70/32` (= current IP at inspection).
- Node group `pulse-eks-workers` ACTIVE, desired/min 2, max 3, t3.medium, 30 GB.
- Add-ons: `vpc-cni v1.23.2-eksbuild.8`, `kube-proxy v1.37.0-eksbuild.32`, `coredns v1.14.7-eksbuild.22`.
- NAT `nat-030343237f66f7b6a`, VPC `vpc-097e563648bf59d81` `10.20.0.0/16`.
- ECR `pulse-api` tags `1.0.0`, `1.0.1`.
- S3 state: versioning on, only `platform/terraform.tfstate`, no lock object (not mid-apply).

### 1.4 Kubernetes live
- Nodes 2/2 Ready (Amazon Linux 2023, containerd).
- ArgoCD chart `argo-cd-10.17.1` / app **v3.6.1**, ClusterIP, 7/7 pods; Application `pulse-api` **Synced/Healthy**.
- Helm: `metrics-server` 3.14.0 (no custom values), `monitoring` kube-prometheus-stack 93.1.1 rev 3 (values ≡ `observability/monitoring-values.yaml`).
- Namespaces: `argocd`, `pulse`, `monitoring`, `kube-system` (+ defaults).
- No HPA. No PVCs. No EBS CSI controller; stray CSIDriver `efs.csi.aws.com` (no EFS in Terraform — flagged).
- `helm get values argocd` → only `server.service.type=ClusterIP`.
- **From `argocd-repo-server`: `git ls-remote` to pulse-platform.git succeeded** (public repo + cluster egress OK).

### 1.5 Tooling
- terraform 1.14.4 · aws-cli 2.33.17 · kubectl 1.36.1 · helm **4.1.4** · git 2.45.2 · jq 1.8.1 · gh 2.92.0 authenticated `Mojojojo0222` with `repo` scope · `yq` absent (used Python PyYAML instead).

---

## 2. Decision record

| # | Decision | Alternatives | Rationale |
|---|----------|--------------|-----------|
| D1 | New **public** GitHub repo `pulse-platform-infra`; `git init` at `E:\Platform-Lab`; `application/` in `.gitignore` | Reuse pulse-platform; private infra repo | User choice; clean app vs platform separation; public → ArgoCD needs no credentials; private would require PAT Secret lifecycle |
| D2 | **No live Helm uninstall/adoption** of metrics-server/monitoring | Uninstall→ArgoCD; label adoption | User choice; avoids ownership conflicts and mid-project downtime; clean rebuild installs via GitOps |
| D3 | Full **destroy→rebuild** as final stage **only after explicit plan review + approval** | Skip rebuild; auto-destroy | User choice; satisfies acceptance criteria honestly; never auto-destroy |
| D4 | Root App of Apps `prune: false`, `selfHeal: true` | prune true | Prune is mass-delete; self-heal demonstrates drift correction safely |
| D5 | Chart versions **pinned** (93.1.1, 3.14.0, 10.17.1) | floating latest | Reproducible disaster recovery |
| D6 | Multi-source monitoring app (chart + `$values` + extras dir) | Separate values repo; inline values | Values versioned with manifests; one logical Application |
| D7 | ArgoCD bootstrap = **idempotent Helm in script** | Terraform helm provider; manual | Chicken-and-egg; script skips if release exists; Terraform stays AWS-only |
| D8 | `observability/*` and old `pulse-api-application.yaml` → **pointer comments** after copying into `gitops/` | Delete originals; leave duplicates | Avoid two “sources of truth”; keep paths in old notes resolvable |
| D9 | Destroy confirmation string `DESTROY-PULSE-PLATFORM`; up confirmation `APPLY` | `yes`/`-auto-approve` | User requirement; prevents muscle-memory destroy |
| D10 | Preserve bucket (bootstrap state + `prevent_destroy`), ECR (outside TF), GitHub | Include in platform state | User cost/lifecycle requirement; destroy script also **verifies** preservation |
| D11 | `.terraform.lock.hcl` **committed**; `*.tfstate`/`*.tfplan` ignored | ignore lock file | HashiCorp best practice for reproducible providers |
| D12 | No RDS, no PVC persistence now | Add DB/CSI early | Disposable lab cost goal; documented future lifecycle constraints |

---

## 3. Step-by-step execution log (this effort)

1. **Read-only sweep** — glob + read all TF/YAML/journals; no mutations.
2. **Live probes** — STS, EKS, nodes, apps, helm values, GitHub API, repo-server git probe, chart versions, IP allowlist, S3/ECR/NAT.
3. **Terraform verify** — `init`, `validate`, `fmt -check`, `plan -out` → No changes (plan file later removed).
4. **Presented findings + plan + risks/costs** to user; asked 3 architecture questions.
5. **User answered** → D1/D2/D3 locked.
6. **Cleanup** — deleted stale `*.tfplan`.
7. **`.gitignore`** — nested repo, state, plans, secrets; lock files kept.
8. **Directory scaffolding** — `gitops/{root,apps,values,monitoring-extras}`, `bootstrap/`, `docs/`.
9. **Wrote 5 GitOps manifests** + copied values/receiver into `gitops/`.
10. **Deprecated pointers** in `observability/` and old Application path.
11. **Wrote `platform-up.sh` (18 steps)** and **`platform-down.sh` (9 steps + guards)**.
12. **Validated** — `bash -n`, PyYAML, client dry-run, **server dry-run** of Applications (`pulse-api unchanged` proved spec parity with live).
13. **Secret scan** of intended commit set — clean; no tfstate/tfplan/application paths.
14. **Wrote 7 docs + this log + mentor guide.**
15. **Create GitHub repo + push** (see changelog for command output).
16. **Generate destroy plan for review** — *stops for user approval before any apply.*

---

## 4. Commands actually executed (inspection + validation)

```bash
# Identity / infra
aws sts get-caller-identity
aws eks describe-cluster --name pulse-eks ...
aws eks describe-nodegroup --cluster-name pulse-eks --nodegroup-name pulse-eks-workers ...
aws ecr describe-images --repository-name pulse-api ...
aws s3api get-bucket-versioning --bucket pulse-platform-tfstate-...
aws s3 cp s3://.../platform/terraform.tfstate -   # read-only state inventory

# Terraform (read-only)
terraform init && terraform validate && terraform fmt -check -recursive
terraform plan -no-color -out=inspection.tfplan   # "No changes" → file deleted

# Cluster
kubectl get nodes/ns/applications.argoproj.io/pods -A
helm list -A && helm get values <release> -n <ns>
kubectl exec -n argocd deploy/argocd-repo-server -- git ls-remote https://github.com/Mojojojo0222/pulse-platform.git HEAD
kubectl apply --dry-run=server -f gitops/root/platform-root.yaml -f gitops/apps/*.yaml

# Scripts / YAML
bash -n bootstrap/platform-up.sh && bash -n bootstrap/platform-down.sh
python -c 'yaml.safe_load_all(...)'   # all manifests
kubectl apply --dry-run=client -f application/k8s/ gitops/monitoring-extras/

# Repo hygiene
git add -n .   # staged list audit
grep -E 'AKIA|BEGIN PRIVATE|ghp_|tfstate|...' <files>   # secret scan → clean
```

---

## 5. Explicit non-actions (proof we didn’t touch the live stack)

| Action | Done? |
|--------|-------|
| `terraform apply` / `destroy` | **No** |
| `helm install/uninstall/upgrade` | **No** |
| `kubectl apply` without dry-run | **No** |
| Editing live Applications / Helm values | **No** |
| Deleting GitHub branches/repos | **No** |
| IAM policy changes | **No** |
| Creating RDS / PVCs / EBS CSI | **No** |

Dry-run server output (`created` / `unchanged`) is **admission rehearsal only** — nothing was persisted.

---

## 6. Open questions for future sessions

1. When to flip `prune: true` (checklist in GITOPS_ARCHITECTURE §9).
2. Karpenter vs Cluster Autoscaler once HPA load tests exist (recommendation framework in INTERVIEW_PREPARATION §8).
3. EBS CSI + storageSpec if metrics durability matters.
4. Webhook-based ArgoCD sync for sub-minute Git→cluster.
5. RDS layer design: separate state, snapshot policy, security groups, Secrets Manager — **before** any DB resource.
6. Clean `target/` out of `pulse-platform.git` (needs approval on that repo).

---

## 7. Where to look next

| Goal | File |
|------|------|
| Big picture diagram | `docs/PLATFORM_ARCHITECTURE.md` |
| Up/down mechanics | `docs/INFRASTRUCTURE_LIFECYCLE.md` |
| ArgoCD deep-dive | `docs/GITOPS_ARCHITECTURE.md` |
| Metrics/alerts deep-dive | `docs/OBSERVABILITY_ARCHITECTURE.md` |
| When something breaks | `docs/TROUBLESHOOTING_RUNBOOK.md` |
| Interview drills | `docs/INTERVIEW_PREPARATION.md` |
| What was verified when | `docs/IMPLEMENTATION_CHANGELOG.md` |
| Commands + techniques drill | `documentation/MENTOR_GUIDE.md` |
| Day 01/02 history | `documentation/journal/` |
