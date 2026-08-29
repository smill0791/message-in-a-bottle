output "url" {
  description = "Open this once the targets are healthy."
  value       = "http://${module.compute.alb_dns_name}"
}

output "alb_dns_name" {
  value = module.compute.alb_dns_name
}

output "asg_name" {
  value = module.compute.asg_name
}

output "target_group_arn" {
  value = module.compute.target_group_arn
}

output "db_endpoint" {
  value = module.data.endpoint
}

output "db_secret_arn" {
  description = "Read the password with: aws secretsmanager get-secret-value --secret-id <arn>"
  value       = module.data.master_secret_arn
}

output "artifact_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "hourly_cost_estimate" {
  description = "Rough on-demand rate while this stack exists. Destroy when finished."
  value = format(
    "~$%.3f/hour (ALB 0.0225 + %d x %s + RDS %s + NAT %s)",
    0.0225 + (var.desired_capacity * 0.0084) + 0.016 + (var.enable_nat_gateway ? 0.045 : 0),
    var.desired_capacity,
    var.instance_type,
    var.db_instance_class,
    var.enable_nat_gateway ? "0.045" : "disabled",
  )
}
