# ArgoCD OIDC SSO with Okta — Production Configuration

## Overview

This guide covers setting up Okta as the OIDC provider for ArgoCD, with three distinct access tiers:

| Okta Group | ArgoCD Role | Access Level |
|---|---|---|
| `okta-platform-admins` | `role:platform-admin` | Full admin access to all resources |
| `okta-dev-team-frontend` | `role:developer-frontend` | Sync + get in `frontend` project only |
| `okta-dev-team-backend` | `role:developer-backend` | Sync + get in `backend` project only |
| Everyone else | `role:readonly` | Read-only (default) |

---

## Prerequisites: Okta App Configuration

Before applying the Kubernetes manifests, configure the Okta side:

1. **Create an OIDC Web Application** in Okta Admin Console:
   - Application type: **Web Application**
   - Sign-in redirect URI: `https://argocd.YOURDOMAIN.com/auth/callback`
   - Sign-out redirect URI: `https://argocd.YOURDOMAIN.com`
   - Grant type: **Authorization Code**

2. **Enable Groups claim** in the Okta application:
   - Go to the app's **Sign On** tab → **OpenID Connect ID Token**
   - Add a **Groups claim**:
     - Name: `groups`
     - Filter: **Matches regex** → `.*` (or restrict to specific groups with prefix matching)
   - This ensures the `groups` claim is included in the ID token

3. **Assign the Okta app** to the groups:
   - `okta-platform-admins`
   - `okta-dev-team-frontend`
   - `okta-dev-team-backend`
   - Plus any other groups you want to have read-only access

4. **Note your Okta domain**: it takes the form `https://YOUR-ORG.okta.com` or `https://dev-XXXXXX.okta.com` for developer accounts.

5. **Copy the Client ID and Client Secret** from the Okta app's General tab — you will need these for the Kubernetes Secret below.

---

## File: clusters/prod/argocd/argocd-secret.yaml

> **Security note:** Do NOT commit this file with real values to Git. Use External Secrets Operator, Sealed Secrets, or a secrets manager (Vault, AWS Secrets Manager, GCP Secret Manager) to inject these values at deploy time. The template below uses placeholder values — replace before applying.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-secret
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-secret
    app.kubernetes.io/part-of: argocd
type: Opaque
stringData:
  # Okta OIDC credentials
  # Replace with your actual Okta app Client ID and Client Secret
  oidc.okta.clientID: "YOUR-OKTA-CLIENT-ID"
  oidc.okta.clientSecret: "YOUR-OKTA-CLIENT-SECRET"
```

> If you are using External Secrets Operator, replace the above with an `ExternalSecret` resource that pulls `oidc.okta.clientID` and `oidc.okta.clientSecret` from your secrets store and creates the `argocd-secret` with the same keys.

---

## File: clusters/prod/argocd/argocd-cm.yaml

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
  # External URL — required for OIDC callback redirect
  # Replace with your actual ArgoCD URL
  url: https://argocd.YOURDOMAIN.com

  # Disable admin once SSO is confirmed working (see "Disabling Admin" section below)
  admin.enabled: "true"

  # Okta OIDC configuration (direct OIDC, no Dex required)
  oidc.config: |
    name: Okta
    issuer: https://YOUR-ORG.okta.com
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

  # Session duration — shorter is more secure for production
  users.session.duration: 8h

  # Never allow anonymous access in production
  users.anonymous.enabled: "false"

  # Reduce API server load by excluding noisy resource types
  resource.exclusions: |
    - apiGroups:
      - "events.k8s.io"
      - "metrics.k8s.io"
      kinds:
      - "*"
      clusters:
      - "*"

  # Reconciliation tuning
  timeout.reconciliation: 180s
  timeout.reconciliation.jitter: 30s

  # Repo server memory protection (prevents DoS via large manifests)
  reposerver.max.combined.directory.manifests.size: 10M

  # Use annotation tracking — more reliable on large clusters
  application.resourceTrackingMethod: annotation

  # Disable exec (terminal access) unless required
  exec.enabled: "false"
```

---

