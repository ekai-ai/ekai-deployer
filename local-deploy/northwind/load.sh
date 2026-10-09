#!/usr/bin/env bash
# Northwind sample data for local Ekai. Runs on the host and talks to the
# ekai-postgres container through `docker exec`.
#
#   load.sh exists <db> <user> <password>   exit 0 if the database already exists
#   load.sh load   <db> <user> <password>   (re)create it from scratch and load the data
#
# Expects setup.sql next to this script. Never writes to ekaibackend.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG_CONTAINER="${PG_CONTAINER:-ekai-postgres}"
CMD="${1:-}"
DB="${2:-}"
DB_USER="${3:-}"
DB_PASSWORD="${4:-}"
# Pinned to a commit so upstream changes can't break installs.
SQL_URL="https://raw.githubusercontent.com/pthom/northwind_psql/4aa7967a33b84e693db56d4c23ada410a3ff04a6/northwind.sql"
EXPECTED_TABLES=14

usage() { echo "usage: load.sh exists|load <db> <user> <password>" >&2; exit 2; }
[ -n "$CMD" ] && [ -n "$DB" ] && [ -n "$DB_USER" ] && [ -n "$DB_PASSWORD" ] || usage

log() { echo "→ $*"; }
die() { echo "✗ $*" >&2; exit 1; }

pg_admin() { docker exec -i "$PG_CONTAINER" psql -U ekai -d postgres -v ON_ERROR_STOP=1 -q "$@"; }
pg_nw()    { docker exec -i -e PGPASSWORD="$DB_PASSWORD" "$PG_CONTAINER" psql -h 127.0.0.1 -U "$DB_USER" -v ON_ERROR_STOP=1 -q "$@"; }

wait_for_postgres() {
  log "Waiting for ${PG_CONTAINER} to accept connections…"
  # TCP (-h) on purpose: during first-time init the entrypoint runs a temporary
  # server that only listens on the unix socket, which would fool a socket check.
  local tries=0
  until docker exec "$PG_CONTAINER" psql -h 127.0.0.1 -U ekai -d ekaibackend -c 'SELECT 1' &>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || die "${PG_CONTAINER} did not become ready in time."
    sleep 3
  done
}

cmd_exists() {
  wait_for_postgres >&2
  [ "$(pg_admin -tA -c "SELECT 1 FROM pg_database WHERE datname = '${DB}'")" = "1" ]
}

cmd_load() {
  wait_for_postgres

  # Download first so a failed download can't leave the user without a DB.
  sql_file=$(mktemp)  # global: the EXIT trap runs after this function returns
  trap 'rm -f "$sql_file"' EXIT
  log "Downloading Northwind sample data…"
  curl -fsSL "$SQL_URL" -o "$sql_file" || die "Could not download ${SQL_URL}"

  log "Creating the ${DB} database and user…"
  pg_admin -v db="$DB" -v usr="$DB_USER" -v pw="$DB_PASSWORD" < "$HERE/setup.sql" >/dev/null

  log "Loading Northwind data…"
  pg_nw -d "$DB" < "$sql_file" >/dev/null || die "Loading the Northwind data failed. Re-run to retry."

  local tables
  tables=$(pg_nw -d "$DB" -tA -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'")
  [ "$tables" = "$EXPECTED_TABLES" ] || die "Verification failed: expected ${EXPECTED_TABLES} tables in public, found '${tables:-none}'."

  if pg_nw -d ekaibackend -c 'SELECT 1' &>/dev/null; then
    die "Isolation check failed: the ${DB_USER} user can open ekai's own database."
  fi
  echo "✓ Northwind loaded (${tables} tables) and isolated from ekai's own database"
}

case "$CMD" in
  exists) cmd_exists ;;
  load)   cmd_load ;;
  *)      usage ;;
esac
