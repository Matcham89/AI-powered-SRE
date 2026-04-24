# ArgoCD AppProject: payments

## Overview

This document provides a complete, production-ready ArgoCD configuration for the payments team. It includes the AppProject definition, a sample Application template, RBAC project roles, and operational notes for the team.

---

## AppProject YAML

```yaml
# File: clusters/prod/argocd/projects/payments-project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: payments
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io  # prevents accidental deletion of the project while Applications exist
  annotations:
    # Document who owns this project
    project.argocd.io/owner: "payments-team-lead"
    project.argocd.io/contact: "payments-team@acme-corp.com"
spec:
  description: "Payments team workloads — production and staging environments"

  # Only repos matching this wildcard are permitted as sources.
  # Any attempt to deploy from a repo outside this prefix will be rejected.
  sourceRepos:
    - https://github.com/acme-corp/payments-*

  # Only the payments-prod and payments-staging namespaces on the in-cluster server
  # are valid deployment targets. No other namespaces or clusters are accessible.
  destinations:
    - namespace: payments-prod
      server: https://kubernetes.default.svc
    - namespace: payments-staging
      server: https://kubernetes.default.svc

  # Cluster-scoped (non-namespaced) resources the project is allowed to create.
  # Namespace is the ONLY cluster-scoped resource permitted — no ClusterRoles,
  # ClusterRoleBindings, CRDs, or PersistentVolumes.
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace

  # Namespace-scoped resources the project is allowed to create.
  # This is an ALLOW list — only these four kinds can be deployed into the
  # payments-prod and payments-staging namespaces. Everything else is blocked.
  namespaceResourceWhitelist:
    - group: "apps"
      kind: Deployment
    - group: ""
      kind: Service
    - group: ""
      kind: ConfigMap
    - group: "autoscaling"
      kind: HorizontalPodAutoscaler

  # Project-level roles
  # These are scoped to this project only and are independent of global ArgoCD RBAC.
  roles:
    - name: payments-admin
      description: "Full administrative access to the payments project — assigned to the payments team lead"
      policies:
        # Full CRUD + sync on all applications within the payments project
        - p, proj:payments:payments-admin, applications, get,    payments/*, allow
        - p, proj:payments:payments-admin, applications, create, payments/*, allow
        - p, proj:payments:payments-admin, applications, update, payments/*, allow
        - p, proj:payments:payments-admin, applications, delete, payments/*, allow
        - p, proj:payments:payments-admin, applications, sync,   payments/*, allow
        - p, proj:payments:payments-admin, applications, override, payments/*, allow
        # Log and exec access for debugging
        - p, proj:payments:payments-admin, logs, get, payments/*, allow
        - p, proj:payments:payments-admin, exec, create, payments/*, allow
      groups:
        - acme-corp:payments-leads   # map your SSO/OIDC group here

    - name: payments-developer
      description: "Sync and read-only access — assigned to payments developers"
      policies:
        # Developers can view app state and trigger syncs but cannot create/delete apps
        - p, proj:payments:payments-developer, applications, get,  payments/*, allow
        - p, proj:payments:payments-developer, applications, sync, payments/*, allow
        # Allow developers to view logs for debugging
        - p, proj:payments:payments-developer, logs, get, payments/*, allow
      groups:
        - acme-corp:payments-developers  # map your SSO/OIDC group here
```

---

## Sample Application YAML (Template for the Payments Team)

Use this as a starting template for each service the payments team deploys. Copy and adjust `name`, `path`, and `namespace` per service.

