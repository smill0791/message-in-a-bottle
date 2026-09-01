terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Reads GitLab's TLS certificate chain at plan time so the OIDC provider's
    # thumbprint is derived rather than pasted in from a blog post and left to
    # rot when the certificate rotates.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
