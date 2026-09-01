/**
 * Bootstrap - the long-lived half of the infrastructure.
 *
 * Everything here outlives `terraform destroy` of the main stack, and that is
 * the entire reason it is a separate root. The main stack is torn down after
 * every working session; the identity CI uses to rebuild it obviously cannot
 * be torn down with it.
 *
 * Applied from a laptop, once. CI cannot apply this root - it creates the role
 * CI authenticates with, so doing it from CI would be circular.
 *
 *   cd infra/bootstrap && terraform init && terraform apply
 */

provider "aws" {
  region = var.region

  # Same reasoning as the main stack: "" must collapse to null, because an
  # empty profile name is still a lookup, for a profile called "".
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = local.tags
  }
}

locals {
  name = var.project_name

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
    Component = "bootstrap"
    Repo      = "gitlab.com/${var.gitlab_project_path}"
  }

  account_id = data.aws_caller_identity.current.account_id

  # The main stack names its artifact bucket from the account id. Reproduced
  # here rather than read from that stack's state, because that state is empty
  # whenever the stack is destroyed - which is most of the time.
  artifact_bucket = "${local.name}-artifacts-${local.account_id}"

  # GitLab's `sub` for a branch pipeline. Anchoring the trust policy on this
  # exact string is what stops another project's pipeline assuming the role.
  deploy_sub = "project_path:${var.gitlab_project_path}:ref_type:branch:ref:${var.deploy_ref}"
}

data "aws_caller_identity" "current" {}

# --------------------------------------------------------- identity provider --

/**
 * OIDC is the design this project wanted, and it is blocked on this account.
 *
 * `terraform apply` on 2026-08-29 failed with:
 *
 *   AccessDenied: not authorized to perform iam:CreateOpenIDConnectProvider
 *   on resource arn:aws:iam::116307287000:oidc-provider/gitlab.com with an
 *   explicit deny in a service control policy
 *   (arn:aws:organizations::714989832131:.../p-iyptwjyf)
 *
 * That SCP belongs to the AWS-managed organization every Free Plan account
 * sits inside, so it cannot be edited from here. The whole federated path -
 * no long-lived credential anywhere - is simply unavailable.
 *
 * The code is kept rather than deleted, behind a flag that defaults off. If
 * the account is ever upgraded to a plan without that SCP, flipping
 * enable_oidc to true restores the intended design and the roles' trust
 * policies switch back automatically. Deleting it would mean rediscovering all
 * of this later.
 *
 * The fallback is in iam_user.tf: a single IAM user whose only permission is
 * to assume these roles.
 */
data "tls_certificate" "gitlab" {
  count = var.enable_oidc ? 1 : 0
  url   = var.gitlab_url
}

resource "aws_iam_openid_connect_provider" "gitlab" {
  count = var.enable_oidc ? 1 : 0

  url = var.gitlab_url

  # Must match the `aud` in the id_token requested by .gitlab-ci.yml.
  client_id_list = [var.gitlab_audience]

  # Derived, not pasted: a hardcoded fingerprint from a blog post rots the
  # moment GitLab rotates its certificate.
  thumbprint_list = [data.tls_certificate.gitlab[0].certificates[0].sha1_fingerprint]

  tags = merge(local.tags, { Name = "${local.name}-gitlab-oidc" })
}

/**
 * Trust policy shared by both roles below. Which form it takes depends on
 * whether federation is available.
 *
 * OIDC form - three conditions, all of which matter:
 *   - the token was issued by GitLab (the Federated principal)
 *   - it was minted for our audience, so a token intended for another service
 *     cannot be replayed here
 *   - it belongs to a pipeline on the deploy branch of this exact project
 *
 * IAM user form - the CI user is the only principal that may assume these
 * roles, and that user can do nothing else whatsoever. The branch restriction
 * that `sub` gave us moves to GitLab's protected-branch settings, which is a
 * genuinely weaker guarantee and is recorded as such in RECAP.md.
 */
