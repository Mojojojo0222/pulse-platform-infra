output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Availability Zones used."
  value       = var.availability_zones
}

output "nat_gateway_public_ip" {
  description = "Public IPv4 address of the NAT Gateway."
  value       = aws_eip.nat.public_ip
}