## File: clusters/prod/argocd/argocd-rbac-cm.yaml

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
  # Default: all authenticated users are read-only unless explicitly granted more
  policy.default: role:readonly

  # Scopes to extract from the OIDC token for policy evaluation
  # 'groups' must be listed here to enable group-based RBAC
  scopes: '[groups, email]'

  policy.csv: |
    # ---------------------------------------------------------------
    # role:platform-admin — full control over all ArgoCD resources
    # ---------------------------------------------------------------
    p, role:platform-admin, applications,    *, */*, allow
    p, role:platform-admin, applicationsets, *, */*, allow
    p, role:platform-admin, clusters,        *, *, allow
    p, role:platform-admin, repositories,    *, *, allow
    p, role:platform-admin, projects,        *, *, allow
    p, role:platform-admin, accounts,        *, *, allow
    p, role:platform-admin, certificates,    *, *, allow
    p, role:platform-admin, gpgkeys,         *, *, allow
    p, role:platform-admin, exec,            create, */*, allow
    p, role:platform-admin, logs,            get, */*, allow

    # ---------------------------------------------------------------
    # role:developer-frontend — sync and view in 'frontend' project only
    # No create, delete, or update of app definitions
    # ---------------------------------------------------------------
    p, role:developer-frontend, applications, get,      frontend/*, allow
    p, role:developer-frontend, applications, sync,     frontend/*, allow
    p, role:developer-frontend, applications, override, frontend/*, allow
    p, role:developer-frontend, logs,         get,      frontend/*, allow
    p, role:developer-frontend, repositories, get,      *, allow

    # ---------------------------------------------------------------
    # role:developer-backend — sync and view in 'backend' project only
    # No create, delete, or update of app definitions
    # ---------------------------------------------------------------
    p, role:developer-backend, applications, get,      backend/*, allow
    p, role:developer-backend, applications, sync,     backend/*, allow
    p, role:developer-backend, applications, override, backend/*, allow
    p, role:developer-backend, logs,         get,      backend/*, allow
    p, role:developer-backend, repositories, get,      *, allow

    # ---------------------------------------------------------------
    # Okta group → ArgoCD role bindings
    # Group names must exactly match the 'groups' claim values from Okta
    # ---------------------------------------------------------------
    g, okta-platform-admins,    role:platform-admin
    g, okta-dev-team-frontend,  role:developer-frontend
    g, okta-dev-team-backend,   role:developer-backend
```

---

## Applying the Configuration

Apply the resources in this order:

```bash
# 1. Apply the secret first (contains OIDC credentials)
kubectl apply -f clusters/prod/argocd/argocd-secret.yaml

# 2. Apply the ConfigMaps
kubectl apply -f clusters/prod/argocd/argocd-cm.yaml
kubectl apply -f clusters/prod/argocd/argocd-rbac-cm.yaml

# 3. Restart argocd-server to pick up the OIDC config
kubectl rollout restart deployment/argocd-server -n argocd

# 4. Watch the rollout
kubectl -n argocd rollout status deployment/argocd-server
```

---

## Verifying SSO Works

1. Open `https://argocd.YOURDOMAIN.com` in an incognito/private window
2. You should see a **"Log in with Okta"** button alongside the local login form
3. Click it and authenticate with an Okta user who is a member of `okta-platform-admins`
4. Verify you have full admin access in the ArgoCD UI
5. Repeat with a user in `okta-dev-team-frontend` — they should only see and be able to sync apps in the `frontend` project
6. Repeat with a user not in any mapped group — they should see all apps but be unable to make any changes

**Check RBAC is working via CLI:**
```bash
# Get the auth token for a logged-in user
argocd login argocd.YOURDOMAIN.com --sso

# Check what the current user can do
argocd account can-i sync applications 'frontend/*'   # should return 'yes' for frontend devs
argocd account can-i delete applications 'frontend/*' # should return 'no' for frontend devs
argocd account can-i sync applications '*/\*'         # should return 'yes' only for platform-admin
```

---

## Disabling the Admin User After SSO is Confirmed Working

Once SSO is verified and at least one platform admin can log in via Okta, disable the built-in admin account to reduce the attack surface:

**Step 1:** Ensure you have a working Okta account with `role:platform-admin` access before proceeding.

**Step 2:** Patch `argocd-cm` to disable admin:

```bash
kubectl patch configmap argocd-cm -n argocd \
  --type merge \
  -p '{"data": {"admin.enabled": "false"}}'
```

Or update `argocd-cm.yaml` in Git:

```yaml
data:
  admin.enabled: "false"   # Changed from "true"
