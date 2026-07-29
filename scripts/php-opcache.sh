#!/usr/bin/env bash
#
# Operator report on the FPM pool's OPcache: memory, interned strings,
# cached-key headroom, hit rate, restarts, preload — the numbers that tell
# you whether the effective PHP_OPCACHE_* tuning fits the deployed image.
#
# Wraps the `opcache-status` probe shipped in the API image (a cgi-fcgi
# round-trip into an FPM worker — the only place the pool's OPcache shared
# memory is visible; CLI PHP has its own). The probe's JSON is formatted by
# a PHP snippet executed in the same container, so the host needs neither
# jq nor PHP. Human-readable output for operator eyeballing, not a metrics
# exporter — pair with the bundled php-fpm_exporter for scraping.
#
# Usage: scripts/php-opcache.sh        (via `task php:opcache`)
#        RAW=1 scripts/php-opcache.sh  (probe JSON untouched, for jq piping)
# Requires: os2display container running, on an API image that ships the
# probe (3.0.0-rc4 and newer). Fails with guidance on older images.

set -euo pipefail

COMPOSE=(docker compose --env-file .env --env-file .env.traefik)

if [ "${RAW:-0}" = "1" ]; then
  exec "${COMPOSE[@]}" exec -T os2display opcache-status
fi

# The formatter runs inside the container: php reads the script from stdin
# (quoted heredoc — no shell interpolation) and fetches the probe JSON via
# shell_exec, so the whole report is one container round-trip.
"${COMPOSE[@]}" exec -T os2display php <<'PHP'
<?php

declare(strict_types=1);

if ('' === trim((string) shell_exec('command -v opcache-status 2>/dev/null'))) {
    fwrite(STDERR, "Error: this API image does not ship the 'opcache-status' probe.\n");
    fwrite(STDERR, "It ships in display-api-service images 3.0.0-rc4 and newer — bump\n");
    fwrite(STDERR, "OS2DISPLAY_VERSION_API in .env, then 'task update'.\n");
    exit(1);
}

$raw = shell_exec('opcache-status 2>/dev/null');
if (!is_string($raw) || '' === trim($raw)) {
    fwrite(STDERR, "Error: the probe returned nothing — is php-fpm up in this container?\n");
    exit(1);
}

$data = json_decode($raw, true);
if (is_array($data) && isset($data['error'])) {
    fwrite(STDERR, 'Error: '.$data['error']."\n");
    exit(1);
}
if (!is_array($data) || !isset($data['status'], $data['configuration'])) {
    fwrite(STDERR, "Error: probe output is not the expected JSON. Raw output:\n".$raw."\n");
    exit(1);
}

$status = $data['status'];
$stats = $status['opcache_statistics'];
$mem = $status['memory_usage'];
$interned = $status['interned_strings_usage'] ?? null;
$preload = $status['preload_statistics'] ?? null;
$directives = $data['configuration']['directives'] ?? [];
$version = $data['configuration']['version'] ?? [];

$mib = static fn (float $bytes): string => sprintf('%.1f MiB', $bytes / 1048576);
$num = static fn (int $n): string => number_format($n);
$yn = static fn (bool $b): string => $b ? 'yes' : 'no';
$ts = static fn (int $t): string => $t > 0 ? gmdate('Y-m-d\TH:i:s\Z', $t) : 'never';
$row = static function (string $label, string $value): void {
    printf("  %-15s %s\n", $label.':', $value);
};

// --- Status -------------------------------------------------------------
printf("OPcache (%s %s)\n",
    $version['opcache_product_name'] ?? 'Zend OPcache',
    $version['version'] ?? '?');
$row('Enabled', $yn((bool) ($status['opcache_enabled'] ?? false))
    .'   cache full: '.$yn((bool) ($status['cache_full'] ?? false))
    .'   restart pending: '.$yn((bool) ($status['restart_pending'] ?? false)));
$row('Started', $ts((int) ($stats['start_time'] ?? 0))
    .'   last restart: '.$ts((int) ($stats['last_restart_time'] ?? 0)));

