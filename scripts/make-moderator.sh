#!/usr/bin/env bash
# Grant moderator rights to an existing account.
#
#   ./scripts/make-moderator.sh driftwood
#
# Deliberately a script rather than a UI. Promoting a moderator is rare,
# consequential, and should leave a trace in shell history rather than being a
# button someone can click by accident.

set -euo pipefail

handle="${1:-}"
if [[ -z "$handle" ]]; then
    echo "usage: $0 <handle>" >&2
    exit 1
fi

updated=$(docker exec -i bottle-db psql -U bottle -d bottle -qtA \
    -c "update users set is_moderator = true where handle = '$handle' returning handle" | tr -d ' \n')

if [[ -z "$updated" ]]; then
    echo "no account with handle '$handle'" >&2
    exit 1
fi

echo "$updated is now a moderator"
