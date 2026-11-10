# Magento 2 ECS Auto Scaling Cluster — Terraform

This repository contains a Terraform configuration that deploys a production-ready Magento 2 infrastructure on AWS.

**Developed and maintained by [EaseCloud](https://easecloud.io)** — cloud-native, AI-driven, and data infrastructure solutions. It provisions an ECS EC2 cluster (ARM Graviton) with separate Varnish and PHP-FPM backend tiers, Aurora MySQL, ElastiCache Valkey for sessions and cache, OpenSearch for catalog search, Amazon MQ for async queues, imgproxy for on-the-fly image optimization via Lambda, CloudFront CDN with WAF, an internal ALB, EFS for shared release storage, four S3 buckets, and a CodeBuild-based release pipeline triggered by S3 uploads via EventBridge. All service credentials are stored in SSM Parameter Store. Infrastructure is configured through a single YAML file per environment instead of Terraform variable files.

---

## Architecture

```
Internet
    |
+------------------+
|  CloudFront+WAF  |
+------------------+
    |            |
    |            +---------------------------+
    v                                        v
/media/catalog/product/*             All other requests
    |                                        |
    v                                        v
+---------------+              +------------------------+
| Lambda URL    |              | ALB (internal, VPC     |
| imgproxy ARM  |              | origin, secret header) |
+---------------+              +------------------------+
    |                                        |
    v                                        v
 S3 media                      ECS Varnish (EC2 ARM ASG)
                                             |
                                             v
                               ECS Backend (EC2 ARM ASG)
                                    |   |   |   |
                               Aurora ElastiCache OpenSearch MQ
                               MySQL  Valkey
                                    |       |
                                   EFS     S3
                               (releases) (media/backup)
```

---

## What's Included

- ECS EC2 clusters with separate Varnish and backend ASGs (ARM Graviton, mixed On-Demand + Spot)
- Aurora MySQL 8.0 with read replica autoscaling and Performance Insights
- ElastiCache Valkey 8.x — two clusters (session, cache) with TLS and encryption at rest
- OpenSearch 2.x for Magento catalog search
- Amazon MQ (RabbitMQ 3.13) for async queue processing
- imgproxy running as a Lambda container image (ARM64) behind CloudFront for image transformation
- CloudFront distribution with WAF ACL (IP lists, geo-blocking, rate limiting, AWS managed rules)
- Internal ALB (VPC origin) with HTTPS termination and CloudFront secret header enforcement
- EFS file system with three access points: `public` (read-only, symlinked releases), `shared` (writable), `releases` (extracted archives)
- S3 buckets: `media`, `releases`, `backup`, `logs`
- CodeBuild release pipeline: S3 upload → EventBridge → SSM Automation → CodeBuild → EFS symlink switch
- EC2 `t4g.nano` NAT instance (Debian ARM) instead of managed NAT Gateway (~$0.50/mo vs ~$32/mo per AZ)
- Route 53 hosted zone, ACM certificates (regional + us-east-1 for CloudFront)
- SES domain identity for transactional email
- SNS topics for budget, devops, and security alerts
- AWS Budgets with forecasted threshold alerts at 25%–150%
- Cost Anomaly Detection with immediate SNS notification
- SSM Parameter Store for all service credentials (passwords as SecureString)
- CloudWatch alarms for Aurora, ElastiCache, OpenSearch, ALB, and ASG metrics

---

## Cost Estimate

A developer configuration using the default `developer.config.yaml` (single AZ, `t4g` instance types, minimal node counts) runs approximately **$300–$450/month** depending on region and traffic volume. The largest cost drivers are Aurora (`db.t3.medium`), OpenSearch (`t3.small.search`), and Amazon MQ (`mq.t3.micro`).

A production configuration with Multi-AZ, larger instance types, and multiple read replicas runs approximately **$600–$900/month** before Reserved Instance discounts.

Use [Infracost](https://www.infracost.io/) for an accurate estimate against your specific configuration:

```bash
infracost breakdown --path .
```

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/easecloudio/magento2-aws-ecs-terraform.git
cd magento2-aws-ecs-terraform

# 2. Edit brand, domain, and email in developer.config.yaml

# 3. Create state bucket and state.config (see Prerequisites)
aws s3 mb s3://your-tfstate-bucket --region us-east-1

# 4. Initialize, create workspace, and deploy
terraform init -backend-config=state.config
terraform workspace new developer
terraform plan -out developer.plan
terraform apply developer.plan
```

After apply: confirm SNS subscription emails, update Route 53 nameservers at your registrar, add ACM DNS validation CNAME records, push Docker images to ECR, and upload your first release archive to the releases S3 bucket.

---

## Configuration

Infrastructure is configured through `developer.config.yaml` (or `staging.config.yaml` / `production.config.yaml` for other workspaces). There are no `.tfvars` files. The active workspace name determines which YAML file is loaded.

Minimum required changes before first apply:
- `brand` — short identifier embedded in all resource names
- `domain` — your store's domain
- `sns.topic.*.email` — alert notification addresses

See the full field reference: [docs/setup/config-reference.md](docs/setup/config-reference.md)

---

## Documentation

- [Prerequisites](docs/setup/prerequisites.md)
- [ECS Quick Start](docs/setup/ecs-quickstart.md)
- [Architecture Overview](docs/architecture/ecs-overview.md)
- [Deploying Releases](docs/operations/deploying-releases.md)
- [Configuration Reference](docs/setup/config-reference.md)

---

## About EaseCloud

EaseCloud is a cloud consulting and solutions company specializing in:

- Cloud-native application development
- AI & automation integrations
- DevOps and infrastructure management
- Magento 2 hosting and platform engineering

We built this project to provide a production-grade, open-source AWS infrastructure baseline for Magento 2 — demonstrating our expertise in cloud architecture, security, and automation.

If your team is scaling Magento 2 on AWS or needs help with infrastructure design, deployment pipelines, or managed support, [get in touch](https://easecloud.io).

📧 [support@easecloud.io](mailto:support@easecloud.io)
🌐 [easecloud.io](https://easecloud.io)

---

## Bug Reports & Issues

Found a bug or have a feature request?

🐛 [Create a GitHub issue](https://github.com/easecloudio/magento2-aws-ecs-terraform/issues)

Please include:
- Terraform version (`terraform version`)
- AWS provider version
- Workspace name and relevant config excerpt (redact credentials)
- Steps to reproduce
- Expected vs actual behavior
- Any error messages from `terraform plan` or `terraform apply`

---

## License

MIT — see [LICENSE](LICENSE)