```

**Step 3:** Delete the initial admin secret if it still exists:

```bash
kubectl delete secret argocd-initial-admin-secret -n argocd 2>/dev/null || echo "Already deleted"
```

**Step 4:** Restart argocd-server:

```bash
kubectl rollout restart deployment/argocd-server -n argocd
```

**Verification:** Attempting to log in with `admin` / any password should now be rejected with a 401.

> **Important:** Keep at least one break-glass mechanism. Options:
> - A local non-admin account with `apiKey,login` capability (e.g., `accounts.break-glass: apiKey,login`) mapped to `role:platform-admin` in RBAC
> - Or re-enable admin temporarily via `kubectl patch` if locked out

---

## Notes on Scopes, Claims, and Okta Configuration

### Groups claim format

The `groups` claim value in the Okta ID token will contain the **Okta group names** (not IDs). The values in `argocd-rbac-cm` must match exactly. For example:

```
# Okta returns:    "groups": ["okta-platform-admins", "Everyone"]
# RBAC must use:   g, okta-platform-admins, role:platform-admin
```

If Okta is returning group IDs instead of names, go to the Okta Admin Console → **API** → **Authorization Servers** → your server → **Claims** and update the groups claim to use **Group name** rather than **Group ID**.

### Required scopes

The `requestedScopes` block in `oidc.config` must include `groups`. Without it, ArgoCD will not receive group membership information and all users will fall through to `role:readonly`.

### `requestedIDTokenClaims`

Setting `groups: essential: true` tells the OIDC provider that the `groups` claim is required. If Okta cannot return it (e.g., the claim is not configured), the login will fail rather than silently granting the default read-only role. This is the safer production behaviour.

### `scopes` in argocd-rbac-cm

The `scopes: '[groups, email]'` field in `argocd-rbac-cm` tells ArgoCD which claims from the ID token to use for policy evaluation. Both `groups` (for group-based RBAC) and `email` (for user-specific policies if needed) should be listed.

### Okta Authorization Server

If you are using a **custom Okta Authorization Server** (not the default `https://YOUR-ORG.okta.com`), your issuer URL will be `https://YOUR-ORG.okta.com/oauth2/YOUR-AUTH-SERVER-ID`. Ensure the groups claim is configured on that specific authorization server, not just the org-level one.

### Token lifetimes

The `users.session.duration: 8h` in `argocd-cm` controls the ArgoCD session JWT, not the Okta token. Consider aligning this with your Okta session policy. Shorter durations (e.g., `4h`) are recommended for production environments with sensitive deployments.

### Developer role scope: separate roles vs. shared role

The configuration above uses two separate developer roles (`role:developer-frontend` and `role:developer-backend`) rather than a single parameterised role. This is intentional:

- ArgoCD's RBAC does not support dynamic role parameters
- Each project-scoped role must be defined separately
- If you add more dev teams/projects, add a corresponding `role:developer-<project>` block and group binding

If you want a simpler model where all developers can sync in all dev projects, you can merge them:

```csv
p, role:developer, applications, get,  frontend/*, allow
p, role:developer, applications, sync, frontend/*, allow
p, role:developer, applications, get,  backend/*, allow
p, role:developer, applications, sync, backend/*, allow
g, okta-dev-team-frontend, role:developer
g, okta-dev-team-backend,  role:developer
```

But keeping them separate follows the principle of least privilege and makes it easier to audit who can touch what.

---

## ArgoCD AppProject Recommendations

To make the RBAC restrictions meaningful, ensure your ArgoCD AppProjects are named `frontend` and `backend` to match the RBAC policy objects:

```yaml
# File: clusters/prod/argocd/projects/frontend.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: frontend
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: Frontend team workloads
  sourceRepos:
    - https://github.com/YOUR-ORG/YOUR-FRONTEND-REPO
  destinations:
    - namespace: frontend
      server: https://kubernetes.default.svc
    - namespace: frontend-staging
      server: https://kubernetes.default.svc
  clusterResourceWhitelist: []   # no cluster-scoped resources for dev teams
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: ''
      kind: LimitRange
```

```yaml
# File: clusters/prod/argocd/projects/backend.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: backend
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: Backend team workloads
  sourceRepos:
    - https://github.com/YOUR-ORG/YOUR-BACKEND-REPO
  destinations:
    - namespace: backend
      server: https://kubernetes.default.svc
    - namespace: backend-staging
      server: https://kubernetes.default.svc
  clusterResourceWhitelist: []
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: ''
      kind: LimitRange
```

The AppProject `spec.roles` field also supports RBAC policies scoped to the project, but the `argocd-rbac-cm` global policy is sufficient and easier to manage for this use case.

---

## Summary Checklist

- [ ] Okta OIDC app created with correct redirect URIs
- [ ] Groups claim configured in Okta to return group names
- [ ] Okta app assigned to all three groups
- [ ] `argocd-secret` applied with Okta client ID and secret
- [ ] `argocd-cm` applied with `oidc.config` block and correct issuer URL
- [ ] `argocd-rbac-cm` applied with `policy.default: role:readonly` and all group bindings
- [ ] ArgoCD server restarted
- [ ] SSO login tested with a user from each Okta group
- [ ] RBAC permissions verified for each role (sync-only for devs, full access for platform admins)
- [ ] Admin user disabled after SSO is confirmed working
- [ ] `argocd-initial-admin-secret` deleted
- [ ] AppProjects `frontend` and `backend` exist with appropriate source/destination restrictions
