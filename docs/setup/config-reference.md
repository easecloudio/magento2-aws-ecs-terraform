# Configuration Reference

All infrastructure configuration lives in a single YAML file. The file is selected by the active Terraform workspace:

| Workspace | Config file |
|---|---|
| `developer` | `developer.config.yaml` |
| `staging` | `staging.config.yaml` |
| `production` | `production.config.yaml` |

Terraform reads the file via `yamldecode(file(...))` in `locals.tf`. All values are available as `local.env.<key>`. YAML anchors (`&name` / `*name`) are supported and used throughout the default config to avoid repetition.

**Warning:** `brand` and `codename` are baked into every resource name as `${brand}-${codename}`. Changing these after the first apply requires destroying and recreating all resources.

---

## Top-Level Keys

### `brand`

| Type | Default |
|------|---------|
| string | `easecloud` |

Short identifier for your project. Must be lowercase, no spaces. Combined with `codename` to form the `project` prefix used in every AWS resource name (e.g. `easecloud-magento-alb`, `easecloud-magento-aurora-cluster`).

### `codename`

| Type | Default |
|------|---------|
| string | `magento` |

Secondary identifier. Typically the application name. Used alongside `brand` in the project prefix.

### `budget_limit_amount`

| Type | Default |
|------|---------|
| string (numeric) | `"800"` |

Monthly budget threshold in USD. AWS Budgets sends SNS notifications when forecasted spend crosses 25%, 50%, 75%, 100%, 125%, and 150% of this value. Affects: `aws_budgets_budget`.

### `domain`

| Type | Default |
|------|---------|
| string | `"yourdomain.com"` |

Primary domain for the store. Used as the CloudFront alias, ALB listener host condition, ACM certificate domain, SES domain, and in imgproxy `IMGPROXY_ALLOW_ORIGIN`. Must be a domain you control.

### `san`

| Type | Default |
|------|---------|
| list of strings | `["*.yourdomain.com"]` |

Subject Alternative Names for the ACM certificates. Typically a wildcard for the primary domain.

### `aliases`

| Type | Default |
|------|---------|
| list | `[domain, san]` |

CloudFront distribution aliases. Usually constructed from YAML anchors pointing to `domain` and `san`.

---

## `sns`

Three SNS topics with email subscriber lists.

