# Credentials from env: B2_APPLICATION_KEY_ID / B2_APPLICATION_KEY (the Tier-0 mgmt key).
provider "b2" {}

# Credentials from env: TAILSCALE_OAUTH_CLIENT_ID / TAILSCALE_OAUTH_CLIENT_SECRET
# (the new ACL-scoped OAuth client, distinct from the node-auth TS_OAUTH_*).
# tailnet "-" = the OAuth client's own default tailnet.
provider "tailscale" {
  tailnet = "-"
}

# Credentials from env: GITHUB_TOKEN (hand-made fine-grained PAT GH_TF_TOKEN, repo
# Secrets RW + Metadata R). Never TF-managed (self-management = chicken-egg).
provider "github" {
  owner = var.github_owner
}
