variable "project" {
  type = string
}

variable "cidr_block" {
  type = string
}

variable "enable_dns_support" {
  type    = bool
  default = true
}

variable "enable_dns_hostnames" {
  type    = bool
  default = true
}

variable "instance_tenancy" {
  type    = string
  default = "default"
}

variable "availability_zone_total" {
  type    = number
  default = 2
}

variable "create_database_subnet" {
  type    = bool
  default = true
}

variable "exclude_zone_ids" {
  type    = list(string)
  default = []
}

variable "nat_gateway_single" {
  type    = bool
  default = true
}

variable "nat_gateway_instance_type" {
  type    = string
  default = "t4g.nano"
}

variable "nat_gateway_volume_size" {
  type    = number
  default = 10
}

variable "ami_owner" {
  type = string
}

variable "ami_image" {
  type = string
}
