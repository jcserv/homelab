# CI/manual node-join auth key. reusable+ephemeral+preauthorized by default.
variable "ci_key_expiry_seconds" {
  description = "Expiry for the tailnet auth key, in seconds. Default 90 days."
  type        = number
  default     = 7776000
}
