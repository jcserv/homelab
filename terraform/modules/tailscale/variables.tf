# CI/manual node-join auth key. reusable+ephemeral+preauthorized by default.
variable "ci_key_expiry_seconds" {
  description = "Expiry for the tailnet auth key, in seconds. Default 90 days."
  type        = number
  default     = 7776000
}

# Cluster nodes that TF tags with tag:k3s, keyed by logical name -> Tailscale
# hostname. Small + stable, so hardcoded. All four get tag:k3s.
variable "managed_nodes" {
  description = "Logical name -> Tailscale hostname for nodes TF tags with tag:k3s."
  type        = map(string)
  default = {
    pi4_01 = "pi4-01"
    pi4_02 = "pi4-02"
    pi5_01 = "pi5-01"
    pi5_02 = "pi5-02"
  }
}
