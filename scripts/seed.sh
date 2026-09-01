#!/usr/bin/env bash
# Put bottles on the beach locally.
#
#   ./scripts/seed.sh                 # db/seeds/messages.txt
#   ./scripts/seed.sh path/to/file    # something else
#
# Kept as a thin shim because it is referenced from RECAP.md and from the e2e
# workflow ("restore the placeholder bottles afterwards"). The messages
# themselves live in db/seeds/messages.txt, and the logic lives in
# api/src/admin.ts so that the same code seeds a local container and an RDS
# instance rather than there being two versions of it that drift.

set -euo pipefail

cd "$(dirname "$0")/.."

export DATABASE_URL="${DATABASE_URL:-postgres://bottle:localdev@127.0.0.1:5432/bottle}"

exec npm run --silent admin -- seed "$@"
