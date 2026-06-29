terraform {
  required_version = ">= 1.7.0"

  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "~> 0.13"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}
