# Production-Grade ArgoCD v3.3.8 on EKS — Complete Setup Guide

## Context Summary

- **Cluster:** Fresh EKS cluster on AWS
- **Mode:** HA (High Availability)
- **Git provider:** GitHub (GitHub App auth)
- **Scale:** ~50 applications to start
- **Use case:** Platform team managing all production workloads

---

## Phase 1 — Install ArgoCD v3.3.8 in HA Mode

HA mode requires at least **3 worker nodes** in your EKS cluster due to pod anti-affinity rules.

```bash
# 1. Create namespace
kubectl create namespace argocd

# 2. Apply HA manifests (v3.3.8)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/ha/install.yaml

# 3. Wait for all components to become ready
kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=300s
kubectl -n argocd wait --for=condition=available deployment/argocd-repo-server --timeout=300s
kubectl -n argocd wait --for=condition=available deployment/argocd-dex-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# 4. Retrieve initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

# 5. Temporary access (replace with Ingress/LoadBalancer for production)
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Visit https://localhost:8080 and log in as admin

# 6. After first login — rotate the admin password, then delete the bootstrap secret
kubectl -n argocd delete secret argocd-initial-admin-secret
```

### HA Component Replicas (deployed by ha/install.yaml)

| Component | HA Replicas | Notes |
|---|---|---|
| argocd-server | 3 | Stateless; horizontally scalable |
| argocd-repo-server | 2 | Manifest generation; tune parallelism |
| argocd-application-controller | 3 (sharded) | Set `ARGOCD_CONTROLLER_REPLICAS=3` |
| argocd-redis | 3 (Sentinel) | Fixed at 3 for quorum |
| argocd-dex-server | 1 | In-memory; single instance only |
| argocd-applicationset-controller | 2 | Leader election; active/standby |

---

## Phase 2 — Core ConfigMap (argocd-cm)

**File: `clusters/prod/argocd/argocd-cm.yaml`**

> SECURITY NOTE: `admin.enabled` is set to `"true"` initially. Disable it once SSO/Dex is working and verified.

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
  # External URL — required for SSO callbacks and notifications
  url: https://argocd.YOURDOMAIN.com

  # Admin user — disable this once Dex/OIDC SSO is configured and verified
  admin.enabled: "true"

  # Anonymous access — always disabled in production
  users.anonymous.enabled: "false"

  # JWT session expiry — 8h is a good production balance
  users.session.duration: 8h

  # Exclude high-noise resources from the watch cache (reduces API server load)
  resource.exclusions: |
    - apiGroups:
      - "events.k8s.io"
      - "metrics.k8s.io"
      kinds:
      - "*"
      clusters:
      - "*"

  # Reconciliation interval — 180s with jitter to avoid thundering herd
  timeout.reconciliation: 180s
  timeout.reconciliation.jitter: 30s

  # Annotation-based resource tracking (more reliable than label-based at scale)
  application.resourceTrackingMethod: annotation

  # Protect repo-server from DoS via large manifests
  reposerver.max.combined.directory.manifests.size: 10M

  # Disable exec (terminal) access in UI — enable only if explicitly required
  exec.enabled: "false"

  # GitHub OAuth via Dex — enables GitHub team-to-RBAC role mapping
  # Store dex.github.clientID and dex.github.clientSecret in argocd-secret
  dex.config: |
    connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: $dex.github.clientID
          clientSecret: $dex.github.clientSecret
          orgs:
            - name: YOUR-GITHUB-ORG
              teams:
                - platform-team
                - dev-team

  # Suppress noisy diffs from HPA-managed replicas and webhook CA injections
  resource.customizations.ignoreDifferences.apps_Deployment: |
    jsonPointers:
      - /spec/replicas
      - /metadata/annotations/deployment.kubernetes.io~1revision

  resource.customizations.ignoreDifferences.admissionregistration.k8s.io_MutatingWebhookConfiguration: |
    jsonPointers:
      - /webhooks/0/clientConfig/caBundle
