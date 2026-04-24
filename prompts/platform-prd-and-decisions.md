# AI-Powered SRE Platform — PRD, Decisions & Session Log

> Last updated: 2026-04-24 (Session 2 — Steps 9–12 complete, all secrets committed)

---

## Original PRD

Solving the "Chicken and Egg" problem of GitOps authentication using **SOPS + Age**.
The GitHub PAT is stored SOPS-encrypted in git. The bootstrap script's only job is
to inject the Age private key into the cluster once — everything else is declarative.

### Directory Structure (Final)
```
.
├── bootstrap/               # Stage 0: The "Spark"
│   ├── install.sh
│   └── manifests/
├── cluster/                 # Stage 1: The "Brain"
│   ├── root-app.yaml
│   ├── kustomization.yaml
│   ├── registry/            # SOPS-encrypted SopsSecret CRDs
│   ├── argocd/              # ArgoCD self-management config
│   └── apps/                # All ArgoCD Application CRDs (one per component)
├── platform/                # Stage 2: The "Body"
│   ├── gateway/             # Envoy Gateway + cert-manager
│   ├── auth/                # Authentik (OIDC/SSO)
│   ├── storage/             # SeaweedFS (S3/Persistence)
│   ├── hooks/               # khook (Event-to-Webhook)
│   └── observability/       # Grafana Alloy, Beyla, Loki, Tempo, Mimir, Grafana
├── agents/                  # Stage 3: The "Intelligence"
│   ├── ai-sre-agent/        # kagent RCA engine
│   └── github-mcp-agent/    # GitHub Issue delivery (MCP)
├── apps/                    # Sample workloads
│   ├── temporal/
│   └── sample-api/
├── security/                # Cilium/K8s NetworkPolicies
└── prompts/                 # Session handoff docs (this dir)
```

---

## Architecture Decisions

### 1. SOPS Secrets Operator (NOT ESO)
ESO has no SOPS backend. Use **SOPS Secrets Operator** (`isindir/sops-secrets-operator`)
chart `0.26.0` app `0.20.2`.

Flow: `git (SopsSecret CRD, encrypted)` → `ArgoCD syncs` → `SOPS Operator decrypts`
→ `native K8s Secret` → `ArgoCD uses for GitHub auth`

No ESO anywhere in this platform.

### 2. Target: Talos Linux homelab (NOT K3s)
User's cluster context: `admin@talos-homelab` at `https://192.168.1.180:6443`
K3s was the original PRD target but actual cluster is Talos. Bootstrap script detects
context and warns user — no hard K3s assumption baked in.

### 3. SeaweedFS for Object Storage
S3-compatible backend for Loki, Tempo, Mimir. Undocumented officially but works via
S3 API compatibility. Smoke test (bucket create/list) gates the observability deploy.

### 4. khook Scope Clarification
`khook` (kagent-dev/khook) handles Kubernetes events → kagent only.
Prometheus/Alertmanager alerts route via Alertmanager webhook receiver → kagent API.

### 5. Envoy Gateway via OCI
Official Helm repo unreachable. Chart available as OCI:
`oci://docker.io/envoyproxy/gateway-helm:v1.3.2`

### 6. cluster/apps/ Pattern
All ArgoCD Application CRDs live in `cluster/apps/`. Platform directories
(`platform/`, `security/`, `agents/`, `apps/`) contain ONLY Helm values files
and raw K8s manifests — NOT Application CRDs. This keeps all routing in one place.

### 7. Staged Kustomization
`cluster/kustomization.yaml` uncomments one app at a time as each step is
implemented and tested. Keeps ArgoCD dashboard clean with no failing apps.

### 8. Two GitHub PATs
- PAT 1 (ArgoCD "Platform Scraper"): stored in `cluster/registry/repo-credentials.enc.yaml`
  → becomes ArgoCD repo credential Secret
- PAT 2 (AI SRE Agent "Reporter"): stored in `agents/github-mcp-agent/github-pat.enc.yaml`
  → consumed by GitHub MCP agent for creating issues

Age public key: `age1jpjljdr54z2929pj587e2tl64cvfz67dugx4df0t93y96fnqx4uq7e8qvg`
Age private key: at `~/.config/sops/age/keys.txt` (NEVER committed)

---

## Implementation Progress

### ✅ Step 1 — Repo Scaffolding & SOPS Config
Files created:
- `.sops.yaml` — Age public key wired for 4 path regexes
- `.gitignore` — excludes Age key, .env, kubeconfig
- `.env.example` — documents all required env vars
- All platform directories with `.gitkeep`

Test gate: SOPS encrypt/decrypt round-trip in `cluster/registry/` — PASS

