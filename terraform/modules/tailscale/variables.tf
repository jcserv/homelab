# Managed cluster nodes -> Tailscale tags. Small + stable, so hardcoded here as a
# map of { logical_name = { hostname, tags } }. `hostname` is the device's short
# Tailscale hostname (looked up via the tailscale_device data source).
#
# TODO(user data): confirm hostnames + tag sets before plan. node IDs go in the
# root import blocks, NOT here.
variable "managed_nodes" {
  description = "Cluster nodes whose Tailscale tags TF owns, keyed by logical name."
  type = map(object({
    hostname = string
    tags     = list(string)
  }))
  default = {
    # pi4_01 = { hostname = "pi4-01", tags = ["tag:k3s"] }
    # pi4_02 = { hostname = "pi4-02", tags = ["tag:k3s"] }
    # pi5_01 = { hostname = "pi5-01", tags = ["tag:k3s"] }
    # pi5_02 = { hostname = "pi5-02", tags = ["tag:k3s"] }
  }
}

# CI/manual node-join auth key. reusable+ephemeral+preauthorized by default.
variable "ci_key_expiry_seconds" {
  description = "Expiry for the tailnet auth key, in seconds. Default 90 days."
  type        = number
  default     = 7776000
}
