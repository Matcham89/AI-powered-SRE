# AI-Powered SRE Platform — Next Agent Instructions

> READ THIS FIRST. You are continuing an in-progress implementation.
> Steps 1–8 are complete and tested. Your job is Steps 9–12.
> After each step, update `prompts/platform-prd-and-decisions.md` with what was built and tested.

---

## What This Platform Is

A production-grade, GitOps-managed Kubernetes platform on a Talos Linux homelab cluster.
It deploys via a single script (`./bootstrap/install.sh`) and self-manages via ArgoCD.

**The core innovation:** SOPS + Age encryption solves the GitOps "chicken and egg" auth problem.
GitHub PATs are stored SOPS-encrypted in git. The bootstrap script injects the Age private key
once — after that, the SOPS Secrets Operator decrypts everything autonomously.

**End goal:** An AI SRE agent (kagent) that automatically detects Kubernetes failures, queries
eBPF traces (Beyla) and metrics (Mimir), and posts RCA reports as GitHub Issues — closed-loop,
no human required.

---

## Cluster Details

- **Context:** `admin@talos-homelab` at `https://192.168.1.180:6443`
- **OS:** Talos Linux (immutable, declarative)
- **StorageClass:** `local-path` (default)
- **CNI:** Likely Cilium (Talos default recommendation)
- **Ingress:** Envoy Gateway (replaces nothing — Talos has no built-in ingress)

---

## Repository Structure

```
.
├── bootstrap/
│   ├── install.sh                          # 9-step bootstrap orchestrator
│   └── manifests/
│       ├── namespaces.yaml                 # argocd, sops-operator
│       ├── sops-operator-values.yaml       # SOPS Operator Helm values
│       └── sops-age-secret.yaml.template   # documents the ONE imperative step
├── cluster/
│   ├── root-app.yaml                       # App-of-Apps (applied by bootstrap)
│   ├── kustomization.yaml                  # ← ADD new apps here as steps complete
│   ├── registry/
│   │   ├── repo-credentials.enc.yaml       # ArgoCD PAT (SopsSecret, SOPS-encrypted)
│   │   └── cluster-local.enc.yaml          # in-cluster registration (SopsSecret)
│   ├── argocd/
│   │   ├── argocd-cm.yaml                  # annotation tracking, OIDC placeholder
│   │   └── argocd-rbac-cm.yaml             # readonly default, admin via OIDC
│   └── apps/                               # ALL ArgoCD Application CRDs live here
│       ├── sops-operator-app.yaml          # ACTIVE ✅
│       ├── gateway-app.yaml                # ACTIVE ✅
│       ├── gateway-resources-app.yaml      # ACTIVE ✅
│       ├── cert-manager-app.yaml           # ACTIVE ✅
│       ├── security-app.yaml               # ACTIVE ✅
│       ├── authentik-app.yaml              # ACTIVE ✅
│       ├── authentik-routes-app.yaml       # ACTIVE ✅
│       ├── seaweedfs-app.yaml              # ← activate in Step 9
│       ├── loki-app.yaml                   # ← activate in Step 10
│       ├── tempo-app.yaml                  # ← activate in Step 10
│       ├── mimir-app.yaml                  # ← activate in Step 10
│       ├── alloy-app.yaml                  # ← activate in Step 10
│       ├── beyla-app.yaml                  # ← activate in Step 10
│       ├── grafana-app.yaml                # ← activate in Step 10
│       ├── kagent-app.yaml                 # ← activate in Step 11
│       ├── khook-app.yaml                  # ← activate in Step 11
│       ├── github-mcp-app.yaml             # ← activate in Step 11
│       ├── temporal-app.yaml               # ← activate in Step 12
│       └── sample-api-app.yaml             # ← activate in Step 12
├── platform/
│   ├── gateway/
│   │   ├── values.yaml                     # Envoy Gateway Helm values ✅
│   │   ├── gateway.yaml                    # EnvoyProxy (NodePort) + Gateway ✅
│   │   ├── cert-manager-values.yaml        # cert-manager Helm values ✅
│   │   └── cluster-issuer.yaml             # self-signed ClusterIssuer + wildcard cert ✅
│   ├── auth/
│   │   ├── authentik-secret.enc.yaml       # SOPS-encrypted secrets ✅
│   │   ├── values.yaml                     # Authentik Helm values ✅
│   │   └── httproute-authentik.yaml        # HTTPRoute: auth.local ✅
│   ├── storage/                            # ← Step 9: create here
│   ├── hooks/                              # ← Step 11: khook config here
│   └── observability/                      # ← Step 10: create here
├── agents/
│   ├── ai-sre-agent/                       # ← Step 11: kagent config here
│   └── github-mcp-agent/
│       └── github-pat.enc.yaml             # AI SRE Agent PAT (SOPS-encrypted) ✅
├── apps/
│   ├── temporal/                           # ← Step 12
│   └── sample-api/                         # ← Step 12
└── security/
    ├── kustomization.yaml                  # ✅
    ├── default-deny.yaml                   # default deny: kagent namespace ✅
    └── allow-rules/
        ├── dns-allow.yaml                  # ✅
        ├── argocd-allow.yaml               # ✅
        ├── agents-allow.yaml               # ✅
        └── observability-allow.yaml        # ✅
```

