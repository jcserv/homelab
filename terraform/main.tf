# Module wiring. Phase 1 = B2 only. Later phases attach their modules below.

module "b2" {
  source = "./modules/b2"
}

module "tailscale" {
  source = "./modules/tailscale"
}

# Phase 3: module "infisical_platform" { source = "./modules/infisical-platform" }
# Phase 4: module "authentik"        { source = "./modules/authentik" }
# Phase 5: module "cluster_bootstrap" { source = "./modules/cluster-bootstrap" }

# Phase 6 — TF-managed credentials pushed straight to GitHub Actions secrets,
# closing the hand-paste loop. ci_auth_key consumed directly from the tailscale
# module (no root output needed). Adopted secrets fed plaintext via TF_VAR_*.
module "github" {
  source      = "./modules/github"
  ci_auth_key = module.tailscale.ci_auth_key
  adopted_secrets = {
    KUBE_CONFIG        = var.kube_config
    TS_OAUTH_CLIENT_ID = var.ts_oauth_client_id
    TS_OAUTH_SECRET    = var.ts_oauth_secret
  }
}
# DNS:     module "dns"              { source = "./modules/dns" }

# ---------------------------------------------------------------------------
# Declarative import (OpenTofu 1.6+): adopt the existing live B2 buckets into
# state WITHOUT recreating them. Plan-only this PR — must be a clean no-op.
#
# IDs are B2 bucket IDs (NOT names). Fill from `b2 list-buckets` before plan.
# restic's bucket is confirmed from Infisical /backup/restic -> RESTIC_REPOSITORY.
#
# HARD STOP: if `tofu plan` shows ANY destroy/replace on a bucket, do not apply.
# Fix module HCL (lifecycle/retention/bucket_info) to match live, then re-plan.
# ---------------------------------------------------------------------------

import {
  to = module.b2.b2_bucket.homelab_backups
  id = "0a041ee91bcea84291a2011d" # homelab-backups-431118
}

import {
  to = module.b2.b2_bucket.open_archiver
  id = "1ae40e29cbdec82291e2011d" # open-archiver-homelab
}

import {
  to = module.b2.b2_bucket.restic
  id = "5ad4be49abae28a291a2011d" # homelab-k3s-567f18
}

# ---------------------------------------------------------------------------
# Phase 2 — Tailscale. Import the live ACL into state WITHOUT mutating it.
# tailscale_tailnet_key.ci is intentionally NOT imported — it's the lone CREATE
# (its `key` secret is never returned on import).
#
# Device tags are NOT managed: cluster nodes are user-owned (untagged) live, so
# tagging is a real mutation, not an import. Deferred to a follow-up.
#
# HARD STOP: if `tofu plan` shows ANY destroy/replace on the ACL, do not apply.
# Reconcile acl.hujson to live first. A bad ACL push can lock the tailnet — treat
# it like a backup bucket.
# ---------------------------------------------------------------------------

import {
  to = module.tailscale.tailscale_acl.this
  id = "acl"
}
