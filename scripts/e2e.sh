#!/usr/bin/env bash
# End-to-end smoke test of the core loop against a local Postgres.
#
# Exercises the real HTTP surface a user would hit: register, write, discover,
# open, rate, keep, report. Approval is done directly in SQL because the
# moderation queue has no UI yet.
#
# Run with the API already listening:
#   npm run db:reset && npm run dev &   # then
#   ./scripts/e2e.sh

set -uo pipefail

API="${API:-http://127.0.0.1:3000}"

pass=0
fail=0

sql() { docker exec -i bottle-db psql -U bottle -d bottle -qtA -c "$1" | tr -d ' \n'; }

# api METHOD PATH [JAR] [JSON]
# Deliberately no `curl -f`: we want to see error bodies, not an empty string.
api() {
    local method="$1" path="$2" jar="${3:-}" json="${4:-}"
    local args=(-s -X "$method" "$API$path")
    [[ -n "$jar" ]] && args+=(-b "$jar" -c "$jar")
    [[ -n "$json" ]] && args+=(-H 'content-type: application/json' -d "$json")
    curl "${args[@]}"
}

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        printf '  \033[32mPASS\033[0m %s\n' "$label"
        pass=$((pass + 1))
    else
        printf '  \033[31mFAIL\033[0m %s\n        expected: %s\n        got:      %s\n' \
            "$label" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

jar_a=$(mktemp); jar_b=$(mktemp)
trap 'rm -f "$jar_a" "$jar_b"' EXIT

suffix=$RANDOM
a="writer_$suffix"
b="reader_$suffix"
pw="correct-horse-battery"
creds_a=$(printf '{"handle":"%s","password":"%s"}' "$a" "$pw")
creds_b=$(printf '{"handle":"%s","password":"%s"}' "$b" "$pw")

echo "=== health ==="
check "healthz is shallow and ok" '"status":"ok"' "$(api GET /healthz)"
check "readyz reports database ok" '"ok":true' "$(api GET /readyz)"

echo "=== auth ==="
check "register author" "\"handle\":\"$a\"" "$(api POST /auth/register "$jar_a" "$creds_a")"
check "register reader" "\"handle\":\"$b\"" "$(api POST /auth/register "$jar_b" "$creds_b")"
check "duplicate handle rejected" "taken" "$(api POST /auth/register "" "$creds_a")"
check "wrong password rejected" "wrong handle or password" \
    "$(api POST /auth/login "" "$(printf '{"handle":"%s","password":"nope-nope-nope"}' "$a")")"
check "unknown handle rejected" "wrong handle or password" \
    "$(api POST /auth/login "" "$(printf '{"handle":"ghost_%s","password":"%s"}' "$suffix" "$pw")")"
check "session resolves" "\"handle\":\"$b\"" "$(api GET /auth/me "$jar_b")"
check "anonymous is refused" "not signed in" "$(api GET /auth/me)"

echo "=== writing ==="
letter="Some days the tide goes out further than you expect. It always comes back."
check "message accepted" '"status":"pending"' \
    "$(api POST /messages "$jar_a" "$(printf '{"body":"%s"}' "$letter")")"
check "links rejected" "links are not allowed" \
    "$(api POST /messages "$jar_a" '{"body":"check out https://buy-my-thing.com"}')"
check "bare domain rejected" "links are not allowed" \
    "$(api POST /messages "$jar_a" '{"body":"find me at buy-my-thing.shop today"}')"
long=$(printf 'x%.0s' {1..501})
check "over-long body rejected" "500 characters at most" \
    "$(api POST /messages "$jar_a" "$(printf '{"body":"%s"}' "$long")")"
check "empty body rejected" "write something first" \
    "$(api POST /messages "$jar_a" '{"body":"   "}')"

echo "=== pending messages are not discoverable ==="
check "beach is empty before approval" '"empty":true' "$(api GET /beach "$jar_b")"

echo "=== approve, then discover ==="
sql "update messages set status='approved' where author_id=(select id from users where handle='$a')" >/dev/null
beach=$(api GET /beach "$jar_b")
check "bottle appears after approval" '"empty":false' "$beach"
mid=$(printf '%s' "$beach" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
check "author does not see own bottle" '"empty":true' "$(api GET /beach "$jar_a")"

echo "=== opening ==="
opened=$(api POST "/beach/$mid/open" "$jar_b")
check "opening reveals the letter" "the tide goes out" "$opened"
check "first open is flagged" '"firstTime":true' "$opened"
check "re-open is idempotent" '"firstTime":false' "$(api POST "/beach/$mid/open" "$jar_b")"
check "discovery recorded exactly once" "1" "$(sql "select count(*) from discoveries where message_id='$mid'")"
check "bottle does not wash up twice" '"empty":true' "$(api GET /beach "$jar_b")"
check "opening a bogus id is refused" "bottle is gone" \
    "$(api POST "/beach/00000000-0000-0000-0000-000000000000/open" "$jar_b")"

echo "=== rating ==="
check "rating accepted" '"resonated":true' \
    "$(api PUT "/chest/$mid/rating" "$jar_b" '{"theme":"hopeful","resonated":true}')"
check "resonance counted once" "1" "$(sql "select resonated_count from message_stats where message_id='$mid'")"
api PUT "/chest/$mid/rating" "$jar_b" '{"theme":"reflective","resonated":false}' >/dev/null
check "changing mind decrements" "0" "$(sql "select resonated_count from message_stats where message_id='$mid'")"
check "rating counted once across updates" "1" "$(sql "select rating_count from message_stats where message_id='$mid'")"
check "invalid theme rejected" "invalid rating" \
    "$(api PUT "/chest/$mid/rating" "$jar_b" '{"theme":"furious","resonated":true}')"

echo "=== keeping ==="
check "keep it" '"saved":true' "$(api PUT "/chest/$mid" "$jar_b" '{"saved":true}')"
check "chest holds it" "the tide goes out" "$(api GET /chest "$jar_b")"
api PUT "/chest/$mid/favorite" "$jar_b" '{"favorited":true}' >/dev/null
check "favouriting implies keeping" "t" "$(sql "select saved and favorited from discoveries where message_id='$mid'")"
check "put it back" '"saved":false' "$(api PUT "/chest/$mid" "$jar_b" '{"saved":false}')"
check "discovery survives putting it back" "1" "$(sql "select count(*) from discoveries where message_id='$mid'")"

echo "=== reporting ==="
check "cannot report an undiscovered bottle" "have not found" \
    "$(api POST "/messages/$mid/report" "$jar_a" '{"reason":"spam"}')"
check "report accepted" "take a look" \
    "$(api POST "/messages/$mid/report" "$jar_b" '{"reason":"off_vibe"}')"
api POST "/messages/$mid/report" "$jar_b" '{"reason":"off_vibe"}' >/dev/null
check "duplicate report counted once" "1" "$(sql "select report_count from message_stats where message_id='$mid'")"

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
