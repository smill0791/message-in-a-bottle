/**
 * Message in a Bottle - root module.
 *
 * The whole stack rises and falls with `terraform apply` / `terraform
 * destroy`. That is not a convenience, it is the cost control: running this
 * continuously would exhaust the credit balance in about six weeks, while a
 * three-hour working session costs roughly thirty cents.
 */

provider "aws" {
  region = var.region

  /**
   * null, not "", when no profile is wanted.
   *
   * A GitLab runner gets its credentials from OIDC role assumption, which
   * lands them in the environment. There is no ~/.aws/config on the runner, so
   * naming a profile makes the provider fail before it plans anything. An
   * empty string is not the same as absent here - it is still a lookup, for a
   * profile called "" - so it has to collapse to null.
   */
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = local.tags
  }
}

locals {
  name = var.project_name

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
    Repo      = "gitlab.com/aws-projects6841835/message-in-a-bottle"
  }
}

# ------------------------------------------------------------------ shared --

/**
 * Artifact bucket. Force-destroyed on teardown because the artifact is a build
 * output, reproducible from a git commit, and leaving a bucket behind after
 * `terraform destroy` is how orphaned resources accumulate.
 */
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.name}-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${local.name}/app"
  retention_in_days = var.log_retention_days
}

# ----------------------------------------------------------------- modules --

module "network" {
  source = "./modules/network"

  name               = local.name
  region             = var.region
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  enable_nat_gateway = var.enable_nat_gateway
  tags               = local.tags
}

module "security" {
  source = "./modules/security"

  name     = local.name
  vpc_id   = module.network.vpc_id
  app_port = var.app_port
  tags     = local.tags
}

module "data" {
  source = "./modules/data"

  name              = local.name
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.security.db_sg_id
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  tags              = local.tags
}

module "compute" {
  source = "./modules/compute"

  name   = local.name
  region = var.region
  vpc_id = module.network.vpc_id

  public_subnet_ids = module.network.public_subnet_ids
  app_subnet_ids    = module.network.app_subnet_ids
  alb_sg_id         = module.security.alb_sg_id
  app_sg_id         = module.security.app_sg_id

  architecture     = var.architecture
  instance_type    = var.instance_type
  app_port         = var.app_port
  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity
  beach_size       = var.beach_size

  db_secret_arn = module.data.master_secret_arn
  db_host       = module.data.endpoint
  db_port       = module.data.port
  db_name       = module.data.database_name

  artifact_bucket     = aws_s3_bucket.artifacts.bucket
  artifact_bucket_arn = aws_s3_bucket.artifacts.arn
  artifact_key        = var.artifact_key

  log_group_name = aws_cloudwatch_log_group.app.name
  log_group_arn  = aws_cloudwatch_log_group.app.arn

  tags = local.tags

  # The instances read the artifact on boot. Without this, Terraform may create
  # the Auto Scaling group before the object exists and every instance fails
  # its bootstrap.
  depends_on = [aws_s3_bucket.artifacts]
}
