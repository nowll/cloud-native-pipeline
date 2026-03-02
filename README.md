# Cloud-Native Infrastructure Pipeline

A production-grade cloud-native CI/CD pipeline demonstrating advanced infrastructure automation, security, GitOps, and observability — built for AWS EKS.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  GitHub Actions (CI/CD Orchestrator)                                │
│                                                                     │
│  push/PR ──► Code Quality ──► SAST ──► Test ──► Build & Sign        │
│                                               │                     │
│                                               ▼                     │
│                                    Image Scan (Trivy + Grype)       │
│                                               │                     │
│                               ┌───────────────┼────────────────┐   │
│                               ▼               ▼                ▼   │
│                         TF Plan (dev)  TF Plan (staging)  TF Plan(prod)│
│                               │               │                │   │
└───────────────────────────────┼───────────────┼────────────────┼───┘
                                ▼               ▼                ▼
              ┌─────────────────────────────────────────────────────┐
              │  AWS Infrastructure (Terraform)                     │
              │                                                     │
              │   VPC ──► EKS (multi-AZ) ──► Aurora PostgreSQL      │
              │    ├── 3× NAT Gateways                              │
              │    ├── Private/Public/DB subnets                    │
              │    └── VPC Flow Logs                                │
              │                                                     │
              │   EKS Node Groups:                                  │
              │    ├── System (Graviton3, reserved)                 │
              │    ├── Application (Bottlerocket, on-demand)        │
              │    └── Burst (Graviton3, Spot, 0→30 nodes)          │
              └─────────────────────────────────────────────────────┘
                                ▼
              ┌─────────────────────────────────────────────────────┐
              │  Kubernetes Platform (Helm + Kustomize)             │
              │                                                     │
              │  Deploy strategy:                                   │
              │   dev     → Rolling update (auto)                   │
              │   staging → Canary (10% → 50% → 100% w/ metrics)   │
              │   prod    → Blue/Green (instant cutover + rollback) │
              │                                                     │
              │  Core add-ons:                                      │
              │   ├── AWS LB Controller, Cluster Autoscaler, KEDA   │
              │   ├── Cert-Manager, External Secrets Operator       │
              │   ├── Kube-Prometheus + Grafana + Loki              │
              │   ├── OpenTelemetry Operator                        │
              │   ├── Falco (runtime security)                      │
              │   └── Argo CD (GitOps)                              │
              └─────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
