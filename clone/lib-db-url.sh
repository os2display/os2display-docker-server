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

# read_database_url [FILE] [VAR]
#   Print the VAR value (default DATABASE_URL) from FILE (default
#   .env.symfony), with any surrounding single/double quotes stripped.
#   Returns non-zero if absent. VAR exists for the 1.x layout, which named
#   the variable APP_DATABASE_URL.
read_database_url() {
  local f="${1:-.env.symfony}" var="${2:-DATABASE_URL}" line
  line=$(grep -E "^${var}=" "$f" | head -1) || true
  if [ -z "$line" ]; then
    echo "Error: ${var} not found in $f" >&2
    return 1
  fi
  line="${line#"${var}"=}"
  # Strip one layer of surrounding quotes (either kind).
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

# find_database_url [DIR]
#   Echo the database URL from a v1 OR v3 stack rooted at DIR (default cwd),
#   scanning .env.local, .env.docker.local, .env.symfony for APP_DATABASE_URL
#   (the 1.x itk-dev hosting name) then DATABASE_URL (v3); first match wins.
#   Returns non-zero (no output) if none is found.
find_database_url() {
  local dir="${1:-.}" f v
  for f in .env.local .env.docker.local .env.symfony; do
    [ -f "$dir/$f" ] || continue
    for v in APP_DATABASE_URL DATABASE_URL; do
      if grep -qE "^${v}=" "$dir/$f"; then
        read_database_url "$dir/$f" "$v"
        return 0
      fi
    done
  done
  return 1
}

# env_get DIR VAR
#   Echo the first VAR=value found across DIR's env files (.env, .env.local,
#   .env.docker.local, .env.symfony), with surrounding quotes stripped.
#   Returns non-zero if the variable is set nowhere. Used to read source
#   values that live under different names/files in v1 vs v3 layouts.
env_get() {
  local dir="$1" var="$2" f line
  for f in .env .env.local .env.docker.local .env.symfony; do
    [ -f "$dir/$f" ] || continue
    line=$(grep -E "^${var}=" "$dir/$f" | head -1) || true
    if [ -n "$line" ]; then
      line="${line#"${var}"=}"
      line="${line%\"}"; line="${line#\"}"
      line="${line%\'}"; line="${line#\'}"
      printf '%s' "$line"
      return 0
    fi
  done
  return 1
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

# The clone DB tooling runs the HOST's mariadb client directly (no transient
# container), so it connects from the host rather than a docker bridge — which
# also means root/admin access is evaluated for the host, not a container IP.

# require_mariadb_client
#   Assert a mariadb (or mysql) client is on PATH; error with install guidance.
require_mariadb_client() {
  command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1 || {
    echo "Error: no 'mariadb' (or 'mysql') client on PATH." >&2
    echo "       Install the MariaDB client, e.g. 'apt-get install -y mariadb-client'." >&2
    return 1
  }
}

# mariadb_client_bin / mariadb_dump_bin
#   Echo the client / dump binary name, preferring the mariadb-named tools and
#   falling back to the mysql-named ones.
mariadb_client_bin() {
  if command -v mariadb >/dev/null 2>&1; then printf 'mariadb'; else printf 'mysql'; fi
}
mariadb_dump_bin() {
  if command -v mariadb-dump >/dev/null 2>&1; then printf 'mariadb-dump'; else printf 'mysqldump'; fi
}

# db_connect_host HOST
#   Translate a docker-internal alias to a host-local address for a client
#   running ON the host: host.docker.internal (a DB on the docker host, as in a
#   v1 install) is reached from the host itself at 127.0.0.1. Everything else
#   is returned unchanged.
db_connect_host() {
  if [ "$1" = "host.docker.internal" ]; then printf '127.0.0.1'; else printf '%s' "$1"; fi
}
