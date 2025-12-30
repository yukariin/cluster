resource "authentik_provider_oauth2" "oauth2_providers" {
  for_each              = var.oauth2_applications
  name                  = each.key
  access_token_validity = "hours=1"
  client_id             = each.value.client_id
  client_type           = each.value.client_type
  client_secret         = sensitive(each.value.client_secret)
  authorization_flow     = data.authentik_flow.default-authorization-flow.id
  invalidation_flow      = data.authentik_flow.default-invalidation-flow.id
  authentication_flow    = data.authentik_flow.default-authorization-flow.id
  allowed_redirect_uris = each.value.redirect_uris
  signing_key           = data.authentik_certificate_key_pair.default-certificate.id
  property_mappings     = data.authentik_property_mapping_provider_scope.oauth2-scopes.ids
}

resource "authentik_application" "oauth2_apps" {
  for_each          = authentik_provider_oauth2.oauth2_providers
  name              = each.value.name
  slug              = replace(replace(lower(each.value.name), " ", "-"), "[^a-z0-9-]", "")
  group             = var.oauth2_applications[each.key].group
  meta_launch_url   = var.oauth2_applications[each.key].url
  protocol_provider = each.value.id
}
