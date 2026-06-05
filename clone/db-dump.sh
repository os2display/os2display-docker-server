#!/usr/bin/env bash
#
# Dump the database referenced by DATABASE_URL in .env.symfony to a gzipped
# SQL file.
#
# Unlike the bundled-only `mariadb-dump`-inside-the-container approach (a
# no-op when the DB is external), this drives a transient `mariadb:<tag>`
# client against whatever DATABASE_URL points at — so it works for both the
# bundled DB and an EXTERNAL one. See clone/lib-db-url.sh for the rationale
# and the network-resolution behaviour.
#
# Run from the stack root via the wrapper path, or directly:
#   clone/db-dump.sh [OUTFILE]      OUTFILE defaults to backup/<UTC-ts>.sql.gz
#
# STACK_ROOT=<dir> overrides which stack to dump (default: the parent of this
# clone/ directory). clone.sh uses it to dump the SOURCE stack while writing
# the file into the destination's backup/ via an absolute OUTFILE.
#
# Requires: docker, a readable .env.symfony with DATABASE_URL.

set -euo pipefail

# Resolve our own dir (for the lib), then operate on the stack root — the
# dir holding .env / .env.symfony / docker-compose.yml.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${STACK_ROOT:-$SCRIPT_DIR/..}"

# shellcheck source=clone/lib-db-url.sh
. "$SCRIPT_DIR/lib-db-url.sh"

[ -f .env.symfony ] || {
  echo "Error: .env.symfony missing — run 'task env:init' first." >&2
  exit 1
}

db_url_parse "$(read_database_url .env.symfony)"
PROJECT=$(compose_project)
TAG=$(mariadb_tag)

net_args=()
NET=$(app_network "$PROJECT")
[ -n "$NET" ] && net_args=(--network "$NET")

mkdir -p backup
OUT="${1:-}"
[ -n "$OUT" ] || OUT="backup/$(date -u +%Y%m%dT%H%M%SZ).sql.gz"

echo "Dumping '${DB_NAME}' from ${DB_HOST}:${DB_PORT} to ${OUT}${NET:+ (via ${NET})}..."

# --no-tablespaces: avoids requiring the PROCESS privilege, which managed /
# least-privilege external DB users often lack. --single-transaction keeps
# the dump consistent without locking (InnoDB), so there's no downtime.
# MYSQL_PWD passes the password without exposing it on the client argv.
docker run -i --rm "${net_args[@]}" -e MYSQL_PWD="$DB_PASS" "mariadb:${TAG}" \
  mariadb-dump \
  --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
  --single-transaction --quick --routines --triggers --events \
  --no-tablespaces \
  "$DB_NAME" \
  | gzip >"$OUT"

echo "Wrote ${OUT} ($(du -h "$OUT" | cut -f1))."