---

## Critical Patterns — Follow These Exactly

### Adding a new platform component (every step follows this)

1. **Create values file:** `platform/<component>/values.yaml`
2. **Create HTTPRoute:** `platform/<component>/httproute-<name>.yaml` (if has UI)
3. **Create SOPS secrets (if needed):** write plaintext to `platform/<component>/<name>.enc.yaml`, immediately encrypt:
   ```bash
   SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
     sops --encrypt --in-place platform/<component>/<name>.enc.yaml
   ```
4. **Update the existing `cluster/apps/<component>-app.yaml`** to use multi-source:
   ```yaml
   sources:
     - repoURL: <helm-chart-repo>
       chart: <chart-name>
       targetRevision: "<version>"
       helm:
         valueFiles:
           - $values/platform/<component>/values.yaml
     - repoURL: https://github.com/Matcham89/AI-powered-SRE
       targetRevision: HEAD
       ref: values
   ```
5. **Uncomment in `cluster/kustomization.yaml`** — remove the `#` from `# - apps/<component>-app.yaml`
6. **Run test gate** — YAML valid, kustomize build passes, helm lint passes

### SOPS Encryption Rule
- `.sops.yaml` regexes: `cluster/registry/.*\.yaml$`, `cluster/argocd/.*\.enc\.yaml$`, `platform/.*\.enc\.yaml$`, `agents/.*\.enc\.yaml$`
- Files MUST be at a matching path before encrypting (SOPS uses the path for key routing)
- Always write to target path first, encrypt in-place immediately
- Age private key: `~/.config/sops/age/keys.txt`
- Age public key: `age1jpjljdr54z2929pj587e2tl64cvfz67dugx4df0t93y96fnqx4uq7e8qvg`

### YAML Validation (use these commands)
```bash
# Check YAML structure (ruby, no python yaml module available)
ruby -e "require 'yaml'; YAML.load_stream(File.read('file.yaml'))"

# kustomize build
kubectl kustomize cluster/
kubectl kustomize security/

# helm lint (pull chart first)
helm pull <repo>/<chart> --version <ver> --untar --untardir /tmp/chart
helm lint --values platform/<component>/values.yaml /tmp/chart/<chart>
rm -rf /tmp/chart
```

### SeaweedFS Helm repo
```bash
helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm
```
Chart: `seaweedfs/seaweedfs` version `3.8.5`

---

## Step 9 — Storage: SeaweedFS (DO THIS FIRST)

**Why:** Loki, Tempo, Mimir, and Temporal all need S3-compatible object storage. SeaweedFS must
be healthy and buckets created before the observability stack deploys.

### Files to Create

