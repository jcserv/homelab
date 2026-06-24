output "b2_bucket_names" {
  description = "Live B2 bucket names managed by TF."
  value       = module.b2.bucket_names
}

output "b2_bucket_ids" {
  description = "Live B2 bucket IDs managed by TF."
  value       = module.b2.bucket_ids
}