.
├── .github/
│   └── workflows/
│       ├── ci-cd.yml          # Main pipeline (9 stages)
│       ├── terraform-apply.yml # Reusable TF apply workflow
│       └── scheduled-ops.yml  # Drift detection, dep updates, chaos
│
├── terraform/
│   ├── modules/
│   │   ├── vpc/               # Networking (subnets, NAT, flow logs)
│   │   ├── eks/               # EKS cluster + node groups + add-ons
│   │   └── rds/               # Aurora PostgreSQL
│   └── environments/
│       ├── dev/
│       ├── staging/
│       └── prod/              # Full platform stack
│
├── kubernetes/
│   ├── base/                  # Shared Kubernetes manifests
│   └── overlays/              # Per-environment Kustomize patches
│       ├── dev/
│       ├── staging/
│       └── prod/
│
├── helm/
│   └── app/                   # Application Helm chart
│       ├── Chart.yaml
│       ├── values.yaml        # Base values
│       ├── values.dev.yaml
│       ├── values.staging.yaml
│       └── values.prod.yaml
│
├── .argocd/
│   └── applicationset.yaml    # GitOps ApplicationSet (all envs)
│
├── scripts/
│   ├── monitor-canary.sh      # Real-time SLO monitoring for canary
│   ├── smoke-tests.sh
│   ├── e2e-tests.sh
│   └── health-check.sh
│
└── Dockerfile                 # Multi-stage, distroless final image
```

---

## Pipeline Stages

| Stage | Description | Key tools |
|-------|-------------|-----------|
| **1 · Code Quality** | Lint, static analysis, vuln check | golangci-lint, staticcheck, govulncheck |
| **2 · SAST** | Secret scanning, code analysis | TruffleHog, CodeQL |
| **3 · Test** | Unit + integration with real services | Go test, Postgres, Redis |
| **4 · Build** | Multi-arch image, SBOM, keyless signing | Buildx, Cosign (OIDC), SLSA |
| **5 · Image Scan** | CVE scanning of final image | Trivy, Grype |
| **6 · TF Plan** | Plan all envs in parallel, IaC scan | Terraform, tfsec, Checkov |
| **7 · Deploy Dev** | Rolling deploy + smoke tests | Helm, AWS EKS |
| **8 · Deploy Staging** | Canary 10%→50%→100% with Prometheus SLOs | Helm, custom monitor |
| **9 · Deploy Prod** | Blue/Green with auto-rollback | Helm, kubectl |

---

## Security Features

- **OIDC-based auth** — No long-lived AWS keys; GitHub Actions assumes IAM roles via OIDC federation
- **Keyless image signing** — Cosign with OIDC; every image signed and verified in the pipeline
- **SBOM generation** — Software Bill of Materials attached to every image (SPDX + CycloneDX)
- **IMDSv2 required** — All EC2/EKS nodes enforce IMDSv2 tokens
- **Bottlerocket nodes** — Minimal, read-only OS for application workloads
- **Distroless final image** — Zero shell, zero package manager in the container
- **Secrets from AWS Secrets Manager** — External Secrets Operator; no secrets in Git or env vars
- **Pod Security** — `readOnlyRootFilesystem`, dropped capabilities, non-root UID
- **KMS encryption** — EKS secrets, EBS volumes, S3 state bucket all KMS-encrypted
- **Falco runtime security** — Detects anomalous syscalls and sends alerts to Slack
- **Network Policies** — Strict ingress/egress rules per workload
- **tfsec + Checkov** — IaC security scanning on every PR

---

## Reliability Features

- **Multi-AZ deployment** — Nodes and NAT Gateways spread across 3 AZs
- **Topology spread constraints** — Pods balanced across zones AND nodes
- **PodDisruptionBudget** — Minimum 50% availability during disruptions
- **HPA + KEDA** — CPU/memory + event-driven autoscaling (0→50 pods)
- **Spot node group** — Burst capacity on Spot Instances (Graviton3 ARM64)
- **Blue/Green prod deploys** — Zero-downtime with instant rollback capability
- **Canary staging deploys** — Traffic weight increments gated by real Prometheus SLOs
- **Auto-rollback** — Pipeline rolls back traffic automatically on failure
- **Drift detection** — Every 6 hours, Terraform checks for config drift across all envs
- **Chaos testing** — Optional Chaos Mesh scenarios (pod failure, network partition, CPU stress)

---

## Observability Stack

| Signal | Tool | Storage |
|--------|------|---------|
| Metrics | Prometheus + kube-state-metrics | Thanos (S3-backed) |
| Logs | Fluent Bit → Loki | S3 |
| Traces | OpenTelemetry → Tempo | S3 |
| Dashboards | Grafana | — |
| Alerting | Alertmanager → PagerDuty + Slack | — |

---

## GitOps (Argo CD)

Deployments are managed by an **ApplicationSet** that generates one Argo CD Application per environment. The matrix generator crosses environments with Git paths — any push to `kubernetes/overlays/<env>/` triggers a sync.

- **Dev** — Auto-sync with self-heal enabled
- **Staging** — Manual promotion required (GitHub environment gate)
- **Production** — Manual approval + PagerDuty notification, `prune: false`

---

## Prerequisites

- AWS account with appropriate IAM roles
- GitHub repository secrets configured (see below)
- Terraform Cloud workspace or S3 backend

### Required Secrets

| Secret | Description |
|--------|-------------|
| `AWS_ROLE_ARN_DEV` | IAM role ARN for dev (OIDC) |
| `AWS_ROLE_ARN_STAGING` | IAM role ARN for staging (OIDC) |
| `AWS_ROLE_ARN_PROD` | IAM role ARN for production (OIDC) |
| `TF_API_TOKEN` | Terraform Cloud token |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook |
| `CODECOV_TOKEN` | Codecov upload token |
| `INFRACOST_API_KEY` | Infracost API key |

### Required Variables

| Variable | Description |
|----------|-------------|
| `AWS_REGION` | AWS region (e.g. `us-east-1`) |
| `TF_STATE_BUCKET` | S3 bucket for Terraform state |
| `TF_LOCK_TABLE` | DynamoDB table for state locking |
| `EKS_CLUSTER_DEV` | EKS cluster name (dev) |
| `EKS_CLUSTER_STAGING` | EKS cluster name (staging) |
| `EKS_CLUSTER_PROD` | EKS cluster name (prod) |

---

## Makefile Quick Reference

```bash
make tf-init ENV=prod         # Initialize Terraform
make tf-plan ENV=prod         # Plan changes
make tf-apply ENV=prod        # Apply (requires approval)
make helm-diff ENV=staging    # Diff Helm chart changes
make deploy ENV=dev           # Deploy to environment
make rollback ENV=prod        # Manual rollback
make chaos ENV=staging        # Run chaos test suite
make cost                     # Generate cost estimate
make lint                     # Run all linters
make test                     # Run full test suite
```

