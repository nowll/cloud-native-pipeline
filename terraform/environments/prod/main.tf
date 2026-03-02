terraform {
  required_version = ">= 1.7"

  backend "s3" {
    # Configured via -backend-config in CI
    encrypt = true
  }

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

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "prod"
      ManagedBy   = "terraform"
      Project     = var.project_name
      Repository  = "github.com/your-org/your-repo"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

locals {
  cluster_name = "${var.project_name}-prod"
  azs          = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
}

# ─────────────────────────────────────────────
# Network
# ─────────────────────────────────────────────
module "vpc" {
  source = "../../modules/vpc"

  cluster_name       = local.cluster_name
  vpc_cidr           = "10.0.0.0/16"
  availability_zones = local.azs
  log_retention_days = 90
  tags               = {}
}

# ─────────────────────────────────────────────
# EKS Cluster
# ─────────────────────────────────────────────
module "eks" {
  source = "../../modules/eks"

  cluster_name        = local.cluster_name
  kubernetes_version  = "1.29"
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  public_subnet_ids   = module.vpc.public_subnet_ids

  # Node groups
  node_instance_types  = ["m7g.2xlarge", "m6g.2xlarge"]
  node_desired_count   = 3
  node_min_count       = 3
  node_max_count       = 20
  spot_desired_count   = 3
  spot_max_count       = 30

  # Access
  public_access        = false
  log_retention_days   = 90
  tags                 = {}
}

# ─────────────────────────────────────────────
# RDS Aurora PostgreSQL
# ─────────────────────────────────────────────
module "rds" {
  source = "../../modules/rds"

  cluster_name       = local.cluster_name
  engine_version     = "16.2"
  instance_class     = "db.r8g.2xlarge"
  instance_count     = 3
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.database_subnet_ids
  deletion_protection = true
  backup_retention   = 30
  tags               = {}
}

# ─────────────────────────────────────────────
# Helm: Core Platform Add-ons
# ─────────────────────────────────────────────

# AWS Load Balancer Controller
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.2"

  set { name = "clusterName"; value = module.eks.cluster_name }
  set { name = "serviceAccount.create"; value = "true" }
  set { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"; value = aws_iam_role.alb_controller.arn }
  set { name = "replicaCount"; value = "2" }
  set { name = "podDisruptionBudget.maxUnavailable"; value = "1" }
}

# Cluster Autoscaler
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = "9.36.0"

  set { name = "autoDiscovery.clusterName"; value = module.eks.cluster_name }
  set { name = "awsRegion"; value = var.aws_region }
  set { name = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"; value = aws_iam_role.cluster_autoscaler.arn }
  set { name = "extraArgs.scale-down-delay-after-add"; value = "5m" }
  set { name = "extraArgs.scale-down-unneeded-time"; value = "5m" }
  set { name = "extraArgs.balance-similar-node-groups"; value = "true" }
  set { name = "extraArgs.skip-nodes-with-system-pods"; value = "false" }
}

# KEDA (event-driven autoscaling)
resource "helm_release" "keda" {
  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  namespace  = "keda"
  version    = "2.14.0"
  create_namespace = true

  set { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"; value = aws_iam_role.keda.arn }
}

# Cert-Manager
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  version          = "v1.14.4"
  create_namespace = true

  set { name = "installCRDs"; value = "true" }
  set { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"; value = aws_iam_role.cert_manager.arn }
  set { name = "replicaCount"; value = "2" }
}

# External Secrets Operator
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  version          = "0.9.15"
  create_namespace = true

  set { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"; value = aws_iam_role.external_secrets.arn }
  set { name = "replicaCount"; value = "2" }
}

# Kube-Prometheus Stack (Prometheus + Grafana + Alertmanager)
resource "helm_release" "kube_prometheus" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  version          = "58.2.2"
  create_namespace = true
  timeout          = 600

  values = [file("${path.module}/values/kube-prometheus-stack.yaml")]
}

# Loki
resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  namespace        = "monitoring"
  version          = "6.3.0"
  create_namespace = true

  values = [file("${path.module}/values/loki.yaml")]
}

# OpenTelemetry Operator
resource "helm_release" "otel_operator" {
  name             = "opentelemetry-operator"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  namespace        = "observability"
  version          = "0.56.0"
  create_namespace = true

  set { name = "manager.collectorImage.repository"; value = "otel/opentelemetry-collector-k8s" }
}

# Falco (runtime security)
resource "helm_release" "falco" {
  name             = "falco"
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falco"
  namespace        = "security"
  version          = "4.2.2"
  create_namespace = true

  set { name = "driver.kind"; value = "ebpf" }
  set { name = "falcosidekick.enabled"; value = "true" }
  set { name = "falcosidekick.config.slack.webhookurl"; value = var.slack_webhook_url }
}

# Argo CD
resource "helm_release" "argocd" {
  name             = "argo-cd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  version          = "7.1.1"
  create_namespace = true

  values = [file("${path.module}/values/argocd.yaml")]
}

# ─────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────
output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "rds_endpoint" { value = module.rds.cluster_endpoint }
output "vpc_id" { value = module.vpc.vpc_id }
