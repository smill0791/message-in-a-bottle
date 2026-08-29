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
    Days of automated backups. One is enough for a stack that is destroyed
    after every session; zero would disable point-in-time recovery entirely
    and is not worth the saving.
  EOT
  type        = number
  default     = 1
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