```

Apply it:
```bash
kubectl apply -f clusters/prod/argocd/argocd-cm.yaml
```

---

## Phase 3 — RBAC ConfigMap (argocd-rbac-cm)

**File: `clusters/prod/argocd/argocd-rbac-cm.yaml`**

> Follows the principle of least privilege. Default role is read-only for all authenticated users.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-rbac-cm
    app.kubernetes.io/part-of: argocd
data:
  # All authenticated users get read-only by default
  policy.default: role:readonly

  # Include both 'groups' and 'email' from OIDC token for group mapping
  scopes: '[groups, email]'

  policy.csv: |
    # ── Platform admins — full control over everything ──────────────────────
    p, role:platform-admin, applications,    *, */*, allow
    p, role:platform-admin, applicationsets, *, */*, allow
    p, role:platform-admin, clusters,        *, *,   allow
    p, role:platform-admin, repositories,    *, *,   allow
    p, role:platform-admin, projects,        *, *,   allow
    p, role:platform-admin, accounts,        *, *,   allow
    p, role:platform-admin, certificates,    *, *,   allow
    p, role:platform-admin, exec,            create, */*, allow

    # ── Developers — view + sync in their own project only ──────────────────
    p, role:developer, applications, get,      platform/*, allow
    p, role:developer, applications, sync,     platform/*, allow
    p, role:developer, applications, override, platform/*, allow
    p, role:developer, logs,         get,      platform/*, allow
    p, role:developer, repositories, get,      *,          allow

    # ── CI/CD bot — sync-only across all projects (for pipeline automation) ─
    p, role:ci-bot, applications, get,  */*, allow
    p, role:ci-bot, applications, sync, */*, allow

    # ── GitHub team → role bindings (via Dex group membership) ──────────────
    g, YOUR-GITHUB-ORG:platform-team, role:platform-admin
    g, YOUR-GITHUB-ORG:dev-team,      role:developer

    # ── Local service account bindings ───────────────────────────────────────
    g, ci-bot, role:ci-bot
```

Apply it:
```bash
kubectl apply -f clusters/prod/argocd/argocd-rbac-cm.yaml
```

---

## Phase 4 — GitHub Repository Secret (GitHub App Auth)

> SECURITY NOTE: GitHub App auth is strongly preferred over PATs — no expiring tokens, fine-grained permissions, and auditable.

### Step 1: Create a GitHub App

1. Go to **GitHub > Your Org > Settings > Developer settings > GitHub Apps > New GitHub App**
2. Set:
   - Name: `argocd-gitops`
   - Homepage URL: `https://argocd.YOURDOMAIN.com`
   - Uncheck "Active" for Webhooks (ArgoCD polls; webhooks are optional)
   - Repository permissions: **Contents: Read**, **Metadata: Read**
3. Generate a private key — download the `.pem` file
4. Note down: **App ID** and **Installation ID** (visible after installing the app on your org)

### Step 2: Apply the Kubernetes Secret

**File: `clusters/prod/argocd/github-app-repo-secret.yaml`**

> SECURITY NOTE: Do NOT commit this file to Git with real values. Use External Secrets Operator or Sealed Secrets to manage the private key. The template below uses placeholder values.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-app-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
  annotations:
    # Managed by: External Secrets / Sealed Secrets — do not edit directly
type: Opaque
stringData:
  type: git
  url: https://github.com/YOUR-ORG/YOUR-GITOPS-REPO

  # From your GitHub App settings page
  githubAppID: "123456"

  # From the App installation page (Org > Settings > Installed GitHub Apps > Configure)
  githubAppInstallationID: "789012"

  # Contents of the downloaded .pem private key
  # SECURITY: Store this in AWS Secrets Manager and pull via External Secrets Operator
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    REPLACE_WITH_ACTUAL_PRIVATE_KEY_CONTENT
    -----END RSA PRIVATE KEY-----
```

Apply it:
```bash
kubectl apply -f clusters/prod/argocd/github-app-repo-secret.yaml
```

### Credential Template (covers all repos in the org — optional but recommended for 50+ apps)

If all 50 apps share the same GitHub org, use a `repo-creds` template so you only need one secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-org-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds   # note: repo-creds, not repository
type: Opaque
stringData:
  type: git
  url: https://github.com/YOUR-ORG   # matches ALL repos under this org prefix
  githubAppID: "123456"
  githubAppInstallationID: "789012"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    REPLACE_WITH_ACTUAL_PRIVATE_KEY_CONTENT
    -----END RSA PRIVATE KEY-----
```