#### `platform/storage/values.yaml`
Helm values for SeaweedFS:
- `master.replicas: 1` (homelab — increase for HA)
- `master.persistence.storageClass: local-path`
- `volume.replicas: 3`
- `volume.persistence.storageClass: local-path`
- `filer.replicas: 1` (POSIX access for AI agent)
- `s3.enabled: true` (S3 API on port 8333)
- `s3.httpsPort: 0` (HTTP only in cluster, TLS terminated at Envoy Gateway)
- `s3.existingConfigSecret: seaweedfs-s3-config` (secret from SopsSecret)

#### `platform/storage/seaweedfs-s3-secret.enc.yaml`
SopsSecret with S3 credentials:
```yaml
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: seaweedfs-s3-credentials
  namespace: seaweedfs
spec:
  secretTemplates:
    - name: seaweedfs-s3-config
      stringData:
        config.json: |
          {
            "identities": [
              {
                "name": "platform-admin",
                "credentials": [
                  {
                    "accessKey": "<generate-random-32-char>",
                    "secretKey": "<generate-random-40-char>"
                  }
                ],
                "actions": ["Admin", "Read", "Write"]
              }
            ]
          }
```
Generate accessKey/secretKey with `openssl rand -hex 16` and `openssl rand -hex 20`.
Write to target path then immediately `sops --encrypt --in-place`.

Also create a second SopsSecret `seaweedfs-s3-credentials-ref` (namespace: observability)
with the same access/secret keys so Loki/Tempo/Mimir can authenticate.

#### `platform/storage/seaweedfs-buckets.yaml`
Kubernetes Job to create initial buckets after SeaweedFS is healthy:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: seaweedfs-create-buckets
  namespace: seaweedfs
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: create-buckets
          image: amazon/aws-cli:latest
          env:
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: seaweedfs-s3-config-parsed  # or inject directly
                  key: accessKey
          command:
            - /bin/sh
            - -c
            - |
              for bucket in loki tempo mimir temporal; do
                aws --endpoint-url http://seaweedfs-s3.seaweedfs.svc:8333 \
                    --region us-east-1 s3 mb s3://$bucket || true
              done
```
(Use envFrom from the S3 secret for credentials)

#### Update `cluster/apps/seaweedfs-app.yaml`
Add multi-source with `$values/platform/storage/values.yaml`.

#### Uncomment in `cluster/kustomization.yaml`
`- apps/seaweedfs-app.yaml`

### Test Gate
```bash
kubectl get pods -n seaweedfs
# All Running

kubectl run -it --rm s3test --image=amazon/aws-cli --restart=Never -- \
  aws --endpoint-url http://seaweedfs-s3.seaweedfs.svc:8333 \
  --region us-east-1 s3 ls
# Should list: loki, tempo, mimir, temporal
```

---

## Step 10 — Observability (LGTM Stack)

**Why:** Full observability before AI agents deploy. kagent needs Tempo + Mimir endpoints.

Deploy in this sub-order (dependencies):
1. alloy (metrics + logs pipeline) 
2. loki (log storage, S3 backend → SeaweedFS)
3. tempo (trace storage, S3 backend → SeaweedFS)
4. mimir (metric storage, S3 backend → SeaweedFS)
5. beyla (eBPF auto-instrumentation → exports to alloy)
6. grafana (UI, OIDC via Authentik)

### Key Values Patterns

**S3 backend pattern for Loki/Tempo/Mimir** (all similar):
```yaml
# loki values
storage:
  type: s3
  s3:
    endpoint: http://seaweedfs-s3.seaweedfs.svc:8333
    region: us-east-1
    bucketnames: loki
    accessKeyId: <from secret>
    secretAccessKey: <from secret>
    s3ForcePathStyle: true
    insecure: true
