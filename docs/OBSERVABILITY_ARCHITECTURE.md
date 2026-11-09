# Observability Architecture — Prometheus, Grafana, Alertmanager, Metrics Server

**Verified:** 2026-11-10 live cluster · chart `kube-prometheus-stack-93.1.1` (app v0.95.1) · `metrics-server-3.14.0` (app 0.9.0)
**Deployment path (target state):** ArgoCD Applications `monitoring` + `metrics-server` (see GITOPS_ARCHITECTURE)
**Current live path:** still Helm-managed until approved rebuild (user decision — no dual ownership)

---

## 1. Component map

```text
                    ┌─────────────────────────────────────────────┐
                    │           monitoring namespace              │
                    │                                             │
 node-exporter ──┐  │  ┌──────────────┐    scrapes    ┌─────────┐ │
 (DaemonSet×2)   ├──┼─▶│  Prometheus  │◀──────────────│prom.    │ │
                 │  │  │  (TSDB, 12h, │               │operator │ │
 kube-state-     ├──┼─▶│   2GB cap)   │◀──────────────│ (CRD    │ │
 metrics         │  │  └──────┬───────┘   watches     │ owner)  │ │
                 │  │         │ alert rules           └─────────┘ │
 pulse-api ──────┘  │         ▼                                   │
 (via ksm metrics)  │  ┌──────────────┐  webhook  ┌─────────────┐ │
                    │  │ Alertmanager │──────────▶│ alert-      │ │
                    │  │ (route, group│  HTTP 200 │ validator   │ │
                    │  │  1h repeat)  │           │ :8089       │ │
                    │  └──────────────┘           └─────────────┘ │
                    │  ┌──────────────┐                           │
                    │  │   Grafana    │  (dashboards, no PVC)     │
                    │  └──────────────┘                           │
                    └─────────────────────────────────────────────┘

 kube-system namespace:
   metrics-server ──▶ serves Metrics API (metrics.k8s.io) ──▶ HPA / kubectl top
```

---

## 2. Why Metrics Server ≠ Prometheus (interview classic)

| | **Metrics Server** | **Prometheus** |
|--|-------------------|----------------|
| API | Kubernetes **Metrics API** (`metrics.k8s.io`) | PromQL HTTP API (`:9090`) |
| Consumers | **HPA**, VPA, `kubectl top` | Humans, Grafana, Alertmanager, custom apps |
| Storage | **None** (scrapes kubelet summary, ~15s, in-memory) | **TSDB** (disk/WAL, retention 12h/2GB here) |
| Cardinality | Tiny (per-container CPU/mem) | Huge (all metric families, labels) |
| Install location | `kube-system` | `monitoring` |

HPA **requires** Metrics Server: the HPA controller calls the Metrics API to compute `currentCPU%` vs `target`. Prometheus never implements that API — scraping `container_cpu_usage_seconds_total` in Prometheus does **not** satisfy HPA.

---

## 3. kube-prometheus-stack (what’s inside)

Helm chart bundles:

| Subcomponent | Role |
|--------------|------|
| **Prometheus Operator** | Reconciles `Prometheus`/`Alertmanager`/`ServiceMonitor`/`PrometheusRule` CRs into Deployments/ConfigMaps |
| **Prometheus** | Scrapes targets; evaluates rules; stores TSDB |
| **Alertmanager** | Dedup, group, route, silence, notify (webhook here) |
| **Grafana** | UI dashboards (persistence **disabled** in lab) |
| **kube-state-metrics** | Exposes object state (`kube_pod_container_status_restarts_total`, etc.) |
| **node-exporter** | Host CPU/mem/disk/net (DaemonSet on each node) |
| **PrometheusRule CRDs** | Alert rule definitions as Kubernetes objects |

Custom values (`gitops/values/monitoring-values.yaml`) set:
1. `additionalPrometheusRulesMap.pulse-alerts` → `PulsePodCrashLooping`
2. `alertmanager.config` → route + webhook receiver
3. Resource requests/limits + retention to fit 2× t3.medium

---

## 4. Alert path end-to-end

### Rule
```yaml
alert: PulsePodCrashLooping
expr: sum by (namespace, pod, instance)
      (increase(kube_pod_container_status_restarts_total[2m])) > 0
for: 30s
labels: {severity: critical, tier: platform}
```

**Mechanism:**
1. `kube-state-metrics` publishes restart counters scraped by Prometheus.
2. `increase(...[2m]) > 0` → a container restarted recently.
3. `for: 30s` → pending until condition holds 30s (reduces flapping).
4. Alert becomes **firing** → sent to Alertmanager.

### Routing (Alertmanager config)
```text
route:
  receiver: terminal-smoke-test          # default
  routes:
    - match: {severity: critical}
      receiver: terminal-smoke-test
receivers:
  - name: terminal-smoke-test
    webhook_configs:
      - url: http://monitoring-alert-routing-svc.monitoring.svc.cluster.local:8089
        send_resolved: true
```

- **Grouping:** `group_by: [alertname, namespace, pod]`, `group_wait: 10s`, `repeat_interval: 1h`.
- **Webhook:** Alertmanager POSTs JSON (`status: firing|resolved`) to the receiver Service.
- **Receiver:** Python `HTTPServer` on `:8089` prints body, returns **200** (verified Day 02; resolved notifications also tested).

