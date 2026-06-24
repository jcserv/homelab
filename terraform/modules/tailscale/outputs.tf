# Sensitive: the tailnet auth key value. Read with `tofu output -raw ci_auth_key`.
# Never committed; Infisical storage deferred to Phase 3.
output "ci_auth_key" {
  description = "TF-managed tailnet auth key (sensitive)."
  value       = tailscale_tailnet_key.ci.key
  sensitive   = true
}
