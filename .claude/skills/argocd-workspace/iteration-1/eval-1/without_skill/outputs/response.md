# ArgoCD v3.3.8 — Production HA Setup on EKS

> Complete production-ready guide for installing ArgoCD in HA mode on a fresh EKS cluster, with GitHub integration, ~50 apps, and platform team RBAC.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Phase 1 — Install ArgoCD in HA Mode](#phase-1--install-argocd-in-ha-mode)
3. [Phase 2 — Core Configuration (argocd-cm)](#phase-2--core-configuration-argocd-cm)
4. [Phase 3 — RBAC Configuration (argocd-rbac-cm)](#phase-3--rbac-configuration-argocd-rbac-cm)
5. [Phase 4 — GitHub Repository Secret](#phase-4--github-repository-secret)
6. [Phase 5 — EKS Cluster Secret](#phase-5--eks-cluster-secret)
7. [Phase 6 — AppProject for Platform Team](#phase-6--appproject-for-platform-team)
8. [Phase 7 — Root App-of-Apps Application](#phase-7--root-app-of-apps-application)
9. [Phase 8 — Ingress and TLS (EKS ALB)](#phase-8--ingress-and-tls-eks-alb)
10. [Phase 9 — Security Hardening](#phase-9--security-hardening)
11. [Phase 10 — HA Tuning for ~50 Apps](#phase-10--ha-tuning-for-50-apps)
12. [Recommended GitOps Repo Layout](#recommended-gitops-repo-layout)

---

## Prerequisites

Before running any commands, ensure:

- `kubectl` is configured and pointing at your EKS cluster (`kubectl config current-context`)
- Your EKS cluster has **at least 3 worker nodes** — HA mode requires this due to pod anti-affinity rules
- Worker nodes should have at least **4 vCPU / 8GB RAM** available in the `argocd` namespace
- You have a domain name ready for the ArgoCD UI (e.g. `argocd.your-company.com`)
- AWS Load Balancer Controller is installed (for ALB Ingress), or you will use `LoadBalancer` service type
- cert-manager is installed if you want automated TLS certificates

---

## Phase 1 — Install ArgoCD in HA Mode

### Step 1.1 — Create the namespace

```bash
kubectl create namespace argocd
```

### Step 1.2 — Apply the HA install manifests

```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/ha/install.yaml
```

### Step 1.3 — Wait for all components to be ready

```bash
# Wait for all deployments
kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=300s
kubectl -n argocd wait --for=condition=available deployment/argocd-repo-server --timeout=300s
kubectl -n argocd wait --for=condition=available deployment/argocd-dex-server --timeout=300s
kubectl -n argocd wait --for=condition=available deployment/argocd-applicationset-controller --timeout=300s

# Wait for the application controller StatefulSet
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# Verify Redis HA pods are up (3 required)
kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-redis-ha
```

### Step 1.4 — Get the initial admin password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

### Step 1.5 — Temporary access (replace with Ingress in production)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Visit `https://localhost:8080` and login as `admin` with the password from step 1.4.

> **Important:** After your first login, change the admin password immediately, then delete the initial secret:
> ```bash
> argocd login localhost:8080 --username admin --password <initial-password>
> argocd account update-password
> kubectl -n argocd delete secret argocd-initial-admin-secret
> ```

### Step 1.6 — Verify HA component counts

After install, confirm you have the correct HA replica counts:

```bash
kubectl -n argocd get pods -o wide
```

Expected HA layout:

| Component | Expected Pods |
|---|---|
| argocd-server | 2 (HA manifest default; scale to 3 post-install) |
| argocd-repo-server | 2 |
| argocd-application-controller | 1 (scale to 3 after configuring sharding) |
| argocd-redis-ha | 3 (Sentinel quorum) |
| argocd-dex-server | 1 |
| argocd-applicationset-controller | 2 |

---

## Phase 2 — Core Configuration (argocd-cm)

Apply this ConfigMap to configure ArgoCD for production. Replace all `YOUR-*` placeholders.

```yaml
# File: clusters/prod/argocd/argocd-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-cm
    app.kubernetes.io/part-of: argocd
data:
  # --- Core identity ---
  # Required for SSO callback URLs and notification links
  url: https://argocd.YOUR-DOMAIN.com

  # Set to "false" only after SSO/OIDC is confirmed working
  admin.enabled: "true"

  # --- User sessions ---
  # Shorter session = more secure; 8h is a good balance for a platform team
  users.session.duration: 8h

  # Never allow anonymous access in production
  users.anonymous.enabled: "false"

  # --- Resource watch optimisation ---
  # Exclude noisy resources that create reconciliation overhead
  resource.exclusions: |
    - apiGroups:
        - "events.k8s.io"
        - "metrics.k8s.io"
      kinds:
        - "*"
      clusters:
        - "*"
    - apiGroups:
        - ""
      kinds:
        - "Event"
      clusters:
        - "*"

  # --- Reconciliation timing ---
  # 180s poll interval is appropriate for ~50 apps; lower = more API server load
  timeout.reconciliation: 180s
  # Spread out reconciliation to avoid thundering herd across 50 apps
  timeout.reconciliation.jitter: 30s

  # --- Resource tracking ---
  # annotation is more reliable than label for large numbers of resources
  application.resourceTrackingMethod: annotation

  # --- Repo server protection ---
  # Prevent DoS via oversized manifest directories
  reposerver.max.combined.directory.manifests.size: 10M

  # --- Terminal access (exec) ---
  # Keep disabled unless your team explicitly needs it; significant attack surface
  exec.enabled: "false"

  # --- UI banner ---
  # Helpful for environment awareness — platform team knows they're on prod
  ui.bannercontent: "Production ArgoCD — Handle with care"
  ui.bannerpermanent: "true"

  # --- GitHub SSO via Dex (uncomment once GitHub OAuth App is created) ---
  # dex.config: |
  #   connectors:
  #     - type: github
  #       id: github
  #       name: GitHub
  #       config:
  #         clientID: $dex.github.clientID
  #         clientSecret: $dex.github.clientSecret
  #         orgs:
  #           - name: YOUR-GITHUB-ORG
  #             teams:
  #               - platform-team
  #               - dev-team

  # --- ignoreDifferences: suppress HPA-managed replica counts ---
  resource.customizations.ignoreDifferences.apps_Deployment: |
    jsonPointers:
      - /spec/replicas
      - /metadata/annotations/deployment.kubernetes.io~1revision

  # --- ignoreDifferences: cert-manager injects caBundle ---
  resource.customizations.ignoreDifferences.admissionregistration.k8s.io_MutatingWebhookConfiguration: |
    jsonPointers:
      - /webhooks/0/clientConfig/caBundle
```

Apply it:

```bash
kubectl apply -f clusters/prod/argocd/argocd-cm.yaml
```

---

## Phase 3 — RBAC Configuration (argocd-rbac-cm)

This configures least-privilege RBAC for your platform team. Adapt `YOUR-GITHUB-ORG` and project names.

```yaml
# File: clusters/prod/argocd/argocd-rbac-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-rbac-cm
    app.kubernetes.io/part-of: argocd
data:
  # Default: any authenticated user gets read-only access
  # This is the safest starting point — grant more as needed
  policy.default: role:readonly

  policy.csv: |
    # -------------------------------------------------------
    # Platform Admins — full control over everything
    # -------------------------------------------------------
    p, role:platform-admin, applications,    *, */*, allow
    p, role:platform-admin, applicationsets, *, */*, allow
    p, role:platform-admin, clusters,        *, *,   allow
    p, role:platform-admin, repositories,    *, *,   allow
    p, role:platform-admin, projects,        *, *,   allow
    p, role:platform-admin, accounts,        *, *,   allow
    p, role:platform-admin, certificates,    *, *,   allow
    p, role:platform-admin, gpgkeys,         *, *,   allow
    p, role:platform-admin, logs,            get, */*, allow
    p, role:platform-admin, exec,            create, */*, allow

    # -------------------------------------------------------
    # Developers — view + sync within their own project only
    # -------------------------------------------------------
    p, role:developer, applications, get,      dev-project/*, allow
    p, role:developer, applications, sync,     dev-project/*, allow
    p, role:developer, applications, override, dev-project/*, allow
    p, role:developer, logs,         get,      dev-project/*, allow
    p, role:developer, repositories, get,      *,             allow

    # -------------------------------------------------------
    # CI/CD bot — sync any app (used by GitHub Actions pipelines)
    # -------------------------------------------------------
    p, role:ci-bot, applications, get,    */*, allow
    p, role:ci-bot, applications, sync,   */*, allow
    p, role:ci-bot, applications, create, */*, allow
    p, role:ci-bot, applications, update, */*, allow

    # -------------------------------------------------------
    # GitHub SSO group bindings (activate after SSO is wired up)
    # Format: g, <org>:<team>, role:<role-name>
    # -------------------------------------------------------
    g, YOUR-GITHUB-ORG:platform-team, role:platform-admin
    g, YOUR-GITHUB-ORG:dev-team,      role:developer

    # -------------------------------------------------------
    # Local user bindings (for service accounts / CI bot)
    # -------------------------------------------------------
    g, ci-bot, role:ci-bot

  # Tell ArgoCD which token claims to use for group lookups
  # 'groups' is populated by Dex from GitHub team membership
  scopes: '[groups, email]'
```

Apply it:

```bash
kubectl apply -f clusters/prod/argocd/argocd-rbac-cm.yaml
```

---

## Phase 4 — GitHub Repository Secret

For ~50 apps in a single GitHub org, use a **repository credential template** — this registers credentials once for the whole org prefix, so you don't need a separate secret per repo.

### Option A — Org-wide Credential Template (recommended for your scale)

```yaml
# File: clusters/prod/argocd/github-repo-creds.yaml
# SECURITY: Do NOT commit the password field to Git.
# Use External Secrets Operator or Sealed Secrets to manage this secret.
apiVersion: v1
kind: Secret
metadata:
  name: github-org-creds
  namespace: argocd
  labels:
    # Note: repo-creds (not repository) — this is a credential template
    argocd.argoproj.io/secret-type: repo-creds
type: Opaque
stringData:
  type: git
  # All repos under this org prefix will use these credentials
  url: https://github.com/YOUR-GITHUB-ORG
  username: YOUR-GITHUB-USERNAME
  # Use a GitHub Personal Access Token (classic) with repo scope,
  # or preferably a fine-grained PAT scoped to Contents: Read-only
  # NEVER commit this value — inject via External Secrets or Sealed Secrets
  password: ghp_REPLACE_WITH_YOUR_PAT
```

### Option B — GitHub App Auth (recommended for production — no expiring tokens)

```yaml
# File: clusters/prod/argocd/github-app-repo-secret.yaml
# SECURITY: githubAppPrivateKey must be stored in a secrets manager.
apiVersion: v1
kind: Secret
metadata:
  name: github-app-credentials
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: https://github.com/YOUR-GITHUB-ORG/YOUR-GITOPS-REPO
  githubAppID: "YOUR-GITHUB-APP-ID"
  githubAppInstallationID: "YOUR-GITHUB-APP-INSTALLATION-ID"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    REPLACE_WITH_YOUR_GITHUB_APP_PRIVATE_KEY
    -----END RSA PRIVATE KEY-----
```

### Applying the secret (do not commit the raw YAML with credentials)

Preferred approach — use External Secrets Operator:

```yaml
# File: clusters/prod/argocd/github-external-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: github-org-creds
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager  # or vault-backend, etc.
  target:
    name: github-org-creds
    template:
      metadata:
        labels:
          argocd.argoproj.io/secret-type: repo-creds
      data:
        type: git
        url: https://github.com/YOUR-GITHUB-ORG
        username: "{{ .username }}"
        password: "{{ .token }}"
  data:
    - secretKey: username
      remoteRef:
        key: argocd/github-creds
        property: username
    - secretKey: token
      remoteRef:
        key: argocd/github-creds
        property: token
```

Fallback — create directly (for initial bootstrap only):

```bash
kubectl create secret generic github-org-creds \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/YOUR-GITHUB-ORG \
  --from-literal=username=YOUR-GITHUB-USERNAME \
  --from-literal=password=YOUR-PAT-HERE
kubectl label secret github-org-creds \
  -n argocd \
  argocd.argoproj.io/secret-type=repo-creds
```

---

## Phase 5 — EKS Cluster Secret

Since ArgoCD is **installed on the same EKS cluster it manages**, you do not need a cluster secret for the local cluster. The in-cluster server `https://kubernetes.default.svc` is always available without any secret.

However, if you later need to register **additional EKS clusters** (e.g. staging, prod-us, prod-eu), use the following pattern with **IRSA (IAM Roles for Service Accounts)** — this is the AWS-native, credential-free approach.

### IRSA-based EKS External Cluster Secret

```yaml
# File: clusters/prod/argocd/eks-external-cluster-secret.yaml
# SECURITY: The roleARN is not sensitive, but caData should come from secrets manager.
apiVersion: v1
kind: Secret
metadata:
  name: eks-prod-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  # Display name shown in ArgoCD UI
  name: eks-prod
  # Your EKS cluster API server endpoint (from: aws eks describe-cluster)
  server: https://XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX.gr7.YOUR-REGION.eks.amazonaws.com
  config: |
    {
      "awsAuthConfig": {
        "clusterName": "YOUR-EKS-CLUSTER-NAME",
        "roleARN": "arn:aws:iam::YOUR-AWS-ACCOUNT-ID:role/argocd-cluster-access"
      },
      "tlsClientConfig": {
        "insecure": false,
        "caData": "BASE64-ENCODED-CLUSTER-CA-CERT"
      }
    }
```

### IRSA Setup Commands

Get the values needed to fill in the secret above:

```bash
# Get API server endpoint
aws eks describe-cluster \
  --name YOUR-EKS-CLUSTER-NAME \
  --region YOUR-REGION \
  --query "cluster.endpoint" --output text

# Get base64-encoded CA cert
aws eks describe-cluster \
  --name YOUR-EKS-CLUSTER-NAME \
  --region YOUR-REGION \
  --query "cluster.certificateAuthority.data" --output text
```

Create the IAM role that ArgoCD will assume (attach to the argocd-application-controller service account via IRSA):

```bash
# Add ArgoCD's service account as a trusted principal in the IAM role trust policy
# The argocd-application-controller SA needs eks:DescribeCluster and
# the aws-auth ConfigMap in the target cluster needs an entry for this role
```

---

## Phase 6 — AppProject for Platform Team

Never use the `default` project for production workloads. This AppProject enforces source/destination boundaries.

```yaml
# File: clusters/prod/argocd/appproject-platform.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
  # Finalizer ensures the project cannot be deleted while Applications reference it
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: Platform team production workloads — manages the full cluster

  # Only these repos can be used as sources for apps in this project
  sourceRepos:
    - https://github.com/YOUR-GITHUB-ORG/YOUR-GITOPS-REPO
    - https://github.com/YOUR-GITHUB-ORG/YOUR-HELM-CHARTS-REPO
    # Allow public Helm chart repos used by platform tooling
    - https://charts.jetstack.io           # cert-manager
    - https://prometheus-community.github.io/helm-charts
    - https://grafana.github.io/helm-charts
    - https://kubernetes.github.io/ingress-nginx

  # Which clusters and namespaces this project can deploy to
  destinations:
    # Allow deployment to any namespace on the in-cluster server
    - namespace: '*'
      server: https://kubernetes.default.svc
    # Add additional cluster destinations here as you onboard more clusters

  # Cluster-scoped resources the platform team is allowed to create
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
    - group: 'rbac.authorization.k8s.io'
      kind: ClusterRole
    - group: 'rbac.authorization.k8s.io'
      kind: ClusterRoleBinding
    - group: 'apiextensions.k8s.io'
      kind: CustomResourceDefinition
    - group: 'admissionregistration.k8s.io'
      kind: MutatingWebhookConfiguration
    - group: 'admissionregistration.k8s.io'
      kind: ValidatingWebhookConfiguration

  # Namespace-scoped resources blocked from creation
  # (prevents apps from overriding quota/limit policies)
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: ''
      kind: LimitRange

  # Project-level roles (supplement the global RBAC in argocd-rbac-cm)
  roles:
    - name: platform-admin
      description: Full access to all applications in the platform project
      policies:
        - p, proj:platform:platform-admin, applications, *, platform/*, allow
      groups:
        - YOUR-GITHUB-ORG:platform-team
    - name: read-only
      description: Read-only access for auditors
      policies:
        - p, proj:platform:read-only, applications, get, platform/*, allow

  # Sync windows — prevent accidental syncs outside business hours in production
  # Adjust schedule to your team's timezone (this example is UTC)
  syncWindows:
    - kind: allow
      schedule: '0 7 * * 1-5'    # Weekdays from 07:00 UTC
      duration: 11h               # Allow syncs until 18:00 UTC
      applications:
        - '*'
      manualSync: true            # Always allow manual syncs regardless of window
    - kind: deny
      schedule: '0 0 * * 6-7'    # Block all automated syncs on weekends
      duration: 48h
      applications:
        - '*'
      manualSync: true            # Still allow emergency manual syncs
```

Apply it:

```bash
kubectl apply -f clusters/prod/argocd/appproject-platform.yaml
```

---

## Phase 7 — Root App-of-Apps Application

The root app bootstraps all other Applications. It points to a directory in your GitOps repo that contains individual Application manifests for each of your 50 workloads.

```yaml
# File: clusters/prod/argocd/root-app.yaml
# This is the only Application you apply manually — everything else is managed by this app.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    # Tell ArgoCD to only re-render when files in this path change (monorepo optimisation)
    argocd.argoproj.io/manifest-generate-paths: clusters/prod/apps
spec:
  project: platform

  source:
    repoURL: https://github.com/YOUR-GITHUB-ORG/YOUR-GITOPS-REPO
    targetRevision: main
    # This directory contains one Application YAML per workload
    path: clusters/prod/apps

  destination:
    server: https://kubernetes.default.svc
    namespace: argocd

  syncPolicy:
    automated:
      # Remove Application CRs from ArgoCD when the YAML file is deleted from git
      prune: true
      # Revert any manual changes made to Application manifests outside of git
      selfHeal: true
    syncOptions:
      # Auto-create namespaces declared in Application manifests
      - CreateNamespace=true
      # Use server-side apply — better for CRD-heavy workloads
      - ServerSideApply=true
      # Foreground deletion ensures child resources are cleaned up before parent
      - PrunePropagationPolicy=foreground
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

Apply the root app to bootstrap the entire system:

```bash
kubectl apply -f clusters/prod/argocd/root-app.yaml
```

### Example child Application (one of your 50 apps)

Place files like this in `clusters/prod/apps/` and the root app will pick them up automatically:

```yaml
# File: clusters/prod/apps/my-service.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-service
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/manifest-generate-paths: services/my-service
spec:
  project: platform
  source:
    repoURL: https://github.com/YOUR-GITHUB-ORG/YOUR-GITOPS-REPO
    targetRevision: main
    path: services/my-service/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: my-service
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

---

## Phase 8 — Ingress and TLS (EKS ALB)

For EKS, the recommended approach is an AWS Application Load Balancer via the AWS Load Balancer Controller, with TLS terminated at the ALB. ArgoCD server is configured in `--insecure` mode behind it.

### Step 8.1 — Patch argocd-server to run in insecure mode

```yaml
# File: clusters/prod/argocd/argocd-server-patch.yaml
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
            - --insecure
            - --staticassets
            - /shared/app
```

```bash
kubectl apply -f clusters/prod/argocd/argocd-server-patch.yaml
```

### Step 8.2 — ALB Ingress

```yaml
# File: clusters/prod/argocd/argocd-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing    # or internal for VPN-only access
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTP     # ArgoCD is insecure, ALB terminates TLS
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    # ACM certificate ARN — replace with your cert
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:YOUR-REGION:YOUR-ACCOUNT-ID:certificate/YOUR-CERT-ID
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    # Security group allowing HTTPS from corporate CIDR only (recommended)
    alb.ingress.kubernetes.io/inbound-cidrs: "YOUR-CORPORATE-CIDR/32"
    # Enable HTTP/2
    alb.ingress.kubernetes.io/load-balancer-attributes: routing.http2.enabled=true
    # Health check
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
    alb.ingress.kubernetes.io/success-codes: "200"
spec:
  rules:
    - host: argocd.YOUR-DOMAIN.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```

```bash
kubectl apply -f clusters/prod/argocd/argocd-ingress.yaml
```

### Alternative: nginx-ingress with TLS passthrough (if you don't use ALB)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.YOUR-DOMAIN.com
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
        - argocd.YOUR-DOMAIN.com
      secretName: argocd-server-tls
```

---

## Phase 9 — Security Hardening

### 9.1 — argocd-cmd-params-cm (global parameter overrides)

```yaml
# File: clusters/prod/argocd/argocd-cmd-params-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
data:
  # Application controller sharding (for HA with 50 apps)
  controller.sharding.algorithm: consistent-hashing

  # Processor counts — defaults are fine for ~50 apps
  controller.status.processors: "20"
  controller.operation.processors: "10"

  # Repo server — limit concurrent manifest generation to prevent OOM
  reposerver.parallelism.limit: "10"
  reposerver.repo.cache.expiration: 24h

  # Server — enable gzip compression for the UI
  server.enable.gzip: "true"

  # Redis compression
  redis.compression: gzip
```

```bash
kubectl apply -f clusters/prod/argocd/argocd-cmd-params-cm.yaml
```

### 9.2 — Redis password (recommended)

```yaml
# File: clusters/prod/argocd/argocd-secret-patch.yaml
# SECURITY: Use External Secrets / Sealed Secrets for the redis-password value.
apiVersion: v1
kind: Secret
metadata:
  name: argocd-secret
  namespace: argocd
type: Opaque
stringData:
  redis-password: "REPLACE-WITH-A-STRONG-RANDOM-PASSWORD"
  # If using GitHub SSO via Dex, add these too:
  # dex.github.clientID: "YOUR-GITHUB-OAUTH-APP-CLIENT-ID"
  # dex.github.clientSecret: "YOUR-GITHUB-OAUTH-APP-CLIENT-SECRET"
```

```bash
kubectl apply -f clusters/prod/argocd/argocd-secret-patch.yaml
```

### 9.3 — Network Policy

```yaml
# File: clusters/prod/argocd/network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: argocd-allow-internal
  namespace: argocd
spec:
  podSelector: {}    # Apply to all pods in the argocd namespace
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow traffic from within the argocd namespace (inter-component communication)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: argocd
    # Allow traffic from the ALB/nginx ingress controller namespace
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
    # Allow Kubernetes liveness/readiness probes from the node CIDR
    # (adjust to your EKS node CIDR)
    - from:
        - ipBlock:
            cidr: 10.0.0.0/8
  egress:
    # Allow all egress — ArgoCD needs to reach Git, Kubernetes API, and managed clusters
    - to:
        - namespaceSelector: {}
    # DNS resolution
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    # HTTPS for GitHub and other external services
    - ports:
        - port: 443
    # Kubernetes API server
    - ports:
        - port: 6443
```

```bash
kubectl apply -f clusters/prod/argocd/network-policy.yaml
```

### 9.4 — Create a CI bot local user

```bash
# Add ci-bot account to argocd-cm (append to the argocd-cm ConfigMap)
kubectl patch configmap argocd-cm -n argocd --type merge \
  -p '{"data":{"accounts.ci-bot":"apiKey"}}'

# Generate an API key for the CI bot
argocd account generate-token --account ci-bot
# Store this token in your CI/CD secrets (GitHub Actions secrets, etc.)
```

### 9.5 — Production Security Checklist

Run through this after initial setup:

- [ ] Initial admin password changed
- [ ] `argocd-initial-admin-secret` deleted
- [ ] `argocd-cm`: `users.anonymous.enabled` set to `"false"`
- [ ] `argocd-cm`: `exec.enabled` set to `"false"` (unless explicitly needed)
- [ ] `argocd-rbac-cm`: `policy.default` set to `role:readonly`
- [ ] Redis password configured in `argocd-secret`
- [ ] GitHub credentials stored via External Secrets / Sealed Secrets — not raw in Git
- [ ] Network policy applied and verified
- [ ] ALB/Ingress restricted to corporate IP ranges (`inbound-cidrs`)
- [ ] AppProject created with explicit `sourceRepos` and `destinations` — no wildcard `*` repos
- [ ] `syncWindows` configured to block out-of-hours automated syncs
- [ ] CI bot using API key (not admin credentials) in pipelines
- [ ] GitHub SSO via Dex configured and tested (then set `admin.enabled: "false"`)
- [ ] `argocd-secret`: Dex GitHub OAuth credentials stored (not in ConfigMap plaintext)
- [ ] Repo server memory limits set (`reposerver.max.combined.directory.manifests.size: 10M`)

---

## Phase 10 — HA Tuning for ~50 Apps

At ~50 apps, the default ArgoCD HA settings are largely appropriate. Here is what to tune and what to leave alone.

### 10.1 — Application Controller: scale to 3 replicas with sharding

```bash
# Scale the application controller StatefulSet to 3 replicas
kubectl scale statefulset argocd-application-controller -n argocd --replicas=3

# Set the replica count env var so each shard knows the total (must match spec.replicas)
kubectl set env statefulset/argocd-application-controller \
  -n argocd \
  ARGOCD_CONTROLLER_REPLICAS=3
```

With consistent-hashing (set in argocd-cmd-params-cm above), ~50 apps will be evenly distributed across 3 controller shards — roughly 17 apps per shard.

### 10.2 — argocd-server: scale to 3 replicas

```bash
kubectl scale deployment argocd-server -n argocd --replicas=3
```

### 10.3 — Processor counts for ~50 apps

At 50 apps, the defaults are fine:
- `--status-processors=20` (default) — adequate up to ~100 apps
- `--operation-processors=10` (default) — adequate unless you have many simultaneous syncs

You only need to increase these when you regularly see the application controller log messages about queue depth. Monitor with:

```bash
kubectl -n argocd logs statefulset/argocd-application-controller | grep -i "queue\|processor"
```

### 10.4 — Repo server: parallelism limit

With 50 apps potentially syncing in parallel (e.g. after a merge), the repo server can spike. `reposerver.parallelism.limit: "10"` (set above in argocd-cmd-params-cm) ensures at most 10 concurrent manifest generations. This is appropriate for 50 apps — increase to 20 if you observe sync queuing.

### 10.5 — Resource allocation summary for ~50 apps

```yaml
# Reference: expected resource usage at ~50 apps steady state
# Tune your node group sizing accordingly

# argocd-server (3 replicas x)
# requests: 250m CPU / 256Mi RAM per replica

# argocd-application-controller (3 shards x)
# requests: 500m CPU / 512Mi RAM per shard
# limits: 4000m CPU / 2Gi RAM per shard

# argocd-repo-server (2 replicas x)
# requests: 250m CPU / 256Mi RAM per replica
# limits: 2000m CPU / 1Gi RAM per replica

# argocd-redis-ha (3 nodes x)
# requests: 100m CPU / 128Mi RAM per node (typical)

# Rough total:
# CPU requests: ~5 vCPU
# RAM requests: ~4 GB
# Fits comfortably on 3 x m5.large nodes dedicated to ArgoCD
```

### 10.6 — Monorepo optimisation

If your 50 apps all live in a single monorepo, add this annotation to every Application to prevent unnecessary cache busting when unrelated paths change:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/manifest-generate-paths: services/MY-SERVICE
```

### 10.7 — Reconciliation jitter

With 50 apps all reconciling at 180s, without jitter you'd get bursts of 50 simultaneous git fetches. The `timeout.reconciliation.jitter: 30s` in argocd-cm spreads these out across a 30-second window — keep this configured.

### 10.8 — Scaling roadmap

| App count | Recommended changes |
|---|---|
| 0–50 (current) | Defaults + sharding enabled. 3 controller replicas |
| 50–150 | Increase `status-processors` to 30, `operation-processors` to 15 |
| 150–300 | Add 1–2 more controller shards. Scale repo-server to 3+ replicas |
| 300–500 | `status-processors=50`, `operation-processors=25`, 5+ controller shards |
| 500+ | Consider multiple ArgoCD instances or ApplicationSets with per-cluster controllers |

---

## Recommended GitOps Repo Layout

```
YOUR-GITOPS-REPO/
├── clusters/
│   └── prod/
│       ├── argocd/                         # ArgoCD configuration (applied by bootstrap)
│       │   ├── argocd-cm.yaml
│       │   ├── argocd-rbac-cm.yaml
│       │   ├── argocd-cmd-params-cm.yaml
│       │   ├── argocd-server-patch.yaml
│       │   ├── argocd-ingress.yaml
│       │   ├── appproject-platform.yaml
│       │   ├── network-policy.yaml
│       │   └── root-app.yaml               # Applied manually once to bootstrap
│       └── apps/                           # One file per workload — managed by root-app
│           ├── my-service.yaml
│           ├── cert-manager.yaml
│           ├── prometheus-stack.yaml
│           └── ... (one per app, ~50 total)
├── services/                               # Actual service manifests / Helm values
│   ├── my-service/
│   │   ├── base/
│   │   └── overlays/
│   │       ├── staging/
│   │       └── prod/
│   └── cert-manager/
│       └── values-prod.yaml
└── README.md
```

### Bootstrap sequence (run once on a fresh cluster)

```bash
# 1. Install ArgoCD HA
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/ha/install.yaml

# 2. Wait for ArgoCD to be ready
kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=300s

# 3. Apply your configuration layer
kubectl apply -f clusters/prod/argocd/argocd-cm.yaml
kubectl apply -f clusters/prod/argocd/argocd-rbac-cm.yaml
kubectl apply -f clusters/prod/argocd/argocd-cmd-params-cm.yaml
kubectl apply -f clusters/prod/argocd/appproject-platform.yaml
kubectl apply -f clusters/prod/argocd/network-policy.yaml

# 4. Create the GitHub credentials secret (via External Secrets or manually for bootstrap)
# ... (see Phase 4)

# 5. Apply the root app — this triggers ArgoCD to sync all 50 apps from Git
kubectl apply -f clusters/prod/argocd/root-app.yaml

# 6. Watch the magic
kubectl -n argocd get applications -w
```

---

## Quick Reference Commands

```bash
# Check all ArgoCD component health
kubectl -n argocd get pods

# Check application sync status
kubectl -n argocd get applications

# Check Redis Sentinel health
kubectl -n argocd exec -it argocd-redis-ha-0 -- \
  redis-cli -p 26379 SENTINEL masters

# Check controller shard assignments
kubectl -n argocd logs statefulset/argocd-application-controller | grep shard

# Force a sync on a specific app
argocd app sync my-service --prune

# View app diff before syncing
argocd app diff my-service

# List all apps and their health/sync status
argocd app list
```

---

*Generated for ArgoCD v3.3.8 — EKS HA production setup — April 2026*
