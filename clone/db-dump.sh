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

SRC_URL=$(find_database_url .) || {
  echo "Error: no DATABASE_URL (v3) or APP_DATABASE_URL (v1) found here." >&2
  echo "       Looked in .env.local, .env.docker.local, .env.symfony." >&2
  exit 1
}
db_url_parse "$SRC_URL"
PROJECT=$(compose_project)
TAG=$(mariadb_tag)

# Network selection:
#   - host.docker.internal (DB on the docker host, e.g. a v1 install): use the
#     default bridge and map the alias to the host gateway. An app network —
#     possibly `internal:` — is the wrong path and may lack the route.
#   - otherwise: attach to the project's app network when present, so a bundled
#     `host=mariadb` URL resolves; real external hosts work either way.
net_args=()
hostmap_args=()
if [ "$DB_HOST" = "host.docker.internal" ]; then
  hostmap_args=(--add-host=host.docker.internal:host-gateway)
else
  NET=$(app_network "$PROJECT")
  [ -n "$NET" ] && net_args=(--network "$NET")
fi

mkdir -p backup
OUT="${1:-}"
[ -n "$OUT" ] || OUT="backup/$(date -u +%Y%m%dT%H%M%SZ).sql.gz"

echo "Dumping '${DB_NAME}' from ${DB_HOST}:${DB_PORT} to ${OUT}${NET:+ (via ${NET})}..."

# --no-tablespaces: avoids requiring the PROCESS privilege, which managed /
# least-privilege external DB users often lack. --single-transaction keeps
# the dump consistent without locking (InnoDB), so there's no downtime.
# MYSQL_PWD passes the password without exposing it on the client argv.
docker run -i --rm "${net_args[@]}" "${hostmap_args[@]}" -e MYSQL_PWD="$DB_PASS" "mariadb:${TAG}" \
  mariadb-dump \
  --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
  --single-transaction --quick --routines --triggers --events \
  --no-tablespaces \
  "$DB_NAME" \
  | gzip >"$OUT"

echo "Wrote ${OUT} ($(du -h "$OUT" | cut -f1))."