### Testing fire/resolved (lab technique)
```bash
# Fire: delete a pulse pod repeatedly or kill the container
kubectl delete pod -n pulse -l app.kubernetes.io/name=pulse-api
# Watch Alertmanager
kubectl port-forward svc/alertmanager-monitoring-kube-prometheus-alertmanager -n monitoring 9093:9093
# Receiver logs
kubectl logs -n monitoring deploy/monitoring-alert-validator -f
```

---

## 5. Discovery & scrape model

- Prometheus Operator creates **ServiceMonitors** (label-selected Services → scrape configs).
- Node exporter: one pod per node (DaemonSet), discovered via ServiceMonitor/EndpointSlice.
- kube-state-metrics: ClusterIP Service in `monitoring`.
- **Targets UP check (used in platform-up.sh):**
  ```bash
  kubectl exec -n monitoring prometheus-monitoring-kube-prometheus-prometheus-0 \
    -c prometheus -- wget -qO- 'localhost:9090/api/v1/query?query=up' \
    | jq '[.data.result[] | select(.value[1]=="1")] | length'
  ```

**Healthy looks like:** `up == 1` for `prometheus`, `alertmanager`, `grafana`, `node-exporter` (×2), `kube-state-metrics`, plus kube-apiserver/cadvisor-style endpoints if configured.

---

## 6. Storage & why there’s no PVC

```yaml
prometheus.prometheusSpec.storageSpec: {}     # no persistent volume claim
grafana.persistence.enabled: false
alertmanager.alertmanagerSpec.storage: {}
```

- Disposable lab → crash loses at most 12h of metrics; acceptable.
- **No EBS CSI driver installed** on the cluster — a PVC with gp2/gp3 would **Pending** forever today. Before adding persistence: install `aws-ebs-csi-driver` add-on + IRSA, then switch `storageSpec`.
- Future RDS is for **application data**, not Prometheus TSDB (unless you deliberately choose managed metrics — usually overkill for a lab).

---

## 7. ArgoCD Application wiring (target state)

`gitops/apps/monitoring.yaml`:
- Multi-source: chart `93.1.1` + Git values + `gitops/monitoring-extras/` (alert receiver).
- `destination.namespace: monitoring`, `CreateNamespace=true`.
- `automated.selfHeal=true`, `prune=false` (CRDs + prune = danger).

`gitops/apps/metrics-server.yaml`:
- Single Helm source, chart `3.14.0`, namespace `kube-system`.

**Live adoption deferred:** Helm releases remain owners until destroy/rebuild (see GITOPS §8).

---

## 8. Sizing reality check (2× t3.medium = 4 vCPU / 8 GB total)

| Workload | Requests (approx.) |
|----------|--------------------|
| Prometheus | 200m / 512Mi |
| Grafana | 100m / 128Mi |
| Alertmanager | modest |
| Operator | 100m / 128Mi |
| kube-state-metrics + node-exporter | modest |
| metrics-server | small |
| pulse-api ×2 | 200m / 384Mi |
| system (coredns, cni, kube-proxy) | ~300m+ |

Fits with headroom; limits prevent one pod from starving the node. If you add HPA load tests, watch node pressure before raising replica caps.

---

## 9. Failure modes

| Symptom | Cause | Investigation | Fix |
|---------|-------|---------------|-----|
| HPA `<unknown>` metrics | Metrics Server down/not ready | `kubectl top nodes` fails; `kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server` | Restore metrics-server App/Helm; check kubelet metrics port |
| Alert never fires | Rule not loaded / no scrape of ksm | Prometheus UI → Rules; targets `kube-state-metrics` | Fix ServiceMonitor labels; check `additionalPrometheusRulesMap` rendered |
| Webhook 4xx/timeout | Receiver down / wrong URL | Alertmanager → Alerts; receiver logs | Fix Service name/namespace; ensure Deployment Ready |
| High memory Prometheus | Cardinality / targets exploded | `prometheus_tsdb_head_series` | Reduce scrape intervals/labels; raise limits |
| Grafana login lost | No persistence (expected) | — | Re-set admin password or enable PVC after CSI |
| Targets DOWN after rebuild | Endpoints not ready / network policies | Prom UI Targets | Wait for pods; check Services |

---

## 10. Verification commands (cheat sheet)

```bash
# Stack health
helm list -A | grep -E 'monitoring|metrics'
kubectl get pods -n monitoring
kubectl get prometheusrules -n monitoring
kubectl get prometheus -n monitoring -o yaml | grep -A2 retention

# Metrics API (HPA prerequisite)
kubectl top nodes
kubectl top pods -A

# Alertmanager config rendered
kubectl get secret -n monitoring alertmanager-monitoring-kube-prometheus-alertmanager-generated \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | head -50

# Receiver
kubectl logs -n monitoring deploy/monitoring-alert-validator --tail=20
```

---

## 11. Interview soundbites

1. *“Metrics Server feeds the Metrics API for HPA; Prometheus is a TSDB for observability. Different APIs, different consumers — HPA cannot use Prometheus directly.”*
2. *“The Operator turns CRs into workloads; that’s why deleting a ServiceMonitor stops scraping without editing Prometheus’s config file.”*
3. *“Our alert uses kube-state-metrics restart counters, a 30s `for` clause, then Alertmanager webhook with `send_resolved` — so both fire and resolve reach the receiver.”*
4. *“We intentionally run without persistence and without EBS CSI in the disposable lab; adding durability means add-on + IRSA + storageSpec change — a conscious trade-off, not an oversight.”*
