#!/usr/bin/env bash
# Run an admin command against the deployed database.
#
#   ./scripts/remote-admin.sh status
#   ./scripts/remote-admin.sh seed
#   ./scripts/remote-admin.sh moderator driftwood
#
# ---------------------------------------------------------------------------
# How this reaches a database with no public endpoint
#
# RDS sits in the data subnets, which have no internet route at all, and the
# instance is in a private subnet with no inbound path. That is the design and
# it is worth keeping - so rather than opening a hole, this runs the admin CLI
# *on* an application instance, which is already inside the VPC and already
# holds the credentials.
#
# Session Manager carries the command. No SSH, no bastion, no key pair, no
# port open anywhere, and every invocation is recorded in CloudTrail against
# the identity that ran it.
#
# The alternative considered and rejected: a protected HTTP admin endpoint.
# That puts a privileged path on the public internet permanently in order to
# serve an operation performed roughly twice a release.
# ---------------------------------------------------------------------------

set -euo pipefail

cd "$(dirname "$0")/.."

REGION="${AWS_REGION:-us-east-2}"
PROJECT="${PROJECT_NAME:-bottle}"
APP_DIR=/opt/bottle

if [[ -z "${AWS_PROFILE:-}" && -z "${CI:-}" ]]; then
    export AWS_PROFILE=aws-dev-project
fi

if [[ $# -eq 0 ]]; then
    echo "usage: $0 <status|seed|moderator> [arg]" >&2
    exit 1
fi

# ------------------------------------------------------------------ target --

# Any instance will do: they are identical and the database is shared. Picking
# the first avoids making the caller find an instance id by hand.
INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT" \
              "Name=instance-state-name,Values=running" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || true)

if [[ -z "$INSTANCE" || "$INSTANCE" == "None" ]]; then
    echo "no running instance tagged Project=$PROJECT in $REGION." >&2
    echo "the stack is not up - bring it up before running admin commands." >&2
    exit 1
fi

echo "target: $INSTANCE"

# ----------------------------------------------------------------- command --

# Built as a quoted array and passed through jq, so a handle or filename
# containing a quote cannot break out of the JSON and become part of the
# command. This runs as root on a production instance; string-concatenating it
# would be the wrong place to save three lines.
#
# `set -a` exports everything in the env file, which is how the CLI receives
# DATABASE_URL and the RDS CA path. The file is 0600 and root-owned, and SSM
# RunShellScript runs as root, so it is readable here and nowhere else.
remote_cmd=$(printf 'set -a; . /etc/bottle.env; set +a; cd %s && node api/dist/admin.js' "$APP_DIR")
for arg in "$@"; do
    remote_cmd+=$(printf ' %q' "$arg")
done

params=$(jq -n --arg c "$remote_cmd" '{commands: [$c]}')

CMD_ID=$(aws ssm send-command \
    --document-name AWS-RunShellScript \
    --instance-ids "$INSTANCE" \
    --parameters "$params" \
    --region "$REGION" \
    --comment "bottle admin: $1" \
    --query 'Command.CommandId' --output text)

echo "command: $CMD_ID"

# -------------------------------------------------------------------- wait --

# `ssm wait command-executed` returns a non-zero exit for a failed command
# without printing why, so the output is fetched either way below.
aws ssm wait command-executed \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE" \
    --region "$REGION" 2>/dev/null || true

result=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE" \
    --region "$REGION" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' \
    --output text)

status=$(printf '%s' "$result" | head -1)

echo "--- output ---"
aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE" \
    --region "$REGION" \
    --query 'StandardOutputContent' --output text

stderr=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE" \
    --region "$REGION" \
    --query 'StandardErrorContent' --output text)

if [[ -n "$stderr" && "$stderr" != "None" ]]; then
    echo "--- stderr ---" >&2
    printf '%s\n' "$stderr" >&2
fi

if [[ "$status" != "Success" ]]; then
    echo "command finished with status: $status" >&2
    exit 1
fi
