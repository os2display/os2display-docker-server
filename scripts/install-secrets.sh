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

if [ ! -f .env.mariadb ]; then
  # Bootstrap will copy from .env.mariadb.example before we get here, but
  # be defensive in case someone runs the script standalone.
  echo "Error: .env.mariadb missing." >&2
  exit 1
fi

if ! grep -q '^MARIADB_\(PASSWORD\|ROOT_PASSWORD\)=CHANGE_ME$' .env.mariadb; then
  exit 0
fi

if [ ! -f .env.symfony ]; then
  echo "Error: .env.symfony missing — run 'task env:init' first." >&2
  exit 1
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
USER=$(grep '^MARIADB_USER=' .env.mariadb | cut -d= -f2)
sed_inplace "s|://${USER}:[^@]*@|://${USER}:${USER_PW}@|" .env.symfony

echo "Generated random MariaDB credentials:"
echo "  MARIADB_PASSWORD       (in .env.mariadb)"
echo "  MARIADB_ROOT_PASSWORD  (in .env.mariadb)"
echo "  DATABASE_URL synced    (in .env.symfony)"
