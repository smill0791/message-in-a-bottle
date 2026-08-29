variable "project_name" {
  description = "Prefix for every resource name."
  type        = string
  default     = "bottle"
}

variable "region" {
  description = "Fixed by the account's project region. Resources cannot be created elsewhere."
  type        = string
  default     = "us-east-2"
}

variable "aws_profile" {
  description = <<-EOT
    Always aws-dev-project. The [default] profile points at us-east-1 and shares
    a login session with this one; alternating between them rotates the refresh
    token and produces spurious 'authorization grant is invalid' errors.
  EOT
  type        = string
  default     = "aws-dev-project"
}

# --- network ----------------------------------------------------------------

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "enable_nat_gateway" {
  description = <<-EOT
    The most expensive line item at roughly $0.045/hour, about $33/month if
    left running. Required for instances to boot: they install packages and
    read Secrets Manager over it. Set false only to inspect the network layout
    without paying for it.
  EOT
  type        = bool
  default     = true
}

# --- compute ----------------------------------------------------------------

variable "architecture" {
  type    = string
  default = "arm64"
}

variable "instance_type" {
  description = "t4g.micro is arm64 Graviton, roughly 20% cheaper than t3.micro."
  type        = string
  default     = "t4g.micro"
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

variable "beach_size" {
  description = "How many bottles appear on the beach at once."
  type        = number
  default     = 5
}

# --- data -------------------------------------------------------------------

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

# --- deployment -------------------------------------------------------------

variable "artifact_key" {
  description = "S3 key of the application tarball, uploaded by scripts/package.sh."
  type        = string
  default     = "app/latest.tar.gz"
}

variable "log_retention_days" {
  description = "Short by default. Logs from a stack that lives for hours have no long-term value."
  type        = number
  default     = 7
}
