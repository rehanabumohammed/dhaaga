#!/usr/bin/env bash
# Start a local PostgreSQL 16 instance for development and testing.
#
# PostgreSQL 16 is used because that is the major version Supabase Cloud runs.
# Development happens against the same major version so that a migration proven
# locally is a migration proven for production (ADR-0001).
#
# Usage: scripts/db_local.sh [start|stop|status|reset]
set -euo pipefail

PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
PGDATA="${PGDATA:-/var/lib/postgresql/dhaaga}"
PGPORT="${PGPORT:-5433}"
ADMIN_URL="postgres://postgres@127.0.0.1:${PGPORT}/postgres"

start() {
  if [ ! -d "$PGDATA/base" ]; then
    mkdir -p "$PGDATA"; chown postgres:postgres "$PGDATA"
    su postgres -c "$PGBIN/initdb -D $PGDATA -U postgres --auth=trust" >/dev/null
  fi
  if ! su postgres -c "$PGBIN/pg_ctl -D $PGDATA status" >/dev/null 2>&1; then
    su postgres -c "$PGBIN/pg_ctl -D $PGDATA -l /tmp/dhaaga_pg.log -o '-p $PGPORT' start" >/dev/null
    sleep 2
  fi
  for db in dhaaga_dev dhaaga_test; do
    psql "$ADMIN_URL" -tAc "select 1 from pg_database where datname='$db'" | grep -q 1 \
      || psql "$ADMIN_URL" -q -c "create database $db;"
  done
  echo "postgres running on port $PGPORT (dhaaga_dev, dhaaga_test ready)"
}

stop()  { su postgres -c "$PGBIN/pg_ctl -D $PGDATA stop" >/dev/null 2>&1 || true; echo "stopped"; }
status(){ su postgres -c "$PGBIN/pg_ctl -D $PGDATA status" || true; }
reset() {
  psql "$ADMIN_URL" -q -c "drop database if exists dhaaga_dev;" -c "create database dhaaga_dev;"
  psql "$ADMIN_URL" -q -c "drop database if exists dhaaga_test;" -c "create database dhaaga_test;"
  echo "databases reset (empty)"
}

case "${1:-start}" in
  start) start ;; stop) stop ;; status) status ;; reset) reset ;;
  *) echo "usage: $0 [start|stop|status|reset]" >&2; exit 2 ;;
esac
