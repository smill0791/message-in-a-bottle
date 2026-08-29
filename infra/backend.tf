terraform {
  backend "s3" {
    bucket = "bottle-tfstate-116307287000-us-east-2"
    key    = "bottle/terraform.tfstate"
    region = "us-east-2"

    encrypt = true

    # Native S3 locking via conditional writes. The DynamoDB lock table is
    # deprecated and would be another resource to pay for and clean up.
    use_lockfile = true
  }
}
