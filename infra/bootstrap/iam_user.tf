/**
 * The CI user - the fallback for a blocked OIDC path.
 *
 * Created only when enable_oidc is false, which on this account is always.
 * See the comment above aws_iam_openid_connect_provider in main.tf for why.
 *
 * ---------------------------------------------------------------------------
 * Why a user that can only assume roles, rather than a user with the
 * permissions attached directly
 *
 * The obvious shortcut is two users - one carrying the deploy policy, one
 * carrying PowerUserAccess - with their keys pasted into GitLab. It works, and
 * it means the long-lived secret in GitLab *is* the permission. A leaked
 * terraform key would be immediate PowerUserAccess on the account, usable from
 * anywhere, until somebody notices and rotates it.
 *
 * Here the key grants exactly one capability: ask STS for a session as one of
 * two named roles. The permissions live on the roles and arrive as credentials
 * that expire in an hour. A leaked key is still bad - it can assume the
 * terraform role - but the blast radius is bounded by the role's policy rather
 * than by whatever the user happened to be granted, there is one credential to
 * rotate instead of two, and every use shows up in CloudTrail as an AssumeRole
 * with a session name naming the pipeline and job that did it.
 *
 * This is not as good as OIDC. OIDC has no long-lived credential at all, and
 * its trust policy pins the exact branch of the exact project. That guarantee
 * is unavailable here; the nearest substitute is marking the GitLab variables
 * protected so only protected branches can read them.
 * ---------------------------------------------------------------------------
 */

resource "aws_iam_user" "ci" {
  count = var.enable_oidc ? 0 : 1

  name = "${local.name}-ci"
  path = "/ci/"

  # No semicolons or commas: IAM tag values are restricted to
  # [\p{L}\p{Z}\p{N}_.:/=+\-@] and reject both.
  tags = merge(local.tags, {
    Name    = "${local.name}-ci"
    Purpose = "GitLab CI. Assumes roles only. Holds no permissions of its own."
  })
}

/**
 * The user's entire policy.
 *
 * Two actions on two named resources. No s3, no ec2, no iam - nothing but the
 * right to become one of these roles. If this policy ever grows a second
 * statement, the reasoning above has been abandoned.
 */
data "aws_iam_policy_document" "ci_user" {
  statement {
    sid     = "AssumeCIRoles"
    actions = ["sts:AssumeRole"]
    resources = [
      aws_iam_role.deploy.arn,
      aws_iam_role.terraform.arn,
    ]
  }
}

resource "aws_iam_user_policy" "ci" {
  count = var.enable_oidc ? 0 : 1

  name   = "${local.name}-ci-assume-only"
  user   = aws_iam_user.ci[0].name
  policy = data.aws_iam_policy_document.ci_user.json
}

/**
 * The access key.
 *
 * Terraform stores the secret in state. That is acceptable only because the
 * state bucket is encrypted, versioned, private, and this key can do nothing
 * except assume two roles. It would not be acceptable for a credential that
 * carried permissions directly.
 *
 * Rotation is `terraform taint` on this resource followed by apply, then
 * updating the two GitLab variables.
 */
resource "aws_iam_access_key" "ci" {
  count = var.enable_oidc ? 0 : 1

  user = aws_iam_user.ci[0].name
}
