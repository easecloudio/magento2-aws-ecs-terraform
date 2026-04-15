# Prerequisites

This document covers everything you need in place before running `terraform init`.

---

## AWS Account

You need an AWS account with sufficient permissions to create IAM roles, VPCs, ECS clusters, RDS clusters, and all associated resources.

For an initial deployment, an IAM user or role with `AdministratorAccess` is the simplest option. For production, scope permissions down to the specific services this project uses (ECS, EC2, RDS, ElastiCache, OpenSearch, MQ, S3, CloudFront, WAF, Lambda, EFS, SSM, CodeBuild, EventBridge, Route 53, ACM, SES, SNS, CloudWatch, Budgets).

---

## AWS CLI v2

Install and configure the AWS CLI:

```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
```

Configure credentials:

```bash
aws configure
# AWS Access Key ID: ...
# AWS Secret Access Key: ...
# Default region name: us-east-1
# Default output format: json
```

Reference: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

---

## Terraform >= 1.9

This project uses `use_lockfile = true` in the S3 backend, which requires Terraform 1.9 or later.

```bash
# macOS
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

# Linux (official binary)
curl -fsSL https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip -o tf.zip
unzip tf.zip && sudo mv terraform /usr/local/bin/
```

Verify: `terraform version`

Reference: https://developer.hashicorp.com/terraform/install

---

## S3 Bucket for Terraform State

Create an S3 bucket to store remote state. The bucket name must be globally unique.

```bash
aws s3 mb s3://your-tfstate-bucket --region us-east-1
```

Optionally enable versioning for state recovery:

```bash
aws s3api put-bucket-versioning \
  --bucket your-tfstate-bucket \
  --versioning-configuration Status=Enabled
```

---

## `state.config` File

The `backend.tf` in this project configures an S3 backend with `use_lockfile = true` (S3-native locking, no DynamoDB required). Create a `state.config` file at the root of the repo to supply the backend values at `terraform init` time. This file should not be committed to version control.

Example `state.config`:

```hcl
bucket               = "your-tfstate-bucket"
key                  = "magento2-ecs"
region               = "us-east-1"
workspace_key_prefix = "workspaces"
```

| Field | Purpose |
|-------|---------|
| `bucket` | The S3 bucket created above |
| `key` | The object key prefix for state files |
| `region` | AWS region where the bucket lives |
| `workspace_key_prefix` | Prefix that separates per-workspace state files |

Pass it at init time:

```bash
terraform init -backend-config=state.config
```

---

## Domain Name

You need a domain name for which you can update nameservers. Terraform creates a Route 53 hosted zone during apply. After the first apply, retrieve the nameserver values from the Route 53 console and update your registrar to delegate the zone.

ACM certificate validation uses DNS validation. Terraform requests the certificates, but because `create_route53_records = false` in `acm.tf`, you must manually add the CNAME validation records that ACM provides in the AWS Console after the first apply.

---

## SES Sandbox

New AWS accounts place SES in sandbox mode, which restricts outbound email to verified addresses only. Magento uses SMTP (via SES) for transactional email (order confirmations, password resets, etc.).

Before going live, request production SES access:
AWS Console > SES > Account Dashboard > Request production access.

Allow 24–48 hours for approval.

---

## ECR Container Images

Three container images must exist in ECR before ECS tasks can start. Terraform creates the ECR repositories during `apply`, but does not build or push images.

The three repositories are:

- `backend` — your Magento 2 PHP-FPM + Nginx image (ARM64)
- `varnish` — Varnish cache image (ARM64)
- `imgproxy` — imgproxy image for on-the-fly image optimization (ARM64)

After the first `terraform apply`, retrieve the repository URLs from the output:

```bash
terraform output ecr_repository_urls
```

Then authenticate Docker to ECR and push each image:

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=us-east-1

aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin \
    ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Build and push the backend image (must target linux/arm64)
docker buildx build --platform linux/arm64 \
  -t ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/<project>-backend:latest \
  --push ./backend

# Repeat for varnish and imgproxy
docker buildx build --platform linux/arm64 \
  -t ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/<project>-varnish:latest \
  --push ./varnish

docker buildx build --platform linux/arm64 \
  -t ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/<project>-imgproxy:latest \
  --push ./imgproxy
```

Replace `<project>` with the value of `${brand}-${codename}` from your config file (e.g. `easecloud-magento`).

---

## AWS Service Quotas

Check the following quotas in your target region before deploying. All are adjustable via the Service Quotas console.

| Service | Quota to check |
|---------|----------------|
| ECS | Running tasks per service (default 1000) |
| EC2 | Running On-Demand ARM instances — ensure your vCPU limit covers the `instance_requirements` range (2–4 vCPUs per container type, min_size instances each) |
| EC2 Spot | Spot instance vCPU limit for ARM instance families |
| ElastiCache | Clusters per region (default 100) |
| OpenSearch | Domains per region (default 5 in some accounts) |
| Amazon MQ | Brokers per region (default 20) |

For a developer configuration with default settings, a new account should be within limits. For production with `multi_az: true` and larger instance types, verify before applying.
