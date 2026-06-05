#!/usr/bin/env bash
#
# Load a SQL dump (.sql or .sql.gz) into the database referenced by
# DATABASE_URL in .env.symfony. Counterpart to clone/db-dump.sh — same
# transient-client approach, so it works for the bundled DB and an external
# one alike (see clone/lib-db-url.sh).
#
# Run from the stack root, directly:
#   clone/db-restore.sh backup/20260101T000000Z.sql.gz
#
# STACK_ROOT=<dir> overrides which stack to restore into (default: the parent
# of this clone/ directory).
#
# Creates the target database if it does not exist (needs CREATE privilege).
# DESTRUCTIVE: a dump containing DROP TABLE / CREATE TABLE overwrites the
# matching tables in the target database. Take a fresh dump first if unsure.
#
# Requires: docker, a readable .env.symfony with DATABASE_URL.

set -euo pipefail

# Resolve our own dir (for the lib), then operate on the stack root — the
# dir holding .env / .env.symfony / docker-compose.yml.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${STACK_ROOT:-$SCRIPT_DIR/..}"

# shellcheck source=clone/lib-db-url.sh
. "$SCRIPT_DIR/lib-db-url.sh"

FILE="${1:-${FILE:-}}"
[ -n "$FILE" ] || {
  echo "Usage: clone/db-restore.sh FILE   (or: FILE=backup/<ts>.sql.gz clone/db-restore.sh)" >&2
  exit 1
}
[ -f "$FILE" ] || {
  echo "Error: dump file '$FILE' not found." >&2
  exit 1
}
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

echo "Restoring '${FILE}' into '${DB_NAME}' at ${DB_HOST}:${DB_PORT}${NET:+ (via ${NET})}..."

# Ensure the target database exists (no-op if it already does). Connect
# without selecting a database so this works on a brand-new clone DB.
docker run -i --rm "${net_args[@]}" -e MYSQL_PWD="$DB_PASS" "mariadb:${TAG}" \
  mariadb --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
  -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"

# Stream the dump into the client. gzip -dc transparently handles .gz;
# plain .sql is cat-ed through. The pipe keeps the (possibly large) dump
# off disk a second time.
case "$FILE" in
  *.gz) reader=(gzip -dc) ;;
  *) reader=(cat) ;;
esac

"${reader[@]}" "$FILE" | docker run -i --rm "${net_args[@]}" -e MYSQL_PWD="$DB_PASS" "mariadb:${TAG}" \
  mariadb --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" "$DB_NAME"

echo "Restore complete."
