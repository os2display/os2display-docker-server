#!/usr/bin/env bash
#
# Shared helpers for the DATABASE_URL-driven clone scripts
# (db-dump.sh, db-restore.sh, clone.sh). Source it; do NOT execute.
#
#   . "$SCRIPT_DIR/lib-db-url.sh"
#
# The functions read project files relative to the CURRENT directory, so
# callers must `cd` to a stack root (the directory holding .env / .env.symfony
# / docker-compose.yml) before using them. The scripts in this dir do that via
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$SCRIPT_DIR/.."
#
# Why DATABASE_URL-driven (vs execing mariadb-dump inside the BUNDLED mariadb
# container): production here runs an EXTERNAL database (COMPOSE_PROFILES drops
# `mariadb`), so there's no container to exec into. Parsing DATABASE_URL and
# driving a transient `mariadb:<tag>` client works for both the bundled DB
# (host=mariadb on the app network) and an external host (public DNS, reached
# via the app network's egress).

# read_database_url [FILE]
#   Print the DATABASE_URL value from FILE (default .env.symfony), with any
#   surrounding single/double quotes stripped. Returns non-zero if absent.
read_database_url() {
  local f="${1:-.env.symfony}" line
  line=$(grep -E '^DATABASE_URL=' "$f" | head -1) || true
  if [ -z "$line" ]; then
    echo "Error: DATABASE_URL not found in $f" >&2
    return 1
  fi
  line="${line#DATABASE_URL=}"
  # Strip one layer of surrounding quotes (either kind).
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

# db_url_parse URL
#   Parse a mysql://USER:PASS@HOST[:PORT]/DBNAME[?query] URL into globals
#   DB_USER, DB_PASS, DB_HOST, DB_PORT, DB_NAME. The password is %XX-decoded
#   (DATABASE_URL percent-encodes reserved chars). PORT defaults to 3306.
#
# The globals are consumed by the sourcing scripts, not here — hence the
# blanket SC2034 (appears unused) suppression for this function.
# shellcheck disable=SC2034
db_url_parse() {
  local url="$1" userinfo rest hostport
  url="${url#mysql://}"
  url="${url#mariadb://}"
  url="${url%%\?*}"           # drop ?serverVersion=… and friends
  userinfo="${url%%@*}"
  rest="${url#*@}"
  DB_USER="${userinfo%%:*}"
  DB_PASS="${userinfo#*:}"
  hostport="${rest%%/*}"
  DB_NAME="${rest#*/}"
  DB_HOST="${hostport%%:*}"
  if [ "$hostport" = "$DB_HOST" ]; then
    DB_PORT=3306
  else
    DB_PORT="${hostport#*:}"
  fi
  # Percent-decode the password: turn %XX into \xXX, then let printf %b
  # expand the hex escapes. Handles the common reserved chars (@ : / ? #)
  # that DATABASE_URL must encode.
  DB_PASS=$(printf '%b' "${DB_PASS//%/\\x}")
}

# compose_project
#   Echo COMPOSE_PROJECT_NAME from .env, defaulting to "os2display".
compose_project() {
  local p
  p=$(grep -E '^COMPOSE_PROJECT_NAME=' .env 2>/dev/null | head -1 | cut -d= -f2-) || true
  printf '%s' "${p:-os2display}"
}

# mariadb_tag
#   Echo the mariadb image tag pinned in docker-compose.yml (e.g. 11.4.10),
#   falling back to a sane default if the line moves. The transient client
#   uses this so its tooling matches the server version.
mariadb_tag() {
  local t
  t=$(awk -F: '/^[[:space:]]+image:[[:space:]]+mariadb:/ {gsub(/ /,"",$NF); print $NF; exit}' docker-compose.yml) || true
  printf '%s' "${t:-11.4.10}"
}

# app_network PROJECT
#   Echo the project's `<project>_app` docker network name if it exists,
#   else nothing. Callers attach the transient client to it when present so
#   a bundled `host=mariadb` URL resolves; when absent (stack down, external
#   DB) the client falls back to the default bridge, which still has egress.
app_network() {
  docker network ls --format '{{.Name}}' | grep -E "^${1}_app$" | head -1 || true
}