// --- Memory ---------------------------------------------------------------
$memTotal = $mem['used_memory'] + $mem['free_memory'] + $mem['wasted_memory'];
printf("\nMemory (PHP_OPCACHE_MEMORY_CONSUMPTION)\n");
$row('Used', $mib($mem['used_memory']).' / '.$mib($memTotal));
$row('Wasted', sprintf('%s (%.2f %%)', $mib($mem['wasted_memory']), $mem['current_wasted_percentage']));

// --- Interned strings -------------------------------------------------------
if (null !== $interned) {
    printf("\nInterned strings (PHP_OPCACHE_INTERNED_STRINGS_BUFFER)\n");
    $row('Used', sprintf('%s / %s (%s strings)',
        $mib($interned['used_memory']),
        $mib($interned['buffer_size']),
        $num((int) $interned['number_of_strings'])));
}

// --- Scripts / keys ----------------------------------------------------------
printf("\nScripts (PHP_OPCACHE_MAX_ACCELERATED_FILES)\n");
$row('Cached scripts', $num((int) $stats['num_cached_scripts']));
$row('Cached keys', $num((int) $stats['num_cached_keys']).' / '.$num((int) $stats['max_cached_keys']));

// --- Hit rate -----------------------------------------------------------------
printf("\nHit rate\n");
$row('Hits', $num((int) $stats['hits']).'   misses: '.$num((int) $stats['misses']));
$row('Rate', sprintf('%.2f %%', $stats['opcache_hit_rate']));

// --- Restarts -------------------------------------------------------------------
printf("\nRestarts (cumulative since start)\n");
$row('OOM', $num((int) $stats['oom_restarts'])
    .'   hash: '.$num((int) $stats['hash_restarts'])
    .'   manual: '.$num((int) $stats['manual_restarts']));

// --- Preload ----------------------------------------------------------------------
printf("\nPreload (opcache.preload = %s)\n", $directives['opcache.preload'] ?: 'not set');
if (null !== $preload) {
    $row('Memory', $mib($preload['memory_consumption']));
    $row('Classes', $num(count($preload['classes'] ?? []))
        .'   functions: '.$num(count($preload['functions'] ?? [])));
} else {
    echo "  (no preload statistics — preloading inactive)\n";
}

// --- Warnings: each maps a symptom to the PHP_OPCACHE_* override that fixes
// it. Host-specific tuning goes in .env.php.local — compose loads it on top
// of .env.php, and it survives a `task env:init` re-bootstrap.
$warnings = [];
if ($status['cache_full'] ?? false) {
    $warnings[] = 'Cache full — new scripts run uncached. Raise PHP_OPCACHE_MEMORY_CONSUMPTION in .env.php.local.';
}
if (($stats['oom_restarts'] ?? 0) > 0) {
    $warnings[] = sprintf('%d OOM restart(s) — the cache ran out of memory and flushed itself. Raise PHP_OPCACHE_MEMORY_CONSUMPTION in .env.php.local.', $stats['oom_restarts']);
}
if (($stats['hash_restarts'] ?? 0) > 0) {
    $warnings[] = sprintf('%d hash restart(s) — the key table overflowed. Raise PHP_OPCACHE_MAX_ACCELERATED_FILES in .env.php.local.', $stats['hash_restarts']);
}
if (($stats['max_cached_keys'] ?? 0) > 0 && $stats['num_cached_keys'] / $stats['max_cached_keys'] > 0.9) {
    $warnings[] = 'Cached keys above 90% of max — raise PHP_OPCACHE_MAX_ACCELERATED_FILES in .env.php.local before the hash table overflows.';
}
if (null !== $interned && $interned['buffer_size'] > 0 && $interned['used_memory'] / $interned['buffer_size'] > 0.9) {
    $warnings[] = 'Interned-strings buffer above 90% used — raise PHP_OPCACHE_INTERNED_STRINGS_BUFFER in .env.php.local.';
}
if (($mem['current_wasted_percentage'] ?? 0) > 5) {
    $warnings[] = 'Wasted memory above 5% — recreate the container to reclaim (with validate_timestamps=0 waste normally only accrues across image upgrades).';
}

echo "\n";
if ([] === $warnings) {
    echo "Health: OK — no warnings.\n";
} else {
    echo "Warnings\n";
    foreach ($warnings as $w) {
        echo '  ! '.$w."\n";
    }
}
PHP