```yaml
# File: clusters/prod/apps/payments/payments-api.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-api
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io  # cascade-delete Kubernetes resources when this Application is deleted
  labels:
    team: payments
    environment: prod
spec:
  # Must match the AppProject name exactly
  project: payments

  source:
    # Must be a repo matching https://github.com/acme-corp/payments-*
    repoURL: https://github.com/acme-corp/payments-api
    targetRevision: main      # use a release tag (e.g. v1.2.3) for production stability
    path: deploy/prod         # path within the repo containing the Kubernetes manifests

  destination:
    server: https://kubernetes.default.svc   # in-cluster
    namespace: payments-prod                 # must be payments-prod or payments-staging

  syncPolicy:
    automated:
      prune: true       # remove resources that are no longer in git
      selfHeal: true    # revert any manual kubectl changes
    syncOptions:
      - CreateNamespace=true          # ArgoCD will create the namespace (allowed by clusterResourceWhitelist)
      - ServerSideApply=true          # recommended — handles CRD-heavy workloads and field ownership correctly
      - PrunePropagationPolicy=foreground
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### Staging variant

```yaml
# File: clusters/prod/apps/payments/payments-api-staging.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-api-staging
  namespace: argocd
  labels:
    team: payments
    environment: staging
spec:
  project: payments

  source:
    repoURL: https://github.com/acme-corp/payments-api
    targetRevision: develop     # track develop branch for staging
    path: deploy/staging

  destination:
    server: https://kubernetes.default.svc
    namespace: payments-staging

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

## Repository Credential Secret (if repos are private)

If `https://github.com/acme-corp/payments-*` repos are private, add a credential template. This single secret covers all repos matching the org prefix.

```yaml
# File: clusters/prod/argocd/secrets/payments-repo-creds.yaml
# NOTE: Do NOT commit raw credentials to git. Use External Secrets Operator or Sealed Secrets.
apiVersion: v1
kind: Secret
metadata:
  name: acme-corp-payments-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds   # credential template — matches all repos under this prefix
stringData:
  type: git
  url: https://github.com/acme-corp                   # prefix match — covers all acme-corp repos
  username: argocd-bot                                 # GitHub service account username
  password: ghp_XXXXXXXXXXXX                           # REPLACE: store in vault/external-secrets
```

