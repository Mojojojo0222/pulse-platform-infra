# Pulse Platform — Architecture

**Status:** living document · **Last verified:** 2026-11-10 (inspection + automation implementation)
**Account/Region:** `047090857529` / `ap-south-1` · **Cluster:** `pulse-eks` (Kubernetes 1.37)

---

## 1. High-level view

```text
 Developer laptop (Windows / Git Bash)
   │
   │  ./bootstrap/platform-up.sh
   │  ./bootstrap/platform-down.sh
   ▼
┌────────────────────────── Terraform ──────────────────────────┐
│  terraform/bootstrap  (local state)                           │
│    └─ S3 state bucket  [PERSISTENT — prevent_destroy]         │
│  terraform/platform   (S3 remote state + lockfile)            │
│    ├─ module.networking  VPC, subnets, IGW, NAT, EIP, routes │
│    └─ module.eks         IAM, OIDC/IRSA, cluster, node group, │
│                          add-ons (vpc-cni, kube-proxy, coredns)│
└───────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────── AWS EKS pulse-eks ────────────────────┐
│  Control plane (managed by AWS)                               │
│  2× t3.medium workers in PRIVATE subnets (NAT for egress)     │
│                                                                │
│  ┌───────────── ArgoCD (Helm-bootstrapped, self-managed) ───┐ │
│  │  pulse-platform-root  (App of Apps → gitops/apps/)       │ │
│  │    ├─ Application pulse-api       → pulse-platform.git   │ │
│  │    │                                path k8s/             │ │
│  │    ├─ Application metrics-server  → Helm chart 3.14.0     │ │
│  │    └─ Application monitoring      → multi-source:        │ │
│  │         chart kube-prometheus-stack 93.1.1               │ │
│  │         + values from pulse-platform-infra.git           │ │
│  │         + manifests gitops/monitoring-extras/            │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                │
│  namespaces: argocd · pulse · monitoring · kube-system        │
└───────────────────────────────────────────────────────────────┘
                              ▲
                              │ clone / watch (public HTTPS)
┌──────────────── GitHub ──────┴───────────────────────────────┐
│  pulse-platform.git        app code + k8s/ manifests          │
│  pulse-platform-infra.git  terraform + gitops + docs + scripts│
└───────────────────────────────────────────────────────────────┘

 External (out of band, NOT Terraform-managed):
   ECR pulse-api  ← docker push from laptop (IAM user CLIUSER)
```

---

## 2. Two planes: artifact vs intent

| Plane | Question it answers | Path |
|-------|---------------------|------|
| **Artifact** | “What binary runs?” | `application/` → `mvn` → Docker → **ECR** `pulse-api:1.0.1` → nodes pull via instance role |
| **Intent** | “What should the cluster look like?” | **GitHub YAML** → **ArgoCD** reconciles live cluster → pods |

You can change the image (artifact) without touching GitOps, and change replicas/probes (intent) without rebuilding the image. Interview soundbite: *“ECR is the package registry; Git is the desired-state source; ArgoCD is the reconciler; Terraform is the infrastructure provisioner.”*

---

## 3. Networking design

- **VPC** `10.20.0.0/16`, two AZs (ap-south-1a/1b).
- **Public subnets** `10.20.0.0/20`, `10.20.16.0/20` — NAT Gateway + (future) internet-facing LBs. Tagged `kubernetes.io/role/elb=1`.
- **Private subnets** `10.20.32.0/20`, `10.20.48.0/20` — worker nodes. Tagged `kubernetes.io/role/internal-elb=1`.
- **Single NAT Gateway** in public[0] with an Elastic IP. Private route table: `0.0.0.0/0 → NAT`.
- **Why private nodes need NAT:** nodes have no public IPs; they must reach ECR, S3, the EKS API (private endpoint), GitHub (for image layers / via NAT), and AWS APIs. Pods inherit this egress path through the node’s ENI unless a VPC endpoint or second CNI hop is used.
- **Cost note:** NAT Gateway is one of the two biggest idle-cost items (≈ $0.045/h + data). Destroying the lab removes it.

### Why workers are private, API is public-but-allowlisted

- Workers in private subnets: no accidental SSH/public exposure, standard AWS EKS guidance.
- Control-plane endpoint: `endpoint_public_access=true` with `public_access_cidrs=["<your-ip>/32"]` so *your laptop* can run `kubectl` without a bastion. Private access is also enabled for in-VPC consumers.
- **Fragility:** if your public IP changes, `kubectl`/Terraform EKS reads fail until the CIDR variable is updated. `platform-up.sh` warns when `checkip.amazonaws.com` ≠ allowlist.

---

## 4. EKS / IAM design

| Role | Trust | Policies | Used by |
|------|-------|----------|---------|
| `pulse-eks-cluster-role` | `eks.amazonaws.com` | `AmazonEKSClusterPolicy` | EKS control plane |
| `pulse-eks-node-role` | `ec2.amazonaws.com` | `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryPullOnly` | EC2 workers (join cluster + pull ECR) |
| `pulse-eks-vpc-cni-role` | OIDC federated, condition `sub=system:serviceaccount:kube-system:aws-node` | `AmazonEKS_CNI_Policy` | **only** the `aws-node` SA via IRSA |

**Key separation:** CNI permissions are *not* on the node role. The `aws-node` pod assumes `pulse-eks-vpc-cni-role` through Kubernetes service-account token projection → OIDC provider → STS `AssumeRoleWithWebIdentity`. This is IRSA (IAM Roles for Service Accounts).

