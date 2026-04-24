# AI-Powered SRE Platform

Kubernetes platform that self-heals: when a pod crashes, a Claude-powered agent gathers logs, traces, and metrics, then opens a GitHub Issue with a root-cause analysis report.

**Stack:** k3s · ArgoCD · Authentik SSO · Loki/Tempo/Mimir/Grafana · kagent (Claude Sonnet 4.6) · SeaweedFS · Temporal · Envoy Gateway · SOPS

---

## Prerequisites

### Tools

| Tool | Purpose | Install |
|------|---------|---------|
| `kubectl` | Talk to the cluster | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | Install ArgoCD + SOPS Operator charts | https://helm.sh/docs/intro/install/ |
| `sops` | Decrypt the bootstrap repo credentials locally | https://github.com/getsops/sops/releases |
| `age` | Encryption backend used by SOPS | https://github.com/FiloSottile/age/releases |
| `python3` | Parses decrypted SOPS JSON during bootstrap (stdlib only — no `pip install` needed) | preinstalled on macOS |
| `terraform` | Configures Authentik OIDC providers (skipped with a warning if missing) | https://developer.hashicorp.com/terraform/install |
| `curl`, `sudo` | k3s installer + `/etc/hosts` update | system packages |

macOS shortcut:
```bash
brew install kubectl helm sops age terraform
```

### Kubernetes cluster

The script installs k3s automatically if no cluster is reachable. If you already have a cluster running (Rancher Desktop, Docker Desktop, kind, etc.), the script detects it and uses your current `kubectl` context — no k3s install attempted.

### Tested environment

Verified end-to-end on:

- **Rancher Desktop** on an Apple Mac (Apple Silicon)
- **6 CPU / 14 GB memory** allocated to the VM
- Kubernetes backend: k3s (Rancher Desktop default)

The platform runs ~25 ArgoCD applications including the full LGTM observability stack, Authentik, Temporal, CNPG, SeaweedFS, and kagent. Smaller VM allocations (under 12 GB) are likely to hit memory pressure during initial sync.

### Age private key

You also need the **Age private key** for this repo — obtain it from the repo owner. Place it at the default location:

```bash
mkdir -p ~/.config/sops/age
# paste the key into this file — it looks like:
# AGE-SECRET-KEY-1XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
nano ~/.config/sops/age/keys.txt
```

That is the only secret you need. Everything else — SSO config, API keys, database passwords, OIDC client secrets — is already SOPS-encrypted in the repo and decrypted automatically at deploy time.

Verify the key works before running bootstrap:
```bash
sops --decrypt cluster/registry/repo-credentials.enc.yaml
```

---

## Deploy

```bash
git clone https://github.com/Matcham89/AI-powered-SRE
cd AI-powered-SRE
./bootstrap/install.sh
```

The script is fully idempotent — safe to re-run.

At the end it prints your **SSO credentials and service URLs**.

---

## What bootstrap does

| Step | Action |
|------|--------|
| 0 | Installs k3s (skips if a cluster is already reachable) |
| 1 | Checks prerequisites |
| 2 | Confirms Kubernetes context |
| 3 | Loads Age private key |
| 4 | Creates namespaces |
| 5 | Injects Age key as a cluster Secret — SOPS Operator uses this to decrypt everything else in-cluster |
| 6 | Installs ArgoCD v3.3.8 |
| 7 | Installs SOPS Secrets Operator |
| 7b | Bootstraps ArgoCD repo credentials (one-time imperative step — decrypted locally with SOPS) |
| 8 | Applies App-of-Apps root — ArgoCD takes over, syncing all platform components from git |
| 9 | Waits for all 25 apps to reach Synced+Healthy (up to 25 min) |
| 10 | Discovers Envoy Gateway NodePort, prints the `/etc/hosts` commands for you to run |
| 11 | Decrypts SSO secrets via SOPS, waits for Authentik, runs `terraform apply` to configure OIDC providers |

No manual secret copying or config file editing required.

**Full e2e validation** (12 integration tests including the AI closed-loop):

```bash
./bootstrap/install.sh --e2e
```

**Dry run** (prints every step, makes no changes):

```bash
./bootstrap/install.sh --dry-run
```

---

## Access

After bootstrap completes, the script prints your SSO username, password, NodePort, and `/etc/hosts` entries. Services are available at:

| Service | URL | Login |
|---------|-----|-------|
| ArgoCD | `https://argocd.local:<port>` | SSO |
| Grafana | `https://grafana.local:<port>` | SSO |
| Authentik | `https://auth.local:<port>` | SSO |
| Temporal | `https://temporal.local:<port>` | SSO |

