terraform {
  required_version = ">= 1.7.0"

  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "~> 0.12"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29"
    }
  }
}
