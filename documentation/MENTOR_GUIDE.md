# Mentor Guide — What We Built, How, and How to Outshine in Interviews

**Audience:** you, before a Platform Engineer / DevOps / SRE interview.
**How to use:** don’t memorize — **re-perform**. Each module has: concept → command → what “good” looks like → interview line → drill.

---

## 0. The mental model (print this)

```text
INTENT (Git)                    ARTIFACT (registry)              RUNTIME (cluster)
pulse-platform-infra.git   →    (platform YAML)             →    ArgoCD reconciles
pulse-platform.git k8s/    →                              →    same
application/ code → mvn → docker → ECR pulse-api:1.0.1  →  nodes pull by tag

CONTROL (Terraform)             DATA PLANE
VPC / IAM / EKS / nodes    →    pods, Services, probes, metrics
state in S3 + lockfile          observability in-cluster
```

**One-liner:** *Terraform builds the house, Git is the blueprint, ArgoCD is the contractor that keeps the house matching the blueprint, ECR delivers the furniture, Prometheus is the smoke detector.*

---

## 1. Infrastructure as Code (Terraform)

### 1.1 What we did
Two roots: `bootstrap` (local state → S3 bucket) and `platform` (S3 state → VPC+EKS). Modules `networking` + `eks`. Plan/apply with typed confirmation; destroy only via guarded script.

### 1.2 Commands to own
```bash
cd terraform/platform
terraform init          # backend + providers
terraform fmt -check    # style gate
terraform validate      # static
terraform plan -out=tf.plan
terraform show tf.plan
terraform apply tf.plan
terraform plan -destroy -out=d.plan
```

### 1.3 Concepts you must explain cold
| Concept | Your sentence |
|---------|----------------|
| State | JSON inventory mapping `aws_vpc.this` → `vpc-097e...` |
| Remote state | S3 object so all operators share one truth |
| Locking | `use_lockfile` writes `.lock` object; second apply fails fast |
| Refresh | Plan re-reads cloud APIs to detect drift |
| Implicit dep | Attribute reference `aws_vpc.this.id` |
| Explicit dep | `depends_on` when no attribute flows but order matters (CNI→nodes) |
| Data source | Read-only lookup (AZs, TLS thumbprint, IAM policy JSON) |
| Lifecycle | `prevent_destroy` on state bucket; replacement shown as `-/+` in plan |
| Backend migration | `init -migrate-state` — never casually |

### 1.4 Failure you can narrate (Day 01)
Nodes NotReady → `aws-node` CrashLoop → no IRSA → no ENI API access → `CREATE_FAILED`.
**Fix = identity (IRSA role/policy) + order (add-on before node group).**
Interview gold: *“Fixing only the policy or only the order is insufficient.”*

### 1.5 Drill
1. What happens if two people `terraform apply` at once without locking?
2. Why is bootstrap local-state instead of S3?
3. Show me on the plan where VPC would be *replaced* vs *updated*.

---

## 2. AWS Networking & EKS

### 2.1 Commands
```bash
aws ec2 describe-vpcs --filters Name=cidr-block,Values=10.20.0.0/16
aws ec2 describe-route-tables --filters Name=vpc-id,Values=<id>
aws ec2 describe-nat-gateways --filter Name=state,Values=available
aws eks describe-cluster --name pulse-eks
aws eks describe-nodegroup --cluster-name pulse-eks --nodegroup-name pulse-eks-workers
aws eks list-addons --cluster-name pulse-eks
kubectl get nodes -L topology.kubernetes.io/zone,topology.kubernetes.io/instance-type
```

### 2.2 Concepts
- **Public subnet:** route to IGW; instances can get public IPs (NAT lives here).
- **Private subnet:** route to NAT only; workers here (no public IP).
- **Why NAT:** egress to ECR/S3/GitHub/AWS APIs for private nodes/pods.
- **EKS split:** AWS runs control plane; you run workers + kube-proxy + CNI + CoreDNS + your apps.
- **IAM triangle:** cluster role / node role / CNI role via IRSA (see §1.4).
- **Add-on pinning:** exact `eksbuild` versions for reproducibility.

### 2.3 Packet path (draw on whiteboard)
```text
pod A (10.20.x) → node ENI → VPC route → node B ENI → pod B
Service ClusterIP → kube-proxy DNAT → ready pod IPs
Egress: pod → node ENI → private RT → NAT → IGW → internet
```

### 2.4 Drill
1. Why tag subnets `kubernetes.io/role/elb` vs `internal-elb`?
2. What breaks if private RT loses `0.0.0.0/0 → nat`?
3. Difference between cluster endpoint private vs public access?

---

## 3. GitOps with ArgoCD

### 3.1 Commands
```bash
kubectl get applications.argoproj.io -n argocd -o wide
kubectl get application pulse-api -n argocd -o yaml | sed -n '/status:/,$p'
kubectl annotate applications.argoproj.io pulse-api -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
kubectl logs -n argocd deploy/argocd-application-controller --tail=100
kubectl logs -n argocd deploy/argocd-repo-server --tail=50
helm list -n argocd
```

