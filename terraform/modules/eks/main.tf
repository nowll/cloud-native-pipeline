terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }
}

# ─────────────────────────────────────────────
# EKS Cluster
# ─────────────────────────────────────────────
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = var.public_access
    public_access_cidrs     = var.public_access_cidrs
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = false
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ─────────────────────────────────────────────
# KMS for EKS secrets encryption
# ─────────────────────────────────────────────
resource "aws_kms_key" "eks" {
  description             = "EKS cluster ${var.cluster_name} secrets encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# ─────────────────────────────────────────────
# Cluster Logs
# ─────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ─────────────────────────────────────────────
# OIDC Provider for IRSA
# ─────────────────────────────────────────────
data "tls_certificate" "cluster" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  tags            = var.tags
}

# ─────────────────────────────────────────────
# Node Groups
# ─────────────────────────────────────────────
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  version         = var.kubernetes_version
  instance_types  = ["m7g.medium"]  # Graviton3 for cost efficiency
  ami_type        = "AL2_ARM_64"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  update_config {
    max_unavailable_percentage = 25
  }

  labels = {
    role = "system"
    "node.kubernetes.io/purpose" = "system"
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version_number
  }

  tags = var.tags
}

resource "aws_eks_node_group" "application" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-application"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  version         = var.kubernetes_version
  instance_types  = var.node_instance_types
  ami_type        = "BOTTLEROCKET_ARM_64"  # Bottlerocket for security

  scaling_config {
    desired_size = var.node_desired_count
    min_size     = var.node_min_count
    max_size     = var.node_max_count
  }

  update_config {
    max_unavailable_percentage = 33
  }

  labels = {
    role = "application"
  }

  launch_template {
    id      = aws_launch_template.application.id
    version = aws_launch_template.application.latest_version_number
  }

  tags = var.tags
}

resource "aws_eks_node_group" "spot" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-spot"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  version         = var.kubernetes_version
  capacity_type   = "SPOT"
  instance_types  = ["m7g.xlarge", "m6g.xlarge", "c7g.xlarge", "c6g.xlarge"]
  ami_type        = "BOTTLEROCKET_ARM_64"

  scaling_config {
    desired_size = var.spot_desired_count
    min_size     = 0
    max_size     = var.spot_max_count
  }

  labels = {
    role                              = "spot"
    "node.kubernetes.io/lifecycle"    = "spot"
  }

  taint {
    key    = "spot"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = var.tags
}

# ─────────────────────────────────────────────
# Launch Templates
# ─────────────────────────────────────────────
resource "aws_launch_template" "system" {
  name_prefix = "${var.cluster_name}-system-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2 required
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }

  monitoring { enabled = true }
  tags = var.tags
}

resource "aws_launch_template" "application" {
  name_prefix = "${var.cluster_name}-application-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }

  monitoring { enabled = true }
  tags = var.tags
}

resource "aws_kms_key" "ebs" {
  description             = "EBS volumes encryption for ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = var.tags
}

# ─────────────────────────────────────────────
# Cluster Add-ons
# ─────────────────────────────────────────────
resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "vpc-cni"
  addon_version            = data.aws_eks_addon_version.vpc_cni.version
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn = aws_iam_role.vpc_cni.arn
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })
  tags = var.tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "coredns"
  addon_version            = data.aws_eks_addon_version.coredns.version
  resolve_conflicts_on_update = "OVERWRITE"
  tags                     = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "kube-proxy"
  addon_version            = data.aws_eks_addon_version.kube_proxy.version
  resolve_conflicts_on_update = "OVERWRITE"
  tags                     = var.tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = data.aws_eks_addon_version.ebs_csi.version
  service_account_role_arn = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_update = "OVERWRITE"
  tags                     = var.tags
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "eks-pod-identity-agent"
  tags          = var.tags
}

# Addon version data sources
data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}
data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}
data "aws_eks_addon_version" "kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}
data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

# ─────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────
output "cluster_name" { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "cluster_ca" { value = aws_eks_cluster.main.certificate_authority[0].data }
output "oidc_provider_arn" { value = aws_iam_openid_connect_provider.cluster.arn }
output "oidc_issuer_url" { value = aws_eks_cluster.main.identity[0].oidc[0].issuer }
