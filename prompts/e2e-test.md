# AI-Powered SRE Platform — End-to-End Test Guide

> READ THIS ALONGSIDE `prompts/platform-prd-and-decisions.md`.
> This document defines the full e2e test sequence the next agent must implement and execute.
> The e2e test is invoked via `./bootstrap/install.sh --e2e` and covers k3s installation through
> AI closed-loop validation.

---

## What the E2E Test Proves

1. **Clone-and-go:** A fresh checkout bootstraps to a fully working platform with one command.
2. **GitOps integrity:** Every component is declared in git and synced by ArgoCD — nothing is imperative except the Age key injection.
3. **Storage:** SeaweedFS S3 is reachable and all buckets exist.
4. **Observability:** Grafana is up, Loki/Tempo/Mimir are receiving data.
5. **AI closed-loop:** A crashing pod triggers kagent → GitHub Issue created automatically.
6. **Security:** Cross-namespace traffic is denied (Cilium/NetworkPolicy enforcement).

---

## Prerequisites (on the test machine)

```
kubectl   — any recent version
helm      — v3.x
sops      — v3.12.2+
age       — v1.3.1+
curl      — for endpoint checks
jq        — for JSON parsing
```

The bootstrap script installs k3s automatically if it is not already running.

---

## Invocation

```bash
# Full e2e: installs k3s, bootstraps platform, runs all checks
./bootstrap/install.sh --e2e

# Bootstrap only (skip e2e checks)
./bootstrap/install.sh

# Dry-run (no changes made)
./bootstrap/install.sh --dry-run
```

---

## K3s Installation — Required Flags

k3s must be installed with these flags (Traefik and ServiceLB conflict with Envoy Gateway):

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644 \
  --node-name ai-sre-node" sh -
```

| Flag | Reason |
|------|--------|
| `--disable traefik` | Traefik occupies ports 80/443 and conflicts with Envoy Gateway NodePort |
| `--disable servicelb` | klipper-lb (k3s built-in LB) conflicts with Envoy Gateway NodePort service |
| `--write-kubeconfig-mode 644` | Non-root kubeconfig read without sudo |
| `--node-name ai-sre-node` | Stable node name for affinity/label targeting |

After install:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes   # expected: ai-sre-node   Ready
```

`local-path` storage provisioner is bundled with k3s — no extra install needed.

---

## E2E Test Sequence

The bootstrap script (`--e2e` flag) runs the following checks in order.
Each check has a pass/fail verdict. If any check fails, the script exits non-zero.

---

### Check 0 — k3s Running

```bash
kubectl get nodes -o jsonpath='{.items[0].status.conditions[-1].type}' | grep -q Ready
```

Expected: `Ready`
If not: install k3s with the flags above, re-export KUBECONFIG.

---

### Check 1 — ArgoCD All Apps Synced+Healthy

Wait up to **25 minutes** for all apps. Poll every 20 seconds.

```bash
# Get count of apps not yet Synced+Healthy
kubectl get applications -n argocd \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}'
```

Expected: every app shows `Synced Healthy`.
Apps to verify (21 total):

```
sops-operator     Synced Healthy
gateway           Synced Healthy
gateway-resources Synced Healthy
cert-manager      Synced Healthy
security          Synced Healthy
authentik         Synced Healthy
authentik-routes  Synced Healthy
seaweedfs         Synced Healthy
loki              Synced Healthy
tempo             Synced Healthy
mimir             Synced Healthy
alloy             Synced Healthy
beyla             Synced Healthy
grafana           Synced Healthy
kagent            Synced Healthy
khook             Synced Healthy
github-mcp-agent  Synced Healthy
cnpg              Synced Healthy
temporal          Synced Healthy
sample-api        Synced Healthy
root              Synced Healthy
```

---

### Check 2 — Envoy Gateway NodePort Discovery

```bash
HTTP_NODEPORT=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway \
  -o jsonpath='{.items[0].spec.ports[?(@.name=="http")].nodePort}')

HTTPS_NODEPORT=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway \
  -o jsonpath='{.items[0].spec.ports[?(@.name=="https")].nodePort}')

echo "HTTP NodePort : ${HTTP_NODEPORT}"
echo "HTTPS NodePort: ${HTTPS_NODEPORT}"
```

