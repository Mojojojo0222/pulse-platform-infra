# Pulse Platform — Networking milestone

## Design

- VPC: `10.20.0.0/16`
- Two public subnets across the first two currently available AZs.
- Two private subnets across the same AZs.
- Internet Gateway routes public subnet internet traffic.
- One NAT Gateway in the first public subnet provides outbound internet for both private subnets.
- EKS subnet discovery tags are applied to public and private subnets.

## Intentional lab trade-off

This is cost-conscious, not fully highly available. The single NAT Gateway is a shared dependency for both private subnets. If its AZ or the NAT Gateway fails, private-subnet outbound internet access is interrupted. EKS worker nodes remain in private subnets and do not receive public IPv4 addresses.

## Apply sequence

From `terraform/platform`:

```bash
terraform fmt -recursive
terraform init
terraform validate
terraform plan -out=network.tfplan
```

Review the plan before applying. The expected network resources include a VPC, IGW, four subnets, route tables/associations, one EIP, and one NAT Gateway. NAT Gateway and its public IPv4 address incur ongoing charges while provisioned, including when idle.

Only after reviewing the plan:

```bash
terraform apply network.tfplan
```

Do not commit `*.tfplan`, state files, or local secret files. Commit `.terraform.lock.hcl`.
