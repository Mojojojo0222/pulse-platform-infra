# Interview Preparation — Pulse Platform

Use this to answer platform/DevOps/SRE questions **from your own project**, not generic scripts. Each section: spoken answers, trade-offs, failure stories, and drill questions.

---

## 1. Elevator pitch (60 seconds)

> “I built **Pulse Platform**: an AWS EKS lab on Terraform with a fully GitOps-managed application stack. Terraform provisions a two-AZ VPC with private workers behind a NAT, an EKS cluster with IRSA-scoped CNI permissions, and pinned add-ons. **ArgoCD** bootstraps from there via an **App of Apps** — one root Application discovers child apps for a Spring Boot API (image from ECR), Metrics Server, and a multi-source Prometheus/Grafana/Alertmanager stack with custom alert rules and a webhook receiver. The whole disposable environment is torn down and rebuilt with two guarded scripts; the state bucket, ECR, and GitHub stay permanent. I can show you the destroy plan, the reconciliation loop, and the Day-01 IRSA ordering incident I root-caused.”

---

## 2. Terraform

### Q: How does Terraform know what exists?
**A:** State file maps addresses (`module.eks.aws_eks_cluster.this`) to cloud IDs. `plan` = refresh via cloud API + diff config ↔ state ↔ reality. We use **S3 remote state** with `use_lockfile` so teammates/CI can’t double-apply; bootstrap uses **local state** because the bucket can’t be its own backend (chicken-and-egg).

### Q: Why is `depends_on` on the node group necessary if Terraform already sees references?
**A:** References create edges only when attributes flow. The node group doesn’t *consume* the CNI add-on’s attributes — it needs *ordering* for **runtime correctness**: without the managed add-on + IRSA first, `aws-node` can’t allocate ENIs, nodes never become Ready. I hit this: `CREATE_FAILED`, CrashLoop on aws-node, no `AWS_ROLE_ARN`. Explicit `depends_on` + IRSA policy was the fix. **Identity and order are both required.**

### Q: What’s the blast radius of `terraform apply` here?
**A:** One root = VPC + EKS + IAM. Replacement of the VPC would cascade (subnets, NAT, cluster). That’s why: review plan files, refuse surprise replacements, destroy only via the guarded script with a typed confirmation string, and keep bootstrap/bucket in a **separate state** so destroy can’t reach it.

### Q: Why private subnets for nodes?
**A:** No public IPs → not SSH-able from internet; egress via **single NAT** (cost/security trade-off). API endpoint is public but **IP-allowlisted** so my laptop can kubectl without a bastion. Trade-off: allowlist breaks when my IP changes — I detect that in the up-script.

### Q: Explain IRSA in one breath.
**A:** Kubernetes SA token projected into the pod → OIDC provider in IAM trusts the cluster issuer → STS `AssumeRoleWithWebIdentity` with condition on `system:serviceaccount:kube-system:aws-node` → narrowly scoped role with `AmazonEKS_CNI_Policy`. Node role deliberately does **not** have CNI permissions.

---

## 3. EKS & Kubernetes internals

### Q: Control plane vs worker responsibilities?
**A:** AWS runs API server, etcd, scheduler, controller-manager (managed). Workers run kubelet, kube-proxy, container runtime, your pods, and **kube-system** DaemonSets (aws-node, node-exporter). Networking data path: pod ENI ← node ENI ← VPC routes; Services = kube-proxy DNAT to endpoints.

### Q: Why was CoreDNS Pending in my incident?
**A:** It needs nodes to schedule **and** cluster networking working. Nodes were NotReady because CNI had no IAM/ENI path → dependency cascade. Fixing CNI IRSA + ordering unblocked nodes → CoreDNS scheduled.

### Q: How do pods get IPs?
**A:** VPC CNI (`aws-node`) calls EC2 `AssignPrivateIpAddresses` via **its IRSA role**, attaches secondary ENIs to the node, assigns IPs from subnet CIDR. Failure mode = exactly my Day-01 bug.

---

## 4. GitOps / ArgoCD

