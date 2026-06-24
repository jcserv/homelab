terraform {
  # State lives in the hand-made (Tier-0) B2 bucket via the S3-compatible endpoint.
  # B2 creds come from env: B2_APPLICATION_KEY_ID / B2_APPLICATION_KEY (reuse the mgmt key).
  backend "s3" {
    bucket = "homelab-tofu-state-dd43bf5b"
    key    = "global/terraform.tfstate"
    region = "ca-east-006"

    endpoints = {
      s3 = "https://s3.ca-east-006.backblazeb2.com"
    }
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    use_path_style              = true
  }

  encryption {
    key_provider "pbkdf2" "k" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "m" {
      keys = key_provider.pbkdf2.k
    }
    state {
      method = method.aes_gcm.m
    }
    plan {
      method = method.aes_gcm.m
    }
  }
}
