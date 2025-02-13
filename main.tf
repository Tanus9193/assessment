module "vpc" {
  source             = "./modules/vpc"
  vpc_cidr           = var.vpc_cidr
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
  availability_zones = var.availability_zones
}
data "aws_caller_identity" "current" {}

module "eks" {
  source     = "./modules/eks"
  subnet_ids = concat(module.vpc.private_subnets, module.vpc.public_subnets)
  vpc_id     = module.vpc.vpc_id
}


# Remove the data.aws_eks_cluster block entirely

data "aws_eks_cluster_auth" "eks" {
  name = module.eks.cluster_name # Use the output from the eks module for the cluster name
}

# Extract OIDC Provider URL
data "tls_certificate" "eks" {
  url = module.eks.oidc_provider_url # Use the output from the eks module for the OIDC issuer
}

# Create IAM OIDC Identity Provider
resource "aws_iam_openid_connect_provider" "eks" {
  url             = module.eks.oidc_provider_url # Use the output from the eks module for the OIDC issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]

  tags = {
    Name = "eks-oidc-provider"
  }
}

resource "kubernetes_service_account" "alb_service_account" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_ingress_role.arn
    }
  }

  depends_on = [aws_iam_role.alb_ingress_role]
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint                            # Use the output from the eks module for the cluster endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority) # Use the output from the eks module for the CA certificate
  token                  = module.eks.cluster_auth_token                          # Use the output from the eks module for the auth token
}


provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint                            # Use the output from the eks module for the cluster endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority) # Use the output from the eks module for the CA certificate
    token                  = module.eks.cluster_auth_token                          # Use the output from the eks module for the auth token
  }
}

resource "helm_release" "alb_ingress" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name # Use the output from the eks module for the cluster name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  depends_on = [module.eks]
}

resource "aws_iam_policy" "alb_ingress_policy" {
  name        = "AWSLoadBalancerControllerIAMPolicy-${random_id.policy_suffix.hex}"
  description = "IAM policy for ALB Ingress Controller"
  policy      = file("${path.module}/modules/eks/iam_policy.json")
}

resource "random_id" "policy_suffix" {
  byte_length = 4
}

resource "aws_iam_role_policy_attachment" "alb_ingress_attachment" {
  policy_arn = aws_iam_policy.alb_ingress_policy.arn
  role       = aws_iam_role.alb_ingress_role.name
}

resource "aws_iam_role" "alb_ingress_role" {
  name = "aws-load-balancer-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${module.eks.oidc_provider_id}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider_id}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          }
        }
      }
    ]
  })
}

resource "null_resource" "wait_for_alb_controller" {
  depends_on = [helm_release.alb_ingress]

  provisioner "local-exec" {
    command = <<EOT
      echo "Waiting for AWS Load Balancer Controller to be ready..."
      while [[ $(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o jsonpath='{.items[*].status.phase}') != "Running" ]]; do
        echo "ALB Controller is not ready yet. Retrying in 10s..."
        sleep 10
      done
      echo "AWS Load Balancer Controller is ready!"
    EOT
  }
}

resource "null_resource" "apply_k8s_manifests" {
  depends_on = [null_resource.wait_for_alb_controller]

  provisioner "local-exec" {
    command = <<EOT
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}
      kubectl apply -f ./manifests/
    EOT
  }
}

# Create a namespace for Metrics Server
resource "kubernetes_namespace" "metrics" {
  metadata {
    name = "metrics-server"
  }
}

# Deploy Metrics Server using Helm
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = kubernetes_namespace.metrics.metadata[0].name

  set {
    name  = "args"
    value = "{--kubelet-insecure-tls}"
  }
}






resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}


resource "kubernetes_storage_class" "ebs_sc" {
  metadata {
    name = "ebs-sc"
  }

  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Retain"

  parameters = {
    type  = "gp3"
    fsType = "ext4"
  }
}


resource "kubernetes_persistent_volume_claim" "prometheus_pvc" {
  metadata {
    name      = "prometheus-pvc"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = "10Gi"
      }
    }

    storage_class_name = kubernetes_storage_class.ebs_sc.metadata[0].name
  }
}

resource "kubernetes_persistent_volume_claim" "alertmanager_pvc" {
  metadata {
    name      = "alertmanager-pvc"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = "5Gi"
      }
    }

    storage_class_name = kubernetes_storage_class.ebs_sc.metadata[0].name
  }
}



