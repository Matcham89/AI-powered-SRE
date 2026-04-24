---
name: argocd
description: >
  Production-grade ArgoCD v3.3.8 deployment skill. Use this skill whenever the user wants to install ArgoCD,
  set up GitOps on a Kubernetes cluster, configure ArgoCD Applications or AppProjects, register repositories or clusters,
  harden ArgoCD security (RBAC, OIDC, TLS), set up App-of-Apps, configure HA ArgoCD, or troubleshoot an ArgoCD deployment.
  Trigger for any mention of ArgoCD, Argo CD, GitOps on Kubernetes, application controller, app-of-apps, sync policies,
  argocd-cm, argocd-rbac-cm, or deploying with ArgoCD. When in doubt, use this skill — it covers the full lifecycle
  from blank cluster to production-grade GitOps platform.
---

# ArgoCD v3.3.8 — Production Deployment Skill

You are helping the user deploy and configure ArgoCD on a production Kubernetes cluster. Follow this structured workflow, reading the relevant reference files as you go.

## Before you start: gather context

Ask the user these questions upfront (or infer from context if already provided). Don't proceed to generate configs without knowing these:

1. **Install method**: kubectl manifests, Helm chart, or Kustomize overlay?
2. **Availability**: Single-node/dev install, or HA (recommended for production)?
3. **Cluster access**: In-cluster deployment (ArgoCD manages its own cluster), or managing external clusters too?
4. **Auth**: Local users only, or SSO/OIDC (Okta, GitHub, Google, Dex)?
5. **Git repo**: HTTPS with credentials, SSH key, or GitHub App?
6. **Cloud provider**: Any? (affects cluster secret auth — EKS uses IRSA, GKE uses Workload Identity, AKS uses managed identity)
7. **Ingress/TLS**: NodePort, LoadBalancer, or Ingress with cert-manager?
8. **Namespace**: Default `argocd` or custom?

If the user says "just set it up", default to: HA install via kubectl, argocd namespace, no SSO (configure later), HTTPS git auth.

---

## Workflow: Phase by Phase

### Phase 1 — Install ArgoCD

Read `references/installation.md` for manifest URLs, HA details, and Helm values.

**Quick path (kubectl HA):**
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/ha/install.yaml
```

**Wait for rollout:**
```bash
kubectl -n argocd rollout status deployment/argocd-server
kubectl -n argocd rollout status statefulset/argocd-application-controller
```

**Get initial admin password:**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

**Access the UI (temporary — replace with Ingress for prod):**
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
Then visit `https://localhost:8080`, login as `admin`.

> After first login, change the admin password and delete `argocd-initial-admin-secret`.

---

### Phase 2 — Core Configuration (argocd-cm)

Read `references/argocd-cm-reference.md` for the full option set.

Generate a production `argocd-cm` ConfigMap. Always include at minimum:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-cm
    app.kubernetes.io/part-of: argocd
data:
  # External URL — required for SSO callback and notifications
  url: https://argocd.YOURDOMAIN.com

  # Exclude noisy resources from watch (reduces API server load)
  resource.exclusions: |
    - apiGroups:
      - "events.k8s.io"
      - "metrics.k8s.io"
      kinds:
      - "*"
      clusters:
      - "*"

  # Reconciliation interval (default 120s is fine; lower only if needed)
  timeout.reconciliation: 180s
  timeout.reconciliation.jitter: 30s
```

If the user wants OIDC/SSO, add the `oidc.config` or `dex.config` block — see `references/security-hardening.md` for examples.

---

### Phase 3 — RBAC Configuration (argocd-rbac-cm)

Read `references/security-hardening.md` for full RBAC policy syntax.

**Principle of least privilege — always start here:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  # Default: read-only for all authenticated users
  policy.default: role:readonly

  policy.csv: |
    # Org admins — full control
    p, role:org-admin, applications, *, */*, allow
    p, role:org-admin, repositories, *, *, allow
    p, role:org-admin, clusters, *, *, allow
    p, role:org-admin, projects, *, *, allow
    p, role:org-admin, accounts, *, *, allow

    # Developers — sync only in their project
    p, role:developer, applications, sync, my-project/*, allow
    p, role:developer, applications, get, my-project/*, allow

    # Map SSO groups to roles
    g, platform-team, role:org-admin
    g, dev-team, role:developer
```

Adapt `my-project`, group names, and projects to the user's actual setup.

---

### Phase 4 — Register Repositories

Read `references/declarative-setup.md` for all secret formats (HTTPS, SSH, GitHub App, Helm).

Generate the appropriate Kubernetes Secret. Label it `argocd.argoproj.io/secret-type: repository`. Never put raw credentials in Application manifests — always use repository secrets.

