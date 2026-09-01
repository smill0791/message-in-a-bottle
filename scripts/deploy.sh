#!/usr/bin/env bash
# Roll the running fleet onto the artifact currently in S3.
#
#   ./scripts/deploy.sh              # refresh and wait for it to finish
#   ./scripts/deploy.sh --no-wait    # start it and return
#
# Assumes scripts/package.sh has already published the artifact.
#
# ---------------------------------------------------------------------------
# Why this script has to exist
#
# The obvious mental model - "upload the new build and the Auto Scaling group
# picks it up" - is wrong, and wrong in a way that looks fine. The instances
# download the artifact once, in user data, at first boot. Publishing a new
# object to the same S3 key changes nothing the ASG can observe: the launch
# template is byte for byte identical, so no replacement is triggered and the
# fleet happily serves the old build forever.
#
# The pipeline would go green. The site would not change. That is the failure
# this script prevents, by asking for the replacement explicitly.
# ---------------------------------------------------------------------------

set -euo pipefail

cd "$(dirname "$0")/.."

REGION="${AWS_REGION:-us-east-2}"
WAIT=true
[[ "${1:-}" == "--no-wait" ]] && WAIT=false

if [[ -z "${AWS_PROFILE:-}" && -z "${CI:-}" ]]; then
    export AWS_PROFILE=aws-dev-project
fi

# --------------------------------------------------------------- discovery --

PROJECT="${PROJECT_NAME:-bottle}"

# Find the group by tag, not by name and not from Terraform state.
#
# The name is unknowable in advance: the ASG uses name_prefix so that
# create_before_destroy can build a replacement alongside the original, which
# means every rebuild produces a different generated suffix.
#
# Reading it from `terraform output` would work, but it would drag Terraform, a
# backend init and S3 state access into a job whose entire purpose is to copy a
# file and call one API. The Project tag is already applied to every resource by
# the provider's default_tags, so it is a stable handle that costs nothing.
ASG="${ASG_NAME:-}"
if [[ -z "$ASG" ]]; then
    ASG=$(aws autoscaling describe-auto-scaling-groups \
        --filters "Name=tag:Project,Values=$PROJECT" \
        --region "$REGION" \
        --query 'AutoScalingGroups[0].AutoScalingGroupName' \
        --output text 2>/dev/null || true)
fi

# describe returns the string "None" for no match, not an empty string.
if [[ -z "$ASG" || "$ASG" == "None" ]]; then
    echo "no Auto Scaling group tagged Project=$PROJECT in $REGION." >&2
    echo "the stack is not up. bring it up first, or set ASG_NAME." >&2
    exit 1
fi

# A name discovered by tag is known to exist. One supplied by hand is not, and
# describe returns an empty list rather than an error for an unknown group, so
# it has to be checked rather than relied on to throw.
if [[ -n "${ASG_NAME:-}" ]]; then
    found=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ASG" \
        --region "$REGION" \
        --query 'length(AutoScalingGroups)' --output text)

    if [[ "$found" != "1" ]]; then
        echo "Auto Scaling group '$ASG' does not exist in $REGION." >&2
        exit 1
    fi
fi

echo "=== rolling $ASG ==="

# ----------------------------------------------------------------- refresh --

# MinHealthyPercentage 50 keeps one of the two instances serving throughout, so
# the site stays up while the other is replaced. InstanceWarmup must clear the
# bootstrap time - these instances run `npm ci` at boot, which is not fast on a
# t4g.micro - or the group calls an instance healthy before the app is
# listening and moves straight on to killing the other one.
refresh_id=$(aws autoscaling start-instance-refresh \
    --auto-scaling-group-name "$ASG" \
    --region "$REGION" \
    --preferences '{
        "MinHealthyPercentage": 50,
        "InstanceWarmup": 300,
        "SkipMatching": false
    }' \
    --query 'InstanceRefreshId' --output text)

echo "refresh started: $refresh_id"

if [[ "$WAIT" != "true" ]]; then
    echo "not waiting (--no-wait)"
    exit 0
fi

# -------------------------------------------------------------------- wait --

# No `aws autoscaling wait` exists for instance refreshes, so this polls.
#
# The timeout is generous because a rolling replacement of two instances that
# each install dependencies at boot genuinely takes a while, but it is bounded:
# a refresh that stalls must fail the job rather than hang the pipeline until
# GitLab's own timeout kills it with no useful message.
deadline=$(( SECONDS + 1800 ))
last=""

while true; do
    read -r status pct <<<"$(aws autoscaling describe-instance-refreshes \
        --auto-scaling-group-name "$ASG" \
        --instance-refresh-ids "$refresh_id" \
        --region "$REGION" \
        --query 'InstanceRefreshes[0].[Status,PercentageComplete]' \
        --output text)"

    [[ "$pct" == "None" ]] && pct=0

    if [[ "$status:$pct" != "$last" ]]; then
        echo "  $status ${pct}%"
        last="$status:$pct"
    fi

    case "$status" in
        Successful)
            echo "=== refresh complete ==="
            # Emitted so the calling job can put a real, clickable URL in the
            # Slack message instead of "the deploy finished". Written to a file
            # as well as stdout because GitLab jobs cannot export variables to
            # later steps any other way.
            alb=$(aws elbv2 describe-load-balancers \
                --names "${PROJECT}-alb" \
                --region "$REGION" \
                --query 'LoadBalancers[0].DNSName' \
                --output text 2>/dev/null || true)
            if [[ -n "$alb" && "$alb" != "None" ]]; then
                echo "url: http://$alb"
                echo "http://$alb" > .deploy-url
            fi
            exit 0
            ;;
        Failed | Cancelled | RollbackSuccessful | RollbackFailed)
            echo "refresh ended in state: $status" >&2
            aws autoscaling describe-instance-refreshes \
                --auto-scaling-group-name "$ASG" \
                --instance-refresh-ids "$refresh_id" \
                --region "$REGION" \
                --query 'InstanceRefreshes[0].StatusReason' --output text >&2
            exit 1
            ;;
    esac

    if (( SECONDS > deadline )); then
        echo "timed out after 30 minutes waiting for the refresh" >&2
        echo "the refresh is still running; check the console before retrying" >&2
        exit 1
    fi

    sleep 15
done
