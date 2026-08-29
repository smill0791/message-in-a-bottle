/**
 * Network: a three-tier VPC across two availability zones.
 *
 *   public  - the load balancer and the NAT gateway. Routes to the internet.
 *   app     - the EC2 instances. Outbound only, via NAT.
 *   data    - RDS. No route to the internet in either direction.
 *
 * Two AZs rather than three. Two is the minimum an Application Load Balancer
 * accepts and the minimum that makes an AZ failure survivable; a third adds
 * cost and teaches nothing further here.
 */

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # 10.0.0.0/16 carved into /24s, grouped by tier so the numbering itself
  # documents the layout:
  #   public 10.0.0.x   app 10.0.10.x   data 10.0.20.x
  public_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  app_cidrs    = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 10)]
  data_cidrs   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 20)]
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both required for RDS to get a resolvable endpoint name.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

# ------------------------------------------------------------------ subnets --

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # The ALB needs a public IP in each subnet. Instances never live here.
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_subnet" "app" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.app_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-app-${local.azs[count.index]}"
    Tier = "app"
  })
}

resource "aws_subnet" "data" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.data_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-data-${local.azs[count.index]}"
    Tier = "data"
  })
}

# ---------------------------------------------------------------------- NAT --

/**
 * One NAT gateway, not one per AZ.
 *
 * A production build puts a NAT in every AZ so a zone failure cannot cut
 * outbound traffic for the others. At roughly $33/month each against a $120
 * credit balance, that redundancy would consume the budget to demonstrate a
 * failure mode we will never trigger. One is a deliberate, costed trade, not
 * an oversight.
 *
 * Toggleable because it is the single most expensive resource here. With
 * enable_nat_gateway = false the app tier has no outbound route, which is
 * fine for inspecting the network layout without paying for it.
 */

resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-eip" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(var.tags, { Name = "${var.name}-nat" })

  depends_on = [aws_internet_gateway.this]
}

# ------------------------------------------------------------- route tables --

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-rt-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

/**
 * One private route table per AZ.
 *
 * They are identical today because there is a single NAT gateway, but keeping
 * them per-AZ means adding a second NAT later is a one-line change rather than
 * a restructure - and it avoids the trap where an AZ routes its outbound
 * traffic across a zone boundary without anyone noticing.
 */
resource "aws_route_table" "app" {
  count = var.az_count

  vpc_id = aws_vpc.this.id
  tags = merge(var.tags, {
    Name = "${var.name}-rt-app-${local.azs[count.index]}"
  })
}

resource "aws_route" "app_nat" {
  count = var.enable_nat_gateway ? var.az_count : 0

  route_table_id         = aws_route_table.app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "app" {
  count = var.az_count

  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# The data tier gets a route table with no internet route at all. Deliberate:
# a database has no business reaching the internet, and an empty route table
# makes that explicit rather than implied.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-rt-data" })
}

resource "aws_route_table_association" "data" {
  count = var.az_count

  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# ----------------------------------------------------------------- endpoint --

/**
 * S3 gateway endpoint. Free, and worth having.
 *
 * Instances pull their deployment artifact from S3 on boot. Without this it
 * goes out through the NAT gateway and is billed per gigabyte; with it the
 * traffic never leaves the VPC. Gateway endpoints cost nothing, unlike
 * interface endpoints.
 */
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    aws_route_table.app[*].id,
    [aws_route_table.public.id],
  )

  tags = merge(var.tags, { Name = "${var.name}-vpce-s3" })
}
