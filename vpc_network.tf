

//////////////////////////////////////////////////[ VPC NETWORKING MODULE ]///////////////////////////////////////////////

# # ---------------------------------------------------------------------------------------------------------------------#
# Create VPC and base networking layout per environment
# # ---------------------------------------------------------------------------------------------------------------------#
module "vpc" {
  source                    = "./modules/vpc"
  project                   = local.project
  cidr_block                = local.env.vpc.cidr_block
  enable_dns_support        = local.env.vpc.enable_dns_support
  enable_dns_hostnames      = local.env.vpc.enable_dns_hostnames
  instance_tenancy          = local.env.vpc.instance_tenancy
  availability_zone_total   = local.env.vpc.availability_zone_total
  create_database_subnet    = local.env.vpc.create_database_subnet
  exclude_zone_ids          = local.env.vpc.exclude_zone_ids
  nat_gateway_single        = local.env.nat_gateway.single
  nat_gateway_instance_type = local.env.nat_gateway.instance_type
  nat_gateway_volume_size   = local.env.nat_gateway.volume_size
  ami_owner                 = local.env.nat_gateway.ami_owner
  ami_image                 = local.env.nat_gateway.ami_image
}
