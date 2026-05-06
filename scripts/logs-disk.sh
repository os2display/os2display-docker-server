#!/usr/bin/env bash
#
# Show docker log disk usage per container in this compose project plus the
# effective LOG_MAX_SIZE / LOG_MAX_FILE retention policy. Linux only — the
# json-file logs at /var/lib/docker are root-owned, so the du walk happens
# in a transient alpine container with a read-only mount.

set -euo pipefail

if [ ! -d /var/lib/docker ]; then
  echo "Error: /var/lib/docker not found. logs:disk requires a Linux host." >&2
  exit 1
fi

# Same compose invocation as the rest of the Taskfile.
COMPOSE=(docker compose --env-file .env --env-file .env.traefik)

ids=$("${COMPOSE[@]}" ps -aq 2>/dev/null || true)
if [ -z "$ids" ]; then
  echo "No containers in this project — bring the stack up first."
  exit 0
fi

# Per-container manifest (name|log-base-path), one line each. The base path
# is e.g. /var/lib/docker/containers/<id>/<id>-json.log; rotated siblings
# (.1, .2, ...) live next to it.
manifest=""
while IFS= read -r id; do
  [ -z "$id" ] && continue
  name=$(docker inspect --format='{{.Name}}' "$id" | sed 's|^/||')
  path=$(docker inspect --format='{{.LogPath}}' "$id")
  [ -n "$path" ] && manifest="${manifest}${name}|${path}
"
done <<< "$ids"

# alpine container does the du since /var/lib/docker is root-owned.
printf '%s' "$manifest" | docker run --rm -i \
  -v /var/lib/docker:/var/lib/docker:ro \
  alpine sh -c '
    printf "%-30s %12s\n" "CONTAINER" "LOG SIZE"
    total_kb=0
    while IFS="|" read -r name path; do
      [ -z "$name" ] && continue
      # du -ck on base + rotated siblings; tail picks the total row.
      kb=$(du -ck "${path}"* 2>/dev/null | tail -1 | cut -f1)
      kb=${kb:-0}
      total_kb=$((total_kb + kb))
      h=$(du -ch "${path}"* 2>/dev/null | tail -1 | cut -f1)
      printf "  %-28s %12s\n" "$name" "${h:-—}"
    done
    printf "  %-28s %12s\n" "----" ""
    # Integer-only formatting (busybox sh has no bc).
    if [ "$total_kb" -lt 1024 ]; then tot="${total_kb}K"
    elif [ "$total_kb" -lt 1048576 ]; then tot="$((total_kb / 1024))M"
    else tot="$((total_kb / 1048576))G"
    fi
    printf "  %-28s %12s\n" "TOTAL" "$tot"
  '

echo
MAX_SIZE=$(grep -E '^LOG_MAX_SIZE=' .env 2>/dev/null | cut -d= -f2- || true)
MAX_FILE=$(grep -E '^LOG_MAX_FILE=' .env 2>/dev/null | cut -d= -f2- || true)
printf "Retention: max-size=%s × max-file=%s per container\n" \
  "${MAX_SIZE:-10m (default)}" "${MAX_FILE:-3 (default)}"
echo "Tune via LOG_MAX_SIZE / LOG_MAX_FILE in .env, then 'task update'."