---

## Phase 5 — EKS Cluster Secret (IRSA)

Since ArgoCD is installed on the same EKS cluster it manages, the **in-cluster server** (`https://kubernetes.default.svc`) is available automatically — no cluster secret is needed for that.

If you are also managing **additional EKS clusters** from this ArgoCD instance (multi-cluster), use the IRSA-based cluster secret below.

### Prerequisites

1. Create an IAM role with the `eks:DescribeCluster` permission and trust policy allowing the ArgoCD service account to assume it
2. Annotate the ArgoCD service accounts with the IAM role ARN
3. Create an aws-auth ConfigMap entry in the target cluster granting the IAM role RBAC access

### IAM Trust Policy (on the target cluster's IAM role)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::YOUR-ACCOUNT-ID:oidc-provider/oidc.eks.YOUR-REGION.amazonaws.com/id/YOUR-OIDC-ID"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.YOUR-REGION.amazonaws.com/id/YOUR-OIDC-ID:sub": "system:serviceaccount:argocd:argocd-application-controller",
          "oidc.eks.YOUR-REGION.amazonaws.com/id/YOUR-OIDC-ID:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

### Annotate the ArgoCD Service Account

```bash
kubectl -n argocd annotate serviceaccount argocd-application-controller \
  eks.amazonaws.com/role-arn=arn:aws:iam::YOUR-ACCOUNT-ID:role/argocd-cluster-access
```

### Cluster Secret YAML

**File: `clusters/prod/argocd/eks-cluster-secret.yaml`**

> SECURITY NOTE: The `caData` value must be base64-encoded. Retrieve it with:
> `kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'`

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
  # Display name in ArgoCD UI
  name: eks-prod

  # EKS cluster API endpoint — retrieve with:
  # aws eks describe-cluster --name YOUR-CLUSTER-NAME --query 'cluster.endpoint' --output text
  server: https://XXXXXX.gr7.YOUR-REGION.eks.amazonaws.com

  config: |
    {
      "awsAuthConfig": {
        "clusterName": "YOUR-EKS-CLUSTER-NAME",
        "roleARN": "arn:aws:iam::YOUR-ACCOUNT-ID:role/argocd-cluster-access"
      },
      "tlsClientConfig": {
        "insecure": false,
        "caData": "BASE64-ENCODED-EKS-CA-CERT"
      }
    }
```

Apply it:
```bash
kubectl apply -f clusters/prod/argocd/eks-cluster-secret.yaml
```

---

## Phase 6 — AppProject for the Platform Team

**File: `clusters/prod/argocd/appproject-platform.yaml`**

> Never use the `default` project for production workloads. Projects enforce source repo allowlists, destination constraints, and resource type controls.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: Platform team production workloads — manages all 50+ apps on EKS

  # Only these source repos are allowed (add more repos as needed)
  sourceRepos:
    - https://github.com/YOUR-ORG/YOUR-GITOPS-REPO
    - https://github.com/YOUR-ORG/helm-charts
    # Public Helm chart registries (add as needed)
    - https://charts.jetstack.io
    - https://prometheus-community.github.io/helm-charts

  # Allowed deployment destinations
  destinations:
    - namespace: '*'
      server: https://kubernetes.default.svc   # in-cluster (EKS)
    # Add additional managed clusters here when needed:
    # - namespace: '*'
    #   server: https://XXXXXX.gr7.YOUR-REGION.eks.amazonaws.com

  # Cluster-scoped resource types this project can create
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
    - group: 'rbac.authorization.k8s.io'
      kind: ClusterRole
    - group: 'rbac.authorization.k8s.io'
      kind: ClusterRoleBinding
    - group: 'apiextensions.k8s.io'
      kind: CustomResourceDefinition
    - group: 'policy'
      kind: PodSecurityPolicy
    - group: 'admissionregistration.k8s.io'
      kind: MutatingWebhookConfiguration
    - group: 'admissionregistration.k8s.io'
      kind: ValidatingWebhookConfiguration

  # Namespace-scoped resource types this project cannot deploy (deny list)
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: ''
      kind: LimitRange

  # Project-level roles (supplemental to global argocd-rbac-cm)
  roles:
    - name: project-admin
      description: Full access to all applications in this project
      policies:
        - p, proj:platform:project-admin, applications, *, platform/*, allow
      groups:
        - YOUR-GITHUB-ORG:platform-team

    - name: developer
      description: View and sync access to platform project apps
      policies:
        - p, proj:platform:developer, applications, get,  platform/*, allow
        - p, proj:platform:developer, applications, sync, platform/*, allow
        - p, proj:platform:developer, logs,         get,  platform/*, allow

  # Sync windows — restrict production syncs to business hours (optional; adjust as needed)
  syncWindows:
    - kind: allow
      schedule: '0 7 * * 1-5'    # Monday–Friday from 07:00 UTC
      duration: 11h               # through 18:00 UTC
      applications:
        - '*'
    - kind: deny
      schedule: '0 20 * * *'     # Every day from 20:00 UTC
      duration: 11h               # until 07:00 UTC (freeze overnight)
      namespaces:
        - production
```

