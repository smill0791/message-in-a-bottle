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

# Start from an empty database.
#
# Several assertions ("the beach is empty before approval", "a bottle does not
# wash up twice") are statements about the whole pool, so leftover approved
# messages from a previous run make them fail. Re-running a green suite and
# watching it go red is the fastest way to stop trusting it.
#
# Restore the placeholder bottles afterwards with scripts/seed.sh.
sql "truncate discoveries, ratings, reports, message_stats, messages, sessions, users cascade" >/dev/null

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

echo "=== registration validation (regression: errors must name their field) ==="
both=$(api POST /auth/register "" '{"handle":"Ab","password":"short"}')
check "both field errors reported" "Password must be at least" "$both"
check "name error names the field" "Name must be" "$both"
check "short password names itself" "Password must be at least" \
    "$(api POST /auth/register "" "$(printf '{"handle":"short_pw_%s","password":"abcde1234"}' "$suffix")")"
check "dashes allowed in handle" "\"handle\":\"drift-wood-$suffix\"" \
    "$(api POST /auth/register "" "$(printf '{"handle":"drift-wood-%s","password":"abcde12345"}' "$suffix")")"

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

echo "=== moderation ==="

# Register a throwaway account and leave its cookie jar in $REPLY_JAR.
signup() {
    local name="$1"
    REPLY_JAR=$(mktemp)
    api POST /auth/register "$REPLY_JAR" "$(printf '{"handle":"%s","password":"abcde12345"}' "$name")" >/dev/null
}

signup "mod_$suffix";   mod_jar=$REPLY_JAR
signup "plain_$suffix"; plain_jar=$REPLY_JAR

check "admin queue hidden from ordinary users" "not found" "$(api GET /admin/queue "$plain_jar")"
check "admin queue hidden from anonymous"      "not found" "$(api GET /admin/queue)"

sql "update users set is_moderator = true where handle = 'mod_$suffix'" >/dev/null
check "moderator can read the queue" '"queue"' "$(api GET /admin/queue "$mod_jar")"
check "me reports moderator status" '"isModerator":true' "$(api GET /auth/me "$mod_jar")"

# A fresh submission sits pending until a moderator acts.
api POST /messages "$jar_a" '{"body":"A message that needs reviewing before it sails."}' >/dev/null
new_id=$(sql "select id from messages where body like 'A message that needs reviewing%' limit 1")
check "new submission appears in the queue" "$new_id" "$(api GET /admin/queue "$mod_jar")"
check "unreviewed item shows no reports" '"open_reports":0' "$(api GET /admin/queue "$mod_jar")"
check "approving works" '"status":"approved"' "$(api POST "/admin/messages/$new_id/approve" "$mod_jar")"
check "approved message left the queue" "0" \
    "$(sql "select count(*) from messages where id='$new_id' and status='pending'")"
check "double approval is refused" "already decided" \
    "$(api POST "/admin/messages/$new_id/approve" "$mod_jar")"
check "approval is attributed" "1" \
    "$(sql "select count(*) from messages where id='$new_id' and moderated_by is not null")"

echo "=== regression: a moderator decision must survive further reports ==="
# Three reporters push the message past the auto-pull threshold.
for n in 1 2 3; do
    signup "rep${n}_$suffix"
    eval "rep${n}_jar=\$REPLY_JAR"
    uid=$(sql "select id from users where handle='rep${n}_$suffix'")
    sql "insert into discoveries (user_id, message_id) values ('$uid','$new_id') on conflict do nothing" >/dev/null
done
api POST "/messages/$new_id/report" "$rep1_jar" '{"reason":"off_vibe"}' >/dev/null
api POST "/messages/$new_id/report" "$rep2_jar" '{"reason":"off_vibe"}' >/dev/null
api POST "/messages/$new_id/report" "$rep3_jar" '{"reason":"spam"}'     >/dev/null
check "three reports pull it from the beach" "pending" \
    "$(sql "select status from messages where id='$new_id'")"
check "queue flags it as reported" '"open_reports":3' "$(api GET /admin/queue "$mod_jar")"
check "queue lists the reasons" "off_vibe" "$(api GET /admin/queue "$mod_jar")"
check "queue marks it previously reviewed" '"previously_reviewed":true' \
    "$(api GET /admin/queue "$mod_jar")"

# The moderator decides the reports were unfounded and re-approves.
api POST "/admin/messages/$new_id/approve" "$mod_jar" >/dev/null
check "re-approval resolves the reports" "0" \
    "$(sql "select count(*) from reports where message_id='$new_id' and resolved=false")"

# One more complaint must NOT instantly undo that decision.
signup "rep4_$suffix"; rep4_jar=$REPLY_JAR
uid=$(sql "select id from users where handle='rep4_$suffix'")
sql "insert into discoveries (user_id, message_id) values ('$uid','$new_id') on conflict do nothing" >/dev/null
api POST "/messages/$new_id/report" "$rep4_jar" '{"reason":"spam"}' >/dev/null
check "a single new report does not re-pull it" "approved" \
    "$(sql "select status from messages where id='$new_id'")"
check "lifetime report count still accumulates" "4" \
    "$(sql "select report_count from message_stats where message_id='$new_id'")"

echo "=== rejection ==="
api POST /messages "$jar_a" '{"body":"Something that should not sail at all."}' >/dev/null
bad_id=$(sql "select id from messages where body like 'Something that should not sail%' limit 1")
check "rejecting works" '"status":"rejected"' "$(api POST "/admin/messages/$bad_id/reject" "$mod_jar")"
check "rejected message is not discoverable" "0" \
    "$(sql "select count(*) from messages where id='$bad_id' and status='approved'")"
check "ordinary user cannot approve" "not found" \
    "$(api POST "/admin/messages/$bad_id/approve" "$plain_jar")"

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