### 3.2 Concept ladder (say it in this order)
1. **Git = desired state.**
2. **Application CR** binds repo+revision+path → cluster+namespace.
3. **Controller loop:** clone → render → diff → set Sync/Health → apply if automated.
4. **selfHeal** reverts live drift; **prune** deletes what left Git (we keep **false**).
5. **App of Apps:** root path contains Applications → platform inventory as code.
6. **Helm source:** ArgoCD renders chart (no Tiller); **pin** chart version.
7. **Multi-source:** chart + `$values` from `ref:` + raw manifests directory.
8. **Bootstrap:** script installs ArgoCD (Helm), then `kubectl apply` root — everything after is GitOps.

### 3.3 Sync vs Health (30-second answer)
> “Sync tells you whether the cluster matches Git; Health tells you whether the workloads are actually functioning. You can be Synced and Degraded, or OutOfSync and Healthy — so production dashboards need both.”

### 3.4 Adoption story
Helm already owned monitoring/metrics-server. Dual ownership = conflicts. We **chose clean rebuild**: validate with server dry-run now; ArgoCD installs on empty cluster after approved destroy. Rejected: uninstall (gap), label-stamping ~100 objects (fragile).

### 3.5 Drill
1. Push to Git — when does the cluster change? How do you force it?
2. Why never both `source` and `sources`?
3. What does the root Application deploy — pods or Applications?
4. When would you set `prune: true`, and what’s your checklist?

---

## 4. Observability

### 4.1 Commands
```bash
kubectl top nodes && kubectl top pods -n pulse
kubectl get prometheusrules -n monitoring
kubectl get pods -n monitoring
kubectl logs -n monitoring deploy/monitoring-alert-validator -f
# Prometheus API inside cluster:
kubectl exec -n monitoring prometheus-monitoring-kube-prometheus-prometheus-0 \
  -c prometheus -- wget -qO- 'localhost:9090/api/v1/query?query=up' | jq .
```

### 4.2 The #1 confusion (HPA)
| | Metrics Server | Prometheus |
|--|----------------|------------|
| API | `metrics.k8s.io` | PromQL `:9090` |
| Used by | **HPA**, `kubectl top` | Grafana, Alertmanager, humans |
| Storage | none | TSDB |

> “HPA cannot read Prometheus — different API surface. That’s why both exist in the stack.”

### 4.3 Alert pipeline (say the chain)
`ksm restart counter → PromQL increase[2m] > 0 → for:30s → Alertmanager group/route → webhook :8089 → 200 + send_resolved`

### 4.4 Trade-off you chose
No persistence, no EBS CSI → simpler disposable lab; PVC would Pending today. Documented path: add-on + IRSA + storageSpec.

### 4.5 Drill
1. Why `for: 30s` instead of firing instantly?
2. How do you prove Alertmanager got a *resolved* notification?
3. What’s one thing node-exporter sees that kube-state-metrics doesn’t?

---

## 5. Cost engineering

```text
UP:   EKS CP $0.10/h + NAT $0.045/h + 2×t3.medium + EBS  ≈ $0.25–0.35/h
DOWN: S3 + ECR + GitHub                                   ≈ pennies
```

**Policy:** destroy when idle; rebuild in ~20 min; never “keep it just in case.”
**Script:** `platform-down.sh` shows full destroy plan, requires `DESTROY-PULSE-PLATFORM`, then **verifies** bucket + ECR survived.

**Interview line:** *“I treat the cluster as a cattle-shaped battery: expensive while plugged in, free when unplugged; only durable assets are state, images, and Git.”*

---

## 6. Scripting & safety patterns (steal these)

| Pattern | Where | Why |
|---------|-------|-----|
| `set -euo pipefail` | both scripts | fail fast, no unset vars |
| Numeric exit codes | 0–10 / 0–8 | automation-friendly errors |
| Account/region assertion | up + down | never touch wrong account |
| Backend string assert + `head-object` | down | wrong state dir = refuse |
| `plan -out` then `apply file` | both | execute what you reviewed |
| Typed `APPLY` / `DESTROY-PULSE-PLATFORM` | both | no muscle-memory accidents |
| Idempotent Helm (`helm status` first) | up | no duplicate releases |
| Wait loops with timeout + on-fail logs | up | debuggable CI-style |
| Post-destroy preservation checks | down | prove bucket/ECR still exist |

```bash
# Rehearse safely anytime (no apply):
bash -n bootstrap/platform-up.sh
bash -n bootstrap/platform-down.sh
terraform -chdir=terraform/platform plan
```

---

## 7. Git hygiene & secrets

```bash
git add -n .                          # dry-run staged list
grep -RInE 'AKIA[0-9A-Z]{16}|BEGIN .*PRIVATE KEY|ghp_[A-Za-z0-9]+' .
# lock files: COMMIT .terraform.lock.hcl
# never commit: *.tfstate, *.tfplan, .terraform/, terraform.tfvars, application/
```