```

**Alloy scrape config** (River/Alloy syntax in a ConfigMap or values):
- Kubernetes service discovery for all namespaces
- Remote write: Loki (logs), Tempo (traces), Mimir (metrics)
- Also receives Alertmanager webhooks and forwards to kagent

**Beyla values:**
```yaml
preset: network           # or application
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: http://alloy.observability.svc:4317
  - name: BEYLA_TRACE_PRINTER
    value: text
```

**Grafana OIDC (Authentik) values:**
```yaml
grafana.ini:
  auth.generic_oauth:
    enabled: true
    name: Authentik
    client_id: <from authentik>
    client_secret: <from secret>
    scopes: openid profile email groups
    auth_url: https://auth.local/application/o/authorize/
    token_url: https://auth.local/application/o/token/
    api_url: https://auth.local/application/o/userinfo/
```

**observability-secrets.enc.yaml** (SopsSecret):
Contains S3 access/secret keys for Loki, Tempo, Mimir (all use same SeaweedFS keys).
Also contains Grafana admin password and Grafana Authentik client secret.

**HTTPRoute for Grafana:**
```yaml
hostname: grafana.local → grafana-service:80
```

### Test Gate
```bash
curl -k https://grafana.local/api/health
# {"database":"ok"}

kubectl logs -n observability -l app.kubernetes.io/name=beyla | grep -i instrument
# Shows eBPF attached to processes
```

---

## Step 11 — AI Agents (kagent + khook + GitHub MCP)

**Why:** The platform differentiator. Closed-loop AI SRE.

### Components

#### `agents/ai-sre-agent/anthropic-secret.enc.yaml`
SopsSecret with `ANTHROPIC_API_KEY`. Get the key from the user before creating this.
```yaml
spec:
  secretTemplates:
    - name: anthropic-api-key
      namespace: kagent
      stringData:
        ANTHROPIC_API_KEY: "sk-ant-..."
```

#### `agents/ai-sre-agent/kagent-values.yaml`
```yaml
llmProvider:
  provider: anthropic
  model: claude-sonnet-4-6
  apiKeySecret:
    name: anthropic-api-key
    key: ANTHROPIC_API_KEY
```

#### `agents/ai-sre-agent/agent-crd.yaml`
kagent `Agent` CRD defining the RCA workflow:
1. Receive K8s Warning event payload from khook
2. Query Tempo: `GET /api/traces?service=<affected-service>&lookback=15m`
3. Query Mimir: `GET /api/v1/query?query=rate(http_requests_total{status=~"5.."}[5m])`
4. Correlate with ArgoCD: `kubectl get applications -n argocd` for recent deploys
5. Format and hand off to GitHub MCP agent

#### `platform/hooks/khook-config.yaml`
khook `Hook` CRD watching for:
- `reason: OOMKilled`
- `reason: CrashLoopBackOff`
- `reason: Evicted`
→ webhook POST to `http://kagent.kagent.svc/webhook`

#### Alertmanager → kagent bridge
In `platform/observability/alloy-values.yaml`, add:
```river
// Alertmanager receiver that forwards to kagent
loki.process "kagent_alerts" {
  ...
}
```
Or configure the Alloy/Mimir Alertmanager with a webhook receiver pointing to kagent.

#### `agents/github-mcp-agent/mcp-config.yaml`
kagent `MCPServer` CRD:
```yaml
spec:
  transport: stdio
  command: npx
  args:
    - -y
    - "@modelcontextprotocol/server-github"
  env:
    - name: GITHUB_PERSONAL_ACCESS_TOKEN
      valueFrom:
        secretKeyRef:
          name: github-pat           # Created by SOPS from github-pat.enc.yaml
          key: token
```

The GitHub PAT Secret (`github-pat`) is already SOPS-encrypted in
`agents/github-mcp-agent/github-pat.enc.yaml` — SOPS Operator will create it.

#### GitHub Issue Format (RCA report)
```markdown
## RCA: [service] — [event type]
**What:** [error logs, trace ID from Tempo]
**Why:** [deployment correlation, latency spike from Mimir]
**Fix:** kubectl rollout undo deployment/[service] -n [ns]
```