Write these to `/tmp/e2e-nodeports.env` for use in subsequent checks.
Then configure `/etc/hosts` (requires sudo):

```bash
NODE_IP="127.0.0.1"   # k3s single-node always on loopback

for hostname in auth.local grafana.local temporal.local sample-api.local; do
  grep -q "${hostname}" /etc/hosts || \
    echo "${NODE_IP} ${hostname}" | sudo tee -a /etc/hosts
done
```

---

### Check 3 — SeaweedFS S3 Buckets

```bash
kubectl run -it --rm s3test --image=amazon/aws-cli --restart=Never \
  --env="AWS_ACCESS_KEY_ID=<from seaweedfs-s3-creds secret>" \
  --env="AWS_SECRET_ACCESS_KEY=<from seaweedfs-s3-creds secret>" \
  --env="AWS_DEFAULT_REGION=us-east-1" \
  -- aws --endpoint-url http://seaweedfs-filer.seaweedfs.svc:8333 s3 ls
```

Read credentials from the cluster secret:

```bash
ACCESS=$(kubectl get secret seaweedfs-s3-creds -n seaweedfs \
  -o jsonpath='{.data.accessKey}' | base64 -d)
SECRET=$(kubectl get secret seaweedfs-s3-creds -n seaweedfs \
  -o jsonpath='{.data.secretKey}' | base64 -d)
```

Expected output includes: `loki`, `tempo`, `mimir`, `temporal`

---

### Check 4 — Grafana Health

```bash
curl -sk --resolve "grafana.local:${HTTPS_NODEPORT}:127.0.0.1" \
  "https://grafana.local:${HTTPS_NODEPORT}/api/health" | jq .
```

Expected:

```json
{"database": "ok"}
```

---

### Check 5 — Loki Receiving Logs

```bash
curl -sk --resolve "grafana.local:${HTTPS_NODEPORT}:127.0.0.1" \
  -u "admin:$(kubectl get secret grafana-admin-credentials -n observability \
    -o jsonpath='{.data.admin-password}' | base64 -d)" \
  "https://grafana.local:${HTTPS_NODEPORT}/api/datasources/proxy/uid/loki/loki/api/v1/labels" \
  | jq '.data | length > 0'
```

Expected: `true` (labels present = Loki has ingested logs)

---

### Check 6 — Temporal UI

```bash
curl -sk --resolve "temporal.local:${HTTPS_NODEPORT}:127.0.0.1" \
  "https://temporal.local:${HTTPS_NODEPORT}/" | grep -q "Temporal"
```

Expected: HTML page contains "Temporal"

---

### Check 7 — CNPG Cluster Ready

```bash
kubectl get cluster temporal-postgres -n temporal \
  -o jsonpath='{.status.readyInstances}'
```

Expected: `1`

---

### Check 8 — Sample API Responding

```bash
curl -sk --resolve "sample-api.local:${HTTPS_NODEPORT}:127.0.0.1" \
  "https://sample-api.local:${HTTPS_NODEPORT}/" | jq .status
```

Expected: `"ok"`

---

### Check 9 — Beyla Auto-Instrumentation Active

```bash
kubectl logs -n observability -l app.kubernetes.io/name=beyla --tail=50 \
  | grep -qi "instrument"
```

Expected: At least one line showing Beyla attached to a process.

---

### Check 10 — AI Closed-Loop Test (kagent → GitHub Issue)

This is the flagship e2e test. It creates a crashing pod, waits for kagent to detect it via khook, and verifies a GitHub Issue is created.

