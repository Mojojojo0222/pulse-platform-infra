# GitOps Architecture — ArgoCD, App of Apps, Helm Sources, Recovery

**Verified:** 2026-11-10 · ArgoCD chart `argo-cd-10.17.1` (app v3.6.1), namespace `argocd`, ClusterIP
**Git repos:** `pulse-platform.git` (app) · `pulse-platform-infra.git` (platform — created this session)

---

## 1. What problem GitOps solves

Without GitOps: `kubectl apply` from a laptop → no audit trail, no drift detection, cluster state exists only in whoever’s terminal history.

With GitOps: **Git is the desired state**; a controller in the cluster continuously **reconciles** live objects toward that state. Changes go through `git commit → push → sync`. Rollback is `git revert`.

---

## 2. Core objects

### Application CRD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: pulse-api
  namespace: argocd          # Applications live in the argocd namespace
spec:
  project: default
  source:                    # OR sources: (plural) — never both
    repoURL: https://github.com/Mojojojo0222/pulse-platform.git
    targetRevision: master   # branch / tag / SHA
    path: k8s                # subdirectory of manifests
  destination:
    server: https://kubernetes.default.svc   # in-cluster
    namespace: pulse
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
```

Each field’s meaning:

| Field | Meaning |
|-------|---------|
| `source.repoURL` | Where to clone |
| `targetRevision` | Which ref (branch moves; tags/SHAs are immutable) |
| `path` | Directory of YAML (directory source) **or** omit and set `chart`+`helm` for Helm |
| `destination` | Which cluster/namespace receives the manifests |
| `syncPolicy.automated` | Controller applies diffs without human click |
| `selfHeal` | Live object edited by `kubectl` → controller reverts to Git |
| `prune` | Git object deleted → controller deletes live object (**off by default here**) |
| `finalizer` `resources-finalizer.argocd.argoproj.io` | Deleting the Application cascades delete tracked resources |

### Sync status vs health status

| | **Sync** | **Health** |
|--|----------|------------|
| Question | “Do live objects match Git?” | “Are the workloads actually OK?” |
| Values | `Synced`, `OutOfSync`, `Unknown` | `Healthy`, `Progressing`, `Degraded`, `Missing`, `Suspended` |
| Example | Deployment image tag matches Git | ReplicaSet ready replicas ≥ desired |

A resource can be **Synced but Degraded** (YAML applied, pods crash) or **OutOfSync but Healthy** (old image still running fine). You need both axes.

---

## 3. Reconciliation loop (how it actually works)

```text
 every ~3 min (repo-server hard-refresh interval) OR webhook OR manual refresh
        │
        ▼
 application-controller
   1. clone repo @ targetRevision (via repo-server)
   2. render manifests (kustomize / helm template / plain YAML / jsonnet)
   3. compare rendered ↔ live (live-objects cache, server-side diff)
   4. set status.sync + status.health on Application CR
   5. if automated && OutOfSync → apply diffs (ApplyOutOfSyncOnly, SSA here)
   6. if selfHeal && live drifted → same apply path reverts drift
   7. if prune && Git object gone → delete live object (when enabled)
```

- **Drift detection** is continuous even with `automated` off — status still shows `OutOfSync`.
- **Git push does not instantly sync** — controller polls. Force immediate:  
  `kubectl annotate applications.argoproj.io <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite`  
  Production: GitHub webhook → ArgoCD notifications, or shorter refresh timeout.

---

## 4. App of Apps (parent/child)

```text
pulse-platform-root  (path: gitops/apps/ in pulse-platform-infra.git)
   │  discovers every Application YAML in that directory
   ├─▶ pulse-api
   ├─▶ metrics-server
   └─▶ monitoring
```

- Root app **deploys Applications, not workloads**.
- Adding a platform component = add a file under `gitops/apps/` + push → root sync creates the child → child syncs its resources.
- Deleting a file with `prune: false` on root → child Application **remains** (documented foot-gun).
- Root `finalizer` means deleting the root CR cascades to children (and, with their finalizers, their resources).

---

## 5. Helm as an ArgoCD source

ArgoCD can render Helm charts itself (`helm template` under the hood) without a Tiller-like runtime:

```yaml
source:
  repoURL: https://kubernetes-sigs.github.io/metrics-server/
  chart: metrics-server          # chart name, not path
  targetRevision: "3.14.0"       # chart version — PINNED
```

**Why pin:** `targetRevision: "*"` (or omitting) can pull a newer chart on rebuild → non-reproducible infrastructure. Your clean rebuild depends on exact pins matching what was validated (`93.1.1`, `3.14.0`, `10.17.1`).

---

## 6. Multi-source Applications (monitoring)

One Application, three sources:

```yaml
sources:
  - repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: "93.1.1"
    helm:
      valueFiles:
        - $values/gitops/values/monitoring-values.yaml   # ← path in Git source
  - repoURL: https://github.com/Mojojojo0222/pulse-platform-infra.git
    targetRevision: master
    ref: values                    # exposes repo as $values — NO path → not deployed
  - repoURL: https://github.com/Mojojojo0222/pulse-platform-infra.git
    targetRevision: master
    path: gitops/monitoring-extras # plain YAML deployed alongside the chart
