# ECS Quick Start

This guide walks through a complete deployment from zero to a running store. Complete all steps in [Prerequisites](prerequisites.md) before starting.

---

## Step 1: Clone the Repository

```bash
git clone https://github.com/easecloudio/magento2-aws-ecs-terraform.git
cd magento2-aws-ecs-terraform
```

---

## Step 2: Edit `developer.config.yaml`

Open `developer.config.yaml` and set at minimum:

```yaml
brand: &brand mystore          # Short identifier — used in all resource names
codename: magento              # Secondary identifier (combined: mystore-magento)

domain: &domain "mystore.com"
san: &san
  - "*.mystore.com"
aliases:
  - *domain
  - *san

sns:
  topic:
    budget:
      email:
        - "ops@mystore.com"
    devops:
      email:
        - "ops@mystore.com"
    security:
      email:
        - "ops@mystore.com"
```

**Important constraints:**
- `brand` and `codename` together form the project prefix (`mystore-magento`) that is embedded in every resource name. Changing these after the first apply requires a destroy and recreate of all resources.
- The `domain` value must match a domain you control. Route 53 will host the zone; update your registrar's nameservers after apply.

All other values in the file have working defaults for a developer environment. Review the [Configuration Reference](config-reference.md) for a full field description.

---

## Step 3: Create the S3 Backend Bucket

If you have not already created a state bucket:

```bash
aws s3 mb s3://mystore-tfstate --region us-east-1
```

---

## Step 4: Create `state.config`

Create a `state.config` file at the repo root (do not commit this file):

```hcl
bucket               = "mystore-tfstate"
key                  = "magento2-ecs"
region               = "us-east-1"
workspace_key_prefix = "workspaces"
```

---

## Step 5: Initialize Terraform

```bash
terraform init -backend-config=state.config
```

This downloads all provider plugins and modules. Expect it to pull roughly 20+ modules from the Terraform registry on first run.

---

## Step 6: Create the `developer` Workspace

Terraform reads `developer.config.yaml` when the active workspace is named `developer`. The workspace name maps directly to the config file name.

```bash
terraform workspace new developer
```

---

## Step 7: Plan

```bash
terraform plan -out developer.plan
```

Review the output. A clean first-run plan creates approximately 250–300 resources. Key things to verify:
- The `local.project` name appears correctly in resource names (e.g. `mystore-magento-alb`).
- The AWS region shown in provider configuration matches your intended region.
- No existing resources conflict with the names being created.

---

## Step 8: Apply

```bash
terraform apply developer.plan
```

The apply takes 20–40 minutes on a fresh account, primarily due to Aurora cluster creation, OpenSearch domain provisioning, and CloudFront distribution deployment.

---

## Step 9: Confirm SNS Subscription Email

Immediately after apply, AWS sends subscription confirmation emails to the addresses configured under `sns.topic.*.email`. You must click the confirmation link in each email to activate alerts. Alerts will not fire until subscriptions are confirmed.

There are three topics: `budget`, `devops`, and `security`. Each address listed under those topics receives a separate confirmation email.

---

## Step 10: Update Route 53 Nameservers

Terraform creates a Route 53 hosted zone for your domain. Retrieve the nameservers:

```bash
aws route53 list-hosted-zones-by-name --dns-name mystore.com \
  --query 'HostedZones[0].Id' --output text \
  | xargs -I{} aws route53 get-hosted-zone --id {} \
  --query 'DelegationSet.NameServers'
```

Log in to your domain registrar and replace the existing nameservers with the four values returned. DNS propagation typically takes 15 minutes to 48 hours depending on the registrar and TTL of existing records.

---

## Step 11: Add ACM Certificate Validation Records

This project sets `create_route53_records = false` in ACM module calls and `validate_certificate = false`, so certificate validation is not automated. After apply:

1. Go to AWS Console > Certificate Manager.
2. Find the two pending certificates (one in your deployment region, one in `us-east-1` for CloudFront).
3. For each certificate, click into the domain, then copy the CNAME name and value shown under "Domains".
4. Add those CNAME records to your Route 53 hosted zone.

