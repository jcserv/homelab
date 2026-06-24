variable "state_passphrase" {
  description = "PBKDF2 passphrase for native state encryption. Tier-0 root; set via TF_VAR_state_passphrase (GH secret TF_STATE_PASSPHRASE). Never in Infisical."
  type        = string
  sensitive   = true
}

variable "github_owner" {
  description = "GitHub owner for the github provider. Set via TF_VAR_github_owner (CI: github.repository_owner)."
  type        = string
}

# Adopted non-Tier-0 secrets re-supplied as plaintext via TF_VAR_* from live GH
# secrets. Accept state exposure (B2 + native PBKDF2/AES encryption at rest).
variable "kube_config" {
  description = "Adopted: KUBE_CONFIG. Supplied via TF_VAR_kube_config."
  type        = string
  sensitive   = true
}

variable "ts_oauth_client_id" {
  description = "Adopted: TS_OAUTH_CLIENT_ID. Supplied via TF_VAR_ts_oauth_client_id."
  type        = string
  sensitive   = true
}

variable "ts_oauth_secret" {
  description = "Adopted: TS_OAUTH_SECRET. Supplied via TF_VAR_ts_oauth_secret."
  type        = string
  sensitive   = true
}
