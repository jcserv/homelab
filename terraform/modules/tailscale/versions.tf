terraform {
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29" # latest minor at impl time (0.29.2)
    }
  }
}
