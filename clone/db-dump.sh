#!/usr/bin/env bash
#
# Dump the database referenced by the stack's DB URL to a gzipped SQL file,
# using the HOST's mariadb client (no transient container).
#
# It finds the URL across layouts — APP_DATABASE_URL (v1) or DATABASE_URL (v3)
# — and runs mariadb-dump directly on the host. A host.docker.internal URL (a
# DB on the docker host) is reached from the host itself at 127.0.0.1.
#
# Run from the stack root via the wrapper path, or directly:
#   clone/db-dump.sh [OUTFILE]      OUTFILE defaults to backup/<UTC-ts>.sql.gz
#
# STACK_ROOT=<dir> overrides which stack to dump (default: the parent of this
# clone/ directory). clone.sh uses it to dump the SOURCE stack while writing
# the file into the destination's backup/ via an absolute OUTFILE.
#
# Requires: a mariadb client + gzip on the host, and a readable env file with
# APP_DATABASE_URL / DATABASE_URL.

set -euo pipefail

# Resolve our own dir (for the lib), then operate on the stack root — the
# dir holding .env / .env.symfony / docker-compose.yml.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${STACK_ROOT:-$SCRIPT_DIR/..}"

# shellcheck source=clone/lib-db-url.sh
. "$SCRIPT_DIR/lib-db-url.sh"

SRC_URL=$(find_database_url .) || {
  echo "Error: no DATABASE_URL (v3) or APP_DATABASE_URL (v1) found here." >&2
  echo "       Looked in .env.local, .env.docker.local, .env.symfony." >&2
  exit 1
}
db_url_parse "$SRC_URL"
require_mariadb_client
DUMP_BIN=$(mariadb_dump_bin)
CONNECT_HOST=$(db_connect_host "$DB_HOST")

mkdir -p backup
OUT="${1:-}"
[ -n "$OUT" ] || OUT="backup/$(date -u +%Y%m%dT%H%M%SZ).sql.gz"

echo "Dumping '${DB_NAME}' from ${CONNECT_HOST}:${DB_PORT} to ${OUT}..."

# --no-tablespaces: avoids requiring the PROCESS privilege, which managed /
# least-privilege DB users often lack. --single-transaction keeps the dump
# consistent without locking (InnoDB), so there's no downtime. MYSQL_PWD passes
# the password without exposing it on the client argv.
MYSQL_PWD="$DB_PASS" "$DUMP_BIN" \
  --host="$CONNECT_HOST" --port="$DB_PORT" --user="$DB_USER" \
  --single-transaction --quick --routines --triggers --events \
  --no-tablespaces \
  "$DB_NAME" \
  | gzip >"$OUT"

echo "Wrote ${OUT} ($(du -h "$OUT" | cut -f1))."
