# ArgoCD OIDC SSO with Okta — Production-Ready Setup

## Overview

This guide covers configuring ArgoCD to authenticate via Okta using OIDC, mapping Okta groups to ArgoCD RBAC roles, and hardening the setup by disabling the built-in admin account after SSO is verified.

**Okta Groups:**
- `okta-platform-admins` → ArgoCD admin (full access)
- `okta-dev-team-frontend` → developer role (sync/get in their project only)
- `okta-dev-team-backend` → developer role (sync/get in their project only)
- Everyone else → read-only (default)

---

## Step 1 — Okta Application Configuration

Before applying any Kubernetes manifests, configure Okta:

1. In Okta Admin Console, go to **Applications → Create App Integration**
2. Choose **OIDC - OpenID Connect** → **Web Application**
3. Configure the app:
   - **App name:** ArgoCD
   - **Sign-in redirect URIs:** `https://<your-argocd-hostname>/auth/callback`
   - **Sign-out redirect URIs:** `https://<your-argocd-hostname>`
   - **Assignments:** Assign the three groups (`okta-platform-admins`, `okta-dev-team-frontend`, `okta-dev-team-backend`) to the app
4. In the app's **Sign On** tab → **OpenID Connect ID Token** section, add a **Groups claim**:
   - **Claim name:** `groups`
   - **Claim type:** ID Token (and optionally Access Token)
   - **Filter:** `Matches regex` → `.*` (or restrict to specific group prefix for security, e.g., `okta-.*`)
5. Note the **Client ID** and **Client Secret** from the app's General tab
6. Note your Okta domain (e.g., `https://your-org.okta.com`)

> **Important:** The groups claim must be present in the ID token. Without it, ArgoCD cannot map group memberships to RBAC roles.

---

## Step 2 — argocd-secret (Client Credentials)

Store the Okta client ID and client secret in the ArgoCD secret. Values must be base64-encoded.

```bash
# Encode your values first:
echo -n 'your-okta-client-id' | base64
echo -n 'your-okta-client-secret' | base64
```

```yaml
# argocd-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-secret
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-secret
    app.kubernetes.io/part-of: argocd
type: Opaque
data:
  # Replace these with your actual base64-encoded values
  oidc.okta.clientSecret: <base64-encoded-client-secret>

  # The following fields are required by ArgoCD — keep existing values or generate new ones
  # admin.password and admin.passwordMtime are managed separately (see Step 5)
  # server.secretkey should already exist — do not overwrite unless rotating
  server.secretkey: <base64-encoded-server-secret-key>
stringData:
  # Using stringData for clientId avoids manual base64 encoding
  oidc.okta.clientId: "your-okta-client-id"
```

> **Note:** In production, manage this secret via Sealed Secrets, External Secrets Operator, or a Vault integration — never commit raw client secrets to Git.

---

## Step 3 — argocd-cm ConfigMap (OIDC Configuration)

```yaml
# argocd-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-cm
    app.kubernetes.io/part-of: argocd
data:
  # The externally-accessible URL of your ArgoCD instance
  url: "https://argocd.example.com"

  # OIDC configuration for Okta
  oidc.config: |
    name: Okta
    issuer: https://your-org.okta.com
    clientID: $oidc.okta.clientId
    clientSecret: $oidc.okta.clientSecret
    requestedScopes:
      - openid
      - profile
      - email
      - groups
    requestedIDTokenClaims:
      groups:
        essential: true
    # The claim in the token that contains group membership
    # This must match the claim name configured in Okta
    groupsClaim: groups

  # Optionally restrict login to users within your Okta org
  # oidc.tls.insecure.skip.verify: "false"  # Default is false — keep TLS verification on

  # (Optional) Disable local user login entirely once SSO is confirmed
  # users.anonymous.enabled: "false"
```

**Key fields explained:**
- `issuer`: Your Okta org's base URL — ArgoCD fetches the OIDC discovery document from `<issuer>/.well-known/openid-configuration`
- `clientID` / `clientSecret`: Reference the keys stored in `argocd-secret` using the `$` prefix syntax — ArgoCD resolves these at runtime
- `requestedScopes`: The `groups` scope must be requested for Okta to include group memberships
- `groupsClaim`: Tells ArgoCD which token claim to parse for group names — must match the claim name set in the Okta app's token configuration

---

## Step 4 — argocd-rbac-cm ConfigMap (RBAC Policy)

