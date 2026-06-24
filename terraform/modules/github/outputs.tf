# Non-secret inventory of what this module manages. Names only — never values.
output "managed_secret_names" {
  description = "Actions secret names managed by this module."
  value       = concat(["TS_TF_CI_AUTH_KEY"], nonsensitive(keys(var.adopted_secrets)))
}
