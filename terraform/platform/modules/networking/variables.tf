variable "project_name" {
  type        = string
  description = "Project identifier."
}

variable "environment" {
  type        = string
  description = "Environment name."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name used in subnet tags."
}

variable "vpc_cidr" {
  type        = string
  description = "VPC IPv4 CIDR."
}

variable "availability_zones" {
  type        = list(string)
  description = "Exactly two available Availability Zones."
  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "The networking module requires exactly two Availability Zones."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "Public subnet CIDRs, one per AZ."
  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Exactly two public subnet CIDRs are required."
  }
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs, one per AZ."
  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Exactly two private subnet CIDRs are required."
  }
}