### ✅ Step 2 — SOPS-Encrypted Secrets (Token First)
Files created:
- `cluster/registry/repo-credentials.enc.yaml` — ArgoCD PAT (SopsSecret CRD, SOPS-encrypted)
- `cluster/registry/cluster-local.enc.yaml` — In-cluster ArgoCD registration (SopsSecret CRD)
- `agents/github-mcp-agent/github-pat.enc.yaml` — AI SRE Agent PAT (SopsSecret CRD)

Test gate: All 3 files have ENC[] values, round-trip decrypt works — PASS

### ✅ Step 3 — Bootstrap Manifests
Files created:
- `bootstrap/manifests/namespaces.yaml` — argocd, sops-operator namespaces
- `bootstrap/manifests/sops-operator-values.yaml` — SOPS Operator Helm values
- `bootstrap/manifests/sops-age-secret.yaml.template` — documents the single imperative step
- `cluster/root-app.yaml` — ArgoCD App-of-Apps pointing to `cluster/`

Test gate: kubectl dry-run + helm lint — PASS

### ✅ Step 4 — Bootstrap Script
File created:
- `bootstrap/install.sh` — 9-step orchestrator, idempotent, --dry-run flag

Test gate: shellcheck clean (0 warnings), dry-run output correct — PASS
Note: Cluster context detected as `admin@talos-homelab` @ `192.168.1.180:6443`

### ✅ Step 5 — ArgoCD Self-Management
Files created:
- `cluster/kustomization.yaml` — staged kustomization (resources added per step)
- `cluster/argocd/argocd-cm.yaml` — annotation tracking, HTTPRoute health check, OIDC placeholder
- `cluster/argocd/argocd-rbac-cm.yaml` — default readonly, admin via OIDC group `argocd-admins`
- `cluster/apps/` — 15 Application CRDs pre-built (all commented in kustomization until their step)

Test gate: All 19 YAML files valid, kustomize builds — PASS

### ✅ Step 6 — Platform Secrets Layer (SOPS Operator as GitOps-managed)
Action: Uncommented `apps/sops-operator-app.yaml` in `cluster/kustomization.yaml`
File: `cluster/apps/sops-operator-app.yaml` (multi-source: OCI chart + git values)

Test gate: kustomize build includes sops-operator app, helm chart reachable — PASS

### ✅ Step 7 — Networking (Envoy Gateway + cert-manager + NetworkPolicies)
Files created:
- `platform/gateway/values.yaml` — Envoy Gateway Helm values
- `platform/gateway/gateway.yaml` — EnvoyProxy (NodePort) + Gateway instance (HTTP+HTTPS)
- `platform/gateway/cert-manager-values.yaml` — cert-manager Helm values
- `platform/gateway/cluster-issuer.yaml` — self-signed ClusterIssuer + wildcard Certificate
- `cluster/apps/gateway-app.yaml` — UPDATED: OCI chart `oci://docker.io/envoyproxy/gateway-helm:v1.3.2`
- `cluster/apps/gateway-resources-app.yaml` — raw Gateway manifests, sync-wave: 1
- `cluster/apps/cert-manager-app.yaml` — jetstack/cert-manager v1.20.2
- `cluster/apps/security-app.yaml` — security policies, sync-wave: 2
- `security/kustomization.yaml`
- `security/default-deny.yaml` — NetworkPolicy default-deny for `kagent` namespace
- `security/allow-rules/dns-allow.yaml` — DNS egress for kagent
- `security/allow-rules/argocd-allow.yaml` — ArgoCD → GitHub + K8s API
- `security/allow-rules/agents-allow.yaml` — kagent → observability + GitHub API
- `security/allow-rules/observability-allow.yaml` — observability stack policies

Kustomization: gateway-app, gateway-resources-app, cert-manager-app, security-app ACTIVE

Test gate: 28 files valid, kustomize build cluster/ + security/ clean — PASS

### ✅ Step 8 — Auth (Authentik OIDC/SSO)
Files created:
- `platform/auth/authentik-secret.enc.yaml` — SopsSecret with secret_key, pg_pass, bootstrap creds (SOPS-encrypted)
- `platform/auth/values.yaml` — Helm values, uses existingSecret for pg auth, envFrom for credentials
- `platform/auth/httproute-authentik.yaml` — HTTPRoute: auth.local → authentik-server:80
- `cluster/apps/authentik-app.yaml` — UPDATED: multi-source Helm, sync-wave: 1
- `cluster/apps/authentik-routes-app.yaml` — NEW: HTTPRoute-only app, sync-wave: 2

Bootstrap password: encrypted in `platform/auth/authentik-secret.enc.yaml`
Retrieve: `sops --decrypt platform/auth/authentik-secret.enc.yaml | grep BOOTSTRAP_PASSWORD`

Kustomization: authentik-app, authentik-routes-app ACTIVE

