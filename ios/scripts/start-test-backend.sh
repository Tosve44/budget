#!/usr/bin/env bash
# Starts a local stand-in for the Supabase project, for testing sync without internet:
# a real Postgres with the web app's real migration (so the real privacy rules apply), and the
# web app's fake-supabase.cjs, which speaks Supabase's web API on http://localhost:54321.
#
#   scripts/start-test-backend.sh /path/to/budget-app
#
# Needs: PostgreSQL 16 (initdb/pg_ctl), Node.js 18+. Linux, run as root or a normal user.
set -euo pipefail
WEB="$(cd "${1:-../budget-app}" && pwd)"
WORK="${WORK:-/tmp/budget-test-backend}"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
PORT_PG=54329
PORT_API=54321
mkdir -p "$WORK"

run_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$*"; else bash -c "$*"; fi; }

if [ ! -d "$WORK/pgdata" ]; then
  mkdir -p "$WORK/pgdata" && chmod 777 "$WORK"
  [ "$(id -u)" = 0 ] && chown postgres "$WORK/pgdata"
  run_pg "$PGBIN/initdb -D $WORK/pgdata -U postgres --auth=trust >/dev/null"
fi
if ! run_pg "$PGBIN/pg_ctl -D $WORK/pgdata status" >/dev/null 2>&1; then
  run_pg "$PGBIN/pg_ctl -D $WORK/pgdata -o '-p $PORT_PG -k /tmp -c listen_addresses=localhost' -l $WORK/pg.log start -w" >/dev/null
fi
PSQL="psql -h /tmp -p $PORT_PG -U postgres -v ON_ERROR_STOP=1 -q"
$PSQL -d postgres -c "drop database if exists budget_test" -c "create database budget_test"
$PSQL -d budget_test -f "$WEB/tests/backend/supabase-base.sql" >/dev/null
for f in "$WEB"/supabase/migrations/*.sql; do $PSQL -d budget_test -f "$f" >/dev/null; done

if [ ! -d "$WORK/node_modules/pg" ] || [ ! -d "$WORK/node_modules/@supabase/supabase-js" ]; then
  (cd "$WORK" && npm init -y >/dev/null && npm install --silent pg@8 @supabase/supabase-js@2 >/dev/null)
fi
pkill -f fake-supabase.cjs 2>/dev/null || true
rm -rf "$WORK/files"
NODE_PATH="$WORK/node_modules" PGURL="postgres://postgres@localhost:$PORT_PG/budget_test" PORT=$PORT_API STORE_DIR="$WORK/files" \
  nohup node "$WEB/tests/backend/fake-supabase.cjs" > "$WORK/api.log" 2>&1 &
for _ in $(seq 1 50); do curl -s "http://localhost:$PORT_API/__test/anon-key" >/dev/null && break; sleep 0.2; done
echo "Test backend running: http://localhost:$PORT_API (database budget_test on port $PORT_PG). Logs in $WORK."
