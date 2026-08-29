output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  value = aws_subnet.data[*].id
}

output "availability_zones" {
  value = local.azs
}

output "nat_gateway_id" {
  description = "Null when enable_nat_gateway is false."
  value       = try(aws_nat_gateway.this[0].id, null)
}