```yaml
# argocd-rbac-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-rbac-cm
    app.kubernetes.io/part-of: argocd
data:
  # Default role for any authenticated user not matched by a group binding
  policy.default: role:readonly

  policy.csv: |
    # -------------------------------------------------------------------------
    # Platform Admin Role — full access to everything
    # -------------------------------------------------------------------------
    p, role:platform-admin, applications, *, */*, allow
    p, role:platform-admin, clusters, *, *, allow
    p, role:platform-admin, repositories, *, *, allow
    p, role:platform-admin, projects, *, *, allow
    p, role:platform-admin, accounts, *, *, allow
    p, role:platform-admin, gpgkeys, *, *, allow
    p, role:platform-admin, logs, get, *, allow
    p, role:platform-admin, exec, create, */*, allow

    # -------------------------------------------------------------------------
    # Developer Role — sync and get apps in their own project only
    # The project name in ArgoCD must match the group-to-project mapping below.
    # Adjust project names to match your ArgoCD AppProject names.
    # -------------------------------------------------------------------------

    # Frontend developers: get and sync in the "frontend" AppProject
    p, role:dev-frontend, applications, get, frontend/*, allow
    p, role:dev-frontend, applications, sync, frontend/*, allow
    p, role:dev-frontend, logs, get, frontend/*, allow

    # Backend developers: get and sync in the "backend" AppProject
    p, role:dev-backend, applications, get, backend/*, allow
    p, role:dev-backend, applications, sync, backend/*, allow
    p, role:dev-backend, logs, get, backend/*, allow

    # -------------------------------------------------------------------------
    # Group bindings — map Okta groups to ArgoCD roles
    # Format: g, <group-name>, <role>
    # -------------------------------------------------------------------------
    g, okta-platform-admins, role:platform-admin
    g, okta-dev-team-frontend, role:dev-frontend
    g, okta-dev-team-backend, role:dev-backend

  # Use 'sub' claim matching — 'email' is also valid if preferred
  # 'groups' is resolved automatically from the groupsClaim in argocd-cm
  scopes: "[groups, email]"
```

**RBAC design decisions:**
- `policy.default: role:readonly` ensures any authenticated user who is not in a mapped Okta group gets read-only access — no anonymous access, no accidental privilege escalation
- The developer roles are intentionally scoped to `get` and `sync` only — they cannot create, delete, or update application definitions, preventing config drift from outside GitOps workflows
- `logs` access is included for developers so they can debug their own app pods without needing admin help
- `exec` (pod exec) is restricted to platform admins only

---

## Step 5 — Apply the Manifests

```bash
# Apply in this order to avoid dependency issues
kubectl apply -f argocd-secret.yaml -n argocd
kubectl apply -f argocd-cm.yaml -n argocd
kubectl apply -f argocd-rbac-cm.yaml -n argocd

# Restart the ArgoCD server to pick up the OIDC configuration
kubectl rollout restart deployment argocd-server -n argocd

# Watch the rollout complete
kubectl rollout status deployment argocd-server -n argocd
```

---

## Step 6 — Verify SSO Before Disabling Admin

1. Open your ArgoCD UI at `https://argocd.example.com`
2. Confirm the **Log in via Okta** button appears on the login page
3. Authenticate with a user from each Okta group
4. Verify the correct access level for each:
   - `okta-platform-admins` member: can see all apps, clusters, repositories, and settings
   - `okta-dev-team-frontend` member: can only see and sync apps in the `frontend` project
   - `okta-dev-team-backend` member: can only see and sync apps in the `backend` project
   - User not in any group: read-only access only
5. Check ArgoCD logs if something is wrong:
   ```bash
   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=100 | grep -i oidc
   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=100 | grep -i groups
   ```

---

## Step 7 — Disable the Built-in Admin User

Once SSO is confirmed working and at least one platform admin can log in via Okta:

**Option A — Disable via argocd-cm (recommended):**

```yaml
# Add to the argocd-cm data section:
data:
  # ... existing config ...
  accounts.admin.enabled: "false"
```

Apply the change:
```bash
kubectl patch configmap argocd-cm -n argocd \
  --type merge \
  -p '{"data":{"accounts.admin.enabled":"false"}}'

kubectl rollout restart deployment argocd-server -n argocd
```

**Option B — Using the ArgoCD CLI:**

```bash
# Log in with admin first
argocd login argocd.example.com --username admin --password <current-admin-password>

# Disable the admin account
argocd account update-password --account admin --new-password ""
# Or patch the configmap as shown above — CLI approach varies by ArgoCD version
```

