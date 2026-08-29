/**
 * Compute: an Application Load Balancer in front of an Auto Scaling group.
 */

data "aws_ssm_parameter" "ami" {
  # Amazon Linux 2023, resolved at plan time. Pinning an AMI id would rot;
  # this always picks up the current patched image.
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.architecture}"
}

# ------------------------------------------------------------------- IAM ----

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

/**
 * Session Manager instead of SSH.
 *
 * The instances sit in private subnets with no inbound path, so there is
 * nothing to SSH to without a bastion. Session Manager gives shell access
 * through the SSM API instead: no key pairs to manage or leak, no port 22 open
 * anywhere, and every session is logged in CloudTrail.
 */
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  # The database password, read once at boot. Scoped to this one secret.
  statement {
    sid       = "ReadDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }

  # The deployment artifact. Read-only, and only this prefix.
  statement {
    sid       = "ReadArtifact"
    actions   = ["s3:GetObject"]
    resources = ["${var.artifact_bucket_arn}/*"]
  }

  statement {
    sid       = "ListArtifactBucket"
    actions   = ["s3:ListBucket"]
    resources = [var.artifact_bucket_arn]
  }

  # Application logs. The instance cannot be reached from outside, so shipping
  # logs out is the only way to see why a boot failed.
  statement {
    sid = "WriteLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${var.log_group_arn}:*"]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${var.name}-instance"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-instance"
  role = aws_iam_role.instance.name
  tags = var.tags
}

# --------------------------------------------------------- launch template --

resource "aws_launch_template" "app" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ssm_parameter.ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  vpc_security_group_ids = [var.app_sg_id]

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    region          = var.region
    app_port        = var.app_port
    db_secret_arn   = var.db_secret_arn
    db_host         = var.db_host
    db_port         = var.db_port
    db_name         = var.db_name
    artifact_bucket = var.artifact_bucket
    artifact_key    = var.artifact_key
    log_group       = var.log_group_name
    beach_size      = var.beach_size
  }))

  metadata_options {
    # IMDSv2 only. IMDSv1 lets any server-side request forgery in the app read
    # the instance role's credentials with a single unauthenticated GET.
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = var.detailed_monitoring
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 8
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-app" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.name}-app" })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------ load balancer --

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [var.alb_sg_id]

  # Deletion protection off for the same reason as the database: this stack is
  # meant to be destroyed after every session.
  enable_deletion_protection = false

  # Slightly longer than the default 60s. The discovery query is the slowest
  # path and a premature 504 during a load test would be measurement noise.
  idle_timeout = 75

  drop_invalid_header_fields = true

  tags = merge(var.tags, { Name = "${var.name}-alb" })
}

resource "aws_lb_target_group" "app" {
  name     = "${var.name}-tg"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  # The app tier is stateless - sessions live in Postgres - so requests can go
  # to any instance. No stickiness needed, which is the whole point of having
  # built it that way.
  target_type = "instance"

  health_check {
    enabled = true
    path    = "/healthz"

    # /healthz is shallow on purpose and does not touch the database. A deep
    # check here would fail every target at once during a brief RDS blip, leave
    # the load balancer with nowhere to route, and have the Auto Scaling group
    # replace a healthy fleet.
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Long enough for in-flight requests to finish on scale-in, short enough that
  # a destroy does not crawl.
  deregistration_delay = 30

  tags = merge(var.tags, { Name = "${var.name}-tg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = var.tags
}

# ------------------------------------------------------ auto scaling group --

resource "aws_autoscaling_group" "app" {
  name = "${var.name}-asg"

  vpc_zone_identifier = var.app_subnet_ids
  target_group_arns   = [aws_lb_target_group.app.arn]

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  /**
   * ELB health checks, not EC2.
   *
   * EC2 health checks only notice that the virtual machine is running. An
   * instance whose Node process has crashed passes an EC2 check indefinitely
   * while returning nothing. ELB checks ask whether it is actually serving.
   */
  health_check_type = "ELB"

  # npm ci on a micro instance is not fast. Too short a grace period and the
  # group kills instances mid-install, forever, in a loop.
  health_check_grace_period = var.health_check_grace_period

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # Replace instances when the launch template changes. This is the deployment
  # mechanism in Phase 3.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      # Keep the service up throughout. With two instances this replaces one at
      # a time.
      min_healthy_percentage = 50
      instance_warmup        = var.health_check_grace_period
    }
  }

  # Wait for instances to pass the ELB check before reporting success, so a
  # broken deploy fails the apply rather than looking clean.
  wait_for_capacity_timeout = "10m"
  min_elb_capacity          = var.min_size

  dynamic "tag" {
    for_each = merge(var.tags, { Name = "${var.name}-app" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

/**
 * Target tracking on CPU.
 *
 * Simpler and better behaved than step scaling: it works out its own alarms
 * and will not oscillate the way hand-written thresholds do. 50% leaves room
 * to absorb a spike while new instances boot, which on this image takes a
 * couple of minutes.
 */
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.name}-cpu"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target
  }
}
