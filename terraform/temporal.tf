resource "authentik_provider_oauth2" "temporal" {
  name          = "Temporal"
  client_id     = "temporal"
  client_secret = var.temporal_client_secret

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
      url           = "http://temporal.demo:32170/oauth2/callback"
    }
  ]

  sub_mode               = "hashed_user_id"
  access_token_validity  = "hours=1"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "temporal" {
  name              = "Temporal"
  slug              = "temporal"
  protocol_provider = authentik_provider_oauth2.temporal.id
  meta_launch_url   = "http://temporal.demo:32170"
  open_in_new_tab   = true
}
