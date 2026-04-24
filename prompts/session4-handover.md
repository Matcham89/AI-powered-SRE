# Session 4 Handover — Chaos Worker + Temporal Demo

## Context

This is an AI-powered SRE platform running on Talos Linux via lima-rancher-desktop.

- Cluster node IP: `192.168.64.2`
- HTTP NodePort: `32170`
- ArgoCD manages everything via GitOps from `https://github.com/Matcham89/AI-powered-SRE`
- SOPS + Age encryption for all secrets (`~/.config/sops/age/keys.txt`)
- All apps are Synced + Healthy in ArgoCD

## What was completed before this session

1. All 23 ArgoCD apps Synced + Healthy (Loki, Mimir, Tempo, Grafana, Temporal, kagent, sample-api, etc.)
2. Authentik SSO configured via Terraform (`terraform/` dir) — Grafana and Temporal both route through Authentik
3. Grafana: basic auth disabled, OAuth auto-login enabled, redirects to Authentik
4. Temporal: protected by oauth2-proxy (`apps/temporal/oauth2-proxy.yaml`), redirects to Authentik
5. A kagent `Hook` CRD (`kagent/kubernetes-sre-responder`) fires the `ai-sre-agent` on `pod-restart` events, with a prompt to investigate and create a GitHub issue in `Matcham89/AI-powered-SRE`

## What needs completing

### Goal

Trigger the full end-to-end AI SRE loop:

```
Temporal workflow → crash sample-api pod → khook detects pod-restart → ai-sre-agent → GitHub MCP → GitHub issue created
```

### Current state of the chaos worker

A `chaos-worker` app exists at `apps/chaos-worker/` and is deployed via ArgoCD into the `chaos-worker` namespace.

It consists of:
- `configmap.yaml` — two Python files (`workflows.py` + `worker.py`) mounted at `/app/`
- `rbac.yaml` — ServiceAccount + Role + RoleBinding allowing pod deletion in `sample-api` namespace
- `job.yaml` — Kubernetes Job with `argocd.argoproj.io/hook: PostSync` and `BeforeHookCreation` delete policy; uses `python:3.11-slim` with an initContainer that `pip install`s `temporalio==1.8.0 kubernetes==32.0.0` into a shared volume

### The problem to fix

The Job is failing. The Temporal Python SDK sandbox re-imports the workflow module during worker validation. The last fix split the code into `workflows.py` (definitions only) and `worker.py` (startup + connect), but the job was deleted mid-flight and a fresh attempt hasn't been observed yet.

The likely remaining issue is that `workflow.unsafe.imports_passed_through()` at module level in `workflows.py` may still cause problems in the sandbox. If so, move the kubernetes imports inside the activity function body (not module level) — activities run outside the sandbox so local imports are safe.

#### Suggested fix if the current code still fails

In `workflows.py`, remove the module-level kubernetes import block and import inside the helper function:

```python
# Remove this at module level:
# with workflow.unsafe.imports_passed_through():
#     from kubernetes import client as k8s_client, config as k8s_config

def _delete_sample_api_pod() -> str:
    from kubernetes import client as k8s_client, config as k8s_config  # local import, safe in activity
    k8s_config.load_incluster_config()
    ...
```

### How to iterate

1. Check current job logs: `kubectl logs -n chaos-worker -l job-name=chaos-worker -c chaos-worker`
2. If still failing, apply the fix above to `apps/chaos-worker/configmap.yaml`
3. Commit with a short why-focused message (no bullet lists of changed files)
4. Push — ArgoCD auto-syncs. The job has `BeforeHookCreation` delete policy so it will re-run on next sync.
5. Force a refresh if needed: `kubectl -n argocd annotate app chaos-worker argocd.argoproj.io/refresh=hard`

### Verifying the full loop works

Once the Job completes successfully:

1. Check the sample-api pod was restarted:
   ```
   kubectl get pods -n sample-api
   ```

2. Check kagent logs to confirm the hook fired:
   ```
   kubectl logs -n kagent deployment/kagent -f
   ```
   Look for `pod-restart` event for `sample-api`.

3. Confirm an agent run was triggered — look for a new GitHub issue at:
   `https://github.com/Matcham89/AI-powered-SRE/issues`

4. Confirm the Temporal workflow shows as Completed in the Temporal UI:
   `http://temporal.local:32170` (will prompt for Authentik login — user: `chris`, password in `terraform/terraform.tfvars`)

## Important constraints

- **Never commit secrets, API keys, or passwords to git** — `terraform/terraform.tfvars` is gitignored
- Commit messages: short, one-line, why-focused (e.g. `Fix kubernetes import — move into activity to avoid sandbox`)
- Do not force-push or amend published commits
- The cluster is accessed via `kubectl` with the default kubeconfig (lima-rancher-desktop context)
- SOPS Age key is at `~/.config/sops/age/keys.txt`

## Key file locations

| File | Purpose |
|------|---------|
| `apps/chaos-worker/configmap.yaml` | Python chaos workflow code |
| `apps/chaos-worker/job.yaml` | Kubernetes Job definition |
| `apps/chaos-worker/rbac.yaml` | RBAC for pod deletion |
| `agents/ai-sre-agent/` | kagent AI SRE agent config |
| `apps/temporal/oauth2-proxy.yaml` | Temporal auth proxy |
| `platform/observability/grafana-values.yaml` | Grafana Helm values |
| `terraform/` | Authentik SSO Terraform (state is local, tfvars gitignored) |

## Cluster access quick reference

```bash
# All apps status
kubectl get applications -n argocd

# chaos-worker job
kubectl get jobs,pods -n chaos-worker
kubectl logs -n chaos-worker -l job-name=chaos-worker -c chaos-worker

# sample-api pod
kubectl get pods -n sample-api

# kagent hook + agent logs
kubectl get hooks -n kagent
kubectl logs -n kagent deployment/kagent -f

# Force ArgoCD sync
kubectl -n argocd annotate app chaos-worker argocd.argoproj.io/refresh=hard
```
