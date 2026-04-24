# email_verified must be True so Grafana v11 uses email-based user lookup.
resource "authentik_property_mapping_provider_scope" "email" {
  name       = "OAuth Mapping: Email"
  scope_name = "email"
  expression = "return {\"email\": request.user.email, \"email_verified\": True}"
}

resource "authentik_property_mapping_provider_scope" "groups" {
  name       = "OAuth Mapping: Groups"
  scope_name = "groups"
  expression = "return {\"groups\": [group.name for group in request.user.ak_groups.all()]}"
}
