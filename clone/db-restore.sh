#!/usr/bin/env bash
#
# Load a SQL dump (.sql or .sql.gz) into the stack's database, using the HOST's
# mariadb client (no transient container). Counterpart to clone/db-dump.sh.
#
# It finds the URL across layouts — APP_DATABASE_URL (v1) or DATABASE_URL (v3).
# A host.docker.internal URL (DB on the docker host) is reached from the host
# itself at 127.0.0.1.
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
# Requires: a mariadb client + gzip on the host, and a readable env file with
# APP_DATABASE_URL / DATABASE_URL.

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
TARGET_URL=$(find_database_url .) || {
  echo "Error: no DATABASE_URL (v3) or APP_DATABASE_URL (v1) found here." >&2
  echo "       Looked in .env.local, .env.docker.local, .env.symfony." >&2
  exit 1
}
db_url_parse "$TARGET_URL"
require_mariadb_client
CLIENT=$(mariadb_client_bin)
CONNECT_HOST=$(db_connect_host "$DB_HOST")

echo "Restoring '${FILE}' into '${DB_NAME}' at ${CONNECT_HOST}:${DB_PORT}..."

# Ensure the target database exists (no-op if it already does). Connect
# without selecting a database so this works on a brand-new clone DB.
MYSQL_PWD="$DB_PASS" "$CLIENT" --host="$CONNECT_HOST" --port="$DB_PORT" --user="$DB_USER" \
  -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"

# Stream the dump into the client. gzip -dc transparently handles .gz;
# plain .sql is cat-ed through. The pipe keeps the (possibly large) dump
# off disk a second time.
case "$FILE" in
  *.gz) reader=(gzip -dc) ;;
  *) reader=(cat) ;;
esac

"${reader[@]}" "$FILE" | MYSQL_PWD="$DB_PASS" "$CLIENT" \
  --host="$CONNECT_HOST" --port="$DB_PORT" --user="$DB_USER" "$DB_NAME"

echo "Restore complete."
