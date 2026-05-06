#!/usr/bin/env bash
#
# Point-in-time snapshot of the MariaDB operational counters relevant to
# PHP-app-under-load symptoms: connection exhaustion, aborted connects,
# row-lock contention, buffer-pool pressure, slow queries.
#
# Two SQL round-trips (one for status, one for variables); formatted via
# shell + awk. Output is human-readable, not metrics-exporter format —
# this is for operator eyeballing during an incident.
#
# Usage: scripts/db-metrics.sh
# Requires: bundled mariadb container running, $MARIADB_ROOT_PASSWORD set
# (loaded by Taskfile's `dotenv:` for `task db:metrics`; sourced from
# .env.mariadb defensively when the script runs outside `task` context).

set -euo pipefail

# Source .env.mariadb if $MARIADB_ROOT_PASSWORD isn't already in the env —
# matches scripts/install-secrets.sh's standalone-invocation pattern.
if [ -z "${MARIADB_ROOT_PASSWORD:-}" ]; then
  if [ ! -f .env.mariadb ]; then
    echo "Error: .env.mariadb missing — run 'task env:init' first." >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1091
  . ./.env.mariadb
  set +a
fi

COMPOSE=(docker compose --env-file .env --env-file .env.traefik)

# Helper: run SQL inside the mariadb container, batch + headers off (-BN),
# return tab-separated `name<TAB>value` rows.
mq() {
  "${COMPOSE[@]}" exec -T mariadb mariadb \
    --user=root --password="$MARIADB_ROOT_PASSWORD" \
    -BNe "$1" 2>/dev/null
}

# Pull all the counters we care about in one round-trip each.
STATUS=$(mq "SHOW GLOBAL STATUS WHERE Variable_name IN (
  'Threads_connected','Threads_running','Max_used_connections',
  'Connections','Aborted_clients','Aborted_connects',
  'Slow_queries',
  'Innodb_row_lock_waits','Innodb_row_lock_time_avg',
  'Innodb_buffer_pool_read_requests','Innodb_buffer_pool_reads',
  'Innodb_buffer_pool_pages_total','Innodb_buffer_pool_pages_free',
  'Open_tables','Opened_tables','Uptime')")

VARS=$(mq "SHOW GLOBAL VARIABLES WHERE Variable_name IN (
  'max_connections','innodb_page_size','slow_query_log')")

# Extract a single value by key from STATUS or VARS (TSV: name<TAB>value).
v() {
  printf '%s\n' "$1" | awk -v k="$2" '$1 == k {print $2; exit}'
}

# --- Connections ------------------------------------------------------------
printf "Connections\n"
printf "  Active:        %s / %s (Threads_connected / max_connections)\n" \
  "$(v "$STATUS" Threads_connected)" "$(v "$VARS" max_connections)"
printf "  Running:       %s (Threads_running — actually executing queries)\n" \
  "$(v "$STATUS" Threads_running)"
printf "  Peak:          %s (Max_used_connections since startup)\n" \
  "$(v "$STATUS" Max_used_connections)"
printf "  Cumulative:    %s connects, %s aborted-connects, %s aborted-clients\n" \
  "$(v "$STATUS" Connections)" \
  "$(v "$STATUS" Aborted_connects)" \
  "$(v "$STATUS" Aborted_clients)"

# --- InnoDB buffer pool ------------------------------------------------------
PAGES_TOTAL=$(v "$STATUS" Innodb_buffer_pool_pages_total)
PAGES_FREE=$(v "$STATUS" Innodb_buffer_pool_pages_free)
PAGE_SIZE=$(v "$VARS" innodb_page_size)
READ_REQ=$(v "$STATUS" Innodb_buffer_pool_read_requests)
READS=$(v "$STATUS" Innodb_buffer_pool_reads)

POOL_SIZE_MB=$((PAGES_TOTAL * PAGE_SIZE / 1024 / 1024))
USED_MB=$(((PAGES_TOTAL - PAGES_FREE) * PAGE_SIZE / 1024 / 1024))
HIT_PCT=$(awk -v r="$READS" -v rr="$READ_REQ" \
  'BEGIN { if (rr+0 > 0) printf "%.2f", 100 * (1 - r/rr); else printf "n/a" }')

printf "\nInnoDB buffer pool\n"
printf "  Size:          %s MiB (used %s MiB)\n" "$POOL_SIZE_MB" "$USED_MB"
printf "  Hit ratio:     %s %%\n" "$HIT_PCT"

# --- InnoDB row locks --------------------------------------------------------
printf "\nInnoDB row locks\n"
printf "  Waits:         %s (cumulative)\n" "$(v "$STATUS" Innodb_row_lock_waits)"
printf "  Avg wait:      %s ms\n" "$(v "$STATUS" Innodb_row_lock_time_avg)"

# --- Queries -----------------------------------------------------------------
SLOW_LOG_VAL=$(v "$VARS" slow_query_log)
case "$SLOW_LOG_VAL" in
  ON|on|1)  SLOW_LOG_DISP="ON" ;;
  *)        SLOW_LOG_DISP="OFF" ;;
esac
printf "\nQueries\n"
printf "  Slow:          %s (cumulative; slow log = %s)\n" \
  "$(v "$STATUS" Slow_queries)" "$SLOW_LOG_DISP"

# --- Tables ------------------------------------------------------------------
printf "\nTables\n"
printf "  Open now:      %s\n" "$(v "$STATUS" Open_tables)"
printf "  Cumulative:    %s opens\n" "$(v "$STATUS" Opened_tables)"

# --- Uptime ------------------------------------------------------------------
UPTIME_S=$(v "$STATUS" Uptime)
UPTIME_H=$(awk -v u="$UPTIME_S" 'BEGIN { printf "%.1f", u/3600 }')
printf "\nUptime: %s seconds (%s hours)\n" "$UPTIME_S" "$UPTIME_H"
