output "vpc_id" {
  description = "ID of the project VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered by Availability Zone. Used by the ALB and the ECS service."
  value       = aws_subnet.public[*].id
}

output "public_subnet_cidrs" {
  description = "CIDR blocks of the public subnets."
  value       = aws_subnet.public[*].cidr_block
}

output "availability_zones" {
  description = "Availability Zones the VPC spans."
  value       = local.azs
}

output "internet_gateway_id" {
  description = "Internet Gateway attached to the VPC."
  value       = aws_internet_gateway.this.id
}
