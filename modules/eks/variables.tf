variable "region" {
type =  string
default = "us-east-1"
}

variable "subnet_ids" {
  type        = list(string)
  description = "List of subnet IDs for EKS worker nodes"
}

variable "vpc_id" {
  description = "VPC ID for the EKS cluster"
  type        = string
}

# Creating EKS Add on

variable "addons" {
  type = list(object({
    name    = string
    version = string
  }))

  default = [
    {
      name    = "kube-proxy"
      version = "v1.31.3-eksbuild.2"
    },
    {
      name    = "vpc-cni"
      version = "v1.19.2-eksbuild.1"
    },
    {
      name    = "coredns"
      version = "v1.11.4-eksbuild.2"
    }
  ]
}

