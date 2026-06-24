# Tailscale tailnet — ACL-as-code + a tailnet auth key + cluster node tags.
#
# The ACL is import->no-op. tailscale_tailnet_key.ci is a CREATE. HARD STOP: if
# `tofu plan` shows destroy/replace on the ACL, fix acl.hujson to match live
# before applying — a bad ACL push can lock the tailnet.

# ---------------------------------------------------------------------------
# ACL-as-code. Kept in acl.hujson so it's diffable as policy, not buried in HCL.
# overwrite_existing_content/reset_acl_on_destroy left at defaults — the default
# refusal-to-overwrite is the safety we want; import satisfies it.
# ---------------------------------------------------------------------------
resource "tailscale_acl" "this" {
  acl = file("${path.module}/acl.hujson")
}

# ---------------------------------------------------------------------------
# Cluster node tags. The nodes were user-owned (untagged); this is the deliberate
# CREATE that moves them to tag-ownership (tag:k3s) so they no longer depend on a
# personal account or key expiry. The required grants (autogroup:admin -> tag:k3s
# and -> 10.2.1.0/24, plus SSH) landed in acl.hujson in the prior PR, so this flip
# does not strand kubectl/SSH/LAN access. The TF OAuth client must own tag:k3s.
# ---------------------------------------------------------------------------
data "tailscale_device" "node" {
  for_each = var.managed_nodes
  hostname = each.value
  wait_for = "30s"
}

resource "tailscale_device_tags" "node" {
  for_each  = var.managed_nodes
  device_id = data.tailscale_device.node[each.key].node_id
  tags      = ["tag:k3s"]
}

# ---------------------------------------------------------------------------
# Tailnet auth key for manual/other node joins (NAS, re-imaging a Pi). CI's
# github-action self-mints from TS_OAUTH_* and does NOT consume this. The lone
# CREATE in this phase; `key` is sensitive -> surfaced via output, never committed.
# Infisical storage of the value deferred to Phase 3.
# ---------------------------------------------------------------------------
resource "tailscale_tailnet_key" "ci" {
  reusable      = true
  ephemeral     = true
  preauthorized = true
  tags          = ["tag:github-actions"]
  expiry        = var.ci_key_expiry_seconds
  # Tailscale rejects non-alphanumeric chars in key descriptions (no / ( ) -).
  description = "TF managed node join key"
}