For production, prefer **GitHub App auth** or **SSH keys** over HTTPS username/password.

---

### Phase 5 — Register External Clusters (if needed)

If ArgoCD is managing clusters other than the one it's installed on, generate a cluster secret. Read `references/declarative-setup.md` for cloud-provider-specific config (EKS IRSA, GKE Workload Identity).

The in-cluster server is always available as `https://kubernetes.default.svc` — no secret needed.

---

### Phase 6 — Create AppProjects

Always create a named AppProject — never use the `default` project for production workloads. Projects enforce:
- Which source repos are allowed
- Which destination clusters/namespaces are allowed
- Which Kubernetes resource kinds can be deployed

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: Platform team workloads
  sourceRepos:
    - https://github.com/YOUR-ORG/YOUR-REPO
  destinations:
    - namespace: '*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
    - group: 'rbac.authorization.k8s.io'
      kind: ClusterRole
    - group: 'rbac.authorization.k8s.io'
      kind: ClusterRoleBinding
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
```

---

### Phase 7 — Deploy the Root Application (App of Apps)

For production, use the App-of-Apps pattern: one root Application that manages all other Applications declaratively.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://github.com/YOUR-ORG/YOUR-GITOPS-REPO
    targetRevision: main
    path: clusters/prod/apps   # directory of Application manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

The repo at `clusters/prod/apps/` should contain individual Application YAML files for each workload.

---

### Phase 8 — Ingress and TLS (Production Access)

Replace port-forward with a proper Ingress. The argocd-server needs to be configured for Ingress correctly — it runs in HTTPS mode by default.

**Option A — nginx-ingress (passthrough TLS):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.YOURDOMAIN.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
  tls:
    - hosts:
        - argocd.YOURDOMAIN.com
```

**Option B — terminate TLS at Ingress (disable argocd-server TLS):**
Add `--insecure` to argocd-server args and use a standard cert-manager Ingress.

---

### Phase 9 — Security Hardening

Read `references/security-hardening.md` for the full checklist. At minimum for production:

1. **Disable admin user** after setting up SSO: set `admin.enabled: "false"` in argocd-cm
2. **Enforce TLS 1.2+**: add `--tlsminversion 1.2` to argocd-server args
3. **Set Redis password**: configure `REDIS_PASSWORD` in HA setup
4. **Limit resource.exclusions**: reduce API server watch load
5. **Rotate initial admin secret**: delete `argocd-initial-admin-secret` after first login
6. **Network policies**: restrict pod-to-pod traffic within the argocd namespace
7. **Set memory limits on repo-server**: prevent DoS via large manifests (`reposerver.max.combined.directory.manifests.size`)

---

### Phase 10 — HA Tuning (if HA install)

Read `references/ha-architecture.md` for replica counts, sharding, and processor tuning.

Key env vars to set on the application controller for scale:
```yaml
env:
  - name: ARGOCD_CONTROLLER_REPLICAS
    value: "3"
```

For large deployments (>100 apps):
- Increase `--status-processors` to 50 and `--operation-processors` to 25
- Enable consistent-hashing sharding: `--sharding-method consistent-hashing`
- Scale argocd-repo-server based on manifest generation load

---

## Output format

When generating configs, always:
- Output complete, valid YAML (not snippets unless specifically asked)
- Use `YOUR-ORG`, `YOUR-REPO`, `YOURDOMAIN.com` as clear placeholders
- Group related resources in one block, separated by `---`
- Note which file each resource should live in (e.g., `# File: clusters/prod/argocd/argocd-cm.yaml`)
- Flag any security-sensitive values that must be stored in a Secrets Manager / external-secrets rather than plain YAML

When the user asks to generate an Application or AppProject, always ask which project, which repo/path, and which destination cluster/namespace if not clear from context.

---

## Common tasks (quick reference)

| User asks for | Go to |
|---|---|
| Install ArgoCD | Phase 1 + `references/installation.md` |
| HA setup / scaling | Phase 1 (HA path) + `references/ha-architecture.md` |
| OIDC / SSO setup | `references/security-hardening.md` |
| Register a Git repo | Phase 4 + `references/declarative-setup.md` |
| Add a cluster | Phase 5 + `references/declarative-setup.md` |
| Create an Application | Phase 7 |
| App of Apps | Phase 7 |
| RBAC policies | Phase 3 + `references/security-hardening.md` |
| Security hardening | Phase 9 + `references/security-hardening.md` |
| Ingress / TLS | Phase 8 |
| argocd-cm options | `references/argocd-cm-reference.md` |
| Helm chart deploy | `references/declarative-setup.md` |
