variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "app_port" {
  description = "Port the application listens on."
  type        = number
  default     = 3000
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "enable_https" {
  description = "Open 443 on the load balancer. Requires an ACM certificate."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