```

Rules:
1. Use **`sources:` (list)** when multi-source; **never** both `source` and `sources`.
2. `ref: values` makes `$values/...` resolve to the **root of that clone**.
3. Values live in Git → chart version and configuration versioned together.
4. Mixing directory + Helm in one Application = one logical unit (same app, same prune/sync lifecycle).

---

## 7. What lives where (this platform)

| Application | Source type | Repo | Version pin |
|-------------|-------------|------|-------------|
| `pulse-platform-root` | Directory | pulse-platform-infra `master` / `gitops/apps` | branch |
| `pulse-api` | Directory | pulse-platform `master` / `k8s` | branch |
| `metrics-server` | Helm | kubernetes-sigs metrics-server | chart `3.14.0` |
| `monitoring` | Multi | prom-community chart + infra values + extras dir | chart `93.1.1` |

---

## 8. Adoption vs clean rebuild (decision record)

**Problem:** On the *live* cluster, `metrics-server` and `monitoring` already exist as **Helm releases**. ArgoCD must not manage the same objects under a second owner (conflicts: tracking labels, `helm.sh` annotations, differing field managers).

**Decision (user-approved):**  
- **Do not** uninstall, label-adopt, or modify the live Helm releases now.  
- Manifests are written and **validated locally** (`kubectl apply --dry-run=server` → `created`/`unchanged`).  
- On the **final approved destroy→rebuild**, the cluster starts empty; ArgoCD installs both from Git with **zero manual Helm** — this is the clean-rebuild adoption path.

**Rejected alternatives:**
| Option | Why rejected |
|--------|--------------|
| `helm uninstall` then ArgoCD install | Changes live stack mid-project; 2–3 min observability gap |
| Label-stamp ~100 objects for adoption | Fragile (CRDs/RBAC/Prometheus CRs); high failure risk |
| Dual-manage (Helm + ArgoCD both live) | Guaranteed ownership conflicts |

---

## 9. Prune — impact before enabling

| `prune` | Git deletion effect |
|---------|---------------------|
| `false` (current, all apps) | Nothing is deleted; live object becomes “orphan but still running”; app may show weird status if path disappears |
| `true` | Controller **deletes** live resources no longer rendered from Git |

**Dangers of `prune: true`:**
- Wrong `path`/branch → mass delete of a namespace’s contents.
- Temporary Git mistake → production-style outage until revert.
- CRDs + prune can remove entire CR families (Prometheus CRs → operator garbage).

**Rules:** enable prune only with (1) trusted CI, (2) narrow paths, (3) understanding of finalizers, (4) ideally `PruneLast=true` so healthy resources delete after new ones are ready. **Never** point a pruned app at RDS/stateful cloud infra — those belong to Terraform.

---

## 10. Recovery playbook

### A. Cluster destroyed, platform must return
```bash
./bootstrap/platform-up.sh
# → terraform apply → kubeconfig → nodes Ready
# → helm install argocd (if missing) → apply root app → children self-assemble
```
No manual `helm install` for metrics-server/monitoring/pulse.

### B. ArgoCD itself missing but cluster alive
```bash
helm status argocd -n argocd || \
  helm install argocd argo/argo-cd -n argocd --version 10.17.1 \
    --set server.service.type=ClusterIP
kubectl apply -f gitops/root/platform-root.yaml
```

### C. Drift (someone kubectl-edited a Deployment)
```bash
kubectl get application pulse-api -n argocd \
  -o jsonpath='{.status.sync.status} {.status.health.status}'
# expect: OutOfSync ... then selfHeal re-applies within a refresh cycle
kubectl annotate applications.argoproj.io pulse-api -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

### D. Sync stuck / wrong revision
```bash
kubectl describe application monitoring -n argocd | sed -n '/Status:/,$p'
kubectl logs -n argocd deploy/argocd-repo-server --tail=50
kubectl logs -n argocd deploy/argocd-application-controller --tail=50
```
Common: bad `valueFiles` path (`$values` root mistake), chart version not in repo, network egress from repo-server, multi-source missing `ref`.

### E. Application deleted accidentally
- With finalizer: children/resources cascade-deleted (may be intended).
- Re-`kubectl apply -f gitops/root/platform-root.yaml` + child file if needed; Git remains source of truth.

### F. Git push not picked up
Poll interval lag → hard refresh annotation (above) or wait ~3 min; confirm `targetRevision` matches pushed branch.

---

## 11. Local validation performed (this session)

```text
YAML parse (PyYAML)     → all gitops/*.yaml OK
kubectl apply --dry-run=client (pulse k8s manifests) → configured (dry run)
kubectl apply --dry-run=server (4 Applications)       → created/unchanged (dry run)
bash -n platform-up.sh / platform-down.sh             → syntax OK
```

**NOT yet verified live:** root app applied, children created by ArgoCD, monitoring/metrics-server installed by GitOps — deferred to approved rebuild (see changelog).