Apply it:
```bash
kubectl apply -f clusters/prod/argocd/appproject-platform.yaml
```

---

## Phase 7 — Root App-of-Apps Application

The App-of-Apps pattern uses one root Application that watches a directory of Application manifests in Git. When you add a new Application YAML to that directory and push, ArgoCD automatically picks it up.

**File: `clusters/prod/argocd/root-app.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: argocd
    app.kubernetes.io/managed-by: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    # Monorepo optimisation — only invalidate cache when this path changes
    argocd.argoproj.io/manifest-generate-paths: clusters/prod/apps
spec:
  project: platform

  source:
    repoURL: https://github.com/YOUR-ORG/YOUR-GITOPS-REPO
    targetRevision: main
    path: clusters/prod/apps   # directory containing one Application YAML per workload

  destination:
    server: https://kubernetes.default.svc
    namespace: argocd   # Applications are created in the argocd namespace

  syncPolicy:
    automated:
      prune: true       # Remove Application objects deleted from Git
      selfHeal: true    # Revert manual changes to Application objects
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - PrunePropagationPolicy=foreground
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
```

Apply the root app to bootstrap the entire platform:
```bash
kubectl apply -f clusters/prod/argocd/root-app.yaml
```

### Recommended GitOps Repo Structure

```
YOUR-GITOPS-REPO/
├── clusters/
│   └── prod/
│       ├── argocd/                    # ArgoCD config (applied manually or via bootstrap)
│       │   ├── argocd-cm.yaml
│       │   ├── argocd-rbac-cm.yaml
│       │   ├── argocd-cmd-params-cm.yaml
│       │   ├── appproject-platform.yaml
│       │   └── root-app.yaml
│       └── apps/                      # One Application YAML per workload
│           ├── cert-manager.yaml
│           ├── external-secrets.yaml
│           ├── ingress-nginx.yaml
│           ├── prometheus-stack.yaml
│           ├── my-service-a.yaml
│           ├── my-service-b.yaml
│           └── ...                    # up to 50 apps here
```

---

## Phase 8 — Ingress and TLS (Production Access)

Replace port-forward with a proper Ingress. Two options:

### Option A — AWS Load Balancer Controller (recommended for EKS)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTPS
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:YOUR-REGION:YOUR-ACCOUNT-ID:certificate/YOUR-CERT-ID
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
spec:
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
```

### Option B — nginx-ingress with SSL passthrough

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

---

## Phase 9 — Security Hardening

### 9.1 Enforce TLS 1.2+ on argocd-server

**File: `clusters/prod/argocd/argocd-server-tls-patch.yaml`**

```yaml
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

```bash
kubectl patch deployment argocd-server -n argocd --patch-file clusters/prod/argocd/argocd-server-tls-patch.yaml
```

### 9.2 Set Redis Password