### Q: What is the App of Apps?
**A:** A root Application whose `path` contains **Application manifests**. The controller creates/manages those CRs; each child then reconciles its own resources. Benefits: one bootstrap entrypoint, per-app sync policies, directory = inventory. Cost: indirection when debugging (“why no child?” → root status/logs).

### Q: Sync status vs health status?
**A:** Sync = live matches Git. Health = workloads actually okay. Synced+Degraded = YAML applied, pods broken. OutOfSync+Healthy = drift but old version still runs. Interviewers love this distinction.

### Q: What does `selfHeal` do that `automated` doesn’t?
**A:** `automated` applies when Git is newer than cluster. `selfHeal` also reverts **live** changes that diverge from Git (someone `kubectl edit`ed). `prune` deletes live objects removed from Git — **I keep it false** because premature prune is a mass-delete foot-gun; CRDs make it worse.

### Q: How does multi-source Helm + Git values work?
**A:** `sources[]` list: chart repo source references `$values/...` paths; a second source with `ref: values` (no path) exposes that repo’s root as `$values`. Never mix `source` and `sources`. I pin chart versions (`93.1.1`, `3.14.0`) so rebuilds are reproducible.

### Q: Why bootstrap ArgoCD with Helm in a script instead of GitOps?
**A:** Chicken-and-egg: GitOps needs a controller first. Script installs ArgoCD **idempotently** (skip if release exists); everything after is GitOps. Alternative — Terraform helm provider — couples cluster add-on lifecycle to infra state; I kept layers separate on purpose.

### Q: Git push → how long until sync?
**A:** Poll (~repo refresh interval) unless webhook. Demo used `argocd.argoproj.io/refresh=hard`. Production: notifications/webhook + PR flow.

### Q: How did you avoid two owners for monitoring?
**A:** Helm release already owned the objects. Options: uninstall+reinstall (gap), label adoption (fragile ~100 objects), or **clean rebuild** (chosen): manifests validated with server dry-run; ArgoCD installs on empty cluster after approved destroy. Never dual-manage.

---

## 5. Observability

### Q: HPA needs Prometheus or Metrics Server?
**A:** **Metrics Server** — it serves the Kubernetes **Metrics API**; HPA controller reads it. Prometheus is a TSDB with PromQL for alerting/dashboards; it doesn’t implement `metrics.k8s.io`. `kubectl top` also uses Metrics Server.

### Q: Walk me through your alert.
**A:** `kube-state-metrics` exposes restart counters → Prometheus rule `increase(kube_pod_container_status_restarts_total[2m]) > 0`, `for: 30s`, severity critical → Alertmanager groups (`alertname, namespace, pod`) → webhook receiver `monitoring-alert-routing-svc:8089` with `send_resolved: true` → Python listener logs payload, returns 200. Tested firing **and** resolved.

### Q: Why no persistent storage?
**A:** Disposable lab; `storageSpec: {}` + Grafana persistence off; **no EBS CSI** installed — PVCs would Pending. Conscious trade-off; durability path documented (add-on + IRSA + storageSpec).

---

## 6. Cost & lifecycle

### Q: What does this cost idle, and what did you do about it?
**A:** ~$0.25–0.35/h (EKS CP $0.10 + NAT ~$0.045 + 2× t3.medium + EBS) ≈ $6–8/day if left up. Two scripts: destroy disposable stack (typed `DESTROY-PULSE-PLATFORM`), keep bucket/ECR/GitHub; rebuild on demand. NAT and EKS CP are the big lines — destroy is the real saver.

### Q: Why can’t RDS live in this VPC?
**A:** Destroy deletes subnets/VPC; RDS either blocks destroy or dies with it. Databases need an **independent state layer** and lifecycle policy (snapshot before destroy, `prevent_destroy`). Not introducing RDS until that design exists.

---

## 7. Failure stories (STAR format)

### Day-01 CNI ordering
- **Situation:** First `terraform apply` of EKS.
- **Task:** Healthy nodes.
- **Action:** Observed aws-node CrashLoop, empty `list-addons`, nodes NotReady; traced to self-managed CNI without IRSA and wrong `depends_on`; fixed role+attachment ordering; targeted add-on apply then full apply (node group replaced).
- **Result:** 2 Ready nodes; lesson: **fix identity and order together**; documented in journal.

