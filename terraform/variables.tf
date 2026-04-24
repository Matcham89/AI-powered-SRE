variable "authentik_url" {
  description = "Authentik API base URL. Port-forward first: kubectl port-forward -n authentik svc/authentik-server 9000:80"
  type        = string
  default     = "http://localhost:9000"
}

variable "authentik_token" {
  description = "Authentik API token — AUTHENTIK_BOOTSTRAP_TOKEN in platform/auth/authentik-secret.enc.yaml"
  type        = string
  sensitive   = true
}

variable "grafana_client_secret" {
  description = "OIDC client secret for Grafana. Must match the value in platform/observability/grafana-oidc-secret.enc.yaml"
  type        = string
  sensitive   = true
}

variable "temporal_client_secret" {
  description = "OIDC client secret for Temporal oauth2-proxy. Must match apps/temporal/oauth2-proxy-secret.enc.yaml"
  type        = string
  sensitive   = true
}

variable "argocd_client_secret" {
  description = "OIDC client secret for ArgoCD. Must match the value patched into argocd-secret."
  type        = string
  sensitive   = true
}

variable "admin_password" {
  description = "Password for the demo-user account in Authentik"
  type        = string
  sensitive   = true
}