Test gate: YAML valid, SOPS round-trip (4 secrets), kustomize build, helm lint 0 failures — PASS

---

## ✅ Step 9 — Storage: SeaweedFS
Files created:
- `platform/storage/values.yaml` — Master×1, Volume×3, Filer×1, S3 on port 8333 via `filer.s3`
- `platform/storage/seaweedfs-s3-secret.enc.yaml` — SopsSecret (3 templates: `seaweedfs-s3-config`, `seaweedfs-s3-creds`, `seaweedfs-s3-credentials-ref`)
- `platform/storage/kustomization.yaml` — deploys SopsSecret via ArgoCD path source
- `cluster/apps/seaweedfs-app.yaml` — UPDATED: multi-source (OCI chart v4.21.0 + $values ref + platform/storage path)

Decisions:
- Chart version updated 3.8.5 → 4.21.0 (3.8.5 no longer in repo)
- Chart supports native bucket creation via `filer.s3.createBuckets` — no Job needed
- Secret key must be `seaweedfs_s3_config` (not `config.json`) per chart schema
- S3 endpoint: `http://seaweedfs-filer.seaweedfs.svc:8333`

Kustomization: `apps/seaweedfs-app.yaml` ACTIVE
Test gate pending: verify pods Running + bucket list via aws-cli

### ✅ Step 10 — Observability (LGTM Stack)
Files created:
- `platform/observability/observability-secrets.enc.yaml` — SopsSecret: Grafana admin creds, OIDC client secret, S3 creds for Loki/Tempo/Mimir
- `platform/observability/alloy-values.yaml` — DaemonSet, pod log scrape, OTLP receiver → Tempo, remote_write → Mimir
- `platform/observability/loki-values.yaml` — SingleBinary mode, S3 backend (SeaweedFS), replicas 0 for read/write/backend
- `platform/observability/tempo-values.yaml` — Single binary (`grafana/tempo` not `tempo-distributed`), S3 backend, OTLP receiver on 4317/4318
- `platform/observability/mimir-values.yaml` — `mimir-distributed` with `structuredConfig.common.storage.backend: s3`, all replicas=1, all caches disabled
- `platform/observability/beyla-values.yaml` — DaemonSet, OTEL exports to `alloy.observability.svc:4317`
- `platform/observability/grafana-values.yaml` — Authentik OIDC, pre-provisioned Loki/Tempo/Mimir datasources, admin secret ref
- `platform/observability/httproute-grafana.yaml` — HTTPRoute: grafana.local → grafana:80
- `platform/observability/kustomization.yaml` — SopsSecret + HTTPRoute

Decisions:
- Loki chart: 6.29.0 → 7.0.0 (latest); using SingleBinary mode (not scalable) for homelab
- Tempo chart: switched from `tempo-distributed` → `grafana/tempo` 1.24.4 (single binary)
- Mimir chart: 5.6.0 → 6.0.6 (latest); all caches disabled for homelab resource efficiency
- Grafana chart: 8.8.4 → 10.5.15 (latest)
- Alloy chart: 0.12.0 → 1.8.0 (latest)
- Beyla chart: 1.4.3 → 1.16.5 (latest)
- Grafana raw manifests (SopsSecret + HTTPRoute) deployed via third source in grafana-app.yaml

Kustomization: loki, tempo, mimir, alloy, beyla, grafana ACTIVE
Test gate pending: `curl -k https://grafana.local/api/health`

### ✅ Step 11 — AI Agents (kagent + khook + GitHub MCP)
Files created:
- `agents/ai-sre-agent/kagent-values.yaml` — `providers.default: anthropic`, model: claude-sonnet-4-6
- `agents/ai-sre-agent/agent-crd.yaml` — ModelConfig CRD (Anthropic) + Agent CRD (RCA workflow, GitHub MCP tools)
- `agents/ai-sre-agent/kustomization.yaml` — deploys Agent + ModelConfig
- `agents/github-mcp-agent/mcp-config.yaml` — MCPServer CRD (`@github/mcp-server` via npx, refs `github-pat` Secret)
- `agents/github-mcp-agent/kustomization.yaml` — deploys SopsSecret + MCPServer
- `platform/hooks/khook-config.yaml` — Hook CRD: pod-restart, oom-kill, probe-failed → ai-sre-agent
- `platform/hooks/kustomization.yaml` — deploys Hook CR
- `cluster/apps/cnpg-app.yaml` (added for Step 12 prereq, wave 1)

Decisions:
- kagent Helm chart: OCI `oci://ghcr.io/kagent-dev/kagent/helm` v0.8.6 (not traditional repo)
- khook Helm chart: OCI `oci://ghcr.io/kagent-dev/khook/helm` v0.0.4
- kagent API version: `kagent.dev/v1alpha2` for Agent/ModelConfig/Hook; `v1alpha1` for MCPServer
- khook event types: `pod-restart`, `oom-kill`, `probe-failed` (khook uses these names, not raw K8s reasons)
- `agents/ai-sre-agent/anthropic-secret.enc.yaml` — SopsSecret: `kagent-anthropic` secret with ANTHROPIC_API_KEY ✅