> **Recommendation:** Use Option A (configmap patch). It is declarative, GitOps-compatible, and survives pod restarts. Ensure your change is committed to your GitOps repo so it is not overwritten on the next sync.

**After disabling admin, verify:**
```bash
# Attempt admin login — this should fail
argocd login argocd.example.com --username admin --password <old-password>
# Expected: "Invalid username or password"
```

---

## AppProject Configuration (Required for Developer RBAC to Work)

The developer RBAC rules reference `frontend` and `backend` AppProjects. These must exist in ArgoCD. Example:

```yaml
# appproject-frontend.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: frontend
  namespace: argocd
spec:
  description: Frontend team applications
  sourceRepos:
    - 'https://github.com/your-org/frontend-*'
  destinations:
    - namespace: 'frontend-*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
  roles:
    - name: developer
      description: Frontend developer access
      policies:
        - p, proj:frontend:developer, applications, get, frontend/*, allow
        - p, proj:frontend:developer, applications, sync, frontend/*, allow
      groups:
        - okta-dev-team-frontend
```

```yaml
# appproject-backend.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: backend
  namespace: argocd
spec:
  description: Backend team applications
  sourceRepos:
    - 'https://github.com/your-org/backend-*'
  destinations:
    - namespace: 'backend-*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
  roles:
    - name: developer
      description: Backend developer access
      policies:
        - p, proj:backend:developer, applications, get, backend/*, allow
        - p, proj:backend:developer, applications, sync, backend/*, allow
      groups:
        - okta-dev-team-backend
```

---

## Troubleshooting Common Issues

### Groups not showing up / users getting wrong role

**Cause:** The `groups` claim is missing from the Okta ID token.

**Fix:**
1. In Okta, go to the ArgoCD app → **Sign On** tab → **Edit** the OpenID Connect ID Token section
2. Add a Groups claim with filter `Matches regex` → `.*`
3. Use the Okta Token Preview feature to confirm the claim is present before redeploying
4. Ensure `requestedScopes` in `argocd-cm` includes `groups`

### Login redirects back to ArgoCD login page with no error

**Cause:** Usually a mismatched redirect URI.

**Fix:** Ensure the `Sign-in redirect URI` in Okta exactly matches `https://<your-argocd-hostname>/auth/callback` — no trailing slash, correct scheme.

### `oidc: failed to get provider` in ArgoCD logs

**Cause:** ArgoCD cannot reach the Okta issuer endpoint (network policy, DNS, or wrong issuer URL).

**Fix:** Verify the issuer URL resolves from within the cluster:
```bash
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n argocd -- \
  curl -v https://your-org.okta.com/.well-known/openid-configuration
```

### clientSecret not resolving

**Cause:** The `$oidc.okta.clientSecret` reference in `argocd-cm` requires the key to exist in `argocd-secret` with exactly that name.

**Fix:** Confirm the secret key name matches:
```bash
kubectl get secret argocd-secret -n argocd -o jsonpath='{.data}' | jq 'keys'
# Should include: "oidc.okta.clientId" and "oidc.okta.clientSecret"
```

---

## Security Hardening Notes

1. **Rotate the client secret regularly** — treat it like a password; store it in a secrets manager and reference it via External Secrets Operator rather than hard-coding in the Secret manifest
2. **Restrict the Okta app assignment** — only assign the three groups to the Okta app; do not assign to all users
3. **Enable Okta MFA** on the ArgoCD app for the platform-admins group at minimum
4. **Audit logs** — ArgoCD writes audit events to its logs; forward them to your SIEM. Key events: `login`, `sync`, `delete`
5. **TLS** — ensure ArgoCD is running with a valid TLS certificate; never set `oidc.tls.insecure.skip.verify: "true"` in production
6. **Token expiry** — Okta tokens default to 1 hour; this is fine for ArgoCD. Adjust in Okta's app settings if sessions need to be shorter for compliance reasons
7. **Avoid `policy.default: role:admin`** — the config above uses `role:readonly` as the safe default; this is intentional

---

## Summary of Files

| File | Purpose |
|---|---|
| `argocd-secret.yaml` | Okta client ID and secret |
| `argocd-cm.yaml` | OIDC provider config pointing to Okta |
| `argocd-rbac-cm.yaml` | Role definitions and group-to-role bindings |
| `appproject-frontend.yaml` | AppProject scoping frontend team access |
| `appproject-backend.yaml` | AppProject scoping backend team access |

Apply in the order listed. Restart `argocd-server` after applying `argocd-cm` and `argocd-rbac-cm`. Verify SSO works before disabling the admin account.