Once the nameservers are delegated and the CNAME records exist, validation completes automatically — usually within 30 minutes.

---

## Step 12: Build and Push Docker Images to ECR

Retrieve the ECR repository URLs from Terraform output:

```bash
terraform output ecr_repository_urls
```

This returns a map such as:

```
{
  "backend"  = "123456789012.dkr.ecr.us-east-1.amazonaws.com/mystore-magento-backend"
  "imgproxy" = "123456789012.dkr.ecr.us-east-1.amazonaws.com/mystore-magento-imgproxy"
  "varnish"  = "123456789012.dkr.ecr.us-east-1.amazonaws.com/mystore-magento-varnish"
}
```

Authenticate and push (ARM64 images required — all ECS tasks run on Graviton):

```bash
AWS_REGION=us-east-1
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin \
    ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Push backend
docker buildx build --platform linux/arm64 \
  -t 123456789012.dkr.ecr.us-east-1.amazonaws.com/mystore-magento-backend:latest \
  --push /path/to/backend

# Push varnish
docker buildx build --platform linux/arm64 \
  -t 123456789012.dkr.ecr.us-east-1.amazonaws.com/mystore-magento-varnish:latest \
  --push /path/to/varnish

# Push imgproxy
docker buildx build --platform linux/arm64 \
  -t 123456789012.dkr.ecr.us-east-1.amazonaws.com/mystore-magento-imgproxy:latest \
  --push /path/to/imgproxy
```

After the first push, ECS tasks will be able to pull the images and start. The ECS service deployment circuit breaker will roll back automatically if a task fails to reach a running state.

---

## Step 13: Deploy the First Magento Release

Package your Magento application from its root directory:

```bash
tar -czf release-$(date +%Y%m%d-%H%M%S).tar.gz -C /path/to/magento/root .
```

Upload to the releases S3 bucket. The bucket name follows the pattern `<project>-releases`:

```bash
aws s3 cp release-*.tar.gz s3://mystore-magento-releases/
```

Uploading the file automatically triggers an EventBridge rule, which invokes an SSM Automation document, which starts a CodeBuild job. The CodeBuild job (named `mystore-magento-deploy-release`) extracts the archive to EFS, links shared directories, and atomically switches the `/public/current` symlink.

See [Deploying Releases](../operations/deploying-releases.md) for the full pipeline description.

---

## Step 14: Verify the Deployment

Check ECS task status:

```bash
# List running tasks for the backend cluster
aws ecs list-tasks \
  --cluster mystore-magento-backend-ecs-cluster \
  --desired-status RUNNING

# Check varnish cluster
aws ecs list-tasks \
  --cluster mystore-magento-varnish-ecs-cluster \
  --desired-status RUNNING
```

Check the health endpoint through the ALB (from within the VPC or via the CloudFront domain after DNS propagates):

```bash
curl -I https://mystore.com/health_check.php
```

A 200 response confirms the backend container is serving requests through Varnish, ALB, and CloudFront.

Monitor the CodeBuild release job:

AWS Console > CodeBuild > Build projects > `mystore-magento-deploy-release` > Build history.

---

## Step 15: Production Hardening Tips

Before moving traffic to a production environment, make the following changes in your `production.config.yaml` (create this file as a copy of `developer.config.yaml` and switch with `terraform workspace new production`):

**Enable deletion protection on the database:**
```yaml
aurora:
  deletion_protection: true
  skip_final_snapshot: false
  backup_retention_period: "30"
```

**Enable ALB deletion protection:**
```yaml
alb:
  enable_deletion_protection: true
```

**Switch CloudFront to production (disable staging flag):**
```yaml
cloudfront:
  staging: false
  wait_for_deployment: true
```

**Enable multi-AZ for database and cache:**
```yaml
vpc:
  availability_zone_total: 2

aurora:
  multi_az: true
  autoscaling_max_capacity: 2

elasticache:
  multi_az: true
  cluster:
    session:
      num_cache_clusters: 2
    cache:
      num_cache_clusters: 2
```

**Use a larger OpenSearch instance for production catalog search:**
```yaml
opensearch:
  instance_type: "r7g.medium.search"
  instance_count: 2
```
