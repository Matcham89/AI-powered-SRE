# ArgoCD AppProject: payments

Production-ready AppProject configuration for the payments team, including RBAC roles, resource restrictions, and a sample Application template.

---

## AppProject YAML

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: payments
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: "AppProject for the payments team. Restricts deployments to payments-prod and payments-staging namespaces."

  # Restrict source repositories to the acme-corp/payments-* pattern
  sourceRepos:
    - "https://github.com/acme-corp/payments-*"

  # Restrict deployments to specific namespaces on the in-cluster server
  destinations:
    - server: https://kubernetes.default.svc
      namespace: payments-prod
    - server: https://kubernetes.default.svc
      namespace: payments-staging

  # Allow only Namespace at the cluster (non-namespaced) resource level
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace

  # Allow only the specified namespaced resource types
  namespaceResourceWhitelist:
    - group: "apps"
      kind: Deployment
    - group: ""
      kind: Service
    - group: ""
      kind: ConfigMap
    - group: "autoscaling"
      kind: HorizontalPodAutoscaler

  # Project-level RBAC roles
  roles:
    - name: payments-admin
      description: "Full administrative access to the payments project. Assigned to the payments team lead."
      policies:
        - p, proj:payments:payments-admin, applications, *, payments/*, allow
        - p, proj:payments:payments-admin, repositories, *, payments/*, allow
      groups:
        - payments-team-leads   # Map to your SSO/OIDC group name

    - name: payments-developer
      description: "Read and sync access for payments developers. Cannot create or delete applications."
      policies:
        - p, proj:payments:payments-developer, applications, get, payments/*, allow
        - p, proj:payments:payments-developer, applications, sync, payments/*, allow
      groups:
        - payments-developers   # Map to your SSO/OIDC group name
```

---

## Sample Application YAML (Template for the Payments Team)

Use this as a starting template when onboarding a new payments service. Replace the placeholder values as indicated.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payments-api          # Replace with your service name, e.g. payments-gateway
  namespace: argocd
  labels:
    team: payments
    environment: staging      # Change to 'prod' for production
  # Optional: add a finalizer to prevent accidental deletion of the Application
  # and ensure ArgoCD deletes the deployed resources before removing the Application.
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: payments           # Must always be 'payments' for this team

  source:
    # Must match the sourceRepos whitelist: https://github.com/acme-corp/payments-*
    repoURL: https://github.com/acme-corp/payments-api
    targetRevision: main      # Branch, tag, or commit SHA
    path: helm/payments-api   # Path within the repo to the Helm chart or manifests

    # If using Helm:
    helm:
      valueFiles:
        - values-staging.yaml  # Use values-prod.yaml for production

  destination:
    server: https://kubernetes.default.svc
    # Must be one of: payments-staging, payments-prod
    namespace: payments-staging

  syncPolicy:
    automated:
      prune: true             # Delete resources removed from Git
      selfHeal: true          # Revert out-of-band changes automatically
    syncOptions:
      - CreateNamespace=true  # Allowed because Namespace is in clusterResourceWhitelist
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m

  # Optionally override values directly (useful for environment-specific config)
  # source.helm.parameters:
  #   - name: image.tag
  #     value: "1.4.2"
```

---

## How the Payments Team Interacts with This Project

### What the payments-admin role can do

The team lead (mapped to the `payments-team-leads` SSO group) has full control within the project boundary:

- Create, update, and delete ArgoCD Applications inside the `payments` project
- Trigger syncs, rollbacks, and hard refreshes on any application
- Manage project-level repository connections (within the `payments-*` wildcard)
- View all application logs, events, and resource trees
- Modify sync policies and application settings

**Cannot do:**

- Deploy to any namespace other than `payments-prod` or `payments-staging`
- Use source repositories outside `https://github.com/acme-corp/payments-*`
- Deploy cluster-scoped resources other than `Namespace`
- Deploy namespaced resource types outside the whitelist (e.g., no StatefulSets, DaemonSets, Secrets, Ingresses, NetworkPolicies, ServiceAccounts, or Roles)
- Access or modify other ArgoCD projects

### What the payments-developer role can do

Developers (mapped to the `payments-developers` SSO group) have a read-and-sync scope:

- View all Applications in the `payments` project (status, health, diff, logs)
- Manually trigger a sync on any application in the project
- Inspect resource trees, events, and sync history

**Cannot do:**

- Create, update, or delete Applications
- Change sync policies or application configuration
- Access repositories or cluster credentials directly
- Perform rollbacks (requires `update` action, not granted)
- Access any other project

---

## Integration Notes

### Mapping SSO groups to project roles

The `groups` field in the AppProject roles binds your identity provider groups to project roles. This works in conjunction with `argocd-rbac-cm`. Ensure your OIDC/Dex configuration exports group claims and that the group names (`payments-team-leads`, `payments-developers`) match exactly.

If you are not using SSO groups, you can bind individual ArgoCD users instead by adding explicit policy lines in `argocd-rbac-cm`:

```yaml
# In argocd-rbac-cm ConfigMap
data:
  policy.csv: |
    g, alice@acme-corp.com, role:proj:payments:payments-admin
    g, bob@acme-corp.com, role:proj:payments:payments-developer
```

### Finalizer behaviour

The `resources-finalizer.argocd.argoproj.io` finalizer on the AppProject prevents the project from being deleted while Applications still belong to it. ArgoCD will block deletion until all child Applications are removed first. This protects against accidental `kubectl delete appproject payments` wiping live workloads.

### Resource whitelists are additive-deny by default

ArgoCD AppProjects use a whitelist model — if a resource kind is not listed, it is implicitly denied. This means:

- A developer cannot slip in a `Secret`, `Ingress`, `NetworkPolicy`, `ServiceAccount`, `Role`, or `RoleBinding` even if they have write access to the Git repo
- ArgoCD will refuse to sync any manifest containing a non-whitelisted resource and will report a sync error without touching the cluster

### Namespace creation

Because `Namespace` is listed in `clusterResourceWhitelist`, ArgoCD can create the `payments-prod` and `payments-staging` namespaces automatically on first sync (when `CreateNamespace=true` is set in the Application's `syncOptions`). Without this, the namespaces would need to exist on the cluster before any Application targeting them can sync successfully.

### Extending the whitelist later

If the team needs additional resource types (e.g., `PodDisruptionBudget`, `Ingress`), a platform engineer with ArgoCD admin access should update the `namespaceResourceWhitelist` in the AppProject. Payments team members cannot self-serve this change — it requires editing the AppProject YAML directly.
