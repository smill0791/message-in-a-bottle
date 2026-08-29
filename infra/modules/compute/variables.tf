variable "name" { type = string }
variable "region" { type = string }
variable "vpc_id" { type = string }

variable "public_subnet_ids" {
  description = "Where the load balancer lives."
  type        = list(string)
}

variable "app_subnet_ids" {
  description = "Private subnets for the instances."
  type        = list(string)
}

variable "alb_sg_id" { type = string }
variable "app_sg_id" { type = string }

variable "architecture" {
  description = <<-EOT
    arm64 or x86_64. arm64 (Graviton, t4g) is roughly 20% cheaper for the same
    performance here. The application has no native dependencies - password
    hashing uses node:crypto rather than bcrypt precisely so this stays true -
    so there is nothing to recompile.
  EOT
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "instance_type" {
  type    = string
  default = "t4g.micro"
}

variable "app_port" {
  type    = number
  default = 3000
}

variable "min_size" {
  type    = number
  default = 2
}

variable "max_size" {
  type    = number
  default = 4
}

variable "desired_capacity" {
  type    = number
  default = 2
}

variable "cpu_target" {
  description = "Target average CPU for the scaling policy."
  type        = number
  default     = 50
}

variable "health_check_grace_period" {
  description = <<-EOT
    Seconds before the Auto Scaling group starts health-checking a new
    instance. Must exceed the boot time - package installs plus npm ci - or the
    group kills instances mid-install in a loop that never converges.
  EOT
  type        = number
  default     = 420
}

variable "detailed_monitoring" {
  description = "One-minute EC2 metrics. Costs money; useful during a load test."
  type        = bool
  default     = false
}

# --- application wiring -----------------------------------------------------

variable "db_secret_arn" { type = string }
variable "db_host" { type = string }
variable "db_port" { type = number }
variable "db_name" { type = string }

variable "artifact_bucket" { type = string }
variable "artifact_bucket_arn" { type = string }
variable "artifact_key" { type = string }

variable "log_group_name" { type = string }
variable "log_group_arn" { type = string }

variable "beach_size" {
  type    = number
  default = 5
}

variable "tags" {
  type    = map(string)
  default = {}
}
