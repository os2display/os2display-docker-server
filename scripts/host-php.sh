#!/usr/bin/env bash
#
# Recommend PHP-FPM settings (pm.max_children, opcache memory, etc.) for a
# given os2display container mem_limit. Math goes to stderr; stdout is pure
# PHP_* env-var lines suitable for merging into .env.php.
#
# Usage: scripts/host-php.sh <container-mem-limit-MiB>
# Example: scripts/host-php.sh 256

set -euo pipefail

MEM_LIMIT_MB="${1:-}"
if [ -z "$MEM_LIMIT_MB" ] || ! [ "$MEM_LIMIT_MB" -gt 0 ] 2>/dev/null; then
  echo "Usage: task host:php -- <container-mem-limit-in-MiB>" >&2
  echo "Example: task host:php -- 256" >&2
  exit 1
fi

# Per-worker estimate for Symfony + Doctrine + warm opcache.
# Conservative — real workers run 40–80 MiB depending on bundles.
PER_WORKER_MB=60
# PHP-FPM master + connection pools + non-pool overhead.
OVERHEAD_MB=50
# OPcache: scale with mem_limit, bounded.
if [ "$MEM_LIMIT_MB" -lt 384 ]; then
  OPCACHE_MB=64
elif [ "$MEM_LIMIT_MB" -lt 1024 ]; then
  OPCACHE_MB=128
else
  OPCACHE_MB=256
fi

WORKER_BUDGET=$((MEM_LIMIT_MB - OPCACHE_MB - OVERHEAD_MB))
if [ "$WORKER_BUDGET" -lt 120 ]; then
  echo "Error: ${MEM_LIMIT_MB} MiB is too small for os2display." >&2
  echo "       After OPcache (${OPCACHE_MB} MiB) + FPM overhead (${OVERHEAD_MB} MiB)," >&2
  echo "       only ${WORKER_BUDGET} MiB remain for workers — not enough for 2 × ${PER_WORKER_MB} MiB." >&2
  echo "       Bump the os2display mem_limit to at least 256 MiB (compose.resource-limits.yml)." >&2
  exit 1
fi

MAX_CHILDREN=$((WORKER_BUDGET / PER_WORKER_MB))
[ "$MAX_CHILDREN" -lt 2 ] && MAX_CHILDREN=2
START_SERVERS=$((MAX_CHILDREN / 4))
[ "$START_SERVERS" -lt 2 ] && START_SERVERS=2
MIN_SPARE=$((MAX_CHILDREN / 5))
[ "$MIN_SPARE" -lt 2 ] && MIN_SPARE=2
MAX_SPARE=$((MAX_CHILDREN / 2))
[ "$MAX_SPARE" -le "$MIN_SPARE" ] && MAX_SPARE=$((MIN_SPARE + 1))

# Math explanation to stderr; stdout is pure env-var lines.
{
  echo "Container mem_limit: ${MEM_LIMIT_MB} MiB"
  echo "  OPcache:               ${OPCACHE_MB} MiB"
  echo "  PHP-FPM overhead:      ${OVERHEAD_MB} MiB"
  echo "  Worker budget:         ${WORKER_BUDGET} MiB"
  echo "  Per-worker estimate:   ${PER_WORKER_MB} MiB (Symfony + Doctrine, conservative)"
  echo "Recommended pool sizing:"
  echo "  pm.max_children:       ${MAX_CHILDREN}"
  echo "  pm.start_servers:      ${START_SERVERS}"
  echo "  pm.min_spare_servers:  ${MIN_SPARE}"
  echo "  pm.max_spare_servers:  ${MAX_SPARE}"
  echo
  echo "Merge these into .env.php (replace existing PHP_PM_* / PHP_OPCACHE_MEMORY_CONSUMPTION):"
} >&2

cat <<EOF
PHP_OPCACHE_MEMORY_CONSUMPTION=${OPCACHE_MB}
PHP_PM_MAX_CHILDREN=${MAX_CHILDREN}
PHP_PM_START_SERVERS=${START_SERVERS}
PHP_PM_MIN_SPARE_SERVERS=${MIN_SPARE}
PHP_PM_MAX_SPARE_SERVERS=${MAX_SPARE}
EOF
