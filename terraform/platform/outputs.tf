output "vpc_id" {
  value = module.networking.vpc_id
}

output "public_subnet_ids" {
  value = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.networking.private_subnet_ids
}

output "availability_zones" {
  value = module.networking.availability_zones
}

output "nat_gateway_public_ip" {
  value = module.networking.nat_gateway_public_ip
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eks_cluster_oidc_issuer" {
  value = module.eks.cluster_oidc_issuer
}

output "eks_node_group_name" {
  value = module.eks.node_group_name
}