### First ArgoCD sync “already exists”
- **Situation:** pulse-api manifests applied manually then by ArgoCD.
- **Action:** Deleted Deployment+Service so ArgoCD could recreate with tracking metadata.
- **Result:** Synced/Healthy; lesson: single ownership; prefer GitOps from day one or careful adoption.

### Alert webhook
- **Situation:** Prove Alertmanager delivery end-to-end.
- **Action:** Custom rule + receiver Deployment; triggered crash loop; observed POST + 200; resolved notification also received.
- **Result:** Full fire/resolve path verified.

---

## 8. Design trade-off drills (expect “why not…”)

| Challenge | Your answer |
|-----------|-------------|
| “Why not ApplicationSet for everything?” | Explicit files easier to audit/teach; ApplicationSet shines for N identical apps / generators (future) |
| “Why not Cluster Autoscaler now?” | Managed node group already; CA is simpler with MNG; **Karpenter** better for learning modern packing + start-up, but adds NodeClass/NodePool/IAM/interruption complexity — recommend **one**, not both; defer until HPA needs it |
| “Why public GitHub?” | ArgoCD needs no PAT; portfolio visibility; secrets scan before push. Private would need repo Secret management |
| “Why one state file for VPC+EKS?” | Lab simplicity, one destroy; split states = migration risk without multi-team need |
| “Why pinned add-on/chart versions?” | Reproducible clean rebuild; floating `latest` breaks disaster recovery |

---

## 9. Live demo script (when asked “show me”)

```bash
# 1. Infra truth
terraform -chdir=terraform/platform plan          # No changes

# 2. GitOps truth
kubectl get applications.argoproj.io -n argocd
kubectl get application pulse-api -n argocd -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'

# 3. Drift self-heal demo
kubectl patch deploy pulse-api -n pulse --type merge -p '{"spec":{"replicas":1}}'
# wait → selfHeal returns replicas to 2 from Git

# 4. Observability
kubectl top nodes
kubectl get prometheusrules -n monitoring
kubectl logs -n monitoring deploy/monitoring-alert-validator --tail=5

# 5. Guard rails (DO NOT complete destroy in interview unless intended)
sed -n '1,80p' bootstrap/platform-down.sh   # show confirmation string + preserves
```

---

## 10. Question bank — answer without notes

1. Draw the request path from `curl` to pod (Service → endpoints → kube-proxy → node → pod).
2. What breaks if I delete the OIDC provider? (all IRSA: CNI, future Karpenter)
3. Difference between `maxUnavailable: 0` and PDB in my deployment?
4. Why does destroy remove Kubernetes objects “for free”?
5. How would you add HTTPS ingress? (LB/Ingress + SG + cert manager — not built yet)
6. How do you roll back a bad GitOps release vs bad image tag?
7. When would you enable `prune: true` and what checklist do you use?
8. How does NAT bill compare to 2 NAT gateways?
9. What does `ServerSideApply=true` change about conflicts?
10. How would you promote the same manifests to a second cluster? (new destination / ApplicationSet)

---

## 11. Answers to the above (abbrev.)

1. Service ClusterIP → iptables/ipvs DNAT → ready pod IPs on node; node forwards to pod veth.
2. aws-node can’t AssumeRoleWithWebIdentity → no ENIs → NotReady cascade.
3. RollingUpdate zero-downtime surge; PDB protects voluntary disruption (drain/node upgrade) separately.
4. Cluster delete tears down API server + etcd; objects cease to exist; Terraform doesn’t iterate pods.
5. Internet Gateway path exists; need Ingress controller + ACM/cert-manager + SG rules + DNS.
6. Image: `rollout undo` or retag ECR; GitOps: `git revert` (preferred — auditable).
7. After trusted inventory, CI, narrow path, PruneLast, CRD awareness, blast-radius review.
8. One NAT ≈ $0.045/h + data; two ≈ double fixed cost; AZ resilience vs lab budget.
9. SSA: fewer conflicts, field managers, can adopt fields; still need correct force conflicts for some CRDs.
10. Add Application with other `destination.server`/context; keep same source; secrets per cluster if private.
