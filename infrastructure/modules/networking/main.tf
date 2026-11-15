data "aws_availability_zones" "available" {
  state = "available"

  # Exclude zones that are not enabled for this account/region, otherwise
  # subnet creation fails with an obscure "unauthorized" error.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  # One /24 per AZ carved from the VPC range. A /16 VPC yields /24 subnets,
  # which leaves room for many more subnets if the design ever needs private
  # subnets or a second environment tier.
  public_subnet_cidrs = [
    for index in range(var.availability_zone_count) :
    cidrsubnet(var.vpc_cidr, 8, index)
  ]
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Required for the ALB and for Fargate task ENIs to resolve names such as the
  # ECR and CloudWatch endpoints.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(
    {
      Name = "${var.name_prefix}-vpc"
    },
    var.tags,
  )
}

resource "aws_subnet" "public" {
  count = var.availability_zone_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # ADR-002: Fargate tasks run in public subnets to avoid NAT Gateway cost.
  #
  # Note: this attribute does not govern awsvpc task ENIs. Public IP assignment
  # for a Fargate task is controlled by `assign_public_ip` on the ECS service's
  # network configuration. It is set here so the subnet's intent is explicit and
  # so anything else launched in it behaves consistently.
  map_public_ip_on_launch = true

  tags = merge(
    {
      Name = "${var.name_prefix}-public-${local.azs[count.index]}"
      Tier = "public"
    },
    var.tags,
  )
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(
    {
      Name = "${var.name_prefix}-igw"
    },
    var.tags,
  )
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(
    {
      Name = "${var.name_prefix}-public"
    },
    var.tags,
  )
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
