# ArgoCD v3.3.8 — Installation Reference

## Manifest URLs

| Type | URL |
|------|-----|
| Standard (cluster-admin) | `https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/install.yaml` |
| HA (cluster-admin) | `https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/ha/install.yaml` |
| Namespace-scoped | `https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/namespace-install.yaml` |
| HA Namespace-scoped | `https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/ha/namespace-install.yaml` |
| Core (no API server/UI) | `https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/core-install.yaml` |

**Use `ha/install.yaml` for any production cluster.**

---

## Installation Types

### Multi-Tenant (default, recommended)
- Full API server + Web UI + CLI access
- Multiple teams share one ArgoCD instance managed by platform team
- Users login via `argocd login <server-host>`

### Core (headless)
- No API server or Web UI
- Only `argocd admin` CLI commands work (requires kubeconfig access)
- Use for single-admin clusters where UI is not needed
- Lighter footprint

### Namespace-scoped
- ArgoCD only manages resources in specific namespaces
- No cluster-admin ClusterRoleBinding
- Use when cluster-admin is not available or for strict multi-tenancy
- Can only manage applications deployed to permitted namespaces; cannot register in-cluster as destination by default

---

## kubectl Install (recommended for production)

```bash
# 1. Create namespace
kubectl create namespace argocd

# 2. Apply HA manifests
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/ha/install.yaml

# 3. Wait for all components
kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=300s
kubectl -n argocd wait --for=condition=available deployment/argocd-repo-server --timeout=300s
kubectl -n argocd wait --for=condition=available deployment/argocd-dex-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# 4. Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

---

## Helm Install

Community chart: `oci://ghcr.io/argoproj/argo-helm/argo-cd`

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version 8.x.x \     # check for chart version matching ArgoCD v3.3.8
  --values values.yaml
```

**Minimal production Helm values (`values.yaml`):**
```yaml
global:
  image:
    tag: v3.3.8

server:
  replicas: 3
  autoscaling:
    enabled: false

repoServer:
  replicas: 2

applicationSet:
  replicas: 2

redis-ha:
  enabled: true   # Enables Redis HA (Sentinel) mode

configs:
  params:
    server.insecure: false   # Keep TLS enabled
  cm:
    url: https://argocd.YOURDOMAIN.com
  rbac:
    policy.default: role:readonly
```

---

## Kustomize Install

Best for GitOps-managed ArgoCD installs (recommended for Day 2):

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: argocd

resources:
  - https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/ha/install.yaml

patches:
  - path: argocd-server-patch.yaml
  - path: argocd-cm-patch.yaml

images:
  - name: quay.io/argoproj/argocd
    newTag: v3.3.8
```

---

## HA Components

| Component | HA Replicas | Scalable? | Notes |
|-----------|-------------|-----------|-------|
| argocd-server | 3+ | Yes | Stateless API; set `ARGOCD_API_SERVER_REPLICAS` |
| argocd-repo-server | 2+ | Yes | Controls `--parallelismlimit` to avoid OOM |
| argocd-application-controller | 3 (sharded) | Yes (sharding) | Set `ARGOCD_CONTROLLER_REPLICAS` |
| argocd-redis | 3 (Sentinel) | No | Fixed at 3 nodes for HA quorum |
| argocd-dex-server | 1 | No | In-memory DB; multiple instances break state |
| argocd-applicationset-controller | 2 | Limited | Leader election; 2 for redundancy |
| argocd-notifications-controller | 1 | No | Single instance |

**HA requires at least 3 worker nodes** due to pod anti-affinity rules.

---

## Custom Namespace

If installing to a namespace other than `argocd`, patch the ClusterRoleBinding:

```yaml
# patch.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-application-controller
subjects:
  - kind: ServiceAccount
    name: argocd-application-controller
    namespace: MY-CUSTOM-NAMESPACE   # <-- change this
```

Apply the same patch for all ClusterRoleBindings in the install manifest.

---

## Upgrade Path

When upgrading between minor versions (e.g. v3.2 → v3.3), always read the upgrade docs first:
- Check for CRD changes — apply CRDs before the main manifests
- Drain the application controller gracefully before upgrade
- Never skip minor versions

```bash
# Re-apply manifests for upgrade
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/ha/install.yaml
```
