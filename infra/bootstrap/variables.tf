variable "project_name" {
  description = "Prefix for every resource name. Matches the main stack."
  type        = string
  default     = "bottle"
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "aws_profile" {
  description = <<-EOT
    Same rule as the main stack: aws-dev-project locally, "" in CI.

    In practice this root is applied from a laptop. It is the bootstrap - it
    creates the role CI assumes, so CI cannot create it.
  EOT
  type        = string
  default     = "aws-dev-project"
}

variable "enable_oidc" {
  description = <<-EOT
    Federate to GitLab via OIDC instead of using an IAM user access key.

    Defaults to false because this account cannot do it. An apply on
    2026-08-29 was refused with an explicit deny on
    iam:CreateOpenIDConnectProvider from a service control policy belonging to
    the AWS-managed organization that Free Plan accounts sit inside
    (p-iyptwjyf). It is not editable from this account.

    Set to true if the account is ever moved to a plan without that SCP. The
    OIDC provider and the federated trust policy are already written and will
    take over automatically; the IAM user and its access key are destroyed in
    the same apply.
  EOT
  type        = bool
  default     = false
}

variable "gitlab_url" {
  description = "Issuer. Self-managed GitLab would use its own hostname."
  type        = string
  default     = "https://gitlab.com"
}

variable "gitlab_project_path" {
  description = <<-EOT
    Namespace and project, exactly as it appears in the repository URL.

    This is the security boundary. It is interpolated into the role's trust
    policy so that only pipelines belonging to this specific project can assume
    the role - without it, any GitLab.com pipeline in the world could.
  EOT
  type        = string
  default     = "aws-projects6841835/message-in-a-bottle"
}

variable "gitlab_audience" {
  description = <<-EOT
    Must match the `aud` of the id_token requested in .gitlab-ci.yml. A token
    minted for a different audience is rejected at assume-role time.
  EOT
  type        = string
  default     = "https://gitlab.com"
}

variable "deploy_ref" {
  description = <<-EOT
    The branch whose pipelines may deploy. Trust is scoped to this ref, so a
    pipeline on a feature branch or a fork's merge request cannot reach AWS
    even though it runs the same pipeline definition.
  EOT
  type        = string
  default     = "main"
}

variable "state_bucket" {
  description = "Terraform state bucket, created by scripts/bootstrap-state.sh. The CI role needs read/write on it to run plan and apply."
  type        = string
  default     = "bottle-tfstate-116307287000-us-east-2"
}