> **Security note:** The `password` field must not be committed in plaintext. Use [External Secrets Operator](https://external-secrets.io) to pull this from Vault, AWS Secrets Manager, or GCP Secret Manager, or use [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) to encrypt the secret before committing.

---

## Global RBAC Additions (argocd-rbac-cm)

To wire the project-level groups into the global RBAC system, patch `argocd-rbac-cm`:

```yaml
# File: clusters/prod/argocd/argocd-rbac-cm-patch.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly   # unauthenticated/default = read-only

  policy.csv: |
    # payments team lead — admin on the payments project
    g, acme-corp:payments-leads, proj:payments:payments-admin

    # payments developers — sync + get on the payments project
    g, acme-corp:payments-developers, proj:payments:payments-developer

  scopes: '[groups, email]'
```

---

## What the Payments Team Can and Cannot Do

### Permitted actions

| Role | Action | Scope |
|---|---|---|
| payments-admin | View, create, update, delete Applications | payments project only |
| payments-admin | Trigger syncs | payments project only |
| payments-admin | Override sync parameters | payments project only |
| payments-admin | View pod logs | payments-prod, payments-staging |
| payments-admin | Exec into pods (if enabled globally) | payments-prod, payments-staging |
| payments-developer | View Application status and resources | payments project only |
| payments-developer | Trigger syncs | payments project only |
| payments-developer | View pod logs | payments-prod, payments-staging |

### Kubernetes resources the team can deploy

| Resource | API Group | Scope |
|---|---|---|
| Deployment | apps | Namespace-scoped |
| Service | core (`""`) | Namespace-scoped |
| ConfigMap | core (`""`) | Namespace-scoped |
| HorizontalPodAutoscaler | autoscaling | Namespace-scoped |
| Namespace | core (`""`) | Cluster-scoped (creation only) |

### What is explicitly blocked

- **Deploying to any namespace other than `payments-prod` or `payments-staging`** — ArgoCD will reject Applications with any other destination namespace.
- **Deploying from repos outside `https://github.com/acme-corp/payments-*`** — the source repo wildcard enforces this. Any third-party chart or repo requires a platform team change.
- **Creating cluster-scoped resources other than Namespaces** — no ClusterRoles, ClusterRoleBindings, CRDs, PersistentVolumes, StorageClasses, etc.
- **Creating namespace-scoped resources beyond the whitelist** — no StatefulSets, DaemonSets, Jobs, CronJobs, Secrets, ServiceAccounts, Roles, RoleBindings, Ingresses, NetworkPolicies, PersistentVolumeClaims, etc. Any new resource kinds require a platform team AppProject update.
- **payments-developer creating or deleting Applications** — developers can sync existing Applications but cannot create new ArgoCD Application objects or delete existing ones.
- **Accessing other projects** — the payments team has no visibility or access into any other AppProject.
- **Managing global ArgoCD configuration** — no access to repositories, clusters, certificates, or accounts at the global level.

### How developers interact day-to-day

1. **Deploying a change:** Merge to the target branch in the relevant `acme-corp/payments-*` repo. If auto-sync is enabled (recommended), ArgoCD will sync within the reconciliation window (~3 minutes). To force an immediate sync, use the ArgoCD UI or CLI:
   ```bash
   argocd app sync payments-api --project payments
   ```

2. **Checking sync status:**
   ```bash
   argocd app get payments-api --project payments
   argocd app list --project payments
   ```

3. **Viewing application logs:**
   ```bash
   argocd app logs payments-api --project payments
   ```

4. **Checking what changed during a sync:**
   ```bash
   argocd app history payments-api --project payments
   argocd app diff payments-api --project payments
   ```

5. **Rolling back (admin only):**
   ```bash
   argocd app rollback payments-api <history-id>
   ```

6. **Adding a new service:** The payments-admin creates a new Application YAML in the GitOps repo using the template above, then merges it. ArgoCD picks it up automatically.

7. **Adding a new resource kind:** Requires the platform team to update the `namespaceResourceWhitelist` in the AppProject — the payments team cannot self-service this.

---

## Key Notes and Caveats

### Finalizer behaviour
The `resources-finalizer.argocd.argoproj.io` finalizer on the AppProject means: if any Applications still exist in this project, ArgoCD will **block deletion** of the AppProject itself. This prevents accidental orphaning of live workloads. To delete the project, all Applications must be removed first.

### CreateNamespace=true requires the Namespace whitelist
The `clusterResourceWhitelist` entry for `Namespace` is required for `CreateNamespace=true` in syncOptions to work. Without it, ArgoCD will fail to create the namespace and the sync will error. The payments team namespaces (`payments-prod`, `payments-staging`) must either already exist or be created via this mechanism.

### namespaceResourceWhitelist vs namespaceResourceBlacklist
This AppProject uses a **whitelist** (`namespaceResourceWhitelist`), which means only the listed resources are permitted — everything else is implicitly denied. This is more secure than a blacklist approach and is the recommended pattern for team-scoped projects.

Note: `namespaceResourceWhitelist` and `namespaceResourceBlacklist` are mutually exclusive per project. Do not add both.

### HorizontalPodAutoscaler API group
HPAs exist in multiple API versions. The whitelist entry `group: "autoscaling"` covers `autoscaling/v1`, `autoscaling/v2beta1`, `autoscaling/v2beta2`, and `autoscaling/v2` — all variants are permitted.

### Secrets are not in the whitelist — intentional
The payments team cannot deploy Kubernetes Secrets directly via ArgoCD. This is intentional: secrets should be injected via an external secrets manager (e.g., External Secrets Operator pulling from Vault). If the team needs to manage Secrets through ArgoCD, the platform team must explicitly add `kind: Secret` to the whitelist after reviewing the security implications.

### Syncing without auto-sync
If a developer triggers a manual sync, ArgoCD enforces that the sync only affects resources within the permitted kinds and namespaces. Attempting to sync an application that references a blocked resource kind will result in a sync error — the offending manifest must be removed before the sync can succeed.
