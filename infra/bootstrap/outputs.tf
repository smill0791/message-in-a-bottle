output "deploy_role_arn" {
  description = "Set as the CI variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.deploy.arn
}

output "terraform_role_arn" {
  description = "Set as the CI variable AWS_TERRAFORM_ROLE_ARN."
  value       = aws_iam_role.terraform.arn
}

output "oidc_provider_arn" {
  description = "Null unless enable_oidc is true. See variables.tf for why it is off."
  value       = var.enable_oidc ? aws_iam_openid_connect_provider.gitlab[0].arn : null
}

output "auth_mode" {
  description = "Which authentication path this state is configured for."
  value       = var.enable_oidc ? "oidc" : "iam-user-assume-role"
}

output "trusted_subject" {
  description = "The GitLab pipeline identity pinned in the trust policy. Only meaningful under OIDC."
  value       = var.enable_oidc ? local.deploy_sub : null
}

output "ci_access_key_id" {
  description = "Set as the CI variable AWS_ACCESS_KEY_ID."
  value       = var.enable_oidc ? null : aws_iam_access_key.ci[0].id
}

/**
 * Marked sensitive so it is never printed by a bare `terraform output`, or by
 * an `apply` running in a pipeline where the log is retained.
 *
 * Read it deliberately:
 *
 *   terraform output -raw ci_secret_access_key
 */
output "ci_secret_access_key" {
  description = "Set as the CI variable AWS_SECRET_ACCESS_KEY. Read with: terraform output -raw ci_secret_access_key"
  value       = var.enable_oidc ? null : aws_iam_access_key.ci[0].secret
  sensitive   = true
}

/**
 * Printed so the values can be pasted straight into GitLab rather than
 * assembled by hand from several separate outputs.
 *
 * The secret is deliberately not included - it is read on its own, once, with
 * the command below, so it does not end up in scrollback alongside everything
 * else.
 */
output "ci_variables" {
  description = "Settings -> CI/CD -> Variables."
  value       = <<-EOT

    Settings -> CI/CD -> Variables. Mark all four Protected; mark the
    secret key Masked as well.

      AWS_DEPLOY_ROLE_ARN     = ${aws_iam_role.deploy.arn}
      AWS_TERRAFORM_ROLE_ARN  = ${aws_iam_role.terraform.arn}
      AWS_ACCESS_KEY_ID       = ${var.enable_oidc ? "(n/a - OIDC)" : aws_iam_access_key.ci[0].id}
      AWS_SECRET_ACCESS_KEY   = terraform output -raw ci_secret_access_key

    Protected matters here. The access key is the one long-lived credential
    in this project, and Protected keeps it readable only by pipelines on
    protected branches - which is the nearest available substitute for the
    branch pinning that the OIDC `sub` condition would have given us.

    Optional, add when you want deploy notifications:
      SLACK_WEBHOOK_URL     = https://hooks.slack.com/services/...  (Masked)
  EOT
}
