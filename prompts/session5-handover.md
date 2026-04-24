# Session 5 Handover — Metrics, Traces & ArgoCD SSO

## Context

AI-powered SRE platform on Rancher Desktop (k3s via lima).

- **Cluster node IP:** `192.168.5.15`
- **HTTP NodePort:** `32170`
- **ArgoCD:** manages all apps via GitOps from `https://github.com/Matcham89/AI-powered-SRE`
- **SOPS + Age** encryption for secrets (`~/.config/sops/age/keys.txt`)
- **Authentik** SSO at `http://auth.local:32170` — `demo-user` account (credentials via `terraform output`)

## /etc/hosts entries required

```
192.168.5.15  grafana.local
192.168.5.15  auth.local
192.168.5.15  temporal.local
192.168.5.15  argocd.local
```

## What was completed before this session

1. Full observability stack running: Mimir (metrics), Loki (logs), Tempo (traces), Grafana
2. Alloy DaemonSet collecting:
   - **Pod logs** → Loki (all namespaces, labels: namespace/pod/container/app)
   - **kube-state-metrics** → Mimir (pod/deployment/namespace state)
   - **cAdvisor via kubelet proxy** → Mimir (container CPU/memory)
3. Beyla eBPF auto-instrumentation → OTLP traces → Alloy → Tempo
4. Three Grafana dashboards provisioned: Beyla RED Metrics (19419), Loki Log Search (13639), Kubernetes Pods (15759)
5. Grafana OIDC login working via Authentik (`demo-user`)
6. Authentik user renamed to `demo-user` (managed via Terraform in `terraform/`)
7. ArgoCD sync waves corrected (dependency order: wave 1→8)
8. ArgoCD OIDC wired to Authentik — **needs Terraform apply + argocd-secret patch to activate**

## What needs completing

### 1. Activate ArgoCD OIDC (requires manual steps)

**Step 1 — Add `argocd_client_secret` to tfvars:**
```bash
# Add to terraform/terraform.tfvars:
argocd_client_secret = "CHOOSE_A_STRONG_SECRET"
```

**Step 2 — Terraform apply:**
```bash
cd terraform
kubectl port-forward -n authentik svc/authentik-server 9000:80
terraform apply
```

**Step 3 — Patch argocd-secret with the client secret:**
```bash
SECRET="<same value as argocd_client_secret in tfvars>"
kubectl patch secret argocd-secret -n argocd \
  -p "{\"data\":{\"oidc.authentik.clientSecret\":\"$(echo -n $SECRET | base64)\"}}"
```

**Step 4 — Restart ArgoCD server:**
```bash
kubectl rollout restart deployment/argocd-server -n argocd
```

**Step 5 — Verify ArgoCD SSO login at `http://argocd.local:32170`**

### 2. Investigate metrics and traces

#### Check metrics are flowing end-to-end

From Grafana (`http://grafana.local:32170`) — Explore → Mimir datasource:

```promql
# Container CPU usage per pod
sum by (pod, namespace) (rate(container_cpu_usage_seconds_total[5m]))

# Memory usage
sum by (pod, namespace) (container_memory_working_set_bytes{container!=""})

# Pod restart count (from kube-state-metrics)
kube_pod_container_status_restarts_total

# HTTP request rate from Beyla eBPF
sum by (service_name) (rate(http_server_request_duration_seconds_count[5m]))
```

#### Check Alloy scrape health

```bash
kubectl logs -n observability daemonset/alloy --since=5m | grep -E "error|warn|remote_write|Failed"
```

Expected: `200 POST /api/v1/push` entries in the Mimir gateway logs — no 500s.

#### Check traces are landing in Tempo

From Grafana → Explore → Tempo datasource:
- Search for recent traces from `sample-api` service
- Expected: HTTP traces from Beyla eBPF for all services that received traffic

#### Verify kube-state-metrics is scraped

```bash
# Should return pod count for observability namespace
kubectl exec -n observability daemonset/alloy -- alloy fmt --help 2>/dev/null
# Instead, check Alloy WAL and scrape stats via Grafana Explore:
# Query: kube_pod_info{namespace="observability"}
```

#### Dashboard gaps to investigate

The **Kubernetes Pods** dashboard (ID 15759) uses `kube_node_info` for node selectors — verify the `cluster` label is set or update the dashboard variable default to empty string.

The **Beyla RED Metrics** dashboard uses `http_server_request_duration_seconds` — trigger some traffic to `sample-api` and verify it appears:
```bash
kubectl run curl-test --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s http://sample-api.sample-api.svc/health
```

### 3. Potential issues to check

- **Mimir replication_factor=1**: set in `platform/observability/mimir-values.yaml`. If Mimir loses data after a restart, check S3 bucket `mimir` exists in SeaweedFS.
- **SeaweedFS bucket persistence**: SeaweedFS restarts lose bucket registration (known issue). Recreate via:
  ```bash
  kubectl port-forward -n seaweedfs svc/seaweedfs-filer 18333:8333
  for bucket in mimir loki tempo; do
    curl -X PUT "http://127.0.0.1:18333/$bucket" \
      --aws-sigv4 "aws:amz:us-east-1:s3" \
      --user "eb564277862c4709b2e1982ffac875e5:07a8e88458f45e85d477011ad257f41e83ca95d1"
  done
  ```
- **Tempo metric generators**: Tempo logs `empty ring` for metric generator queries — this is expected (generators not configured). Trace search still works.

## Key file locations

| Component | Config |
|---|---|
| Alloy scrape config | `platform/observability/alloy-values.yaml` |
| Grafana dashboards/datasources | `platform/observability/grafana-values.yaml` |
| Mimir config | `platform/observability/mimir-values.yaml` |
| ArgoCD OIDC | `cluster/argocd/argocd-cm.yaml` |
| Authentik Terraform | `terraform/argocd.tf` |
| NetworkPolicies | `security/allow-rules/` |
| Sync waves | `cluster/apps/*.yaml` (waves 1–8) |

## Sync wave order (for reference)

| Wave | Apps |
|---|---|
| 1 | cert-manager, envoy-gateway, sops-secrets-operator |
| 2 | gateway-resources, security-policies |
| 3 | seaweedfs, authentik, cnpg |
| 4 | loki, mimir, tempo, authentik-routes |
| 5 | alloy, beyla, kube-state-metrics, temporal, kagent-crds |
| 6 | grafana, sample-api, kagent |
| 7 | khook-crds, github-mcp-agent |
| 8 | khook |
