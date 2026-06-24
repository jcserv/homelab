output "bucket_names" {
  description = "Map of logical name -> live B2 bucket name."
  value = {
    homelab_backups = b2_bucket.homelab_backups.bucket_name
    open_archiver   = b2_bucket.open_archiver.bucket_name
    restic          = b2_bucket.restic.bucket_name
  }
}

output "bucket_ids" {
  description = "Map of logical name -> live B2 bucket ID."
  value = {
    homelab_backups = b2_bucket.homelab_backups.bucket_id
    open_archiver   = b2_bucket.open_archiver.bucket_id
    restic          = b2_bucket.restic.bucket_id
  }
}
