terraform {
  backend "s3" {
    bucket       = "pulse-platform-tfstate-047090857529-ap-south-1"
    key          = "platform/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
