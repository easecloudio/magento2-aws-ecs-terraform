
//////////////////////////////////////////////////////////////[ OUTPUTS ]//////////////////////////////////////////////////

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  value       = module.cloudfront.cloudfront_distribution_domain_name
}

output "alb_dns_name" {
  description = "Internal ALB DNS name"
  value       = module.alb.dns_name
}

output "ecr_repository_urls" {
  description = "ECR repository URLs for each container image"
  value       = { for k, v in module.ecr : k => v.repository_url }
}

output "ecs_cluster_names" {
  description = "ECS cluster names"
  value       = { for k, v in module.ecs_cluster : k => v.name }
}

output "aurora_cluster_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = try(module.aurora.cluster_endpoint, null)
}

output "opensearch_endpoint" {
  description = "OpenSearch domain endpoint"
  value       = try(module.opensearch.domain_endpoint, null)
}

output "ssm_parameter_prefix" {
  description = "SSM Parameter Store path prefix for all service config"
  value       = "/${local.project}/"
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}