**SECURITY NOTE:** Store the Redis password in AWS Secrets Manager and sync it with External Secrets Operator — do not hardcode it.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-secret
  namespace: argocd
stringData:
  # Also store dex OAuth credentials here (referenced by $dex.github.clientID in argocd-cm)
  dex.github.clientID: "YOUR-GITHUB-OAUTH-APP-CLIENT-ID"
  dex.github.clientSecret: "YOUR-GITHUB-OAUTH-APP-CLIENT-SECRET"

  # Redis auth password — use a strong random value
  # Generate with: openssl rand -base64 32
  redis-password: "REPLACE-WITH-STRONG-RANDOM-PASSWORD"
```

### 9.3 Network Policies

**File: `clusters/prod/argocd/network-policy.yaml`**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: argocd-allow-internal
  namespace: argocd
spec:
  podSelector: {}   # applies to all pods in the argocd namespace
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow intra-namespace traffic (ArgoCD components talk to each other)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: argocd
    # Allow ingress controller to reach argocd-server
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 443
        - port: 8080
  egress:
    # Allow DNS
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    # Allow HTTPS outbound (Git, Helm registries)
    - ports:
        - port: 443
    # Allow Kubernetes API server
    - ports:
        - port: 6443
```

```bash
kubectl apply -f clusters/prod/argocd/network-policy.yaml
```

### 9.4 Post-SSO Hardening Steps

Once GitHub SSO via Dex is verified and working:

```bash
# 1. Disable local admin user (patch argocd-cm)
kubectl patch configmap argocd-cm -n argocd \
  --type merge \
  -p '{"data":{"admin.enabled":"false"}}'

# 2. Verify no one can log in as admin
argocd login argocd.YOURDOMAIN.com --username admin
# Should return: "invalid username/password"
```

### 9.5 Security Hardening Checklist

- [ ] TLS 1.2+ enforced on argocd-server (step 9.1)
- [ ] Admin user disabled after SSO is working (step 9.4)
- [ ] `argocd-initial-admin-secret` deleted after first login
- [ ] Redis password set in `argocd-secret` (step 9.2)
- [ ] `policy.default: role:readonly` set in argocd-rbac-cm (Phase 3)
- [ ] Named AppProject with explicit source/destination whitelists (Phase 6)
- [ ] GitHub App private key stored in AWS Secrets Manager (not in Git)
- [ ] `argocd-secret` managed via External Secrets Operator or Sealed Secrets
- [ ] Network policies applied to argocd namespace (step 9.3)
- [ ] `reposerver.max.combined.directory.manifests.size: 10M` set in argocd-cm (Phase 2)
- [ ] Repo-server resource limits configured (see Phase 10)
- [ ] `users.anonymous.enabled: "false"` set in argocd-cm (Phase 2)
- [ ] `exec.enabled: "false"` set in argocd-cm (Phase 2)
- [ ] Webhook secrets configured if using GitHub webhooks for faster reconciliation

---

## Phase 10 — HA Tuning for ~50 Applications

At 50 apps, the default settings are sufficient to start. However, configure the following for headroom and stability.

### argocd-cmd-params-cm (global parameter overrides)

**File: `clusters/prod/argocd/argocd-cmd-params-cm.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-cmd-params-cm
    app.kubernetes.io/part-of: argocd
data:
  # ── Application Controller ───────────────────────────────────────────────
  # Defaults (20 status, 10 operation) are fine for 50 apps.
  # Increase to 30/15 if you see sync backlogs in the controller logs.
  controller.status.processors: "20"
  controller.operation.processors: "10"

  # Sharding algorithm — consistent-hashing gives stable distribution
  # when controller replicas scale up/down
  controller.sharding.algorithm: consistent-hashing

  # ── Repo Server ──────────────────────────────────────────────────────────
  # Limit parallel manifest generation to prevent repo-server OOM
  reposerver.parallelism.limit: "10"

  # Cache repos for 24h — reduce Git API calls at scale
  reposerver.repo.cache.expiration: 24h

  # ── Server ───────────────────────────────────────────────────────────────
  server.insecure: "false"
  server.enable.gzip: "true"

  # ── Redis ────────────────────────────────────────────────────────────────
  redis.compression: gzip
```

