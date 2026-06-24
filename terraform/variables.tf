variable "state_passphrase" {
  description = "PBKDF2 passphrase for native state encryption. Tier-0 root; set via TF_VAR_state_passphrase (GH secret TF_STATE_PASSPHRASE). Never in Infisical."
  type        = string
  sensitive   = true
}
