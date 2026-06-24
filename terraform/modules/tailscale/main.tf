# Tailscale tailnet — ACL-as-code + TF-managed device tags + a tailnet auth key.
#
# Import discipline (mirrors B2): the ACL and every device_tags are import->no-op.
# Only tailscale_tailnet_key.ci is a CREATE (its `key` secret is never returned on
# import). HARD STOP: if `tofu plan` shows destroy/replace on the ACL or any tags,
# fix HCL/acl.hujson to match live before applying — a bad ACL push can lock the
# tailnet.

# ---------------------------------------------------------------------------
# ACL-as-code. Kept in acl.hujson so it's diffable as policy, not buried in HCL.
# overwrite_existing_content/reset_acl_on_destroy left at defaults — the default
# refusal-to-overwrite is the safety we want; import satisfies it.
# ---------------------------------------------------------------------------
resource "tailscale_acl" "this" {
  acl = file("${path.module}/acl.hujson")
}

# ---------------------------------------------------------------------------
# TF-managed device tags on the managed cluster nodes (import -> no-op).
# Looks each device up by hostname, then owns its tag set.
# ---------------------------------------------------------------------------
data "tailscale_device" "node" {
  for_each = var.managed_nodes
  hostname = each.value.hostname
  wait_for = "30s"
}

resource "tailscale_device_tags" "node" {
  for_each  = var.managed_nodes
  device_id = data.tailscale_device.node[each.key].node_id
  tags      = each.value.tags
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
  description   = "TF-managed node-join key (manual/NAS/re-image); see terraform/modules/tailscale"
}
