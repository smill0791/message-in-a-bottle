# Shared Postgres access for the shell scripts. Source it, do not execute it.
#
#   sql "select count(*) from messages"   # one statement, trimmed scalar result
#   run_sql <<SQL ... SQL                 # a script on stdin, stops on error
#
# Two ways to reach the database, because the two environments genuinely
# differ:
#
#   - In CI, Postgres is a GitLab service container on its own host. There is
#     no local container to `docker exec` into, so the client must connect over
#     the network.
#   - On this laptop there is no psql binary installed at all, but the compose
#     container ships one.
#
# So: prefer a real client when the host has one, fall back to the container
# otherwise. Both paths read the same DATABASE_URL, which keeps one source of
# truth for where the database actually is.

DATABASE_URL="${DATABASE_URL:-postgres://bottle:localdev@127.0.0.1:5432/bottle}"

if command -v psql >/dev/null 2>&1; then
    sql() { psql "$DATABASE_URL" -qtA -c "$1" | tr -d ' \n'; }
    run_sql() { psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q; }
else
    sql() { docker exec -i bottle-db psql -U bottle -d bottle -qtA -c "$1" | tr -d ' \n'; }
    # -i matters: without it the heredoc never reaches psql and every statement
    # silently does nothing.
    run_sql() { docker exec -i bottle-db psql -U bottle -d bottle -v ON_ERROR_STOP=1 -q; }
fi