### Test Gate
```bash
kubectl run crasher --image=busybox --restart=Always -- /bin/false
# Wait ~60-90 seconds
kubectl logs -n kagent -l app=kagent | grep -i rca
# Check GitHub repo Issues tab: new issue auto-created
kubectl delete pod crasher
```

---

## Step 12 — Sample Workloads (Temporal + Sample API)

### Temporal
- Chart: `https://go.temporal.io/helm-charts`, chart `temporal`, version `0.54.0`
- S3: SeaweedFS (`s3://temporal`) for history/visibility
- PostgreSQL: bundled Bitnami sub-chart, `local-path` storage
- HTTPRoute: `temporal.local → temporal-web:8080`

### Sample Go API
A minimal HTTP API in `apps/sample-api/` that:
- Has NO OpenTelemetry SDK imports (demonstrates Beyla zero-code instrumentation)
- Exposes `/` and `/health` endpoints
- Generates realistic HTTP traffic for Beyla to capture

Create:
- `apps/sample-api/deployment.yaml`
- `apps/sample-api/service.yaml`
- `apps/sample-api/httproute.yaml` (optional: sample-api.local)

### Test Gate
```bash
kubectl get pods -n temporal
curl -k https://temporal.local      # UI responds

kubectl get pods -n sample-api
kubectl logs -n observability -l app.kubernetes.io/name=beyla | grep sample-api
# Beyla showing traces from sample-api without any SDK
```

---

## End-to-End Verification (Run After Step 12)

```bash
# 1. Clone-and-go test (destroy and rebuild)
# On the Talos cluster, clear all namespaces then:
git clone https://github.com/Matcham89/AI-powered-SRE
cd AI-powered-SRE
./bootstrap/install.sh
# Expected: ~15-20 min, all ArgoCD apps Synced+Healthy

# 2. AI closed-loop test
kubectl run crasher --image=busybox --restart=Always -- /bin/false
# Wait 2-3 min
# GitHub repo → Issues → new RCA issue auto-created
kubectl delete pod crasher

# 3. Security validation
kubectl exec -it -n apps deploy/sample-api -- \
  curl http://argocd-server.argocd 2>&1
# Expected: timeout (Cilium default-deny blocks)
```

---

## E2E Test

Read `prompts/e2e-test.md` alongside this PRD. It defines:
- k3s installation flags (Traefik + ServiceLB disabled)
- All 12 e2e checks (k3s, ArgoCD apps, SeaweedFS, Grafana, Loki, Temporal, CNPG, Sample API, Beyla, AI closed-loop, Security)
- The full e2e is invoked via `./bootstrap/install.sh --e2e`
- The script auto-installs k3s if not present, then bootstraps and runs all checks

**Run this after all platform steps are deployed and healthy before marking the project complete.**

---

## Important Rules for the Next Agent

1. **Test every step before moving to the next.** No skipping test gates.
2. **Update `prompts/platform-prd-and-decisions.md`** after each step with what was built and test results.
3. **Never write plaintext secrets.** All secrets: write to path matching `.sops.yaml` regex, encrypt in-place immediately.
4. **YAML validation:** use `ruby -e "require 'yaml'; YAML.load_stream(File.read('file.yaml'))"` (no python yaml module).
5. **kustomize:** use `kubectl kustomize <path>` (standalone `kustomize` not installed).
6. **Helm lint:** pull chart to /tmp first, then lint, then rm -rf /tmp/chart.
7. **Don't activate an app in `cluster/kustomization.yaml` until its values files exist** — ArgoCD will fail to sync without them.
8. **Keep `cluster/kustomization.yaml` as the single source of truth** for what's active.
9. **SeaweedFS MUST be healthy before observability apps are activated.**
10. **The Anthropic API key is already committed** — `agents/ai-sre-agent/anthropic-secret.enc.yaml` exists and is encrypted.
11. **Run `./bootstrap/install.sh --e2e` as the final verification step** — all 12 checks must pass before the project is complete.
