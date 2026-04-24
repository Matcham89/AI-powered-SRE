# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

An AI-powered SRE platform on Kubernetes. It combines GitOps (ArgoCD), a full observability stack (LGTM: Loki/Grafana/Tempo/Mimir), and Claude-powered AI agents (kagent) that automatically detect Kubernetes failures, gather observability data, and open GitHub Issues with root-cause analysis reports.

## Deployment Commands

```bash
# Full bootstrap (installs k3s, ArgoCD, SOPS Operator, applies App-of-Apps)
./bootstrap/install.sh

# Dry-run to preview all steps without making changes
./bootstrap/install.sh --dry-run

# Bootstrap + run full e2e validation suite
./bootstrap/install.sh --e2e

# Configure Authentik OIDC providers for ArgoCD/Grafana (after bootstrap)
cd terraform && terraform apply

# Watch all ArgoCD apps sync
kubectl get applications -n argocd -w
```

## Secret Management (SOPS + Age)

All secrets are SOPS-encrypted and committed to git. The Age private key is the only thing not in git.

**Encrypt a new secret file:**
```bash
# Must be a SopsSecret CRD with data/stringData keys
sops --encrypt --in-place path/to/file.enc.yaml
```

**Edit an encrypted file:**
```bash
sops path/to/file.enc.yaml
```

**Routing rules** (from `.sops.yaml`): files under `cluster/registry/`, `platform/`, `agents/`, and `apps/` with `.enc.yaml` suffix are encrypted. Only `data`/`stringData` keys are encrypted — structural fields stay plaintext so ArgoCD/kustomize can parse them.

**In-cluster decryption:** The SOPS Operator watches `SopsSecret` CRDs and materialises them as native `Secret` objects automatically.

## Four-Stage Architecture

| Stage | Directory | What it does |
|-------|-----------|--------------|
| **Spark** | `bootstrap/` | Installs k3s, ArgoCD, SOPS Operator; injects Age key once |
| **Brain** | `cluster/` | App-of-Apps root; ArgoCD self-management; encrypted registry secrets |
| **Body** | `platform/` | Envoy Gateway, Authentik SSO, LGTM observability, SeaweedFS storage, khook event watcher |
| **Intelligence** | `agents/` | kagent RCA engine (Claude Sonnet 4.6) + GitHub MCP server |

## Adding a New Platform Component

1. Add a Helm `values.yaml` under `platform/<component>/` or `apps/<component>/`
2. Add an `ArgoCD Application` CRD under `cluster/apps/<component>.yaml` pointing to it
3. Uncomment the new app in `cluster/kustomization.yaml`
4. If the component needs a secret, create a `SopsSecret` CRD as `<name>.enc.yaml` and run `sops --encrypt --in-place` on it

## Observability Data Flow

```
pod logs           → Alloy (DaemonSet) → Loki
kubelet metrics    → kube-state-metrics + node-exporter → Alloy → Mimir
HTTP traces        → Beyla (eBPF DaemonSet) → Alloy (OTLP :4317/4318) → Tempo
↓
Grafana ← all three datasources unified
```

Alloy config is in `platform/observability/alloy-values.yaml`. Beyla requires no application changes — it auto-instruments HTTP via eBPF.

## AI Agent (kagent) Flow

```
Kubernetes event (crash/OOM/probe failure)
  → khook (platform/hooks/) watches events
  → webhooks to kagent API
  → Claude Sonnet 4.6 RCA agent runs
  → gathers pod logs, events, Tempo traces, Mimir metrics
  → GitHub MCP server creates Issue with RCA report
```

The agent system prompt and tool list live in `agents/ai-sre-agent/agent-crd.yaml`.

## Ingress Pattern

All UIs are exposed via Envoy Gateway HTTPRoute CRDs (not Ingress). Pattern:

```yaml
# platform/<component>/httproute-<name>.yaml
parentRefs: [{name: platform-gateway, namespace: envoy-gateway}]
hostnames: ["<service>.local"]
rules: [{backendRefs: [{name: <svc>, port: 80}]}]
```

TLS is handled by cert-manager with a self-signed wildcard certificate (`platform/gateway/cluster-issuer.yaml`).

## Key Environment Variables

Copy `.env.example` → `.env` before bootstrapping:

| Variable | Purpose |
|----------|---------|
| `SOPS_AGE_KEY_FILE` | Path to Age private key (default: `~/.config/sops/age/keys.txt`) |
| `GITHUB_PAT` | GitHub PAT (repo read + issues write) — gets SOPS-encrypted into cluster |
| `ANTHROPIC_API_KEY` | Claude API key for kagent — gets SOPS-encrypted into agents |
| `PLATFORM_DOMAIN` | Base domain; services exposed as `<name>.<PLATFORM_DOMAIN>` |

## Local Access (after bootstrap)

Services are accessible via NodePort at port `32170`. Add these to `/etc/hosts` (pointing to k3s bridge IP, usually `172.20.0.2` on macOS):

```
argocd.local, grafana.local, auth.local, temporal.local, seaweedfs-filer.local, sample-api.local
```

Step 10 of `install.sh` discovers the correct IP + NodePort and prints a ready-to-paste `sudo` command — run it yourself to update `/etc/hosts`.
