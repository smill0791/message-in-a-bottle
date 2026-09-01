#!/usr/bin/env bash
# Post a message to Slack via an Incoming Webhook.
#
#   ./scripts/slack-notify.sh "text"
#   ./scripts/slack-notify.sh --status ok    "Deployed" "extra context"
#   ./scripts/slack-notify.sh --status fail  "Deploy failed"
#
# Requires SLACK_WEBHOOK_URL, a masked GitLab CI/CD variable.
#
# Silent no-op when that variable is unset, which is deliberate: notification
# is not the point of the pipeline, and a missing webhook must never be the
# reason a good build goes red. Adding the variable later lights this up with
# no change to the pipeline.

set -euo pipefail

STATUS="info"
if [[ "${1:-}" == "--status" ]]; then
    STATUS="$2"
    shift 2
fi

TEXT="${1:-(no message)}"
CONTEXT="${2:-}"

if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    echo "slack: SLACK_WEBHOOK_URL not set, skipping notification"
    echo "slack: would have sent [$STATUS] $TEXT"
    exit 0
fi

case "$STATUS" in
    ok) emoji=":white_check_mark:" ;;
    fail) emoji=":x:" ;;
    start) emoji=":rocket:" ;;
    *) emoji=":information_source:" ;;
esac

# CI_* are absent when this is run from a laptop, so every one of them is
# defaulted rather than left to trip `set -u`.
commit="${CI_COMMIT_SHORT_SHA:-local}"
branch="${CI_COMMIT_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
project="${CI_PROJECT_NAME:-message-in-a-bottle}"
pipeline="${CI_PIPELINE_URL:-}"

footer="$project · $branch@$commit"
[[ -n "$pipeline" ]] && footer="$footer · <$pipeline|pipeline>"
[[ -n "$CONTEXT" ]] && footer="$CONTEXT"$'\n'"$footer"

# Built with jq so that a URL or an apostrophe in the message cannot break out
# of the JSON string. Hand-rolled interpolation here would be a quoting bug
# waiting to happen, and it would only show up on the message that mattered.
payload=$(jq -n \
    --arg text "$emoji $TEXT" \
    --arg footer "$footer" \
    '{
        text: $text,
        blocks: [
            { type: "section", text: { type: "mrkdwn", text: $text } },
            { type: "context", elements: [ { type: "mrkdwn", text: $footer } ] }
        ]
    }')

# --fail so a webhook that has been revoked surfaces as an error here rather
# than a silent 404, but the caller decides whether that should fail the job.
if curl -sS --fail -X POST -H 'Content-type: application/json' \
    --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null; then
    echo "slack: sent [$STATUS] $TEXT"
else
    echo "slack: webhook rejected the message" >&2
    exit 1
fi
