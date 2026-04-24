# ArgoCD v3.3.8 — argocd-cm ConfigMap Reference

All keys go in the `data` section of the `argocd-cm` ConfigMap in the `argocd` namespace.

## Full Production Template

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
  # --- Core ---
  url: https://argocd.YOURDOMAIN.com         # required for SSO and notifications
  admin.enabled: "true"                        # set "false" after SSO is working

  # --- User sessions ---
  users.session.duration: 24h                 # JWT expiry; shorter = more secure
  users.anonymous.enabled: "false"            # never enable in production

  # --- Resource watch optimisation ---
  resource.exclusions: |
    - apiGroups:
      - "events.k8s.io"
      - "metrics.k8s.io"
      kinds:
      - "*"
      clusters:
      - "*"

  # --- Reconciliation ---
  timeout.reconciliation: 180s               # how often to pull from git (default 120s)
  timeout.reconciliation.jitter: 30s         # spread requeues to avoid thundering herd

  # --- Repository server memory protection ---
  reposerver.max.combined.directory.manifests.size: 10M

  # --- Application tracking ---
  application.resourceTrackingMethod: annotation  # annotation|label; annotation is more reliable

  # --- Exec (terminal access) ---
  exec.enabled: "false"                       # only enable if needed; security risk
```

---

## Key Options Reference

### Core identity
| Key | Default | Notes |
|-----|---------|-------|
| `url` | — | External base URL; required for SSO callback |
| `admin.enabled` | `"true"` | Disable after SSO setup |
| `installationID` | — | Unique ID for multi-instance support |

### Authentication
| Key | Default | Notes |
|-----|---------|-------|
| `dex.config` | — | Dex OAuth connectors (GitHub, Google, etc.) |
| `oidc.config` | — | External OIDC provider (Okta, Keycloak, etc.) |
| `users.session.duration` | `24h` | JWT token lifetime |
| `users.anonymous.enabled` | `"false"` | Allow unauthenticated UI access — never for prod |
| `oidc.tls.insecure.skip.verify` | `"false"` | Skip OIDC TLS cert verification — security risk |

### Resource management
| Key | Default | Notes |
|-----|---------|-------|
| `resource.exclusions` | — | Resources to exclude from watch (reduces API server load) |
| `resource.inclusions` | — | Allowlist; if set, only these resource types are watched |
| `resource.customizations.health.<group/Kind>` | — | Lua script for custom health checks |
| `resource.customizations.ignoreDifferences.<group/Kind>` | — | Fields to ignore in diff |
| `resource.customizations.actions.<group/Kind>` | — | Custom sync actions via Lua |
| `resource.ignoreResourceUpdatesEnabled` | `"false"` | Apply ignore rules to cache updates |

### Reconciliation
| Key | Default | Notes |
|-----|---------|-------|
| `timeout.reconciliation` | `180s` | Git poll interval; lower = more API calls |
| `timeout.reconciliation.jitter` | `60s` | Random spread on requeue |
| `application.resourceTrackingMethod` | `label` | `annotation` recommended for large clusters |
| `application.instanceLabelKey` | `app.kubernetes.io/instance` | Label key for resource tracking |

### Tool configuration
| Key | Default | Notes |
|-----|---------|-------|
| `kustomize.enable` | `"true"` | Disable to prevent Kustomize use |
| `helm.enable` | `"true"` | Disable to prevent Helm use |
| `helm.valuesFileSchemes` | `https,http` | Allowed schemes for remote value files |

### UI
| Key | Default | Notes |
|-----|---------|-------|
| `ui.bannercontent` | — | Top-of-page message (useful for environment labels) |
| `ui.bannerurl` | — | Banner link |
| `ui.bannerpermanent` | `"false"` | Make banner non-dismissible |
| `exec.enabled` | `"false"` | Enable terminal access in UI |
| `exec.shells` | `bash,sh,powershell,cmd` | Allowed shell types |

### Server behaviour
| Key | Default | Notes |
|-----|---------|-------|
| `server.maxPodLogsToRender` | `10` | Max pods shown in log view |
| `cluster.inClusterEnabled` | `"true"` | Allow `https://kubernetes.default.svc` as destination |
| `webhook.maxPayloadSizeMB` | `50` | Max webhook payload size |

---

## Custom Health Checks (Lua)

ArgoCD uses Lua scripts for custom health assessment. Add them per resource type:

```yaml
data:
  resource.customizations.health.networking.k8s.io_Ingress: |
    hs = {}
    if obj.status ~= nil then
      if obj.status.loadBalancer ~= nil then
        if obj.status.loadBalancer.ingress ~= nil then
          hs.status = "Healthy"
          hs.message = "Ingress is healthy"
          return hs
        end
      end
    end
    hs.status = "Progressing"
    hs.message = "Waiting for Ingress to get an IP"
    return hs
```

---

## ignoreDifferences (reduce noise)

Suppress diffs on fields managed by operators or admission webhooks:

```yaml
data:
  resource.customizations.ignoreDifferences.apps_Deployment: |
    jsonPointers:
      - /spec/replicas            # HPA manages this
      - /metadata/annotations/deployment.kubernetes.io~1revision

  resource.customizations.ignoreDifferences.admissionregistration.k8s.io_MutatingWebhookConfiguration: |
    jsonPointers:
      - /webhooks/0/clientConfig/caBundle   # cert-manager manages this
```

---

## SSO Quick Configs

### GitHub OAuth via Dex
```yaml
data:
  dex.config: |
    connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: $dex.github.clientID
          clientSecret: $dex.github.clientSecret
          orgs:
            - name: MY-GITHUB-ORG
```

### Google OAuth via Dex
```yaml
data:
  dex.config: |
    connectors:
      - type: google
        id: google
        name: Google
        config:
          clientID: $dex.google.clientID
          clientSecret: $dex.google.clientSecret
          serviceAccountFilePath: /tmp/dex/sa.json
          adminEmail: admin@MY-DOMAIN.com
```

### Okta (direct OIDC, no Dex)
```yaml
data:
  oidc.config: |
    name: Okta
    issuer: https://MY-ORG.okta.com
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
