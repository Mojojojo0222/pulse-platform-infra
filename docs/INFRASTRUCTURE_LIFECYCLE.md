# Infrastructure Lifecycle — Terraform Up/Down, State, Cost

**Verified against live config:** 2026-11-10 · `terraform init/validate/plan` → **No changes** (serial 33 in remote state)

---

## 1. Two Terraform root configurations

| Root | Backend | State location | Lifetime | Purpose |
|------|---------|----------------|----------|---------|
| `terraform/bootstrap` | **local** | `terraform/bootstrap/terraform.tfstate` (serial 5) | Permanent | Creates the S3 bucket used as everyone else’s backend |
| `terraform/platform` | **S3** | `s3://pulse-platform-tfstate-047090857529-ap-south-1/platform/terraform.tfstate` | Disposable | VPC + EKS + IAM + add-ons |

**Why bootstrap cannot use the bucket it creates:** chicken-and-egg — the backend must exist before `init` can read it. Local state for the bucket is correct; the bucket resource carries `lifecycle { prevent_destroy = true }`.

**S3 backend settings (`backend.tf`):**
- `key = platform/terraform.tfstate` — object path inside the bucket
- `encrypt = true` — SSE-S3 at rest
- `use_lockfile = true` — writes `terraform.tfstate.lock` beside the state object (requires Terraform ≥ 1.10; you run 1.14.4). Prevents two concurrent applies.

---

## 2. Module structure & dependency graph

```text
terraform/platform (root)
├── data.aws_availability_zones.available  → picks first 2 AZs
├── module.networking
│   ├── aws_vpc
│   ├── aws_internet_gateway
│   ├── aws_subnet.public[0..1]
│   ├── aws_subnet.private[0..1]
│   ├── aws_route_table.public  + aws_route.public_internet (0.0.0.0/0 → IGW)
│   ├── aws_eip.nat
│   ├── aws_nat_gateway  (depends_on IGW; uses public[0])
│   ├── aws_route_table.private + aws_route.private_nat (0.0.0.0/0 → NAT)
│   └── aws_route_table_association.public/private[0..1]
└── module.eks  (vpc_id, subnet ids ← module.networking outputs)
    ├── aws_iam_role.cluster + attachment AmazonEKSClusterPolicy
    ├── aws_iam_role.node + attachments (WorkerNode, ECR-PullOnly)
    ├── aws_eks_cluster (depends_on cluster policy attachment)
    ├── data.tls_certificate → aws_iam_openid_connect_provider (IRSA)
    ├── aws_iam_role.vpc_cni + attachment AmazonEKS_CNI_Policy (IRSA trust)
    ├── aws_eks_addon.vpc_cni (service_account_role_arn = vpc_cni role)
    ├── aws_eks_node_group (depends_on node attachments + vpc_cni addon)
    ├── aws_eks_addon.kube_proxy (depends_on node group)
    └── aws_eks_addon.coredns   (depends_on node group)
```

### Implicit vs explicit dependencies

| Type | Example | Mechanism |
|------|---------|-----------|
| **Implicit** | subnet → VPC | Reference `aws_vpc.this.id` |
| **Implicit** | node group → cluster | Reference `aws_eks_cluster.this.name` |
| **Explicit** | node group → vpc-cni addon | `depends_on = [aws_eks_addon.vpc_cni]` — no attribute reference, but ordering required for correctness (Day-01 bug) |
| **Explicit** | cluster → cluster policy | `depends_on` on policy attachment (EKS validates IAM at create) |
| **Data source** | AZs, TLS cert for OIDC thumbprint, IAM policy documents | Read-at-plan-time; refresh each plan |

### Outputs (root `outputs.tf`)
`vpc_id`, subnet IDs, AZs, NAT public IP, cluster name/endpoint/OIDC issuer, node group name — consumed by humans/scripts; not cross-module for EKS (module passes values down as inputs instead).

---

## 3. Plan / apply / destroy lifecycle

```text
terraform init      → load backend + providers (aws 6.71.0, tls 4.4.2 locked)
terraform fmt      → style enforcement (CI-able with -check)
terraform validate  → schema/type checks (no AWS calls)
terraform plan     → refresh real infra + diff config ↔ state ↔ reality
                      -out=FILE freezes the decision
terraform apply FILE → execute EXACTLY that reviewed plan
terraform plan -destroy -out=FILE
terraform apply FILE → destroy what the plan listed (not "everything Terraform knows" blindly)
```

**Why `-out` plan files:** a plan is a snapshot. Applying the file guarantees you destroy/apply what you read, not what a re-plan might compute after drift.

### Destroy ordering (Terraform’s graph)

Rough reverse-dependency order:
1. Node group (and its EC2/EBS)
2. Add-ons (vpc-cni, kube-proxy, coredns)
3. EKS cluster
4. OIDC provider, CNI role
5. IAM roles/attachments (cluster, node)
6. NAT gateway → EIP → private/public routes & associations → subnets → IGW → VPC

Kubernetes objects are **not** individually destroyed by Terraform — deleting the cluster removes the API server that owns them.

---

## 4. `platform-up.sh` (command 1) — stage map

