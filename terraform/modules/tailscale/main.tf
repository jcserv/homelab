# Tailscale tailnet — ACL-as-code + a tailnet auth key.
#
# Import discipline (mirrors B2): the ACL is import->no-op. Only
# tailscale_tailnet_key.ci is a CREATE (its `key` secret is never returned on
# import). HARD STOP: if `tofu plan` shows destroy/replace on the ACL, fix
# acl.hujson to match live before applying — a bad ACL push can lock the tailnet.
#
# Device tags are intentionally NOT managed here: the cluster nodes are currently
# user-owned (untagged) live, so tagging them would be a real ownership-changing
# mutation, not an import-no-op. Deferred to a deliberate follow-up (add the node
# tag to tagOwners + grants in acl.hujson, then apply).

# ---------------------------------------------------------------------------
# ACL-as-code. Kept in acl.hujson so it's diffable as policy, not buried in HCL.
# overwrite_existing_content/reset_acl_on_destroy left at defaults — the default
# refusal-to-overwrite is the safety we want; import satisfies it.
# ---------------------------------------------------------------------------
resource "tailscale_acl" "this" {
  acl = file("${path.module}/acl.hujson")
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