**ArgoCD native admin password** (if you need it before SSO is configured):
```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

---

## Architecture

The platform is split into four stages, each building on the last.

```
bootstrap/    Spark   — k3s, ArgoCD, SOPS Operator, Age key injection
cluster/      Brain   — App-of-Apps root; ArgoCD self-manages from here
platform/     Body    — Gateway, SSO, LGTM observability, storage, event hooks
agents/       Intel   — kagent RCA engine (Claude Sonnet 4.6) + GitHub MCP server
```

### Ingress

All UIs are exposed through a single Envoy Gateway NodePort. TLS is terminated at the gateway using a cert-manager self-signed wildcard certificate. Routes are declared as `HTTPRoute` CRDs (Kubernetes Gateway API), not legacy `Ingress` objects.

```
Browser → Envoy Gateway (NodePort :32170)
             ├── argocd.local   → argocd-server (argocd ns)
             ├── grafana.local  → grafana (observability ns)
             ├── auth.local     → authentik-server (authentik ns)
             └── temporal.local → temporal-ui (temporal ns)
```

### SSO

Authentik acts as the OIDC identity provider for all services. Terraform provisions the OAuth2 providers and applications inside Authentik at bootstrap time. Each service (ArgoCD, Grafana, Temporal) uses OIDC login backed by Authentik, with ArgoCD routing through DEX so the OIDC redirect hits the internal Authentik service URL rather than the external gateway.

### Secret management

All secrets are SOPS-encrypted with Age and committed to git. The Age private key is the only thing not in git.

```bash
# Edit an encrypted secret
sops path/to/file.enc.yaml

# Encrypt a new secret file
sops --encrypt --in-place path/to/file.enc.yaml
```

SOPS routing rules (`.sops.yaml`) ensure only `data` and `stringData` keys are encrypted — structural YAML fields stay plaintext so ArgoCD and kustomize can parse manifests without decrypting them. The SOPS Secrets Operator watches `SopsSecret` CRDs in-cluster and materialises them as native `Secret` objects automatically.

### GitOps

A single App-of-Apps root (`cluster/root-app.yaml`) points ArgoCD at `cluster/kustomization.yaml`, which declares all 23 platform applications. Every app uses automated sync with `prune: true` and `selfHeal: true` — the cluster continuously converges to whatever is in git.

```
Git push
  → ArgoCD detects diff
  → Syncs Application
  → Applies Helm chart or kustomize manifests
  → SOPS Operator decrypts any new SopsSecrets
```

### Observability pipeline

```
Pod logs        → Alloy (DaemonSet)         → Loki   (S3: SeaweedFS)
Kubernetes/host → kube-state-metrics +
                  node-exporter → Alloy     → Mimir  (S3: SeaweedFS)
HTTP traces     → Beyla (eBPF DaemonSet) →
                  Alloy (OTLP :4317/4318)   → Tempo  (S3: SeaweedFS)
                                                 ↓
                                         Grafana (unified view)
```

Beyla auto-instruments HTTP at the kernel level — no application code changes, no sidecars. Alloy is the single data pipeline collecting from all sources and fanning out to Loki, Mimir, and Tempo. SeaweedFS provides S3-compatible object storage for all three backends, running entirely in-cluster.

### AI agent loop

```
Pod crashes (CrashLoopBackOff / OOM / probe failure)
  → khook watches Kubernetes events
  → Webhooks to kagent API (:8080)
  → Claude Sonnet 4.6 RCA agent runs:
      1. k8s_get_pod_logs / k8s_get_events
      2. Query Tempo for trace IDs and latency spikes
      3. Query Mimir for error rates and memory trends
      4. Query Kubernetes API for recent ArgoCD deployments
      5. Correlate findings → root cause
  → GitHub MCP server opens Issue with RCA report + suggested fix commands
