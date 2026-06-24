# Module wiring. Phase 1 = B2 only. Later phases attach their modules below.

module "b2" {
  source = "./modules/b2"
}

# Phase 2: module "tailscale"        { source = "./modules/tailscale" }
# Phase 3: module "infisical_platform" { source = "./modules/infisical-platform" }
# Phase 4: module "authentik"        { source = "./modules/authentik" }
# Phase 5: module "cluster_bootstrap" { source = "./modules/cluster-bootstrap" }
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
  id = "REPLACE_WITH_BUCKET_ID_homelab-backups-431118"
}

import {
  to = module.b2.b2_bucket.open_archiver
  id = "REPLACE_WITH_BUCKET_ID_open-archiver-homelab"
}

import {
  to = module.b2.b2_bucket.restic
  id = "REPLACE_WITH_BUCKET_ID_homelab-k3s-567f18"
}
