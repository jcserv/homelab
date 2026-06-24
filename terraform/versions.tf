terraform {
  # >= 1.7.0: native state encryption GA'd in 1.7; declarative `import` blocks 1.6+.
  required_version = ">= 1.7.0"

  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "~> 0.10"
    }
    # Other providers (dns, tailscale, authentik, infisical, kubernetes) added in later phases.
  }
}