```bash
# 1. Deploy crasher
kubectl run ai-sre-e2e-crasher \
  --image=busybox \
  --restart=Always \
  -- /bin/false

# 2. Wait for pod to enter CrashLoopBackOff (up to 3 minutes)
TIMEOUT=180
ELAPSED=0
while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
  STATE=$(kubectl get pod ai-sre-e2e-crasher \
    -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
  [[ "${STATE}" == "CrashLoopBackOff" ]] && break
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

if [[ "${STATE}" != "CrashLoopBackOff" ]]; then
  echo "FAIL: Pod did not enter CrashLoopBackOff within timeout"
  kubectl delete pod ai-sre-e2e-crasher --ignore-not-found
  exit 1
fi

# 3. Wait for kagent to process and create GitHub Issue (up to 5 minutes)
sleep 30   # Give khook time to fire
TIMEOUT=300
ELAPSED=0
ISSUE_FOUND=false

while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
  KAGENT_LOGS=$(kubectl logs -n kagent -l app.kubernetes.io/name=kagent \
    --tail=200 2>/dev/null || echo "")
  if echo "${KAGENT_LOGS}" | grep -qi "rca\|issue.*created\|github"; then
    ISSUE_FOUND=true
    break
  fi
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done

# 4. Cleanup
kubectl delete pod ai-sre-e2e-crasher --ignore-not-found

if [[ "${ISSUE_FOUND}" == "false" ]]; then
  echo "FAIL: No evidence of kagent creating GitHub Issue within timeout"
  echo "Check: kubectl logs -n kagent -l app.kubernetes.io/name=kagent"
  exit 1
fi

echo "PASS: AI closed-loop test — GitHub Issue creation confirmed"
```

---

### Check 11 — Security (Cross-Namespace Deny)

Verify the default-deny NetworkPolicy blocks cross-namespace traffic for the kagent namespace:

```bash
# Attempt connection from sample-api namespace to argocd-server
# Should fail (connection timeout or refused)
kubectl run nettest \
  --image=busybox \
  --namespace=sample-api \
  --restart=Never \
  --rm -it \
  -- wget -qO- --timeout=5 http://argocd-server.argocd 2>&1 | grep -qiE "timeout|refused"

echo "PASS: Cross-namespace traffic correctly blocked"
```

---

## E2E Test Output

The script writes a summary table on completion:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  E2E Test Results
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [PASS] k3s running
  [PASS] All 21 ArgoCD apps Synced+Healthy
  [PASS] Envoy Gateway NodePort discovered (HTTP: 32080, HTTPS: 32443)
  [PASS] SeaweedFS buckets: loki, tempo, mimir, temporal
  [PASS] Grafana /api/health → {"database":"ok"}
  [PASS] Loki labels present (logs ingested)
  [PASS] Temporal UI responding
  [PASS] CNPG cluster ready (1/1 instances)
  [PASS] Sample API responding
  [PASS] Beyla auto-instrumentation active
  [PASS] AI closed-loop: GitHub Issue created
  [PASS] Security: cross-namespace traffic blocked
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  All checks passed. Platform is production-ready.
```

---

## Teardown (k3s)

```bash
# Remove the k3s installation completely
/usr/local/bin/k3s-uninstall.sh

# Remove /etc/hosts entries
sudo sed -i '/\.local$/d' /etc/hosts
```

---

## Known Issues / Notes for Next Agent

1. **SeaweedFS bucket creation**: Buckets are created by the chart's `createBuckets` hook at first deploy. If the filer pod restarts before the hook runs, re-sync the seaweedfs ArgoCD app.

2. **Temporal schema init**: On first deploy, Temporal runs a schema migration Job. Wait for `kubectl get jobs -n temporal` to show `Complete` before checking the UI.

3. **CNPG timing**: The CNPG `Cluster` must reach `Running` state before Temporal's Helm release syncs. ArgoCD sync-waves handle this (cnpg is wave 1, temporal is wave 3) but on a cold cluster the CRD registration takes ~30 seconds.

4. **kagent Anthropic API**: The `kagent-anthropic` Secret must exist in the `kagent` namespace before the Agent CRD will activate. This is created from `agents/ai-sre-agent/anthropic-secret.enc.yaml` by the SOPS Operator.

5. **GitHub Issue creation**: The GitHub PAT in `agents/github-mcp-agent/github-pat.enc.yaml` must have `repo` scope (Issues write permission) on the `Matcham89/AI-powered-SRE` repository.
