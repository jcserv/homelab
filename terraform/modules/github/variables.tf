variable "repository" {
  description = "GitHub repo (name only) that receives the Actions secrets."
  type        = string
  default     = "homelab-k8s"
}

variable "ci_auth_key" {
  description = "TF-managed tailnet auth key, fed from module.tailscale.ci_auth_key. Written to Actions secret TS_TF_CI_AUTH_KEY."
  type        = string
  sensitive   = true
}

variable "adopted_secrets" {
  description = "Logical SECRET_NAME -> plaintext value for pre-existing live secrets adopted into TF (KUBE_CONFIG / TS_OAUTH_CLIENT_ID / TS_OAUTH_SECRET). Supplied via TF_VAR_* — lands in encrypted state."
  type        = map(string)
  default     = {}
  sensitive   = true
}