**Interview line:** *“I audit the staged file list and pattern-scan before first push; state files are worse than source secrets because they contain full resource inventories and sometimes embedded secrets.”*

---

## 8. Incident response framework (use on any outage)

```text
1. Layer:  Terraform → AWS → nodes → system pods → ArgoCD → app
2. Signal: status codes, events, logs (kubectl describe before kubectl edit)
3. Change: git log / helm history / terraform plan / last deploy
4. Blast:  what else shares this failure domain?
5. Fix:    smallest reversible action; then document in runbook
6. Verify: same triage commands show healthy baseline
```

**Your Day-01 story fits this framework perfectly — rehearse it until 90 seconds.**

---

## 9. Mock interview question set (answer out loud)

1. Walk me through `./bootstrap/platform-up.sh` from click to healthy pods.
2. What does `terraform plan` compare, and what does state contain?
3. Why did I need `depends_on` for the node group when references exist?
4. Explain IRSA with the exact trust condition on my CNI role.
5. App of Apps: what does the root deploy? What does prune=false mean?
6. Multi-source Application: how does `$values` resolve?
7. Why Metrics Server *and* Prometheus?
8. How is the crash-loop alert routed to the webhook?
9. What does `platform-down.sh` refuse to do, and why?
10. If kubectl suddenly times out, what’s your first three commands?
11. How would you add node autoscaling — Karpenter or CA — and why?
12. Why can’t RDS live in this VPC today?

### Answer skeletons
1. prereqs → identity → init/fmt/validate/plan → typed APPLY → apply plan → kubeconfig → wait nodes → idempotent ArgoCD → apply root → wait children → verify/report.
2. config ↔ state ↔ cloud (refresh); state = addresses→IDs + attributes + metadata + serial.
3. No attribute edge; runtime ordering for CNI/IRSA or nodes join broken.
4. Federated OIDC + `StringEquals` on `sub=system:serviceaccount:kube-system:aws-node` + aud `sts.amazonaws.com`.
5. Applications (CRs); live objects stay until you enable prune deliberately.
6. Source with `ref: values` exposes repo root as `$values`; valueFiles point inside it.
7. Metrics API vs TSDB — different consumers.
8. Prom rule → AM route severity=critical → webhook URL Service FQDN → 200 + resolved.
9. Wrong account/region/bucket/key; non-matching confirm string; only apply reviewed plan; preserves bucket/ECR.
10. `kubectl get nodes` / `get applications -n argocd` / `aws eks describe-cluster` — layer isolation.
11. Pick one: CA fits managed node group simplicity; Karpenter for modern just-in-time + interview depth; never both.
12. Destroy deletes VPC/subnets → RDS needs independent state + snapshot lifecycle first.

---

## 10. 7-day practice plan

| Day | Task |
|-----|------|
| 1 | Draw architecture from memory; check `PLATFORM_ARCHITECTURE.md`; fix gaps |
| 2 | Run all §0 triage commands; explain each output |
| 3 | Rehearse Day-01 IRSA story (90s, 4min versions) |
| 4 | GitOps: trigger drift (scale=1), watch self-heal, refresh annotation |
| 5 | Observability: fire alert via pod delete; show receiver logs |
| 6 | Read `platform-down.sh` guards aloud; run `plan -destroy` **only when you intend to** |
| 7 | Full mock: 12 questions in §9, timed, out loud |

---

## 11. What “outshining” sounds like

Weak: “I used ArgoCD to deploy my app.”
Strong: “I bootstrapped ArgoCD with Helm because of the chicken-and-egg problem, then moved to an App of Apps so platform inventory is a directory of Application CRs. I keep prune off because it’s a mass-delete switch, pin chart versions so disaster recovery is reproducible, and use a multi-source Application so Helm values live in Git next to the manifests. I can show you the sync/health split and a self-heal demo.”

Weak: “Terraform manages my AWS.”
Strong: “Two state layers: bootstrap with local state creates the bucket that can’t be its own backend; platform uses S3 + lockfile. I use explicit `depends_on` where attribute references don’t capture runtime ordering — I learned that the hard way when nodes joined before the CNI had IRSA.”

---

## 12. File map for last-minute review

```text
docs/PLATFORM_ARCHITECTURE.md          # big picture + trade-offs table
docs/INFRASTRUCTURE_LIFECYCLE.md        # state, up/down, cost
docs/GITOPS_ARCHITECTURE.md             # ArgoCD deep-dive + recovery
docs/OBSERVABILITY_ARCHITECTURE.md      # metrics vs prometheus + alert path
docs/TROUBLESHOOTING_RUNBOOK.md         # layered triage
docs/INTERVIEW_PREPARATION.md           # Q&A bank + demo script
documentation/IMPLEMENTATION_LOG.md     # decisions D1–D12 + non-actions
documentation/journal/day-01, day-02    # raw incident history
```

**Final advice:** every claim in an interview should map to a command you can run. If you can’t show it, soften the language (“planned”, “validated locally”) — credibility compounds.
