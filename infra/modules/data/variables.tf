variable "name" {
  type = string
}

variable "subnet_ids" {
  description = "Private data subnet ids. At least two, in different AZs."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "engine_version" {
  description = "Major version only; RDS selects the current minor."
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = "db.t4g.micro is Graviton and the cheapest option that runs Postgres 16."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling. Set equal to allocated_storage to disable."
  type        = number
  default     = 50
}

variable "database_name" {
  type    = string
  default = "bottle"
}

variable "master_username" {
  type    = string
  default = "bottle"
}

variable "backup_retention_days" {
  description = <<-EOT
    Days of automated backups. Zero disables them entirely, which is correct
    for a stack that is destroyed after every session.

    This was 1, on the reasoning that point-in-time recovery was worth a few
    cents. That was wrong twice over. The data does not survive `destroy`
    anyway - skip_final_snapshot is true - so the backups protect nothing. And
    automated snapshots *outlive the instance*: after the destroy there was a
    20GB snapshot still sitting there, which cannot be deleted by hand
    ("automated snapshots cannot be deleted") and only disappears when its
    retention expires. Residue that survives a teardown is exactly what the
    ephemeral model is meant to avoid.

    Raise this for anything long-lived, where the trade is real.
  EOT
  type        = number
  default     = 0
}

variable "enable_performance_insights" {
  description = "Free at 7 days retention, and the fastest way to see a slow discovery query."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "log_retention_days" {
  description = <<-EOT
    Retention for the Postgres log group. Short by default: logs from a stack
    that lives for hours have no long-term value, and RDS would otherwise
    create this group with no expiry at all.
  EOT
  type        = number
  default     = 7
}