```yaml
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

| Key | Purpose |
|-----|---------|
| `budget` | Budget threshold and cost anomaly alerts |
| `devops` | ASG launch/terminate events, CodeBuild build results, SSM automation notifications |
| `security` | Reserved for security-related alerts |

Each address receives a subscription confirmation email on first apply. Alerts do not fire until subscriptions are confirmed.

---

## `vpc`

Controls the VPC and subnet layout. Affects the inline `./modules/vpc` module.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `cidr_block` | string | `"10.0.0.0/16"` | VPC CIDR. Subnets are carved from this with `/20` blocks. |
| `availability_zone_total` | int | `2` | Number of AZs to use. Private, public, and database subnets are created per AZ. |
| `enable_dns_support` | bool | `true` | Enable DNS resolution in the VPC. |
| `enable_dns_hostnames` | bool | `true` | Enable DNS hostnames for EC2 instances. |
| `instance_tenancy` | string | `"default"` | EC2 tenancy. Use `"dedicated"` only if required for compliance — significantly increases cost. |
| `create_database_subnet` | bool | `true` | Create dedicated database subnets and an RDS subnet group. Disable only if not using Aurora or RDS. |
| `exclude_zone_ids` | list | `["use1-az3"]` | AZ IDs to exclude when selecting availability zones. Useful for excluding zones that lack certain instance types (e.g. `use1-az3` lacks some ARM instance types). |

---

## `nat_gateway`

Configures the EC2-based NAT instance. Affects `./modules/vpc`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `single` | bool | `true` | Use one NAT instance for all AZs. Set `false` for one NAT instance per AZ (higher availability, higher cost). |
| `instance_type` | string | `"t4g.nano"` | EC2 instance type for the NAT instance. `t4g.nano` (~$0.50/mo) is sufficient for most workloads. |
| `ami_owner` | string | `"136693071363"` | AWS account ID that owns the AMI. The default value is the Debian official AMI owner. |
| `ami_image` | string | `"debian-13-arm64*"` | AMI name filter. Must resolve to an ARM64 image. |
| `volume_size` | int | `10` | Root EBS volume size in GB for the NAT instance. |
| `firewall` | bool | `true` | Reserved field; not currently used in the module logic. |

---

## `managed_services`

| Type | Default |
|------|---------|
| bool (YAML anchor) | `true` |

YAML anchor (`&create`) used as a shorthand in ElastiCache, RabbitMQ, and OpenSearch `create` fields. Set to `false` to skip creation of all managed services at once.

---

## `elasticache`

Controls ElastiCache Valkey clusters. Two clusters are created: `session` and `cache`. Affects `elasticache.tf`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `create` | bool | `true` | Create ElastiCache resources. |
| `multi_az` | bool | `false` | Enable Multi-AZ for replication groups. |
| `engine` | string | `"valkey"` | Cache engine. `valkey` is a Redis-compatible open-source engine. |
| `engine_version` | string | `"8.2"` | Engine version. |
| `parameter_group_family` | string | `"valkey8"` | Parameter group family matching the engine version. |

### `elasticache.cluster.session` and `elasticache.cluster.cache`

Each cluster supports the following keys:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `node_type` | string | `"cache.t4g.micro"` | ElastiCache node type. Graviton-based `t4g` types offer best price/performance. |
| `num_cache_clusters` | int | `1` | Number of cache clusters (nodes) in the replication group. Set to `availability_zone_total` for Multi-AZ. |
| `transit_encryption_enabled` | bool | `true` | Enable TLS for in-transit encryption. |
| `at_rest_encryption_enabled` | bool | `true` | Enable encryption at rest. |
| `maintenance_window` | string | `"sun:05:00-sun:09:00"` | Maintenance window in UTC. |
| `apply_immediately` | bool | `true` | Apply configuration changes immediately rather than at next maintenance window. |

### `elasticache.parameters`

Key-value map of ElastiCache parameters applied to the parameter group.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `maxmemory-policy` | `"allkeys-lru"` | Eviction policy. `allkeys-lru` evicts least-recently-used keys when memory is full. Appropriate for Magento cache. |

### `elasticache.metrics`

CloudWatch alarm definitions for CPU, memory (freeable), evictions, and connections. Each metric entry has `comparison_operator`, `evaluation_periods`, `metric_name`, `namespace`, `period`, `statistic`, `threshold`, and `dimensions`.

---

## `rabbitmq`

Controls Amazon MQ (RabbitMQ) broker. Affects `rabbitmq.tf`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `create` | bool | `true` | Create the MQ broker. |
| `engine_version` | string | `"3.13"` | RabbitMQ engine version. |
| `deployment_mode` | string | `"SINGLE_INSTANCE"` | Broker deployment mode. Options: `SINGLE_INSTANCE`, `ACTIVE_STANDBY_MULTI_AZ`, `CLUSTER_MULTI_AZ`. |
| `host_instance_type` | string | `"mq.t3.micro"` | Broker instance type. |
| `publicly_accessible` | bool | `false` | Do not expose broker publicly. Must be `false` for this architecture. |
| `apply_immediately` | bool | `true` | Apply changes immediately. |
| `auto_minor_version_upgrade` | bool | `true` | Allow automatic minor version upgrades. |
| `maintenance_window_start_time` | map | Sunday 00:30 GMT | Maintenance window for the broker. |
| `encryption_options.use_aws_owned_key` | bool | `false` | Use a customer-managed KMS key rather than the AWS-owned key. |
| `logs.general` | bool | `true` | Enable general log delivery to CloudWatch. |

---

## `opensearch`

Controls the Amazon OpenSearch domain. Affects `opensearch.tf`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `create` | bool | `true` | Create the OpenSearch domain. |
| `engine_version` | string | `"OpenSearch_2.19"` | OpenSearch engine version. |
| `instance_type` | string | `"t3.small.search"` | Data node instance type. For production use `r7g.medium.search` or larger. |
| `instance_count` | int | `1` | Number of data nodes. Set to `availability_zone_total` for Multi-AZ. |
| `multi_az` | bool | `false` | Enable Multi-AZ with standby. |
| `multi_az_with_standby_enabled` | bool | `false` | Enable dedicated standby node. |
| `ebs_enabled` | bool | `true` | Attach EBS volumes to data nodes. |
| `volume_type` | string | `"gp3"` | EBS volume type. |
| `volume_size` | string | `"10"` | EBS volume size in GB per data node. |
| `tls_security_policy` | string | `"Policy-Min-TLS-1-2-PFS-2023-10"` | TLS policy for HTTPS endpoint. |
| `dedicated_master_enabled` | bool | `false` | Enable dedicated master nodes. Recommended for clusters with 10+ data nodes. |
| `ip_address_type` | string | `"ipv4"` | IP address type for the domain. |
| `auto_software_update_enabled` | bool | `false` | Disable automatic software updates. |
| `auto_tune_options.desired_state` | string | `"DISABLED"` | OpenSearch Auto-Tune state. |

### `opensearch.metrics`

CloudWatch alarms for cluster status (red), JVM memory pressure, and free storage space.

---

## `aurora`

Controls the Aurora MySQL cluster. Affects `aurora.tf`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `create` | bool | `true` | Create Aurora cluster. Set `false` to use `rds` instead. |
| `engine` | string | `"aurora-mysql"` | Must be `aurora-mysql`. |
| `engine_version` | string | `"8.0"` | Aurora MySQL engine version. |
| `instance_class` | string | `"db.t3.medium"` | DB instance class. For production, use `db.r7g.large` or larger. |
| `master_username` | string | `*brand` | Database master username. Defaults to the brand name. |
| `database_name` | string | `*brand` | Default database name. |
| `multi_az` | bool | `false` | Use database subnets across multiple AZs. |
| `storage_encrypted` | bool | `true` | Encrypt storage at rest. |
| `storage_type` | string | `"gp3"` | Storage type for Aurora I/O-optimized (use `"aurora"` for standard). |
| `backup_retention_period` | string | `"30"` | Days to retain automated backups. |
| `skip_final_snapshot` | bool | `true` | Skip final snapshot on destroy. Set `false` for production. |
| `deletion_protection` | bool | `false` | Prevent accidental cluster deletion. Set `true` for production. |
| `enabled_cloudwatch_logs_exports` | list | `["audit","error","general","slowquery"]` | Log types to export to CloudWatch. |
| `cluster_performance_insights_enabled` | bool | `true` | Enable Performance Insights. |
| `cluster_performance_insights_retention_period` | int | `7` | Retention in days (7 free, 731 paid). |
| `autoscaling_enabled` | bool | `true` | Enable read replica autoscaling. |
| `autoscaling_min_capacity` | int | `1` | Minimum read replicas. |
| `autoscaling_max_capacity` | int | `2` | Maximum read replicas. |
| `apply_immediately` | bool | `true` | Apply changes immediately. |
| `copy_tags_to_snapshot` | bool | `true` | Copy resource tags to snapshots. |

### `aurora.parameters`

Key-value map of cluster and instance parameter group settings. Applied to both `db_cluster_parameter_group` and `db_parameter_group`.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `log_bin_trust_function_creators` | `1` | Required for Magento stored procedures. |
| `max_allowed_packet` | `268435456` | 256 MB. Required for large Magento import operations. |
| `max_connect_errors` | `10000` | Host blocking threshold. |
| `interactive_timeout` | `120` | Seconds before closing idle interactive connections. |
| `wait_timeout` | `300` | Seconds before closing idle non-interactive connections. |
| `innodb_lock_wait_timeout` | `60` | Lock wait timeout in seconds. |
| `tmp_table_size` | `{DBInstanceClassMemory/512}` | Dynamic based on instance memory. |
| `max_heap_table_size` | `{DBInstanceClassMemory/512}` | Dynamic based on instance memory. |

---

## `rds`

Standard RDS MySQL instance. Alternative to Aurora. Disabled by default (`create: false`). When enabled, uses the same parameter set as Aurora.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `create` | bool | `false` | Create an RDS instance. Use `aurora` instead for production. |
| `engine_version` | string | `"8.0"` | MySQL engine version. |
| `instance_class` | string | `"db.t3.micro"` | DB instance type. |
| `allocated_storage` | int | `20` | Initial storage in GB. |
| `max_allocated_storage` | int | `100` | Max storage for autoscaling. |
| `multi_az` | bool | `false` | Enable Multi-AZ standby. |
| `deletion_protection` | bool | `true` | Block accidental deletion. |

---

## `alb`

Controls the internal Application Load Balancer. Affects `alb.tf`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `ssl_policy` | string | `"ELBSecurityPolicy-TLS13-1-2-Res-2021-06"` | TLS policy for the HTTPS listener. This policy requires TLS 1.3 or TLS 1.2 with restricted cipher suites. |
| `enable_deletion_protection` | bool | `false` | Prevent ALB deletion. Set `true` for production. |
| `target_type` | string | `"ip"` | ECS Fargate-style IP-based target registration. Must be `"ip"` for ECS services. |
| `health_check_path` | string | `"/health_check.php"` | ALB health check endpoint on the backend. Must return HTTP 200. |
| `fixed_response.status_code` | string | `"418"` | Status code returned by the ALB default action when no rule matches (i.e., requests without the CloudFront secret header). |
| `fixed_response.message_body` | string | `"No targets are responding..."` | Body of the fixed response. |

### `alb.metrics`

CloudWatch alarms for 5xx error count, target response time, unhealthy host count, and ELB-level 5xx errors.

---

## `ecr`

Controls ECR private repositories. Affects `ecr.tf`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `create` | bool | `true` | Create ECR repositories. |
| `repository_type` | string | `"private"` | Repository visibility. |
| `create_lifecycle_policy` | bool | `true` | Create an image lifecycle policy. |
| `keep_images` | int | `5` | Number of images to retain per repository. |

### `ecr.repository`

Three repositories are configured: `imgproxy`, `backend`, `varnish`. Each has:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `create_repository` | bool | `true` | Create this specific repository. |
| `repository_image_tag_mutability` | string | `"MUTABLE"` | Allow overwriting existing tags (e.g. `latest`). |
| `repository_force_delete` | bool | `true` | Allow `terraform destroy` to delete the repository even if it contains images. |

---

## `ecs`

Controls ECS cluster and service configuration. Affects `ecs.tf` and `asg.tf`.

### `ecs.cluster`

Cluster-level capacity provider settings.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `minimum_scaling_step_size` | int | `1` | Minimum number of EC2 instances to add/remove in a single scaling action. |
| `maximum_scaling_step_size` | int | `6` | Maximum instances per scaling step. |
| `target_capacity` | int | `70` | Managed scaling target capacity utilization percentage. |
| `cpu` | int | `2048` | CPU units for the ECS task definition (1024 = 1 vCPU). |
| `memory` | int | `3072` | Memory in MB for the ECS task definition. |
| `cpu_architecture` | string | `"ARM64"` | Task CPU architecture. Must be `ARM64` to match the Graviton EC2 instances. |

### `ecs.container`

Per-container configuration. Two containers are defined by default: `varnish` and `backend`. Adding additional keys creates additional ECS clusters, services, and ASGs.

| Key | Type | Default (varnish) | Default (backend) | Description |
|-----|------|-------------------|-------------------|-------------|
| `image` | string | `"latest"` | `"latest"` | ECR image tag to use. |
| `port` | int | `80` | `80` | Container port. |
| `protocol` | string | `"tcp"` | `"tcp"` | Port protocol. |
| `instance_type` | string | `"t4g.micro"` | `"t4g.micro"` | EC2 instance type for the ASG launch template. Used as the base; the mixed instances policy may select other types. |
| `volume_size` | int | `30` | `30` | EBS root volume size in GB for ASG EC2 instances. |
| `cpu` | int | `2048` | `2048` | CPU units allocated to the container. |
| `memory` | int | `3072` | `3072` | Memory in MB allocated to the container. For Varnish, this also sets `VARNISH_SIZE`. |
| `desired_capacity` | int | `1` | `2` | Initial/desired number of EC2 instances in the ASG. |
| `min_size` | int | `1` | `2` | Minimum ASG instance count. |
| `max_size` | int | `2` | `6` | Maximum ASG instance count. |
| `secrets` | list | `["PROJECT"]` | `["AURORA_*", ...]` | SSM parameter names to inject as container secrets. Each name maps to `/<project>/<name>` in Parameter Store. |

The `varnish` container receives EFS mounts only on the `backend` container. The `backend` container mounts all three EFS access points (`public`, `shared`, `releases`) and sets its `workingDirectory` to `/home/<brand>/public/current`.

---

## `asg`

Auto Scaling Group configuration shared across all container ASGs. Affects `asg.tf`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `multi_az` | bool | `false` | Spread instances across all VPC private subnets. When `false`, instances launch in the primary AZ only. |
| `health_check_type` | string | `"EC2"` | ASG health check type. `"EC2"` uses EC2 instance status checks. |
| `protect_from_scale_in` | bool | `true` | Prevent the ASG from terminating instances during scale-in. ECS managed draining handles termination instead. |
| `instance_warmup` | int | `60` | Seconds to wait after an instance launches before including it in health metrics. |
| `use_mixed_instances_policy` | bool | `true` | Use the mixed instances policy to allow Spot instances. |
| `mixed_instances_policy.spot_allocation_strategy` | string | `"price-capacity-optimized"` | Spot allocation strategy. |

### `asg.override.instance_requirements`

Defines the flexible instance type constraints used in the mixed instances policy instead of a fixed instance type.

| Key | Default | Description |
|-----|---------|-------------|
| `vcpu_count.min` | `2` | Minimum vCPUs per instance. |
| `vcpu_count.max` | `4` | Maximum vCPUs per instance. |
| `memory_mib.min` | `4096` | Minimum memory in MiB (4 GB). |
| `memory_mib.max` | `8192` | Maximum memory in MiB (8 GB). |
| `instance_generations` | `["current"]` | Only use current-generation instance types. |
| `burstable_performance` | `"included"` | Allow burstable instance types (t4g family). |

---

## `s3`

Four S3 buckets are created. Each bucket name follows the pattern `<project>-<key>`.

### `s3.bucket.<key>`

| Key | Purpose | `eventbridge` | `versioning` | `intelligent_tiering` | `lifecycle_rule` |
|-----|---------|--------------|-------------|----------------------|-----------------|
| `media` | Product images, customer uploads | `false` | `false` | Enabled | Disabled |
| `releases` | Release tar.gz archives | `true` | `true` | Disabled | Disabled |
| `backup` | Database dumps and other backups | `true` | `true` | Disabled | Disabled |
| `logs` | ALB + CloudFront access logs | `false` | `false` | Enabled | Enabled |

| Field | Description |
|-------|-------------|
| `eventbridge` | Enable S3 EventBridge notifications. Required `true` for `releases` to trigger the deployment pipeline. |
| `versioning` | Enable S3 object versioning. |
| `intelligent_tiering.status` | `"Enabled"` or `"Disabled"`. When enabled, objects are automatically moved to ARCHIVE_ACCESS after 90 days. |
| `lifecycle_rule.status` | `"Enabled"` or `"Disabled"`. When enabled, objects are deleted after 91 days (used for log rotation). |

All buckets use SSE-KMS encryption. Access policies restrict each bucket to its intended principal (CloudFront for logs, CodeBuild for releases, ECS roles for media, SSM role for backup).

---

## `efs`

Three EFS access points are created on a single EFS file system.

| Access point | Container path | Mode | Purpose |
|---|---|---|---|
| `public` | `/home/<brand>/public` | read-only | Live release symlink (`current` → latest release) |
| `shared` | `/home/<brand>/shared` | read-write | `pub/media/` and `var/` persisted across deployments |
| `releases` | `/home/<brand>/releases` | read-only | Extracted release archives |

Each access point is configured with:

| Key | Default | Description |
|-----|---------|-------------|
| `uid` | `"1000"` | POSIX UID for access point root. |
| `gid` | `"1001"` | POSIX GID for access point root. |
| `permissions` | `"750"` (public/releases), `"770"` (shared) | Directory permissions. |
| `read_only` | `true` (public/releases), `false` (shared) | Mount mode in the container. |

---

## `cloudfront`

Controls the CloudFront distribution. Affects `cloudfront.tf`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `staging` | bool | `false` | Create as a staging distribution. Set `true` for testing new configurations without affecting production. |
| `wait_for_deployment` | bool | `false` | Block `terraform apply` until the distribution is fully deployed. |
| `http_version` | string | `"http2and3"` | Supported HTTP versions. |
| `price_class` | string | `"PriceClass_100"` | Edge location pricing tier. `PriceClass_100` covers North America and Europe. Use `PriceClass_All` for global coverage. |
| `origin_shield_enabled` | bool | `true` | Enable Origin Shield to reduce origin load. Origin Shield is placed in the same region as the origin. |
| `origin_ssl_protocols` | string | `"TLSv1.2"` | Minimum TLS version for origin connections. |
| `retain_on_delete` | bool | `false` | Keep the distribution when `terraform destroy` is run. Useful for production to prevent accidental deletion. |
| `is_ipv6_enabled` | bool | `true` | Enable IPv6 on the distribution. |
| `minimum_protocol_version` | string | `"TLSv1.3_2025"` | Minimum viewer-facing TLS version. |
| `path_pattern` | string | `"/media/catalog/product/*"` | Path pattern routed to the imgproxy Lambda URL origin. |
| `failover_criteria_status_codes` | list | `[403,404,500,503,504]` | HTTP status codes that trigger origin failover. |
| `create_monitoring_subscription` | bool | `true` | Enable CloudFront real-time metrics subscription (additional cost). |

---

## `waf`

Controls the WAFv2 web ACL attached to CloudFront. Affects `waf.tf` and `locals.tf`. The WAF is always created in `us-east-1` regardless of deployment region (CloudFront requirement).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `restricted_countries` | list | `[CN, RU, IR, KP, SD, SY, CU]` | ISO 3166-1 alpha-2 country codes to block. Used in both the WAF geo-match rule and the CloudFront geo-restriction. |
| `whitelist_ip` | list | `["1.2.3.4/32"]` | IP addresses (CIDR) to explicitly allow (priority 0, evaluated before all other rules). Add office IPs, CI/CD runner IPs, monitoring IPs. |
| `blacklist_ip` | list | `["5.6.7.8/32"]` | IP addresses (CIDR) to unconditionally block (priority 1). |

Additional WAF rules applied automatically (not configurable via YAML):
- Rate limit: 500 requests per IP per 120 seconds (priority 3)
- AWSManagedRulesCommonRuleSet (priority 4)
- AWSManagedRulesAmazonIpReputationList (priority 5)

---

## `lambda`

Controls the imgproxy Lambda function configuration. Affects `lambda.tf`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `memory_size` | int | `2048` | Lambda function memory in MB. imgproxy is memory-intensive; 2 GB is the recommended minimum. |
| `timeout` | int | `60` | Lambda function timeout in seconds. |
| `invoke_mode` | string | `"RESPONSE_STREAM"` | Lambda URL invocation mode. `RESPONSE_STREAM` allows streaming responses. |
| `tracing_mode` | string | `"Active"` | AWS X-Ray tracing mode. |
| `cloudwatch_logs_retention_in_days` | int | `30` | Log group retention period. |
| `logging_log_format` | string | `"JSON"` | Lambda log format. |

---

## `imgproxy`

Controls imgproxy container environment variables. The imgproxy container runs as a Lambda container image (ARM64). Affects `lambda.tf`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `image` | string | `"latest"` | ECR image tag for the imgproxy repository. |
| `port` | string | `"8080"` | Port imgproxy listens on inside the container. |
| `use_s3` | bool | `true` | Enable S3 source (`s3://` URIs). |
| `allow_insecure` | bool | `true` | Allow unsigned image URLs. Set `false` and configure `IMGPROXY_KEY`/`IMGPROXY_SALT` in SSM for signed URL verification. |
| `allow_origin` | string | `*domain` | `Access-Control-Allow-Origin` header value. Defaults to the primary domain. |
| `allowed_sources` | string | `"s3://,local://"` | Allowed source URL schemes. |
| `allowed_processing_options` | string | `"rs,fit,wm,soea"` | Comma-separated list of allowed processing options (`rs`=resize, `fit`=fit, `wm`=watermark, `soea`=strip other existing attachments). |
| `fallback_image_path` | string | `""` | Path to a fallback image when the source cannot be found. |
| `watermark_path` | string | `""` | Path to a watermark image. |
| `max_redirects` | int | `1` | Maximum number of source URL redirects to follow. |
| `ttl` | string | `"31536000"` | Cache TTL in seconds (1 year). Passed as the `Cache-Control: max-age` value. |
| `auto_webp` | bool | `true` | Serve WebP to browsers that support it. |
| `auto_avif` | bool | `true` | Serve AVIF to browsers that support it. |
| `quality` | string | `"70"` | Default image quality (1–100). |
| `format_quality` | string | `"jpeg=70,avif=40,webp=60"` | Per-format quality overrides. |
| `use_etag` | bool | `true` | Add ETag header to responses. |
| `enable_debug_headers` | bool | `true` | Add `X-Imgproxy-*` debug headers. Disable in production if exposing headers is a concern. |
| `log_format` | string | `"json"` | Log format (`json` or `text`). |
| `log_level` | string | `"warn"` | Log level (`error`, `warn`, `info`, `debug`). |
| `cloud_watch_service_name` | string | `"imgproxy"` | Service name dimension in CloudWatch metrics. |
| `cloud_watch_namespace` | string | `"imgproxy"` | CloudWatch metrics namespace. |
