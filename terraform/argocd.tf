resource "authentik_provider_oauth2" "argocd" {
  name          = "ArgoCD"
  client_id     = "argocd"
  client_secret = var.argocd_client_secret

  authorization_flow = data.authentik_flow.authorization.id
  invalidation_flow  = data.authentik_flow.invalidation.id
  signing_key        = data.authentik_certificate_key_pair.default.id

  property_mappings = concat(
    data.authentik_property_mapping_provider_scope.oauth2.ids,
    [
      authentik_property_mapping_provider_scope.email.id,
      authentik_property_mapping_provider_scope.groups.id,
    ]
  )

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "http://argocd.local:32170/auth/callback"
    }
  ]

  sub_mode               = "hashed_user_id"
  access_token_validity  = "hours=1"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "argocd" {
  name              = "ArgoCD"
  slug              = "argocd"
  protocol_provider = authentik_provider_oauth2.argocd.id
  meta_launch_url   = "http://argocd.local:32170"
  open_in_new_tab   = true
}
