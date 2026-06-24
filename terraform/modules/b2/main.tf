# One b2_bucket per REAL live bucket (live state corrected from spec's assumed 4).
#
#   resource              live bucket name          region        used by
#   --------              ----------------          ------        -------
#   homelab_backups   ->  homelab-backups-431118    ca-east-006   immich-db / home-assistant / authentik backups (SHARED)
#   open_archiver     ->  open-archiver-homelab     ca-east-006   open-archiver
#   restic            ->  homelab-k3s-567f18        ca-east-006   restic-backup
#
# All bucket_type allPrivate. Imported via `import` blocks in ../../main.tf.

resource "b2_bucket" "homelab_backups" {
  bucket_name = "homelab-backups-431118"
  bucket_type = "allPrivate"

  default_server_side_encryption {
    mode      = "SSE-B2"
    algorithm = "AES256"
  }
}

resource "b2_bucket" "open_archiver" {
  bucket_name = "open-archiver-homelab"
  bucket_type = "allPrivate"
}

resource "b2_bucket" "restic" {
  bucket_name = "homelab-k3s-567f18"
  bucket_type = "allPrivate"
}

# ---------------------------------------------------------------------------
# DEFERRED: app keys — apply in a follow-up rotation PR.
# B2 never re-returns a key's secret, so existing keys CANNOT be imported, and
# creating new keys is a CREATE (violates this PR's plan-only no-op). Resources
# are sketched below and intentionally commented out until the rotation PR.
# ---------------------------------------------------------------------------
#
# resource "b2_application_key" "homelab_backups" {
#   key_name     = "homelab-backups-rw"
#   bucket_id    = b2_bucket.homelab_backups.bucket_id
#   capabilities = ["listBuckets", "listFiles", "readFiles", "writeFiles", "deleteFiles"]
# }
#
# resource "b2_application_key" "open_archiver" {
#   key_name     = "open-archiver-rw"
#   bucket_id    = b2_bucket.open_archiver.bucket_id
#   capabilities = ["listBuckets", "listFiles", "readFiles", "writeFiles", "deleteFiles"]
# }
#
# resource "b2_application_key" "restic" {
#   key_name     = "restic-rw"
#   bucket_id    = b2_bucket.restic.bucket_id
#   capabilities = ["listBuckets", "listFiles", "readFiles", "writeFiles", "deleteFiles"]
# }
