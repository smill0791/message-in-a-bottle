terraform {
  backend "s3" {
    bucket = "bottle-tfstate-116307287000-us-east-2"

    # A different key from the main stack, in the same bucket.
    #
    # This root is deliberately a separate state file. The main stack is
    # destroyed at the end of every working session - that is the cost control
    # - and anything sharing its state would be destroyed with it. The CI role
    # is exactly what CI needs in order to come back, so it cannot live there:
    # the first teardown would delete the credential the next pipeline needs
    # and leave no way to restore it except a manual local apply.
    key    = "bottle/bootstrap.tfstate"
    region = "us-east-2"

    encrypt      = true
    use_lockfile = true
  }
}
