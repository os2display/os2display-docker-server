#!/usr/bin/env bash
#
# `task install` precondition helper: detect CHANGE_ME sentinels in
# .env.mariadb, replace them with random 32-character hex passwords, and
# sync the new application-user password into DATABASE_URL in .env.symfony.
#
# Idempotent — if no sentinels are present, exits silently with no change.
#
# Why: `.env.mariadb.example` ships passwords as `CHANGE_ME` to fail-loud
# if operators forget to rotate. Auto-replacing on first install means
# operators get safe random credentials by default; explicit values they
# set before running install are preserved.

set -euo pipefail

if [ ! -f .env.mariadb ] || [ ! -f .env.symfony ]; then
  echo "Error: env files missing — run 'task env:init' first." >&2
  exit 1
fi

# Source .env.mariadb so $MARIADB_PASSWORD etc. are set whether the
# script runs via `task install` (Taskfile's `dotenv:` already loaded it)
# or stand-alone (CI workflow, manual invocation). Without this, an empty
# env defeats the sentinel check below — both `${VAR:-}` evaluate to
# empty (≠ "CHANGE_ME"), so the script silently exits 0 and mariadb
# starts with the literal CHANGE_ME password from the file.
set -a
# shellcheck disable=SC1091
. ./.env.mariadb
set +a

# Sentinel detection. If neither password is the CHANGE_ME placeholder,
# there's nothing to do.
if [ "${MARIADB_PASSWORD:-}" != "CHANGE_ME" ] && [ "${MARIADB_ROOT_PASSWORD:-}" != "CHANGE_ME" ]; then
  exit 0
fi

USER_PW=$(docker run --rm alpine/openssl rand -hex 16)
ROOT_PW=$(docker run --rm alpine/openssl rand -hex 16)

# Helper: in-place sed portable across BSD (macOS) and GNU (Linux).
sed_inplace() {
  local pattern="$1" file="$2"
  sed -i.bak "$pattern" "$file"
  rm -f "${file}.bak"
}

sed_inplace "s|^MARIADB_PASSWORD=CHANGE_ME$|MARIADB_PASSWORD=${USER_PW}|"      .env.mariadb
sed_inplace "s|^MARIADB_ROOT_PASSWORD=CHANGE_ME$|MARIADB_ROOT_PASSWORD=${ROOT_PW}|" .env.mariadb

# Sync the application-user password into DATABASE_URL. Targeted swap of
# just the password component (between `://USER:` and `@HOST`); the rest
# of the URL — host, port, db, serverVersion — is left untouched.
sed_inplace "s|://${MARIADB_USER}:[^@]*@|://${MARIADB_USER}:${USER_PW}@|" .env.symfony

echo "Generated random MariaDB credentials:"
echo "  MARIADB_PASSWORD       (in .env.mariadb)"
echo "  MARIADB_ROOT_PASSWORD  (in .env.mariadb)"
echo "  DATABASE_URL synced    (in .env.symfony)"
