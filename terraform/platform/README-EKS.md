# Pulse Platform — EKS foundation

## What this adds

- Separate EKS control-plane and EC2 worker IAM roles.
- EKS 1.37 control plane with private and public API access.
- Public API allowlist defaults to `103.171.55.70/32`; update it if your public IP changes.
- Control-plane ENIs can use both public and private subnets across two AZs.
- Managed worker nodes run only in the two private subnets.
- OIDC provider and IRSA role for the VPC CNI add-on.
- Pinned, region-verified versions of VPC CNI, kube-proxy and CoreDNS.
- Two On-Demand `t3.medium` nodes by default, with autoscaling bounds 2–3.

## Cost and availability decisions

This is a learning environment, not a claim of production-grade HA.

- EKS control plane has an hourly charge.
- Two `t3.medium` On-Demand instances, EBS volumes, NAT Gateway, public IPv4 and data transfer add costs.
- One NAT Gateway serves both private AZs. It is a deliberate cost compromise and a single-AZ dependency.
- Two worker nodes provide basic node-level redundancy, but this is not equivalent to multi-AZ application resilience.
- Consider scaling node count to zero / destroying the lab when not in use. The NAT Gateway and EKS control plane continue to incur costs while present.

## Apply workflow

Run from `terraform/platform`:

```bash
terraform fmt -recursive
terraform init
terraform validate
terraform plan -out=eks.tfplan
terraform show eks.tfplan
```

Review the plan carefully. It should add EKS IAM, the cluster, OIDC, the managed node group and three managed add-ons. It must not replace or destroy the existing VPC, subnets, NAT Gateway, route tables or state backend.

Only after review:

```bash
terraform apply eks.tfplan
```

Then configure kubectl:

```bash
aws eks update-kubeconfig --region ap-south-1 --name pulse-eks
kubectl get nodes -o wide
kubectl get pods -A
```

## Important operational notes

- If the public IP changes, update `cluster_public_cidrs` in `terraform.tfvars` (or the default in `variables.tf`) before attempting public endpoint access.
- Private endpoint access works only from within the VPC or a connected network; this laptop currently uses the restricted public endpoint.
- Do not commit `*.tfplan`, Terraform state, `.terraform/`, or secret values.
- Commit `.terraform.lock.hcl`.
- EBS CSI is intentionally a separate next step. First verify the cluster and query the EBS CSI add-on version supported by the regional EKS API; then add its dedicated workload IAM role.
- The node role intentionally does not carry `AmazonEKS_CNI_Policy`; VPC CNI uses its own IRSA role.