data "aws_iam_policy_document" "gitlab_assume" {
  dynamic "statement" {
    for_each = var.enable_oidc ? [1] : []
    content {
      actions = ["sts:AssumeRoleWithWebIdentity"]

      principals {
        type        = "Federated"
        identifiers = [aws_iam_openid_connect_provider.gitlab[0].arn]
      }

      condition {
        test     = "StringEquals"
        variable = "${replace(var.gitlab_url, "https://", "")}:aud"
        values   = [var.gitlab_audience]
      }

      condition {
        test     = "StringEquals"
        variable = "${replace(var.gitlab_url, "https://", "")}:sub"
        values   = [local.deploy_sub]
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_oidc ? [] : [1]
    content {
      actions = ["sts:AssumeRole"]

      principals {
        type        = "AWS"
        identifiers = [aws_iam_user.ci[0].arn]
      }
    }
  }
}

# ------------------------------------------------------------- deploy role --

/**
 * The role the automatic deploy job assumes on every merge to main.
 *
 * Genuinely least privilege: it can publish a build artifact and ask the Auto
 * Scaling group to roll the fleet onto it. It cannot create, modify or delete
 * infrastructure. A compromised pipeline running as this role can ship a bad
 * build - which a rollback fixes - but cannot spin up an instance, open a
 * security group, or read the database password.
 */
resource "aws_iam_role" "deploy" {
  name                 = "${local.name}-ci-deploy"
  description          = "GitLab CI: publish the artifact and roll the ASG. No infrastructure changes."
  assume_role_policy   = data.aws_iam_policy_document.gitlab_assume.json
  max_session_duration = 3600

  tags = merge(local.tags, { Name = "${local.name}-ci-deploy" })
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "PublishArtifact"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["arn:aws:s3:::${local.artifact_bucket}/*"]
  }

  statement {
    sid       = "ListArtifactBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.artifact_bucket}"]
  }

  /**
   * Instance refresh is the deploy mechanism.
   *
   * Uploading a new artifact to the same S3 key changes nothing the Auto
   * Scaling group can observe - the launch template is byte for byte
   * identical, so no replacement is triggered and the running fleet keeps
   * serving the old build indefinitely. The refresh has to be asked for
   * explicitly, which is what scripts/deploy.sh does.
   */
  statement {
    sid = "RollTheFleet"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:StartInstanceRefresh",
      "autoscaling:DescribeInstanceRefreshes",
      "autoscaling:CancelInstanceRefresh",
    ]
    resources = ["*"]
  }

  # Read-only, so the deploy job can report the ALB URL and confirm targets
  # came back healthy before declaring success.
  statement {
    sid = "ObserveTheLoadBalancer"
    actions = [
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "${local.name}-ci-deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

# ---------------------------------------------------------- terraform role --

/**
 * The role the manual stack:up / stack:down jobs assume.
 *
 * Broad, and honestly so. A role that runs `terraform apply` over a VPC, RDS
 * instance, load balancer and IAM instance profile needs to create and delete
 * all of those; pretending otherwise would mean a policy that has to be
 * widened every time the stack gains a resource, which fails at the worst
 * moment - halfway through a destroy, leaving billable resources orphaned.
 *
 * The containment is elsewhere: this role is only reachable from a pipeline on
 * main in this project, and only from jobs that a human has clicked. It is not
 * on the automatic path.
 */
resource "aws_iam_role" "terraform" {
  name                 = "${local.name}-ci-terraform"
  description          = "GitLab CI: apply and destroy the main stack. Manual jobs only."
  assume_role_policy   = data.aws_iam_policy_document.gitlab_assume.json
  max_session_duration = 3600

  tags = merge(local.tags, { Name = "${local.name}-ci-terraform" })
}

/**
 * PowerUserAccess covers every service in the stack but deliberately excludes
 * IAM, which is why the inline policy below exists.
 */
resource "aws_iam_role_policy_attachment" "terraform_poweruser" {
  role       = aws_iam_role.terraform.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "terraform_iam" {
  /**
   * IAM, scoped by name prefix.
   *
   * The stack creates an instance role, an inline policy and an instance
   * profile. Granting iam:* account-wide would let a pipeline mint itself an
   * administrator; restricting to bottle-* means the worst it can do is
   * rearrange its own application's roles.
   */
  statement {
    sid = "ManageStackRoles"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:PassRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${local.name}-*",
      "arn:aws:iam::${local.account_id}:instance-profile/${local.name}-*",
    ]
  }

  /**
   * Service-linked roles.
   *
   * The first apply in a fresh account fails without this: Auto Scaling needs
   * AWSServiceRoleForAutoScaling, which AWS normally creates on first console
   * use, and an account driven purely by API has never triggered that.
   */
  statement {
    sid       = "CreateServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "autoscaling.amazonaws.com",
        "rds.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "spot.amazonaws.com",
      ]
    }
  }

  # Terraform's own state. Without ListBucket the backend cannot enumerate
  # versions; without DeleteObject it cannot release a lock.
  statement {
    sid       = "TerraformStateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}/*"]
  }

  statement {
    sid       = "TerraformStateBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }
}

resource "aws_iam_role_policy" "terraform_iam" {
  name   = "${local.name}-ci-terraform-iam"
  role   = aws_iam_role.terraform.id
  policy = data.aws_iam_policy_document.terraform_iam.json
}

/**
 * The deploy role also needs state read access.
 *
 * Not to run Terraform - it has no permission to change anything - but so the
 * deploy job can read outputs (the ASG name, the ALB DNS name) instead of
 * having them pasted into CI variables where they would drift every time the
 * stack is rebuilt.
 */
data "aws_iam_policy_document" "deploy_state_read" {
  statement {
    sid       = "ReadTerraformState"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}/*"]
  }

  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }
}

resource "aws_iam_role_policy" "deploy_state_read" {
  name   = "${local.name}-ci-deploy-state"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_state_read.json
}