```

The agent is declared as a Kubernetes CRD (`agents/ai-sre-agent/agent-crd.yaml`). It has access to two MCP tool servers: one for Kubernetes API operations, one for GitHub. A `ModelConfig` CRD points it at `claude-sonnet-4-6` via a SOPS-encrypted Anthropic API key secret.

### Network security

A default-deny `NetworkPolicy` is applied to the `kagent` namespace. Explicit allow rules in `security/allow-rules/` open only the required egress paths: Kubernetes API, Tempo, Mimir, GitHub (443), and the khook webhook port. Other namespaces follow a similar pattern. DNS egress to kube-dns is explicitly allowed across all namespaces.

---

## Running Terraform manually

Bootstrap handles Terraform automatically. If you need to re-run it outside of bootstrap:

```bash
kubectl port-forward -n authentik svc/authentik-server 9000:80 &
cd terraform && terraform apply
```

Terraform variables are pulled from `TF_VAR_*` env vars when set by the bootstrap script. For manual runs, copy `terraform/terraform.tfvars.example` to `terraform/terraform.tfvars` and fill in the values (comments in the file explain where each comes from).

---

## Design decisions

**k3s over a managed Kubernetes service.** The goal was a full platform that runs on a single machine — a MacBook or a homelab node — without a cloud bill. k3s ships as a single binary, starts in seconds, and supports everything in this stack. Traefik and the default load balancer are disabled so Envoy Gateway owns ingress without conflicts.

**App-of-Apps with automated sync.** A single root ArgoCD Application bootstraps all 25 apps from one kustomize manifest. Automated sync with self-heal means the cluster continuously reconciles to git state — no manual `argocd app sync` required after a change is pushed.

**SOPS + Age over external secret stores.** Vault and AWS Secrets Manager require running infrastructure before Kubernetes is up. Age encryption is file-based: secrets live in git, encrypted, and are decrypted in-cluster by the SOPS Operator. The only operational requirement is one private key file. This keeps the bootstrap entirely self-contained.

**Envoy Gateway over Ingress.** The Kubernetes Gateway API (`HTTPRoute`, `GatewayClass`) is the successor to `Ingress`. Envoy Gateway implements it cleanly and supports the traffic splitting and header manipulation needed for more complex routing later — without the hacks required to achieve the same with annotations on an Ingress controller.

**Beyla for zero-touch tracing.** Beyla uses eBPF to instrument HTTP at the kernel level. The sample API needed no changes to produce distributed traces in Tempo. This matters for the RCA agent: traces are available for any workload that runs on the cluster, not just ones instrumented by developers.

**SeaweedFS over cloud object storage.** Loki, Tempo, and Mimir all require S3-compatible backends for long-term storage. SeaweedFS runs in-cluster and exposes an S3 API, keeping the platform fully air-gapped. The tradeoff is that SeaweedFS is not highly available in this single-node configuration — acceptable for a homelab platform, not for production.

**Terraform for SSO configuration.** Authentik's API is rich but complex. Terraform's Authentik provider declaratively provisions OAuth2 providers, applications, scopes, and users. The alternative — clicking through the Authentik UI — is not repeatable. Bootstrap runs `terraform apply` automatically so SSO is ready on first boot.

**kagent + khook for the AI loop.** kagent is a Kubernetes-native agent framework: agents are declared as CRDs, tooling is provided via MCP servers, and the model config is separate from the agent logic. khook watches raw Kubernetes events and webhooks to kagent — the event-to-agent path requires no custom controller code. The combination is declarative end-to-end.

**Observability stack tuned for single-node use.** The default Loki, Mimir, and Tempo Helm values target multi-replica, long-retention deployments. On a single k3s node this causes unnecessary resource pressure. Retention is set to 1 hour for logs (Loki) and traces (Tempo), and 2 hours for metrics (Mimir) — enough for real-time debugging and alert evaluation without unbounded storage growth. Alloy scrape intervals are doubled from 30 s to 60 s, halving metric collection overhead. The Mimir `query_scheduler` is disabled since it only helps when there are multiple query-frontend and querier replicas. Beyla's `BEYLA_TRACE_PRINTER` env var is removed (it was printing every trace to stdout, which Alloy vacuumed into Loki and created a CPU feedback loop); a 20 % sampling ratio keeps a representative trace sample. Resource requests and limits are set on all five components so the scheduler has accurate bin-packing data and no single component can saturate the node.

---

## Roadmap

Things I would build or improve if this were going to production:

**Grafana alerting rules and metric/label standardisation.** The observability stack collects data from all components but has no alerting configured. The next step would be a set of PrometheusRule CRDs covering pod restart rates, OOM events, API error rates, and Envoy upstream health — with consistent label schemes across Loki, Mimir, and Tempo so correlating across signals in Grafana is straightforward. Metric relabelling and stream selectors would need a cleanup pass to ensure label cardinality stays manageable.

**Agent Gateway for AI traffic control.** All Claude API calls currently go direct from the kagent pod to Anthropic. An Agent Gateway (such as Portkey or a self-hosted proxy) would add rate limiting, cost tracking per-agent, prompt logging, and a kill switch — without changing the agent code. This becomes important once multiple agents are running concurrently or the platform is shared across teams.

**External RBAC provider.** Kubernetes RBAC covers in-cluster authorisation, but there is no centralised policy store. Integrating Open Policy Agent (OPA) or Kyverno as an admission controller would allow policy-as-code for things the cluster currently has no visibility into: which namespaces can mount which secrets, which service accounts can call which APIs, and cross-namespace network rules. This would also give the AI agent a structured policy document to query when evaluating whether a configuration change is safe.

**Richer agent skills with per-service documentation.** The current RCA agent has a generalised system prompt and a set of Kubernetes + GitHub tools. The meaningful improvement is bespoke skills per service — a Grafana skill that knows the datasource UIDs and panel query patterns, an Authentik skill that knows the flow and provider structure, an ArgoCD skill that knows the sync window and app dependency graph. Each skill would embed the relevant operational runbook so the agent can not just diagnose but prescribe. kagent supports skill composition via CRDs; the limiting factor is writing the skills, not wiring them in.

**High-availability SeaweedFS and CNPG.** The current SeaweedFS deployment is single-replica and single-node. For a production platform the Loki, Tempo, and Mimir backends need at minimum a replicated volume server and a distributed master. CNPG already supports standby replicas; increasing the CNPG cluster from 1 to 3 instances and enabling SeaweedFS replication would be the first step toward a durable platform.