| Step | Action | Failure exit |
|------|--------|--------------|
| 1 | Prereqs: terraform, aws, kubectl, helm, git | 2 |
| 2 | `sts get-caller-identity` == `047090857529`, region `ap-south-1`, advisory IP-allowlist check | 3 |
| 3–6 | `init` → `fmt -check` → `validate` | 4 |
| 7–8 | `plan -out=platform-up.tfplan` + `show` | 4 |
| 9 | Interactive confirmation must be exactly `APPLY` | 5 |
| 10 | `apply platform-up.tfplan` | 6 |
| 11–12 | `aws eks update-kubeconfig` → `kubectl wait node Ready` (600s) | 7 |
| 13–14 | Idempotent ArgoCD: create ns if missing; `helm install` only if release absent; wait deployments; probe GitHub from repo-server | 8 |
| 15–16 | `kubectl apply` root app → poll children until Synced+Healthy (600s) | 9 |
| 17–18 | Verify rollouts, monitoring pods, Prometheus `up` query, print report | 10 |

**Idempotency rules:**
- Helm: `helm status argocd` exists → skip install (warn on version drift, never blind upgrade).
- Terraform: naturally idempotent — second run on existing infra → “No changes” plan → still requires typed `APPLY` (safe no-op).
- ArgoCD resources: `kubectl apply` on root is idempotent; children created by ArgoCD, not the script.

---

## 5. `platform-down.sh` (command 2) — guard rails

| Step | Guard | Exit |
|------|-------|------|
| 1 | terraform, aws, jq present | 2 |
| 2 | Account `047090857529`, region `ap-south-1` | 3 |
| 3 | In `terraform/platform`; `backend.tf` contains expected bucket **and** key; `head-object` confirms state exists in S3 | 3 / 8 |
| 4 | If cluster exists: ARN account+region+name must match `pulse-eks` | 3 |
| 5–6 | `init` + `plan -destroy -out=platform-down.tfplan` | 4 |
| 7 | `show` full destroy plan + banner listing removed vs preserved resources | — |
| 8 | User must type **`DESTROY-PULSE-PLATFORM`** (plain `yes` rejected) → `apply <planfile>` only | 5 / 6 |
| 9 | Verify: cluster ABSENT, VPC CIDR ABSENT; **bucket present, ECR present** | 7 / 8 |

**Preserved by construction:**
- State bucket lives in *bootstrap* state — not in `platform/terraform.tfstate`, so destroy never sees it.
- ECR + GitHub are outside Terraform entirely.
- Script refuses wrong account/region/bucket/key *before* generating a plan.

---

## 6. State management deep-dive

| Concept | In this project |
|---------|-----------------|
| **State file** | JSON mapping config addresses → cloud IDs |
| **Remote state** | S3 object; enables single source of truth across machines |
| **Locking** | `use_lockfile=true` → `terraform.tfstate.lock` object; concurrent apply fails fast |
| **Serial / version** | State serial 33 at inspection — increments each successful apply |
| **Drift** | `plan` refreshes via AWS API; differences appear as `+/-/~` |
| **Partial state after failed apply** | Possible — Terraform records what it created; re-run plan to see remainder. Never delete state manually to “fix” drift. |
| **State migration** | Changing `backend` requires `init -migrate-state`. **Not done and not planned** without explicit approval. |

**Never (without showing exact consequences + approval):** `state mv`, `state rm`, `state import`, `destroy`, backend changes, deleting the bucket.

---

## 7. Cost management

### Idle cost drivers (UP state)

| Resource | Approx. rate (ap-south-1) | Notes |
|----------|---------------------------|-------|
| EKS control plane | $0.10/h | Always on while cluster exists |
| NAT Gateway | $0.045/h + $0.045/GB | Biggest *avoidable* line |
| 2× t3.medium | ~$0.04–0.05/h each | On-demand |
| EBS 2×30 GB | ~$0.006/h combined | gp2/gp3 equivalent |
| S3 state + ECR images | pennies | Persistent, trivial |

### Policy
1. Run `platform-down.sh` when not practising → near-zero spend.
2. Rebuild with `platform-up.sh` (~15–25 min) when needed.
3. Do **not** keep a cluster “just in case” — that is the #1 EKS cost mistake.
4. Future: single NAT is already a cost optimization (vs per-AZ NAT); VPC endpoints would cut NAT data charges when traffic grows.

---

## 8. Failure modes & remediation

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `Error acquiring state lock` | Another apply running / stale lock | Confirm no teammate/CI; remove stale `terraform.tfstate.lock` **only** if sure no process holds it |
| `Backend configuration changed` | Edited `backend.tf` | `terraform init` (migrates if `-migrate-state` needed — ask first) |
| Plan wants to **replace** VPC/EKS | Config drift or accidental variable change | **STOP.** Do not apply. Diff plan; restore variable values |
| `AccessDenied` on S3 state | Wrong credentials/account | Re-check `sts get-caller-identity` |
| IP allowlist failure on `kubectl` | Home IP changed | Update `cluster_public_cidrs` variable, plan, apply (control-plane only, no replacement) |
| Node group `CREATE_FAILED` / NotReady | CNI/IRSA ordering (historical) | Ensure `depends_on` chain intact; check `aws-node` logs + `AWS_ROLE_ARN` |
| Destroy blocked by bucket | Wrong state / wrong directory | down script guards this; confirm you are in `terraform/platform` |

---

## 9. Acceptance evidence (this implementation)

| Check | Result |
|-------|--------|
| `terraform init` | **PASS** (providers re-used from lock: aws 6.71.0, tls 4.4.2) |
| `terraform validate` | **PASS** |
| `terraform fmt -check -recursive` | **PASS** |
| `terraform plan` | **PASS — “No changes”** (infra ≡ config) |
| `platform-up.sh` prereq + identity checks | Implemented; syntax `bash -n` **PASS** |
| `platform-down.sh` guards + confirm string | Implemented; syntax `bash -n` **PASS** |
| Full destroy→rebuild demonstration | **PENDING USER APPROVAL** (see IMPLEMENTATION_CHANGELOG) |
