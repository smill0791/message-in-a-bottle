#!/usr/bin/env bash
# Grant moderator rights to an existing local account.
#
#   ./scripts/make-moderator.sh driftwood
#
# For the deployed database use ./scripts/remote-admin.sh moderator <handle>.
#
# Deliberately a script rather than a UI. Promoting a moderator is rare,
# consequential, and should leave a trace in shell history rather than being a
# button someone can click by accident.
#
# A shim over api/src/admin.ts, so local and deployed promotion run the same
# code path. This previously spoke to the compose container directly, which is
# why it never worked against AWS.

set -euo pipefail

cd "$(dirname "$0")/.."

handle="${1:-}"
if [[ -z "$handle" ]]; then
    echo "usage: $0 <handle>" >&2
    exit 1
fi

export DATABASE_URL="${DATABASE_URL:-postgres://bottle:localdev@127.0.0.1:5432/bottle}"

exec npm run --silent admin -- moderator "$handle"
