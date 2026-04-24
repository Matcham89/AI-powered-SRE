# ArgoCD v3.3.8 — Security Hardening Reference

## Production Security Checklist

- [ ] TLS 1.2+ enforced on argocd-server
- [ ] Admin user disabled after SSO setup
- [ ] Initial admin secret deleted after first login
- [ ] Redis password configured
- [ ] RBAC policy.default set to `role:readonly`
- [ ] AppProjects with explicit source/destination whitelists
- [ ] Repository credentials stored as Secrets (not hardcoded)
- [ ] Secrets managed via external-secrets or Sealed Secrets
- [ ] Network policies restricting argocd namespace traffic
- [ ] Memory limits on repo-server
- [ ] Audit logging enabled via Kubernetes Events
- [ ] Webhook secrets configured for Git webhooks

---

## TLS Configuration

### Enforce TLS 1.2 minimum

Patch the argocd-server Deployment to add the flag:

```yaml
# argocd-server-tls-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-server
  namespace: argocd
spec:
  template:
    spec:
      containers:
        - name: argocd-server
          args:
            - /usr/local/bin/argocd-server
            - --tlsminversion
            - "1.2"
            - --tlsmaxversion
            - "1.3"
```

### Disable TLS on argocd-server (terminate at Ingress)

Only do this if your Ingress terminates TLS:

```yaml
args:
  - /usr/local/bin/argocd-server
  - --insecure
```

---

## Admin User Management

### Disable admin after SSO is working

```yaml
# argocd-cm patch
data:
  admin.enabled: "false"
```

### Create local users (non-admin)

```yaml
data:
  accounts.ci-bot: apiKey        # API key only (for CI/CD pipelines)
  accounts.developer1: login     # UI login only
  accounts.ops-user: apiKey,login  # both
```

Set passwords via CLI:
```bash
argocd account update-password \
  --account developer1 \
  --current-password <admin-password> \
  --new-password <new-password>
```

---

## OIDC Configuration

### Using Dex (built-in) with GitHub OAuth

```yaml
# argocd-cm
data:
  url: https://argocd.YOURDOMAIN.com
  dex.config: |
    connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: $dex.github.clientID       # references argocd-secret
          clientSecret: $dex.github.clientSecret
          orgs:
            - name: MY-ORG
              teams:
                - platform-team
                - dev-team
```

Store clientID and clientSecret in `argocd-secret`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-secret
  namespace: argocd
stringData:
  dex.github.clientID: "your-github-oauth-app-client-id"
  dex.github.clientSecret: "your-github-oauth-app-client-secret"
```

### Using external OIDC provider (Okta, Google, etc.)

```yaml
# argocd-cm
data:
  url: https://argocd.YOURDOMAIN.com
  oidc.config: |
    name: Okta
    issuer: https://dev-XXXXX.okta.com
    clientID: $oidc.okta.clientID
    clientSecret: $oidc.okta.clientSecret
    requestedScopes:
      - openid
      - profile
      - email
      - groups
    requestedIDTokenClaims:
      groups:
        essential: true
```

Map OIDC groups to RBAC roles in `argocd-rbac-cm`:
```yaml
data:
  policy.csv: |
    g, platform-team, role:admin
    g, dev-team, role:developer
```

---

## RBAC Deep Reference

### Built-in roles
- `role:readonly` — read everything, change nothing
- `role:admin` — full access to all resources

### Policy syntax

```
p, <subject>, <resource>, <action>, <object>, <effect>
g, <user/group>, <role>
```

**Resources:** `applications`, `applicationsets`, `clusters`, `repositories`, `accounts`, `certificates`, `gpgkeys`, `logs`, `exec`, `extensions`, `projects`

**Actions:** `get`, `create`, `update`, `delete`, `sync`, `override`, `action/<group/kind/action-name>`

**Objects:** `<project>/<app-name>` for applications, `*` for wildcard

### Full production RBAC example

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly

  policy.csv: |
    # Platform admins — full control
    p, role:platform-admin, applications, *, */*, allow
    p, role:platform-admin, applicationsets, *, */*, allow
    p, role:platform-admin, clusters, *, *, allow
    p, role:platform-admin, repositories, *, *, allow
    p, role:platform-admin, projects, *, *, allow
    p, role:platform-admin, accounts, *, *, allow
    p, role:platform-admin, certificates, *, *, allow
    p, role:platform-admin, exec, create, */*, allow

    # Developers — sync and view in their projects only
    p, role:developer, applications, get, dev-project/*, allow
    p, role:developer, applications, sync, dev-project/*, allow
    p, role:developer, applications, override, dev-project/*, allow
    p, role:developer, logs, get, dev-project/*, allow
    p, role:developer, repositories, get, *, allow

    # CI/CD service accounts — sync only
    p, role:ci-bot, applications, sync, */*, allow
    p, role:ci-bot, applications, get, */*, allow

    # SSO group bindings
    g, my-org:platform-team, role:platform-admin
    g, my-org:dev-team, role:developer

    # Local user bindings
    g, ci-bot, role:ci-bot

  scopes: '[groups, email]'
```

---

## Secrets Management (production patterns)

### External Secrets Operator (recommended)

Don't store raw credentials in Git. Use ESO to pull from your secrets store:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: argocd-github-repo
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend
  target:
    name: my-private-repo
    template:
      metadata:
        labels:
          argocd.argoproj.io/secret-type: repository
      data:
        type: git
        url: https://github.com/MY-ORG/MY-REPO
        username: "{{ .username }}"
        password: "{{ .token }}"
  data:
    - secretKey: username
      remoteRef:
        key: argocd/github
        property: username
    - secretKey: token
      remoteRef:
        key: argocd/github
        property: token
```

### Sealed Secrets (simple alternative)

```bash
# Seal the repository secret for GitOps storage
kubectl create secret generic my-private-repo \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/MY-ORG/MY-REPO \
  --from-literal=username=my-user \
  --from-literal=password=my-token \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > sealed-my-private-repo.yaml
```

---

## Network Policies

Restrict pod-to-pod traffic within the argocd namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: argocd-allow-internal
  namespace: argocd
spec:
  podSelector: {}   # apply to all pods in namespace
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: argocd
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx   # allow Ingress controller
  egress:
    - to:
        - namespaceSelector: {}   # allow all egress (ArgoCD needs to reach Git + clusters)
    - ports:
        - port: 53     # DNS
        - port: 443    # HTTPS
        - port: 6443   # Kubernetes API
```

---

## Memory Limits for Repo Server (DoS protection)

In `argocd-cm`:
```yaml
data:
  reposerver.max.combined.directory.manifests.size: 10M
```

In the repo-server Deployment, set resource limits:
```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 2000m
    memory: 1Gi
```

---

## Audit Logging

ArgoCD emits Kubernetes Events for all operations. Persist them with an event exporter:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kubernetes-event-exporter
  namespace: argocd
spec:
  project: platform
  source:
    chart: kubernetes-event-exporter
    repoURL: https://resmoio.github.io/kubernetes-event-exporter
    targetRevision: 2.x
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
```

Security-related log fields to watch: `security=true`, `level=warning`, `level=error`.
