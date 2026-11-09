variable "project_name" {
  type    = string
  default = "pulse"
}

variable "environment" {
  type    = string
  default = "lab"
}

variable "cluster_name" {
  type    = string
  default = "pulse-eks"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.0.0/20", "10.20.16.0/20"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Exactly two public subnet CIDRs are required."
  }
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.32.0/20", "10.20.48.0/20"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Exactly two private subnet CIDRs are required."
  }
}

variable "kubernetes_version" {
  type        = string
  description = "EKS Kubernetes control-plane version."
  default     = "1.37"
}

variable "cluster_public_cidrs" {
  type        = list(string)
  description = "IPv4 CIDRs allowed to reach the public Kubernetes API endpoint."
  default     = ["103.171.55.70/32"]

  validation {
    condition     = length(var.cluster_public_cidrs) > 0
    error_message = "At least one public API allowlist CIDR is required."
  }
}

variable "node_instance_types" {
  type        = list(string)
  description = "EC2 instance types for the managed node group."
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "node_disk_size" {
  type    = number
  default = 30
}
