/**
 * Data tier: a single Postgres instance in the private data subnets.
 */

resource "aws_db_subnet_group" "this" {
  name        = "${var.name}-db"
  description = "Private data subnets for ${var.name}"
  subnet_ids  = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.name}-db-subnets" })
}

resource "aws_db_instance" "this" {
  identifier = "${var.name}-db"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  # gp3 is cheaper per GB than gp2 at this size and has a higher baseline.
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.database_name
  username = var.master_username

  /**
   * RDS generates the password and owns it in Secrets Manager.
   *
   * The alternative - random_password plus an aws_secretsmanager_secret -
   * writes the password into Terraform state in plaintext, where it sits in
   * the state bucket forever and appears in any `terraform show`. With this,
   * the password never enters state at all and rotation is handled for us.
   */
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]

  # No public endpoint. The instance is reachable only from the app tier.
  publicly_accessible = false

  /**
   * Single-AZ, deliberately.
   *
   * Multi-AZ doubles the instance cost for a standby that exists to survive a
   * zone failure. Against a $120 credit balance on a portfolio project that is
   * the wrong trade. The failure mode is understood and accepted rather than
   * overlooked - flip this to true and it is a live change.
   */
  multi_az = false

  backup_retention_period = var.backup_retention_days
  backup_window           = "07:00-08:00"
  maintenance_window      = "Mon:08:30-Mon:09:30"

  auto_minor_version_upgrade = true

  /**
   * These three exist so the stack can actually be destroyed.
   *
   * The whole cost model here depends on tearing everything down after each
   * session. deletion_protection or a required final snapshot turns
   * `terraform destroy` into a manual console errand, which is exactly how a
   * database gets left running for a month.
   */
  deletion_protection      = false
  skip_final_snapshot      = true
  delete_automated_backups = true

  # Free tier of Performance Insights is 7 days retention.
  performance_insights_enabled          = var.enable_performance_insights
  performance_insights_retention_period = var.enable_performance_insights ? 7 : null

  # Postgres logs to CloudWatch so a failed boot is diagnosable without
  # reaching the instance, which sits in a subnet with no inbound path.
  enabled_cloudwatch_logs_exports = ["postgresql"]

  apply_immediately = true

  tags = merge(var.tags, { Name = "${var.name}-db" })
}
