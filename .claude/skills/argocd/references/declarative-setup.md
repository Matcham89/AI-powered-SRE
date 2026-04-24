# ArgoCD v3.3.8 — Declarative Setup Reference

## Application CRD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io  # enables cascade delete
  annotations:
    argocd.argoproj.io/manifest-generate-paths: .  # monorepo optimisation
spec:
  project: my-project

  source:
    repoURL: https://github.com/MY-ORG/MY-REPO
    targetRevision: main    # branch, tag, or commit SHA
    path: apps/my-app       # path within repo

    # Helm-specific (omit if using plain manifests)
    helm:
      releaseName: my-app
      valueFiles:
        - values.yaml
        - values-prod.yaml
      parameters:
        - name: image.tag
          value: "1.2.3"

    # Kustomize-specific (omit if using plain manifests)
    kustomize:
      namePrefix: prod-
      images:
        - my-image:1.2.3

  destination:
    server: https://kubernetes.default.svc  # in-cluster
    namespace: my-app-prod

  syncPolicy:
    automated:
      prune: true       # delete resources removed from git
      selfHeal: true    # revert manual changes
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true    # recommended for CRD-heavy workloads
      - PrunePropagationPolicy=foreground
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### Multi-source Application (v3 feature)

```yaml
spec:
  sources:
    - repoURL: https://github.com/MY-ORG/helm-charts
      chart: my-chart
      targetRevision: 1.2.3
    - repoURL: https://github.com/MY-ORG/config-values
      targetRevision: main
      path: environments/prod
      helm:
        valueFiles:
          - $values/environments/prod/values.yaml
```

---

## AppProject CRD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: Platform team production workloads

  # Which git repos are allowed as sources
  sourceRepos:
    - https://github.com/MY-ORG/MY-REPO
    - https://github.com/MY-ORG/helm-charts
    # - '*'   # allow all (not recommended for prod)

  # Which clusters and namespaces can be deployed to
  destinations:
    - namespace: '*'                             # all namespaces on this cluster
      server: https://kubernetes.default.svc
    - namespace: 'monitoring'
      server: https://external-cluster.example.com

  # Cluster-scoped resources that can be created
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
    - group: 'rbac.authorization.k8s.io'
      kind: ClusterRole
    - group: 'rbac.authorization.k8s.io'
      kind: ClusterRoleBinding
    - group: 'apiextensions.k8s.io'
      kind: CustomResourceDefinition

  # Namespace-scoped resources that cannot be created (deny list)
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: ''
      kind: LimitRange

  # Project-level roles (in addition to global RBAC)
  roles:
    - name: project-admin
      description: Full access to this project
      policies:
        - p, proj:platform:project-admin, applications, *, platform/*, allow
      groups:
        - platform-team
    - name: developer
      description: Sync access only
      policies:
        - p, proj:platform:developer, applications, sync, platform/*, allow
        - p, proj:platform:developer, applications, get, platform/*, allow

  # Sync windows — restrict when syncs can happen
  syncWindows:
    - kind: allow
      schedule: '0 8 * * 1-5'    # weekdays 8am
      duration: 10h
      applications:
        - '*'
    - kind: deny
      schedule: '0 0 * * *'      # midnight every day
      duration: 1h
      namespaces:
        - production
```

---

## Repository Secrets

All repository secrets live in the `argocd` namespace with label `argocd.argoproj.io/secret-type: repository`.

### HTTPS with credentials
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-private-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/MY-ORG/MY-REPO
  username: my-username
  password: ghp_XXXXXXXXXXXX   # use external-secrets in production
```

### SSH key
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-repo-ssh
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: git@github.com:MY-ORG/MY-REPO.git
  sshPrivateKey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    [key content — use external-secrets or Sealed Secrets]
    -----END OPENSSH PRIVATE KEY-----
```

### GitHub App (recommended for production — no expiring tokens)
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-app-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/MY-ORG/MY-REPO
  githubAppID: "123456"
  githubAppInstallationID: "789012"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    [GitHub App private key]
    -----END RSA PRIVATE KEY-----
```

### Repository credential template (share creds across multiple repos)
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: org-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds   # note: repo-creds not repository
stringData:
  type: git
  url: https://github.com/MY-ORG   # prefix — matches all repos under this org
  username: my-username
  password: ghp_XXXXXXXXXXXX
```

### Helm OCI registry
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-helm-registry
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  name: my-registry
  url: registry.example.com
  type: helm
  enableOCI: "true"
  username: my-username
  password: my-password
```

---

## Cluster Secrets

Register external clusters ArgoCD should manage.

### Generic external cluster
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: prod-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: prod-cluster           # display name in ArgoCD UI
  server: https://api.prod-cluster.example.com
  config: |
    {
      "bearerToken": "<service-account-token>",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "<base64-encoded-CA-cert>"
      }
    }
```

### EKS with IRSA
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: eks-prod-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: eks-prod
  server: https://XXXXXX.gr7.eu-west-1.eks.amazonaws.com
  config: |
    {
      "awsAuthConfig": {
        "clusterName": "my-eks-prod",
        "roleARN": "arn:aws:iam::123456789:role/argocd-cluster-access"
      },
      "tlsClientConfig": {
        "insecure": false,
        "caData": "<base64-encoded-CA-cert>"
      }
    }
```

### GKE with Workload Identity
```yaml
stringData:
  config: |
    {
      "execProviderConfig": {
        "command": "argocd-k8s-auth",
        "args": ["gcp"],
        "apiVersion": "client.authentication.k8s.io/v1beta1"
      },
      "tlsClientConfig": {
        "insecure": false,
        "caData": "<base64-encoded-CA-cert>"
      }
    }
```

---

## Helm Chart Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: platform
  source:
    chart: cert-manager
    repoURL: https://charts.jetstack.io
    targetRevision: v1.14.x
    helm:
      releaseName: cert-manager
      parameters:
        - name: installCRDs
          value: "true"
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

---

## ApplicationSet (generate Applications dynamically)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cluster-apps
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/MY-ORG/gitops-repo
        revision: main
        directories:
          - path: apps/*
  template:
    metadata:
      name: '{{path.basename}}'
    spec:
      project: platform
      source:
        repoURL: https://github.com/MY-ORG/gitops-repo
        targetRevision: main
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```
