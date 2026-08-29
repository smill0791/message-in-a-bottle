variable "name" {
  description = "Prefix for resource names and Name tags."
  type        = string
}

variable "region" {
  description = "AWS region. Used to build the S3 endpoint service name."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the VPC. Must be large enough for three /24s per AZ."
  type        = string

  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 8, 20))
    error_message = "vpc_cidr must be a /16 or larger to fit the three subnet tiers."
  }
}

variable "az_count" {
  description = "How many availability zones to spread across."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "An Application Load Balancer requires at least two AZs."
  }
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Whether to create the NAT gateway.

    This is the most expensive resource in the stack at roughly $0.045/hour.
    Set false to inspect the network layout without paying for outbound
    connectivity; the app tier will have no route to the internet.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