Kustomization: kagent, khook, github-mcp ACTIVE
Test gate pending: needs Anthropic API key first

### ✅ Step 12 — Sample Workloads (CNPG + Temporal + sample API)
Files created:
- `cluster/apps/cnpg-app.yaml` — CloudNative-PG operator v0.28.0 (chart 0.28.0), wave 1
- `apps/temporal/temporal-secret.enc.yaml` — SopsSecret: superuser + app + db-secret for CNPG
- `apps/temporal/postgresql.yaml` — CNPG `Cluster` CR (1 instance, `temporal` database + `temporal_visibility`, local-path 5Gi)
- `apps/temporal/values.yaml` — Temporal 1.1.1, postgres12_pgx driver, connects to `temporal-postgres-rw.temporal.svc:5432`
- `apps/temporal/httproute-temporal.yaml` — HTTPRoute: temporal.local → temporal-web:8080
- `apps/temporal/kustomization.yaml`
- `apps/sample-api/deployment.yaml` — nginx:1.27-alpine serving JSON at `/` and `/health` (no SDK — Beyla auto-instruments)
- `apps/sample-api/service.yaml`
- `apps/sample-api/httproute.yaml` — HTTPRoute: sample-api.local → sample-api:80
- `apps/sample-api/kustomization.yaml`
- `.sops.yaml` updated: added `apps/.*\.enc\.yaml$` path regex

Decisions:
- Temporal chart: 0.54.0 → 1.1.1 (latest); new chart has no bundled sub-charts
- PostgreSQL: CNPG `Cluster` CR (not Bitnami sub-chart) — user directive
- CNPG service: `temporal-postgres-rw` (read-write endpoint auto-created by CNPG operator)
- `visibility` database created via `postInitSQL` in CNPG bootstrap
- Sample API: nginx instead of Go binary (simpler, same Beyla instrumentation demo)

Kustomization: cnpg, temporal, sample-api ACTIVE
Test gate pending: `kubectl get cluster -n temporal`, `curl -k https://temporal.local`

---

---

## Tool Versions Pinned

| Tool | Version | Notes |
|------|---------|-------|
| ArgoCD | v3.3.8 | HA manifest |
| SOPS | v3.12.2 | installed |
| age | v1.3.1 | installed |
| SOPS Secrets Operator | chart 0.26.0, app 0.20.2 | |
| Envoy Gateway | v1.3.2 | OCI: `oci://docker.io/envoyproxy/gateway-helm` |
| cert-manager | v1.20.2 | jetstack repo |
| Authentik | 2024.12.3 | charts.goauthentik.io |
| SeaweedFS | **4.21.0** (chart) | seaweedfs.github.io/seaweedfs/helm |
| Grafana Alloy | **1.8.0** (chart) | grafana repo |
| Grafana Beyla | **1.16.5** (chart) | grafana repo |
| Grafana Loki | **7.0.0** (chart) | SingleBinary mode |
| Grafana Tempo | **1.24.4** (chart) | `grafana/tempo` single binary |
| Grafana Mimir | **6.0.6** (chart) | mimir-distributed, caches disabled |
| Grafana | **10.5.15** (chart) | grafana repo |
| kagent | **0.8.6** (chart) | OCI: `oci://ghcr.io/kagent-dev/kagent/helm` |
| khook | **0.0.4** (chart) | OCI: `oci://ghcr.io/kagent-dev/khook/helm` |
| CloudNative-PG | **0.28.0** (chart) | cloudnative-pg.github.io/charts |
| Temporal | **1.1.1** (chart) | go.temporal.io/helm-charts |

---

## Key File Locations

| File | Purpose |
|------|---------|
| `.sops.yaml` | SOPS Age routing (4 path regexes) |
| `bootstrap/install.sh` | Single entry point, 9 steps, --dry-run safe |
| `cluster/root-app.yaml` | App-of-Apps (applied by bootstrap) |
| `cluster/kustomization.yaml` | Staged list of active ArgoCD apps |
| `cluster/apps/` | ALL ArgoCD Application CRDs |
| `platform/*/values.yaml` | Helm values per component |
| `platform/*/httproute-*.yaml` | Envoy Gateway HTTPRoutes per UI |
| `security/` | NetworkPolicies (kustomize-managed) |
| `agents/github-mcp-agent/github-pat.enc.yaml` | AI SRE Agent PAT (SOPS) |
| `platform/auth/authentik-secret.enc.yaml` | Authentik secrets (SOPS) |