**Order dependency (Day-01 incident):** node group must start only *after* the managed `vpc-cni` add-on + IRSA role exist, otherwise `aws-node` cannot call EC2 ENI APIs → no pod IPs → nodes `NotReady` → `CREATE_FAILED`. Fixed via `depends_on` in `modules/eks/main.tf`.

**Add-ons pinned** (not “latest”): `vpc-cni v1.23.2-eksbuild.8`, `kube-proxy v1.37.0-eksbuild.32`, `coredns v1.14.7-eksbuild.22`. `bootstrap_self_managed_addons=false` so Terraform owns them.

**OIDC:** cluster issuer URL → `tls_certificate` data source thumbprint → `aws_iam_openid_connect_provider`. Needed for any IRSA (CNI now; Karpenter/cluster-autoscaler later).

---

## 5. GitOps design (summary — full detail in GITOPS_ARCHITECTURE.md)

- **App of Apps:** one root Application (`pulse-platform-root`) points at `gitops/apps/` in `pulse-platform-infra.git`. Every YAML there that is an `Application` becomes a managed child.
- **Child apps:**
  - `pulse-api` → app repo `pulse-platform.git`, path `k8s`, auto-sync + selfHeal, **prune=false**.
  - `metrics-server` → Helm repo `kubernetes-sigs.github.io/metrics-server`, chart pinned `3.14.0`.
  - `monitoring` → **multi-source**: chart `kube-prometheus-stack 93.1.1` + `$values` from Git + raw manifests dir for the alert receiver.
- **Bootstrap asymmetry:** ArgoCD *itself* is installed by Helm inside `platform-up.sh` (chicken-and-egg: something must exist before GitOps can run). Everything *after* ArgoCD is GitOps.

```text
platform-up.sh
  ├─ Terraform apply          (infrastructure)
  ├─ helm install argocd      (bootstrap only, idempotent skip if present)
  ├─ kubectl apply root app   (single GitOps entrypoint)
  └─ wait children Synced/Healthy
```

---

## 6. Observability design (summary — full detail in OBSERVABILITY_ARCHITECTURE.md)

- **Prometheus Operator** stack via `kube-prometheus-stack-93.1.1`.
- **Metrics Server** provides the Kubernetes **Metrics API** (`metrics.k8s.io`) — required by HPA and `kubectl top`. Prometheus does *not* serve that API; they solve different problems (autoscaling signal vs long-term TSDB/alerting).
- **Custom rule** `PulsePodCrashLooping` (restarting containers in 2m) → Alertmanager route (severity=critical) → webhook `http://monitoring-alert-routing-svc.monitoring.svc:8089` → Python listener returns HTTP 200 (verified Day 02).
- **No persistence** (by design for disposable lab): Grafana persistence off, Prometheus `storageSpec: {}`, retention 12h / 2GB cap.

---

## 7. Lifecycle & cost model

| State | What runs | Approx. idle cost |
|-------|-----------|-------------------|
| **UP** (lab in use) | EKS CP + 2× t3.medium + NAT + EBS | ≈ **$0.25–0.35/h** (~$6–8/day) |
| **DOWN** (destroyed) | only S3 state bucket + ECR storage + GitHub | ≈ **pennies/day** |

**Persistent by design:** S3 state bucket (bootstrap layer, `prevent_destroy`), ECR repo+images, GitHub repos, local files.
**Disposable:** everything inside `terraform/platform` state — VPC through node group and all Kubernetes objects (they die with the cluster).

**Why RDS cannot live inside this disposable VPC (future note):** `terraform destroy` deletes subnets/NAT/VPC. An RDS instance in those subnets would either block destroy (dependency) or be destroyed with them. RDS needs its **own state layer** (or explicit `prevent_destroy` + moved lifecycle) and a VPC that outlives the lab — to be designed before any database is introduced. *No RDS exists today.*

---

## 8. Repository layout

```text
Platform-Lab/                          ← git: pulse-platform-infra (public)
├── bootstrap/
│   ├── platform-up.sh                 ← bring-up orchestration
│   └── platform-down.sh               ← guarded destroy
├── terraform/
│   ├── bootstrap/                     ← state bucket (local backend, persistent)
│   └── platform/                      ← VPC+EKS (S3 backend, disposable)
├── gitops/
│   ├── root/platform-root.yaml        ← App of Apps
│   ├── apps/*.yaml                    ← child Applications
│   ├── values/monitoring-values.yaml  ← Helm values from Git
│   └── monitoring-extras/             ← alert receiver manifests
├── observability/                     ← deprecated pointers → gitops/
├── application/                       ← SEPARATE git repo: pulse-platform.git
├── documentation/                     ← journals + implementation log + mentor guide
└── docs/                              ← architecture & runbooks (this folder)
```

---

## 9. Design trade-offs (interview-ready)

| Decision | Alternative | Why this way |
|----------|-------------|--------------|
| Single S3 state for VPC+EKS | Split state per layer | Lab simplicity; destroy is one plan; split-state migration risk not justified yet |
| Private nodes + single NAT | Public nodes / VPC endpoints | Cost + security baseline; endpoints can be added later for S3/ECR/STS |
| ArgoCD bootstrap via Helm script | Terraform helm provider / kubectl manifests | Keeps Terraform focused on AWS resources; ArgoCD lifecycle separate and idempotent in script |
| App of Apps | ApplicationSet only | Explicit files are easier to teach/audit; ApplicationSet better for many similar apps (future) |
| `prune: false` everywhere | `prune: true` | Prune deletes cluster objects missing from Git — dangerous until inventory is trusted |
| Chart versions pinned | `latest` | Reproducible rebuilds; floating versions break clean-room restore |
| No RDS yet | Add DB now | Persistent DB contradicts “destroy when idle” cost goal until lifecycle layer exists |