```bash
kubectl apply -f clusters/prod/argocd/argocd-cmd-params-cm.yaml
```

### Resource Limits (apply as patches to the HA manifests)

**Application Controller:**
```yaml
# patch: argocd-application-controller resources
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 4000m
    memory: 2Gi
```

**Repo Server:**
```yaml
# patch: argocd-repo-server resources
resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    cpu: 2000m
    memory: 1Gi
```

**ArgoCD Server:**
```yaml
# patch: argocd-server resources
resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    cpu: 2000m
    memory: 512Mi
```

### Controller IRSA Annotation (required for IRSA to work)

The HA manifest creates the application controller as a StatefulSet. Annotate its service account:

```bash
kubectl -n argocd annotate serviceaccount argocd-application-controller \
  eks.amazonaws.com/role-arn=arn:aws:iam::YOUR-ACCOUNT-ID:role/argocd-cluster-access
```

### Scaling Guidance as You Grow

| App count | Controller replicas | Status processors | Operation processors | Sharding |
|---|---|---|---|---|
| Up to 100 | 1 (default) | 20 (default) | 10 (default) | Not needed |
| 100–500 | 2–3 | 30 | 15 | `consistent-hashing` |
| 500+ | 3+ | 50 | 25 | `consistent-hashing` |

At 50 apps you are well within defaults. Pre-configure `consistent-hashing` now so you get smooth scaling without reshuffling when you do grow.

### Verify HA Health After Setup

```bash
# All HA pods running and ready
kubectl -n argocd get pods -o wide

# Redis Sentinel quorum status
kubectl -n argocd exec -it argocd-redis-ha-0 -- \
  redis-cli -p 26379 SENTINEL masters

# Application controller shard assignments
kubectl -n argocd logs statefulset/argocd-application-controller | grep shard

# Check all applications are synced
kubectl -n argocd get applications -A
```

---

## Summary: Apply Order

Apply resources in this order to avoid dependency issues:

```bash
# 1. Namespace + HA install
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.8/manifests/ha/install.yaml

# 2. Wait for readiness
kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=300s

# 3. Core configuration
kubectl apply -f clusters/prod/argocd/argocd-cm.yaml
kubectl apply -f clusters/prod/argocd/argocd-rbac-cm.yaml
kubectl apply -f clusters/prod/argocd/argocd-cmd-params-cm.yaml

# 4. Secrets (SECURITY: use External Secrets Operator in production)
kubectl apply -f clusters/prod/argocd/github-app-repo-secret.yaml
# kubectl apply -f clusters/prod/argocd/eks-cluster-secret.yaml  # only if managing additional clusters

# 5. AppProject
kubectl apply -f clusters/prod/argocd/appproject-platform.yaml

# 6. Network policies + TLS patch
kubectl apply -f clusters/prod/argocd/network-policy.yaml
kubectl patch deployment argocd-server -n argocd --patch-file clusters/prod/argocd/argocd-server-tls-patch.yaml

# 7. Root App — bootstraps all 50 applications
kubectl apply -f clusters/prod/argocd/root-app.yaml

# 8. Get admin password, log in, rotate it, delete bootstrap secret
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
# After rotating password:
kubectl -n argocd delete secret argocd-initial-admin-secret
```

---

## Key Placeholders to Replace

| Placeholder | What to replace with |
|---|---|
| `YOUR-ORG` | Your GitHub organisation name |
| `YOUR-GITOPS-REPO` | Your GitOps repository name |
| `YOURDOMAIN.com` | Your actual domain |
| `YOUR-GITHUB-ORG` | GitHub org name (used in Dex group bindings) |
| `YOUR-ACCOUNT-ID` | AWS account ID |
| `YOUR-REGION` | AWS region (e.g. `eu-west-1`) |
| `YOUR-EKS-CLUSTER-NAME` | EKS cluster name |
| `YOUR-OIDC-ID` | EKS OIDC provider ID |
| `123456` / `789012` | Real GitHub App ID / Installation ID |
| `BASE64-ENCODED-EKS-CA-CERT` | Output of `kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'` |
