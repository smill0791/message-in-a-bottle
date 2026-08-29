terraform {
  # 1.10 introduced S3 native state locking (use_lockfile), which removes the
  # DynamoDB table the old pattern required.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
