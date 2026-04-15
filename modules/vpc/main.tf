
data "aws_availability_zones" "available" {
  state            = "available"
  exclude_zone_ids = var.exclude_zone_ids
}

locals {
  azs = slice(sort(data.aws_availability_zones.available.names), 0, var.availability_zone_total)
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  instance_tenancy     = var.instance_tenancy
  enable_dns_support   = var.enable_dns_support
  enable_dns_hostnames = var.enable_dns_hostnames
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index + 1)
  tags              = { Name = "${var.project}-private-${local.azs[count.index]}" }
}

resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.cidr_block, 4, count.index + 10)
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public-${local.azs[count.index]}" }
}

resource "aws_subnet" "database" {
  count             = var.create_database_subnet ? length(local.azs) : 0
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index + 6)
  tags              = { Name = "${var.project}-database-${local.azs[count.index]}" }
}

resource "aws_db_subnet_group" "this" {
  count      = var.create_database_subnet ? 1 : 0
  name       = "${var.project}-db-subnet-group"
  subnet_ids = aws_subnet.database[*].id
  tags       = { Name = "${var.project}-db-subnet-group" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-igw" }
}

# NAT via lightweight EC2 instance (cheaper than NAT Gateway — saves ~$32/mo per AZ)
data "aws_ami" "nat" {
  most_recent = true
  owners      = [var.ami_owner]
  filter {
    name   = "name"
    values = [var.ami_image]
  }
}

resource "aws_security_group" "nat" {
  name        = "${var.project}-nat-sg"
  vpc_id      = aws_vpc.this.id
  description = "NAT instance security group"
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-nat-sg" }
}

resource "aws_instance" "nat" {
  count                  = var.nat_gateway_single ? 1 : length(local.azs)
  ami                    = data.aws_ami.nat.id
  instance_type          = var.nat_gateway_instance_type
  subnet_id              = aws_subnet.public[count.index].id
  source_dest_check      = false
  vpc_security_group_ids = [aws_security_group.nat.id]
  root_block_device {
    volume_size = var.nat_gateway_volume_size
    volume_type = "gp3"
    encrypted   = true
  }
  user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    sysctl -w net.ipv4.ip_forward=1
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  EOF
  )
  tags = { Name = "${var.project}-nat-${count.index}" }
}

resource "aws_route_table" "private" {
  count  = length(local.azs)
  vpc_id = aws_vpc.this.id
  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat[var.nat_gateway_single ? 0 : count.index].primary_network_interface_id
  }
  tags = { Name = "${var.project}-private-rt-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
