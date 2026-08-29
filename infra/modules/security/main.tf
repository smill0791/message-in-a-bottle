/**
 * Security groups, chained by reference rather than by CIDR.
 *
 *   internet -> alb -> app -> db
 *
 * Every rule between tiers names the *source security group*, never an IP
 * range. That is the difference between "the load balancer may reach the app"
 * and "anything that happens to be in 10.0.10.0/24 may reach the app". When
 * the Auto Scaling group replaces an instance the new private IP is covered
 * automatically, and a CIDR rule would quietly permit anything else that lands
 * in that range.
 *
 * Rules are separate resources rather than inline blocks. Inline `ingress`
 * blocks fight with anything that modifies rules out of band and produce
 * permanent diffs.
 */

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public entry point. Accepts web traffic from the internet."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "Application instances. Reachable only from the load balancer."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-app" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "Database. Reachable only from the application tier."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-db" })

  lifecycle {
    create_before_destroy = true
  }
}

# -------------------------------------------------------------- ALB ingress --

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"

  tags = var.tags
}

/**
 * HTTPS is created only when a certificate exists.
 *
 * Opening 443 without a listener behind it would be a rule that permits
 * traffic nothing answers - misleading to anyone reading the group later.
 * See the note on TLS in the root module: it needs a domain name.
 */
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count = var.enable_https ? 1 : 0

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from anywhere"

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"

  tags = var.tags
}

# The load balancer may only talk to the app tier, and only on the app port.
resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id = aws_security_group.alb.id
  description       = "Forward to application instances"

  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"

  tags = var.tags
}

# -------------------------------------------------------------- app ingress --

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id = aws_security_group.app.id
  description       = "Application traffic from the load balancer only"

  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"

  tags = var.tags
}

/**
 * Outbound to anywhere.
 *
 * Instances need to reach the package repositories on boot, S3 for the
 * deployment artifact, and Secrets Manager for the database credentials.
 * Narrowing this to specific prefix lists is possible but brittle - AWS
 * service ranges change - and the instances sit in a private subnet with no
 * inbound path from the internet, so the exposure is limited.
 */
resource "aws_vpc_security_group_egress_rule" "app_outbound" {
  security_group_id = aws_security_group.app.id
  description       = "Package repositories, S3, Secrets Manager"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"

  tags = var.tags
}

# --------------------------------------------------------------- db ingress --

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id = aws_security_group.db.id
  description       = "Postgres from the application tier only"

  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"

  tags = var.tags
}

/**
 * The database has no egress rule at all.
 *
 * Removing the default allow-all egress means a compromised database instance
 * cannot open an outbound connection to exfiltrate anything. RDS is managed by
 * AWS and does not need to originate traffic for normal operation.
 */
