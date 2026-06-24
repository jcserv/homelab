# GitHub Actions secrets — TF-managed credentials pushed straight to repo Secrets,
# closing the hand-paste loop (e.g. the tailnet node-join key).
#
# CREATE-only discipline (mirrors tailscale_tailnet_key.ci): the GitHub API never
# returns a secret's value, so there is no import->no-op possible. Every managed
# secret is an inherent CREATE. This module verifies by COUNT OF CREATES, not a
# clean no-op plan. Boundary: external/cloud gap only — never charts/** or workloads.

resource "github_actions_secret" "ci_auth_key" {
  repository  = var.repository
  secret_name = "TS_TF_CI_AUTH_KEY"
  value       = var.ci_auth_key # plaintext; provider encrypts. (plaintext_value deprecated in v6)
}

# for_each over the secret NAMES only — keys() of a sensitive map is itself
# derived-sensitive, but the names (KUBE_CONFIG, …) are not secret, so nonsensitive()
# is safe and required (sensitive values can't be for_each keys). The value lookup
# stays sensitive -> plaintext_value stays sensitive.
resource "github_actions_secret" "adopted" {
  for_each    = nonsensitive(toset(keys(var.adopted_secrets)))
  repository  = var.repository
  secret_name = each.key
  value       = var.adopted_secrets[each.key]
}
