# OS2display v3 — Docker hosting

[![E2E](https://github.com/os2display/os2display-docker-server/actions/workflows/e2e.yaml/badge.svg?branch=release%2F3.0.0)](https://github.com/os2display/os2display-docker-server/actions/workflows/e2e.yaml)
[![Compose](https://github.com/os2display/os2display-docker-server/actions/workflows/compose.yaml/badge.svg)](https://github.com/os2display/os2display-docker-server/actions/workflows/compose.yaml)
[![Tasks](https://github.com/os2display/os2display-docker-server/actions/workflows/tasks.yaml/badge.svg)](https://github.com/os2display/os2display-docker-server/actions/workflows/tasks.yaml)
[![Markdown](https://github.com/os2display/os2display-docker-server/actions/workflows/markdown.yaml/badge.svg)](https://github.com/os2display/os2display-docker-server/actions/workflows/markdown.yaml)
[![Shell](https://github.com/os2display/os2display-docker-server/actions/workflows/sh.yaml/badge.svg)](https://github.com/os2display/os2display-docker-server/actions/workflows/sh.yaml)
[![YAML](https://github.com/os2display/os2display-docker-server/actions/workflows/yaml.yaml/badge.svg)](https://github.com/os2display/os2display-docker-server/actions/workflows/yaml.yaml)
[![License: MPL 2.0](https://img.shields.io/badge/license-MPL_2.0-brightgreen.svg)](https://www.mozilla.org/en-US/MPL/2.0/)
[![Docker Compose v2](https://img.shields.io/badge/docker--compose-v2-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![Task v3](https://img.shields.io/badge/task-v3-29BEB0)](https://taskfile.dev/)

Deployment tooling for hosting the [os2display](https://github.com/os2display) v3 API on a single
host. Wraps the upstream
[`display-api-service`](https://github.com/os2display/display-api-service) image (which bundles
the admin UI and screen client in 3.x) with a docker-compose stack, optional bundled MariaDB and
Traefik, and a Taskfile for the operator workflow.

The whole repo is two binaries away: install [Docker](https://docs.docker.com/engine/install/)
with Compose v2 and [Task](https://taskfile.dev/) and you can run any task. No language tooling,
no build step, no shell-script glue beyond the Taskfile.

## Contents

- [Operator guide](#operator-guide)
  - [Prerequisites](#prerequisites)
  - [Quick start: fresh install](#quick-start-fresh-install)
  - [Configuration files](#configuration-files)
  - [Stack composition (compose profiles)](#stack-composition-compose-profiles)
  - [Network topology](#network-topology)
  - [Cookbook](#cookbook)
  - [Caveats and foot-guns](#caveats-and-foot-guns)
  - [Migrating from an older release](#migrating-from-an-older-release)
- [Developer guide](#developer-guide)
  - [Local dev quick start](#local-dev-quick-start)
  - [Design principles](#design-principles)
  - [Local development](#local-development)
  - [Repository layout](#repository-layout)
  - [Linting](#linting)
  - [CI workflows](#ci-workflows)
- [Reference](#reference)
  - [All tasks](#all-tasks)
  - [Image registries](#image-registries)

---

## Operator guide

> [!IMPORTANT]
> This section covers **production server installs** — real FQDN, public
> ports 80/443, Let's Encrypt or operator-supplied cert, real tenant +
> admin user. For **local testing on a dev machine** (no public DNS, no
> real cert, throwaway tenant/user), jump to the
> [Developer guide → Local dev quick start](#local-dev-quick-start).

### Prerequisites

**Host.**

- **Production deploy target: Linux.** All testing assumes a Linux deploy host; BSDs untested.
  No host-side build, language toolchain, or DB-client dependencies — every script invocation
  routes through a transient docker container (`alpine/openssl`, `alpine`, the bundled
  mariadb image, etc.). `task db:backup` runs `mariadb-dump` *inside* the mariadb container.
- **Local dev: Linux, macOS, Windows-WSL2.** All Taskfile-driven workflows (`task env:init`,
  `task env:traefik`, `task dev:cert`, `task install`, `task host:resources`, etc.) run their
  shell logic inside transient docker containers, so they're cross-platform on any host with a
  reachable docker daemon. Docker Desktop (macOS / Windows) and Docker Engine on Linux both work.
- Docker Engine 20.10+ with Compose v2 (the integrated `docker compose` command, not the
  legacy `docker-compose` Python wrapper).
- [Task](https://taskfile.dev/#/installation) v3+.
- A host user with **UID 1042 / GID 1042** (Linux deploy only) — the os2display container writes
  media and reads JWT keys as `deploy` (UID 1042). Installing as a host user with the same UID
  prevents bind-mount permission surprises. The `nginx-api` container reads `./media` as UID 101
  (`nginx-unprivileged`), so `./media` must be group-readable as well.

  ```bash
  sudo groupadd -g 1042 deploy
  sudo useradd -u 1042 -g 1042 -m -s /bin/bash deploy
  sudo usermod -aG docker deploy
  ```

  On macOS / Windows-WSL2 dev hosts the bind-mount UID contract is irrelevant — Docker Desktop
  brokers ownership at the VM boundary.

**Network and DNS.**

- A fully qualified domain name (FQDN) resolving to the host. Two DNS records by default:
  - `os2display.example.com` (the main api + admin + client domain)
  - `traefik.example.com` (the Traefik dashboard, if exposed)
- Inbound `:80` (Let's Encrypt http-01 challenge + the redirect to https) and `:443` (https).

**Certificates.** Either:

- **Let's Encrypt** (default): Traefik issues per-host on first request via http-01 challenge.
  Operator just supplies an email address and a host that's reachable from the public internet.
- **Custom cert** (`SERVER_CERT_PROVIDER=cert-file`): operator drops `docker.crt` + `docker.key`
  in `traefik/ssl/`. Cert must cover **every** host the stack serves (api domain *and* dashboard
  domain) — see [Caveats](#caveats-and-foot-guns).

### Quick start: fresh install

```bash
git clone git@github.com:os2display/os2display-docker-server.git
cd os2display-docker-server

# 1. Bootstrap every env file in one go: prompts for the public domain,
#    copies per-service templates, extracts .env.symfony from the API
#    image, auto-generates random APP_SECRET + JWT_PASSPHRASE, and bumps
#    DATABASE_URL serverVersion to match the bundled mariadb pin.
task env:init

# 2. Traefik dashboard auth + (for letsencrypt) Let's Encrypt email,
#    or (for cert-file) custom cert filenames. Interactive prompts.
task env:traefik

# 3. Bring the stack up: auto-fills any CHANGE_ME mariadb sentinels,
#    pulls images, runs migrations, prompts for initial tenant + admin
#    user, installs bundled templates.
task install
```

Edit `.env.symfony` afterwards for any `ADMIN_*`, `CLIENT_*`, `OIDC_*`,
or `DATABASE_URL` overrides; `task env:diff` highlights what the image
ships vs what you've changed. See [Configuration files](#configuration-files)
for the full per-service surface.

After `task install` returns, the API + bundled admin UI + screen client are reachable at
`https://<your-domain>/`, `/admin/`, `/client/`. The Traefik dashboard is at
`https://<traefik-host>/traefik/dashboard/` (basic-auth-gated).

**Local dev testing?** Use `task dev:install` instead — see
[Developer guide → Local dev quick start](#local-dev-quick-start).

### Configuration files

Each service reads its own env file. The checked-in `.env.<X>.example` files are the canonical
templates; edit your local copy, never the committed one.

**Three project-wide conventions** that hold across every env file:

1. **Sane production defaults.** The shipped examples produce a working production stack
   without operator-edit-everywhere ceremony. Values that *can* default safely (PHP memory
   limits, OPcache settings, nginx body sizes, log retention, TLS profile) are tuned for a
   medium-load production deploy. Values that *must* be operator-supplied (API domain,
   dashboard auth, MariaDB passwords) are sentinels that fail-loud or prompt: `task env:init`
   prompts for the domain and auto-generates `APP_SECRET` / `JWT_PASSPHRASE`; `task install`
   refuses to start while `MARIADB_*=CHANGE_ME` or `SERVER_DASHBOARD_AUTH=CHANGE_ME` sentinels
   remain (mariadb auto-fills with random hex; dashboard auth must be set via `task env:traefik`).
2. **All configuration options are documented in the `.env.<X>.example` files.** The examples
   are the canonical reference — if a knob exists, it's there with a comment explaining what
   it does and what value space it accepts. There's no separate "advanced configuration"
   surface elsewhere.
3. **`env_file:` (not compose `environment:`) per service** — see
   [Design principles](#design-principles) for the rationale. Each service's `env_file:` list
   is what isolates its config; compose-level `environment:` blocks would shadow `env_file:`
   values silently and were removed in v3.

| File | Service | Purpose | Bootstrap |
|---|---|---|---|
| `.env` | (compose) | Compose orchestration: project name, profile, image versions, server domain. Read by `docker compose` for substitution into the YAML before parsing. | `task env:init` (prompts for domain) |
| `.env.symfony` | os2display | Symfony app config — `APP_SECRET`, `DATABASE_URL`, `JWT_*`, `INTERNAL_OIDC_*`, `EXTERNAL_OIDC_*`, `ADMIN_*`, `CLIENT_*`, calendar feed, etc. | `task env:init` (extracts `/app/.env` from the API image — the upstream-canonical source — auto-generates secrets, bumps `serverVersion`) |
| `.env.php` | os2display | PHP-FPM runtime tuning — `PHP_MEMORY_LIMIT`, `PHP_OPCACHE_*`, `PHP_PM_*`. | `task env:init` (copies template) |
| `.env.nginx` | nginx-api | Nginx runtime tuning — `NGINX_MAX_BODY_SIZE`, etc. | `task env:init` (copies template) |
| `.env.mariadb` | mariadb | MariaDB credentials. `task install` auto-fills `CHANGE_ME` sentinels with random hex and syncs `DATABASE_URL`. | `task env:init` (copies template) |
| `.env.traefik` | traefik | Cert provider, dashboard auth (htpasswd), domain, Let's Encrypt email. | `task env:traefik` (interactive) |

`task env:diff` compares your `.env.symfony` against the example shipped in the currently-pinned
API image — useful when bumping `OS2DISPLAY_VERSION_API` to spot new keys upstream added.

### Stack composition (compose profiles)

`COMPOSE_PROFILES` in `.env` controls which built-in infrastructure services start. Core services
(`os2display`, `nginx-api`, `redis`) always run. The admin UI and screen client are bundled into
the `os2display` image in 3.x and served as Symfony routes — there are no separate `admin` /
`client` containers.

| `COMPOSE_PROFILES` | Built-in services started | Use when |
|---|---|---|
| `mariadb,traefik` | MariaDB + Traefik (default) | Single-host install with no external infra. |
| `traefik` | Traefik only | External database (set `DATABASE_URL` in `.env.symfony` to point at it). |
| `mariadb` | MariaDB only | External proxy in front. |
| (empty) | Neither | Both DB and proxy provided externally. |

`COMPOSE_PROFILES` is read natively by docker compose; no `-f` flags or wrapper scripts.

There is also a `dev` profile for the local linters (`markdownlint`, `prettier`). It's only
activated explicitly via `docker compose --profile dev run …`, never by `task install`.

### Network topology

```mermaid
flowchart LR
    Internet((Internet))

    subgraph frontend ["frontend network (public)"]
        direction TB
        Traefik[Traefik]
        NginxAPI[nginx-api]
    end

    subgraph proxy ["proxy network (internal)"]
        SocketProxy["socket-proxy<br/>(RO docker.sock)"]
    end

    subgraph app ["app network (internal)"]
        direction TB
        OS2Display["os2display<br/>(PHP-FPM)"]
        Redis[(Redis)]
        MariaDB[(MariaDB)]
    end

    Media[/"./media bind mount"/]

    Internet -->|":80, :443"| Traefik
    Traefik -->|HTTP| NginxAPI
    NginxAPI -->|"FastCGI :9000"| OS2Display
    OS2Display --> Redis
    OS2Display --> MariaDB
    Traefik -.->|read-only docker API| SocketProxy
    NginxAPI -.->|reads| Media
    OS2Display -.->|writes| Media
```

Three docker networks:

- **`frontend`** (compose-managed by default) — the public-facing network. Traefik attaches here
  on the operator side; nginx-api attaches here so Traefik can route to it. Engine name is
  configurable via `OS2DISPLAY_FRONTEND_NETWORK` in `.env` (default: `frontend`). To share this
  network with other compose projects, see
  [Cookbook: share Traefik with another compose project](#how-do-i-share-traefik-with-another-compose-project).
- **`app`** (internal, compose-managed) — isolates os2display ↔ nginx-api ↔ redis ↔ mariadb.
  `nginx-api` is the only service that straddles `app` and `frontend` (see diagram); every other
  application service is reachable only over `app`.
- **`proxy`** (internal, compose-managed, traefik profile only) — locks down Traefik ↔
  socket-proxy. Read-only docker socket exposure on a network with `internal: true`, no
  bridge to the host.

### Cookbook

- [How do I install fresh?](#how-do-i-install-fresh)
- [How do I upgrade the os2display api + nginx images?](#how-do-i-upgrade-the-os2display-api--nginx-images)
- [How do I upgrade the bundled MariaDB across a major version?](#how-do-i-upgrade-the-bundled-mariadb-across-a-major-version)
- [How do I switch from Let's Encrypt to a custom certificate?](#how-do-i-switch-from-lets-encrypt-to-a-custom-certificate)
- [How do I run the stack on localhost without a public domain?](#how-do-i-run-the-stack-on-localhost-without-a-public-domain)
- [How do I run with an external database?](#how-do-i-run-with-an-external-database)
- [How do I run with an external Traefik?](#how-do-i-run-with-an-external-traefik)
- [How do I share Traefik with another compose project?](#how-do-i-share-traefik-with-another-compose-project)
- [How do I tune PHP for big imports or long requests?](#how-do-i-tune-php-for-big-imports-or-long-requests)
- [How do I tune nginx for large uploads?](#how-do-i-tune-nginx-for-large-uploads)
- [How do I take a database backup?](#how-do-i-take-a-database-backup)
- [How do I diagnose database performance issues?](#how-do-i-diagnose-database-performance-issues)
- [How do I check PHP OPcache health?](#how-do-i-check-php-opcache-health)
- [How do I restore from a backup?](#how-do-i-restore-from-a-backup)
- [How do I add a tenant?](#how-do-i-add-a-tenant)
- [How do I add a user?](#how-do-i-add-a-user)
- [How do I install or update bundled templates?](#how-do-i-install-or-update-bundled-templates)
- [How do I authenticate to Docker Hub (rate limits)?](#how-do-i-authenticate-to-docker-hub-rate-limits)
- [How do I authenticate to GHCR?](#how-do-i-authenticate-to-ghcr)
- [How do I clear the application cache?](#how-do-i-clear-the-application-cache)
- [How do I set resource limits for a dedicated host?](#how-do-i-set-resource-limits-for-a-dedicated-host)
- [How do I tune PHP-FPM for the os2display container's memory limit?](#how-do-i-tune-php-fpm-for-the-os2display-containers-memory-limit)
- [How do I see overall disk usage of the stack?](#how-do-i-see-overall-disk-usage-of-the-stack)
- [How do I see media disk usage per tenant?](#how-do-i-see-media-disk-usage-per-tenant)
- [How do I tail and triage logs?](#how-do-i-tail-and-triage-logs)
- [How do I see docker log disk usage and tune retention?](#how-do-i-see-docker-log-disk-usage-and-tune-retention)

#### How do I install fresh?

See [Quick start](#quick-start-fresh-install).

#### How do I upgrade the os2display api + nginx images?

> [!IMPORTANT]
> Always run `task db:backup` before `task update`. The `app:update` step applies Doctrine
> migrations that may include `DROP COLUMN`, type changes, or data transforms — none of which
> are reversed by reverting `OS2DISPLAY_VERSION_API`. Rollback is "restore from backup, then
> revert the tag", not a clean tag swap.

```bash
task db:backup                     # before every task update
$EDITOR .env                       # bump OS2DISPLAY_VERSION_API
task update                        # pull, recreate, run app:update (migrations + cache:warmup)
task env:diff                      # check whether the new image added Symfony env keys
                                   # — if yes, edit .env.symfony to match
```

`task update` pulls fresh images, recreates the containers (preserving named volumes), and runs
`bin/console app:update`. Image swaps and container recreation themselves don't touch data —
the schema rewrite happens inside `app:update`. See
[Caveats](#caveats-and-foot-guns) for the full reasoning.

#### How do I upgrade the bundled MariaDB across a major version?

See [UPGRADE.md](UPGRADE.md). The 1.x → 3.x section has the recipe (it covers the 10.x → 11.4
jump that came with the 3.0 release); the same `task db:backup` → `task db:upgrade` →
update `DATABASE_URL` `serverVersion=` flow applies to any future major bump.

#### How do I switch from Let's Encrypt to a custom certificate?

```bash
$EDITOR .env.traefik
# SERVER_CERT_PROVIDER=cert-file
# SERVER_CUSTOM_CERT_FILE=docker.crt
# SERVER_CUSTOM_KEY_FILE=docker.key

cp /path/to/your.crt traefik/ssl/docker.crt
cp /path/to/your.key traefik/ssl/docker.key

task up                            # picks up the new SERVER_CERT_PROVIDER
```

`SERVER_CERT_PROVIDER` selects two files via the volume mounts:
`traefik/traefik-${SERVER_CERT_PROVIDER}.yml` and
`traefik/dynamic-conf-${SERVER_CERT_PROVIDER}.yaml`. The cert-file variants have no Let's
Encrypt resolver — Traefik picks certs from the file provider via SNI matching against the
hostnames in your cert.

> [!IMPORTANT]
> The cert must cover **every** host the stack serves — both `OS2DISPLAY_SERVER_DOMAIN` and the
> Traefik dashboard `SERVER_DOMAIN`. A wildcard (`*.example.com`) is the simplest path. Without
> SAN coverage for the dashboard host, Traefik falls back to the file provider's default cert
> (whichever you declared first), and the dashboard hits a TLS error. See
> [Caveats](#caveats-and-foot-guns).

#### How do I run the stack on localhost without a public domain?

For local-host development without a real DNS name or Let's Encrypt.

**Shortcut.** `task dev:install` runs the recipe below end-to-end:
bootstraps the env files for `*.localhost`, generates the self-signed cert,
and runs `task install`. `task dev:env` is the env-only step (no cert, no
stack start) if you want finer control. See the
[Localhost dev quick start](#quick-start-fresh-install) box for usage.

The manual steps the shortcut codifies:

1. Set localhost-friendly domains in `.env` and `.env.traefik`:

   ```bash
   # .env
   OS2DISPLAY_SERVER_DOMAIN=os2display.localhost

   # .env.traefik
   SERVER_DOMAIN=traefik.localhost
   SERVER_CERT_PROVIDER=cert-file
   SERVER_CUSTOM_CERT_FILE=dev.crt
   SERVER_CUSTOM_KEY_FILE=dev.key
   ```

   `*.localhost` resolves to `127.0.0.1` automatically on Linux, macOS, and Windows per
   RFC 6761 — no `/etc/hosts` edit needed.

2. Generate a self-signed cert:

   ```bash
   task dev:cert
   ```

   Writes `traefik/ssl/dev.{crt,key}` covering both `*.localhost` SANs plus plain `localhost`
   and `127.0.0.1`. Uses a transient `alpine/openssl` container, so no host `openssl`
   dependency. `FORCE=1 task dev:cert` to regenerate.

3. `task install` and visit `https://os2display.localhost/admin`. The browser shows an
   "untrusted CA" warning the first time — accept it (or trust `traefik/ssl/dev.crt` in your
   system keychain to skip the prompt; macOS `security add-trusted-cert -k
   ~/Library/Keychains/login.keychain-db traefik/ssl/dev.crt`).

**Caveats.** If you've previously run a real-cert stack on the same domain, the browser's
HSTS cache may refuse the self-signed cert. Use a fresh `.localhost` name to avoid this. The
filenames `dev.{crt,key}` are deliberate — they sit alongside any operator-supplied
production `docker.{crt,key}` without overwriting it. Not for production: RSA-2048 / SHA-256
/ 365 days / untrusted CA.

#### How do I override env config locally without committing?

Each service's compose `env_file:` block reads two files in order:
`.env.<svc>` (the operator's primary config, copied from the committed
`.env.<svc>.example` template) and an optional `.env.<svc>.local` (loaded
on top, overrides earlier values). The same pattern applies to
`.env.symfony.local`. All `*.local` files are gitignored.

```bash
# Example: temporarily bump mariadb innodb buffer pool for one host
$EDITOR .env.mariadb.local
# MARIADB_INNODB_BUFFER_POOL_SIZE=2G

# Or: per-host PHP-FPM worker count without forking the example
$EDITOR .env.php.local
# PHP_PM_MAX_CHILDREN=32

task update                            # picks up the override on container recreate
```

Use this for site-specific overrides that shouldn't end up in `.env.<svc>`
(which `task env:init` may bootstrap from the committed template on a
fresh install). The two-file `env_file:` list is compose-native; missing
`.local` files are silently skipped (`required: false`).

| Layer | Purpose | Lifecycle |
|---|---|---|
| `.env.<svc>.example` | Committed template, sane production defaults | Edit via PR — affects every operator |
| `.env.<svc>` | Operator's primary config | Bootstrapped from the example by `task env:init`; gitignored |
| `.env.<svc>.local` | Site-specific overrides (host-specific tuning, debug flags) | Operator-managed, never auto-created; gitignored |

#### How do I run with an external database?

```bash
$EDITOR .env
# COMPOSE_PROFILES=traefik          # drop "mariadb" — bundled mariadb won't start

$EDITOR .env.symfony
# DATABASE_URL="mysql://user:pass@your-db-host:3306/dbname?serverVersion=mariadb-11.4.10-MariaDB"

task up
```

`.env.mariadb` and `task db:backup` / `task db:upgrade` are no-ops in this configuration — they
operate on the bundled mariadb container, not your external DB. Run your own backup tooling
against the external DB.

#### How do I run with an external Traefik?

```bash
$EDITOR .env
# COMPOSE_PROFILES=mariadb           # drop "traefik"
```

The bundled Traefik and socket-proxy don't start. Your external Traefik must be on a docker
network the nginx-api container can join. By default that's a network named `frontend` —
override the engine name via `OS2DISPLAY_FRONTEND_NETWORK` and use the shared-frontend opt-in
(next recipe).

#### How do I share Traefik with another compose project?

When running multiple compose projects on one host behind a single Traefik, switch the
`frontend` network from compose-managed to external:

```bash
docker network create os2display_shared_frontend     # once on the host

$EDITOR .env
# OS2DISPLAY_FRONTEND_NETWORK=os2display_shared_frontend
# COMPOSE_FILE=docker-compose.yml:compose.shared-frontend.yml
```

Now `task install` (and `docker compose up`) attaches services to the existing engine network
instead of creating one. `task purge` will not remove the shared network.

`compose.shared-frontend.yml` is a one-line override that flips the network to `external: true`.
Compose's auto-loaded `compose.override.yml` is also available for one-off per-host customisation.

#### How do I tune PHP for big imports or long requests?

```bash
$EDITOR .env.php
# PHP_MAX_EXECUTION_TIME=120
# PHP_MEMORY_LIMIT=512M
# PHP_PM_MAX_CHILDREN=32             # if you have lots of concurrent traffic
# PHP_OPCACHE_VALIDATE_TIMESTAMPS=0  # KEEP at 0 in production

task up                              # recreate the os2display container
```

Match `PHP_POST_MAX_SIZE` and `PHP_UPLOAD_MAX_FILESIZE` with `NGINX_MAX_BODY_SIZE` in
`.env.nginx` — see next recipe.

#### How do I tune nginx for large uploads?

```bash
$EDITOR .env.nginx
# NGINX_MAX_BODY_SIZE=500m

$EDITOR .env.php
# PHP_POST_MAX_SIZE=500M             # nginx must be >= php
# PHP_UPLOAD_MAX_FILESIZE=500M

task up
```

Nginx rejects oversized requests at the proxy edge before they reach php-fpm; PHP rejects them
at the parser. Both must be raised together for the larger uploads to actually go through.

#### How do I take a database backup?

```bash
task db:backup
ls backup/
# 20260505T140723Z.sql.gz
```

Online dump (`mariadb-dump --single-transaction --quick --routines --triggers --events`),
gzipped. No service downtime; the `--single-transaction` flag gives a consistent InnoDB
snapshot. The `backup/` directory has its own `.gitignore` keeping all dumps out of git.

#### How do I diagnose database performance issues?

Three tasks for the typical PHP-app-under-load symptom set — connection exhaustion,
aborted connects, lock-wait timeouts, slow queries, buffer-pool pressure:

```bash
task db:metrics      # snapshot of operational counters (connections, locks, buffer pool)
task db:processes    # SHOW FULL PROCESSLIST — every active connection + its query
task db:errors       # mariadb stderr filtered for trouble patterns, last hour
```

`db:metrics` is the first stop. Output looks like:

```text
Connections
  Active:        23 / 151 (Threads_connected / max_connections)
  Peak:          47 (Max_used_connections since startup)
  Cumulative:    1342 connects, 0 aborted-connects, 3 aborted-clients

InnoDB buffer pool
  Size:          128 MiB (used 122 MiB)
  Hit ratio:     99.87 %
…
```

If `Active` is approaching `max_connections`, PHP-FPM is opening connections faster than
they're closing — bump `pm.max_children` down, raise mariadb's `max_connections`, or both.
If `Hit ratio` is below ~99%, the buffer pool is too small for the working set; raise
`innodb_buffer_pool_size` via a `command:` override in a compose override file. If
`InnoDB row locks > Waits` is climbing, run `task db:processes` to find the blocking
query. Cumulative `aborted-connects` ticks usually mean Doctrine's connection wait timed
out before the connect handshake finished.

`db:errors` greps the mariadb container's stderr for `Too many connections`, `Aborted
connection`, `lock wait timeout exceeded`, `Out of memory`, `[ERROR]`, `[CRITICAL]` over
the last hour. Empty output means clean.

#### How do I check PHP OPcache health?

```bash
task php:opcache          # human-readable report
RAW=1 task php:opcache    # the probe's raw JSON, for jq piping
```

The PHP-side counterpart to `db:metrics`: a snapshot of the FPM pool's OPcache —
memory used/wasted, interned-strings buffer, cached keys vs `max_accelerated_files`,
hit rate, OOM/hash restarts, and preload statistics. It wraps the `opcache-status`
probe shipped in the API image (a cgi-fcgi round-trip into an FPM worker — the only
place the pool's OPcache shared memory is visible; CLI PHP keeps a separate cache),
and ends with a warnings block that maps each symptom to the `PHP_OPCACHE_*`
override that fixes it:

```text
Memory (PHP_OPCACHE_MEMORY_CONSUMPTION)
  Used:           98.2 MiB / 256.0 MiB
  Wasted:         0.0 MiB (0.00 %)

Scripts (PHP_OPCACHE_MAX_ACCELERATED_FILES)
  Cached scripts: 7,912
  Cached keys:    8,065 / 16,229
…
Health: OK — no warnings.
```

OOM restarts or `cache full: yes` → raise `PHP_OPCACHE_MEMORY_CONSUMPTION`; cached
keys near max or hash restarts → raise `PHP_OPCACHE_MAX_ACCELERATED_FILES`. Set the
override in `.env.php.local` — compose loads it on top of `.env.php`, and it survives
an `env:init` re-bootstrap (see
[How do I override env config locally without committing?](#how-do-i-override-env-config-locally-without-committing)).
The probe ships in API images **3.0.0-rc4 and newer** — on older images the task
fails with guidance to bump `OS2DISPLAY_VERSION_API` and `task update`.

#### How do I restore from a backup?

> [!CAUTION]
> Piping a dump into a populated database overwrites rows in place — there's no confirmation
> prompt, no dry-run. Make sure the target is the database you intend to overwrite before
> running the command. To restore into a clean DB instead, `task purge` first (also destructive
> — wipes all data and volumes) and re-run `task install` before piping in the dump.

```bash
gunzip < backup/20260505T140723Z.sql.gz \
  | docker compose exec -T mariadb mariadb -u root -p"$(grep ^MARIADB_ROOT_PASSWORD= .env.mariadb | cut -d= -f2-)"
```

#### How do I add a tenant?

```bash
task tenant:add                      # interactive: prompts for tenant id, title, description
```

Tenants are groups of users sharing configuration (IT, Library, Schools, …). `task install`
prompts for the first tenant during install.

#### How do I add a user?

```bash
task user:add                        # interactive: email, password, role, tenant
```

Roles are `editor` or `admin`. Editors create slides + screens within their tenant; admins
manage tenant-level config too.

#### How do I install or update bundled templates?

```bash
task templates:install
```

Runs `bin/console app:templates:install --all --update` and
`bin/console app:screen-layouts:install --all --update --cleanupRegions` against the bundled
template set in the API image. v3 ships templates inside the image — there's no longer a list
of names or a version pin in `.env`.

Re-run after `task update` when the new image version added templates.

#### How do I authenticate to Docker Hub (rate limits)?

Anonymous Docker Hub pulls are capped at **100 / 6h / IP**. Multi-host operators behind a NAT
hit it during a sequence of `task install` runs.

```bash
docker login docker.io
# Username: <your Docker Hub username>
# Password: <a Docker Hub Personal Access Token>
```

Authenticated free accounts get **200 / 6h / user**. For higher scale, set up a
[pull-through registry mirror](https://docs.docker.com/registry/recipes/mirror/) and point
your daemon at it.

For unattended hosts, configure a credential helper instead of leaving the token in
`~/.docker/config.json` plaintext — `docker-credential-pass` (backed by `pass`) is the usual
pick.

#### How do I authenticate to GHCR?

All `ghcr.io/os2display/*` images this stack uses are public today, so `docker pull` works
without `docker login`. No action needed for a fresh install.

If a future image becomes private or you mirror Docker Hub images into your own private GHCR
namespace, authenticate with a GitHub PAT scoped `read:packages`:

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
# or, if `gh` is set up:
gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin
```

#### How do I clear the application cache?

```bash
task cache:clear                     # bin/console cache:clear inside os2display
```

Run after editing `.env.symfony` (Doctrine and Symfony cache resolved-config), after upgrading
the image (`task update` already does it), or when troubleshooting stale routes.

#### How do I set resource limits for a dedicated host?

The stack ships with no `mem_limit` / `cpus` constraints by default — fixed limits without
measuring host capacity are guesses. `task host:resources` derives a reasonable allocation
from `/proc/meminfo` + `nproc` for **dedicated** hosts and prints a compose override:

```bash
task host:resources                                            # see the recommendation
task host:resources > compose.resource-limits.yml              # capture
$EDITOR .env
# add:  COMPOSE_FILE=docker-compose.yml:compose.resource-limits.yml
task up                                                        # picks up the limits
```

The recommendation sets `mem_limit` for **every service**, not just the memory-hungry ones:

- **Sized to host RAM** (50% / 30% of dynamic allocation): `os2display`, `mariadb`.
- **Fixed ceilings** (bounded workloads, host-independent): `nginx-api` 128 MiB, `redis`
  384 MiB (above the in-process `--maxmemory 256mb` so the kernel-level OOM kill is a hard
  stop, not normal operation), `traefik` 256 MiB, `socket-proxy` 64 MiB.

The task is **Linux-only** and assumes a **dedicated** host. On macOS it exits with an error;
on shared hosts (a VPS also running other services), scale the recommended values down before
applying. Hosts with less than ~2.3 GiB of RAM will fail with an explicit error message —
the dynamic split needs at least 1 GiB on top of the fixed ceilings.

`compose.resource-limits.yml` is gitignored — it's host-specific and operator-generated, never
committed.

#### How do I tune PHP-FPM for the os2display container's memory limit?

> [!IMPORTANT]
> If you set a `mem_limit` on the os2display container without re-tuning PHP-FPM,
> `pm.max_children` will spawn workers past the cgroup ceiling and the container OOM-kills
> itself under load. Always re-run this recipe after the first time you set or change a memory
> limit (via `host:resources` or hand-edit), not just during initial setup.

Once `host:resources` (or a hand-set `mem_limit`) caps the os2display container at, say, 256 MiB,
PHP-FPM's `pm.max_children`, OPcache memory, and the spare-worker thresholds need to fit
inside that ceiling.

```bash
task host:php -- 256                         # tight ceiling: 2 workers
task host:php -- 1024                        # comfortable mid-size: ~11 workers
task host:php -- 4096                        # big host: ~60+ workers
```

The task prints math + recommendations to stderr and the env-var assignments on stdout, so
operators can capture the override:

```bash
task host:php -- 256 >> .env.php             # append; remove the duplicates afterwards
$EDITOR .env.php                             # confirm only one of each PHP_PM_* / PHP_OPCACHE_*
task up                                      # picks up the new pool sizing
```

Heuristic (Symfony + Doctrine + warm OPcache):

- Per-worker estimate: 60 MiB (conservative; real is 40–80 MiB depending on bundles).
- PHP-FPM overhead (master + non-pool): 50 MiB.
- OPcache memory: 64 MiB / 128 MiB / 256 MiB depending on container size.
- `pm.max_children = (mem_limit − OPcache − overhead) / 60`, with a floor of 2.
- `pm.start_servers ≈ max_children / 4`; `pm.min_spare ≈ /5`; `pm.max_spare ≈ /2`.

Hosts smaller than 256 MiB on the os2display container will fail with an explicit error —
after OPcache + overhead there isn't enough budget for two workers. Bump `mem_limit` (in
`compose.resource-limits.yml`) to at least 256 MiB and re-run.

#### How do I see overall disk usage of the stack?

```bash
task host:disk
```

Reports bind-mount sizes (`./media`, `./jwt`, `./backup`), named-volume sizes (the bundled
MariaDB and Redis volumes, detected by their `${COMPOSE_PROJECT_NAME}_*` prefix), and host
filesystem free-space on the project's mount point. Use it before / after `task db:backup` to
confirm the dump landed, or before scaling up the host to see the actual stack footprint.

#### How do I see media disk usage per tenant?

```bash
task host:disk:tenants
```

Walks `./media/`, prints each tenant's subdirectory size sorted descending, with a total at
the bottom. Per the v3 image's Vich uploader config, each tenant's uploads are stored at
`./media/<tenantKey>/`, so the directory names ARE the tenant keys — the task doesn't query
the database, it just reads the filesystem.

#### How do I tail and triage logs?

```bash
task logs                       # follow all services, last 100 lines
task logs S=os2display          # follow one service
task logs S=traefik lines=500   # bigger backlog
task logs:since T=30m           # everything from the last 30 minutes (no follow)
task logs:since T=2h S=mariadb  # one service, last 2 hours
task logs:errors                # error/critical/fatal/exception lines, last hour
task logs:access                # tail traefik's JSON access log, one compact line per request
```

`logs` (alias of `logs:follow`) is the daily driver. `logs:since` is for "what happened since X"
without the live tail. `logs:errors` greps the last hour across all services for the noisy
keywords (`error`, `critical`, `emerg`, `fatal`, `exception`, `stacktrace`, case-insensitive) —
useful first stop after a user reports something broke. `logs:access` requires `jq` on the
host and projects each access-log JSON line to `{ts, host, path, status, dur_ms}`.

#### How do I see docker log disk usage and tune retention?

```bash
task logs:disk
```

Prints per-container json-file log size (base + rotated siblings) and the effective retention
policy. The stack caps each container at `LOG_MAX_SIZE × LOG_MAX_FILE` via the `x-logging`
anchor in `docker-compose.yml`; defaults give ~30 MiB per container, ~210 MiB total.

To change the policy, edit `LOG_MAX_SIZE` / `LOG_MAX_FILE` in `.env` (e.g. `LOG_MAX_SIZE=50m`
for noisy debugging on a bigger host, or `LOG_MAX_SIZE=2m` on a small one), then run
`task update`.

> [!NOTE]
> A plain `task up` will **not** pick up new `LOG_MAX_*` values. Docker only applies log-driver
> options on container creation, so the change requires `--force-recreate` (which `task update`
> does, but `task up` doesn't). Symptom: edits look applied (`docker inspect` shows the new
> values on the next recreate) but the running container's old retention policy stays in
> effect until then.

The task itself reads sizes via a transient `alpine` container with a read-only `/var/lib/docker`
mount, since docker's json log files are root-owned on the host. Linux only.

### Caveats and foot-guns

A grab-bag of operator gotchas the stack documents but doesn't (and in some cases can't)
prevent.

- [TLS: cert-file requires a multi-host SAN](#tls-cert-file-requires-a-multi-host-san)
- [Upgrades are not reversible by tag revert](#upgrades-are-not-reversible-by-tag-revert)
- [Doctrine `serverVersion` drives SQL dialect selection](#doctrine-serverversion-drives-sql-dialect-selection)
- [MariaDB / Symfony credential parity](#mariadb--symfony-credential-parity)
- [`./media` permissions: the dual-UID contract](#media-permissions-the-dual-uid-contract)
- [OPcache mtime checking off in production](#opcache-mtime-checking-off-in-production)
- [Let's Encrypt rate limits (50/domain/week)](#lets-encrypt-rate-limits-50domainweek)
- [`purge` and `reinstall` delete data](#purge-and-reinstall-delete-data)
- [`env:init FORCE=1` overwrites without prompt](#envinit-force1-overwrites-without-prompt)
- [Compose profiles gate services, not volumes](#compose-profiles-gate-services-not-volumes)
- [Body-size parity between nginx and PHP](#body-size-parity-between-nginx-and-php)
- [`mysql_native_password` is deprecated upstream](#mysql_native_password-is-deprecated-upstream)
- [Docker Hub anonymous pull cap](#docker-hub-anonymous-pull-cap)
- [External `frontend` network must exist before `task install`](#external-frontend-network-must-exist-before-task-install)
- [`compose.override.yml` is silently auto-loaded](#composeoverrideyml-is-silently-auto-loaded)
- [Committed `.example` files are templates, not your config](#committed-example-files-are-templates-not-your-config)

#### TLS: cert-file requires a multi-host SAN

When `SERVER_CERT_PROVIDER=cert-file`, Traefik selects certs by SNI from the file provider.
Your cert must include both `OS2DISPLAY_SERVER_DOMAIN` (api + admin + client) **and**
`SERVER_DOMAIN` (Traefik dashboard) as SAN entries — or use a wildcard. Without one, the
dashboard host gets the file provider's default cert (the first one declared), which won't
match → browser TLS errors. Let's Encrypt mode handles this automatically (per-host issuance).

#### Upgrades are not reversible by tag revert

`task update` runs `app:update` which applies the new image's Doctrine schema migrations.
Some migrations include `DROP COLUMN`, type changes, or data transforms that the previous
image's `app:update` doesn't undo (and that Doctrine's `down()` method, if defined, may not
lossly reverse). The on-disk data files are preserved across the image swap and container
recreation, but the *schema* gets rewritten. Rolling back is `task db:backup`-restore +
revert image tag — not a clean tag revert. **Always take a fresh `task db:backup` before
`task update`**, not just relying on yesterday's snapshot.

#### Doctrine `serverVersion` drives SQL dialect selection

`DATABASE_URL` in `.env.symfony` has a `serverVersion=` parameter that Doctrine reads to
pick its SQL dialect. After a MariaDB major bump, this *must* be updated; otherwise queries
silently use the wrong dialect (most visible on JSON columns and date/time functions). The
mismatch doesn't error at startup — queries fail at runtime in production traffic.

#### MariaDB / Symfony credential parity

The bundled mariadb container initialises with credentials from `.env.mariadb`; Doctrine
connects with credentials from `.env.symfony`'s `DATABASE_URL`. Edit one without the other
and the api can't connect. After the data dir is initialised, mariadb refuses to
re-initialise with different credentials — changing them later requires a manual
`ALTER USER` SQL run inside the container.

#### `./media` permissions: the dual-UID contract

The os2display container writes media as UID 1042 (deploy); the nginx container reads them
as UID 101 (nginx-unprivileged). `./media` must be readable by both. The simplest fix is
owning `./media` as group 1042 with mode 750 + `chmod g+rx ./media`. Symptoms of getting it
wrong: thumbnails 404, uploaded images don't render. Always check `./media` perms first when
troubleshooting media issues.

#### OPcache mtime checking off in production

`PHP_OPCACHE_VALIDATE_TIMESTAMPS=1` makes opcache check file mtime on every request — fine in
development for live reloads, terrible in production for performance. The `.env.php.example`
defaults to `=0`. If you copied it to `.env.php` and edited to `=1`, expect significant CPU +
I/O overhead.

#### Let's Encrypt rate limits (50/domain/week)

Production LE allows 50 certificate issuances per registered domain per week. Hitting it
locks you out for 7 days. When iterating on Traefik config, point at the LE staging server
first via
`TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_CASERVER=https://acme-staging-v02.api.letsencrypt.org/directory`
in `.env.traefik`. Switch to production only when the cert flow works end-to-end.

#### `purge` and `reinstall` delete data

`task purge` runs `docker compose down --volumes` — the mariadb data volume goes too.
`task reinstall` is `purge` + `install`. Both destroy the database. `down` and `stop`
preserve volumes.

#### `env:init FORCE=1` overwrites without prompt

Without `FORCE=1`, env:init refuses to run if `.env.symfony` already exists. With `FORCE=1`,
it silently overwrites — your operator-edited secrets included. Always backup first.

#### Compose profiles gate services, not volumes

Compose `profiles:` only gate which **services** start. Networks, volumes, and top-level
config don't accept `profiles:`. Switching `COMPOSE_PROFILES=traefik` doesn't tear down the
bundled mariadb's data volume — a previous `mariadb` run leaves data on disk that's idle
until the profile is re-enabled. `task purge` is the only path to actually delete it.

#### Body-size parity between nginx and PHP

`NGINX_MAX_BODY_SIZE` must be ≥ `PHP_UPLOAD_MAX_FILESIZE`. Nginx rejects oversized requests
at the proxy edge; PHP at the parser. If nginx is lower, large uploads get truncated before
PHP sees them — the operator sees a 413 from nginx, not a clean PHP error.

#### `mysql_native_password` is deprecated upstream

MariaDB 11.4 still ships it (and the official image defaults to it), but the auth plugin is
flagged for removal. Operators on default auth will hit a hard break on 11.5+. Plan to
migrate to `caching_sha2_password` before that bump.

#### Docker Hub anonymous pull cap

100 pulls / 6h / IP. NAT'd hosts share the cap with every other anonymous puller behind the
same egress. `docker login docker.io` lifts to 200/6h/user; a registry mirror lifts further.
See [Cookbook: authenticate to Docker Hub](#how-do-i-authenticate-to-docker-hub-rate-limits).

#### External `frontend` network must exist before `task install`

When using `compose.shared-frontend.yml`, the network is `external: true`. Compose won't
create it. Run `docker network create <name>` once on the host before `task install`.

#### `compose.override.yml` is silently auto-loaded

If you have a leftover `compose.override.yml` from a 2.x deployment or experiment, it will
silently apply on top of `docker-compose.yml`. Inspect with
`docker compose config | grep -A 5 <suspicious-service>` to see the merged result.

#### Committed `.example` files are templates, not your config

The checked-in `.env.<X>.example` files are templates, intentionally producing safe-but-not-
secret defaults. Your operator edits go into `.env.<service>` (gitignored). Editing the
templates means future `task install` invocations bootstrap your custom values into other
operators' checkouts, and `git status` is permanently dirty.

#### `.env.local.php` does not reflect your operator config

The upstream image's entrypoint runs `composer dump-env prod` then `bin/console cache:warmup`
before exec'ing php-fpm. `dump-env` only reads the bundled `/app/.env*` files — it does **not**
capture process-environment values set by compose `env_file:` (`.env.symfony`,
`.env.mariadb`, …). So `/app/.env.local.php` inside a running container shows the image's
shipped defaults (`APP_SECRET=CHANGE_ME`, the placeholder `DATABASE_URL`, etc.), not the values
you actually configured.

This is fine in practice — Symfony's documented precedence is "real environment variables
always win over `.env*` files", and `.env.local.php` is just a fast-path replacement for
parsing those files. The env_file values still override at request time, and `cache:warmup`
compiles `%env(FOO)%` placeholders that are resolved at request time, not bake-time. Two
implications worth knowing:

- **Inspecting `.env.local.php` is misleading** — to see what Symfony actually resolves, run
  `task console -- debug:dotenv` (its "Value" column is the effective resolved value) or
  `getenv()` from inside the container.
- **`composer dump-env` runs once at container start.** If you change `.env.symfony` and want
  the new values active, restart the container (`docker compose restart os2display` /
  `task update`). Editing `/app/.env` by hand inside an already-running container does
  *nothing* until the next restart re-runs `dump-env`.

If you ever explicitly want to suppress a `.env.local.php` value (say a sentinel that's leaking
through because your env_file omits the key), set `KEY=` (empty) in `.env.symfony` rather than
omitting the line — Symfony's "real env wins" rule only kicks in when the variable is set.

### Migrating from an older release

See [UPGRADE.md](UPGRADE.md) for the step-by-step 1.x → 3.x migration recipe (this repo skips
2.x to align its major version with upstream `display-api-service`).

---

## Developer guide

> [!IMPORTANT]
> This guide is for development of **this compose server setup** —
> the Taskfile, env-file layout, Traefik wiring, CI workflows, and
> bundled service composition. To develop the **OS2display application
> itself** (admin UI, screen client, API), work in the upstream
> [`display-api-service`](https://github.com/os2display/display-api-service)
> repo, which ships its own docker compose dev environment.

### Local dev quick start

One command brings up a fully working stack on your laptop against
`*.localhost` with a self-signed cert and no external services:

```bash
git clone git@github.com:os2display/os2display-docker-server.git
cd os2display-docker-server
task dev:install
```

`dev:install` chains three steps in fresh `task` subprocesses:

1. **`task dev:env`** — bootstraps env files for localhost (non-interactive):
   - `.env` with `OS2DISPLAY_SERVER_DOMAIN=os2display.localhost`
   - `.env.traefik` with `SERVER_DOMAIN=traefik.localhost`,
     `SERVER_CERT_PROVIDER=cert-file`, and a hashed `admin`/`admin`
     dashboard basic-auth value (override via `DEV_DASHBOARD_PASSWORD=…`
     before running)
   - `.env.symfony` extracted from the pinned API image, with random
     `APP_SECRET` + `JWT_PASSPHRASE` and the Doctrine `serverVersion`
     aligned to the bundled MariaDB pin
   - `.env.{php,nginx,mariadb}` copied from their `.example` templates
2. **`task dev:cert` (`FORCE=1`)** — generates `traefik/ssl/dev.{crt,key}`
   covering `os2display.localhost`, `traefik.localhost`, `localhost`, and
   `127.0.0.1` (transient `alpine/openssl` container, no host openssl
   needed)
3. **`task install`** — auto-fills `CHANGE_ME` MariaDB sentinels with
   random hex, pulls images, brings the stack up with healthcheck waits,
   runs Doctrine migrations, generates the JWT keypair, and walks the
   interactive prompts below

**Interactive prompts during `task install`** — `dev:install` is hands-off
through cert generation; from `task install` onward you'll see:

| Prompt | Default | What it does |
|---|---|---|
| `WARNING! You are about to execute a migration… Are you sure?` | `yes` | Press Enter — applies Doctrine migrations to the bundled MariaDB. |
| `No templates are installed. Install all 15?` | `yes` | Press Enter — installs the bundled slideshow templates. |
| `No screen layouts are installed. Install all 9?` | `yes` | Press Enter — installs the bundled screen layouts. |
| `Tenant Key:` | — | Short identifier (e.g. `dev`). Used in URLs and the media path. |
| `Title:` | — | Human-readable tenant name. |
| `Description:` | — | Optional, leave blank to skip. |
| `Email:` | — | Your admin login. |
| `Password:` | — | Hidden as you type. |
| `Full Name:` | — | Displayed in the admin UI header. |
| `Please select the user's role` | `editor` | Type `1` for `admin`. |
| `Please select the tenant(s)` | — | Type the tenant key from step 4. |

When `task install` returns, the URLs print at the bottom:

- Admin: `https://os2display.localhost/admin`
- Screen client: `https://os2display.localhost/client`
- Traefik dashboard: `https://traefik.localhost/traefik/dashboard/`
  (basic-auth `admin`/`admin`)

`*.localhost` resolves to `127.0.0.1` automatically on Linux, macOS, and
Windows per RFC 6761 — no `/etc/hosts` edit needed. The browser shows an
"untrusted CA" warning the first time (accept it, or trust
`traefik/ssl/dev.crt` in your system keychain to skip the prompt).

**Reset to bare checkout.** `task dev:teardown` wipes containers + named
volumes (MariaDB + Redis data loss), the JWT keypair, the dev cert, and
the bootstrapped env files. Operator `.env.*.local` overrides and
`./media` uploads are preserved. Re-run `task dev:install` afterwards
for a clean rebuild. Prompt-gated.

### Design principles

The repo is a thin wrapper around upstream tooling. The constraints we work under:

1. **Only Task and docker compose required locally.** No make, no Python tooling, no
   shell-script glue beyond the Taskfile. The Taskfile itself is a thin wrapper that exists for
   ergonomics (lifecycle commands, env-file bootstrap), not because it carries logic the stack
   couldn't otherwise express. Adding a new dependency to the local dev workflow needs a strong
   justification.

2. **Build on stack standards. Don't reinvent.** Where compose, Task, or the upstream images
   already provide a feature, use it directly. Concretely:
   - **Compose profiles** (`COMPOSE_PROFILES`) for optional services. Not custom `-f` flag
     juggling, not Taskfile-side compose-file synthesis.
   - **Compose's `env_file:`** for service env. Not `environment:` translation blocks that
     substitute from `.env` — those silently shadow `env_file:` values.
   - **Compose's `name:`** on networks for engine-name configurability. Not `${VAR}`
     substitution into `services.X.networks:` (which is the wrong layer).
   - **Compose's `COMPOSE_FILE`** for opt-in overrides. Not custom Taskfile branches that
     decide which files to load.
   - **The image's annotated `/app/.env`** as the canonical Symfony env source. Not a
     parallel checked-in copy that drifts against upstream.
   - **Native YAML anchors** (`x-logging`) for repeated config blocks.

3. **Per-service env files.** One file per service, named `.env.<service>`, with a checked-in
   `.env.<service>.example` template. No mega-file mixing Symfony app config with
   PHP runtime tuning with MariaDB credentials. Compose `environment:` translation blocks
   (`- APP_X=${APP_X}`) are forbidden — they shadow `env_file:` and create a split surface.

4. **Production examples are canonical.** The `.example` files in this repo are the
   source of truth for runtime/deployment config. Symfony app config is the asymmetric
   exception — the upstream API image's `/app/.env` is canonical there, and
   `task env:init` extracts it. We don't duplicate upstream content.

5. **Compose-managed by default; cross-stack sharing is opt-in.** Networks, volumes, and
   services are compose-controlled out of the box. Sharing infrastructure across compose
   projects (one Traefik fronting several stacks) is explicit operator opt-in via
   `compose.shared-frontend.yml` (or a similarly-scoped override file), never the default.

6. **No bash glue when compose can do it.** If the question is "how do operators activate X",
   the answer should be a compose feature (profile, env-file, override file), not a Taskfile
   shell block. Network creation, image selection, profile gating, and config file selection
   all belong to compose, not Task.

7. **Use the upstream image's environment contract.** Image-side env vars (`PHP_*`, `NGINX_*`,
   `MARIADB_*`) keep their upstream names. Operator-facing repo-specific vars use the
   `OS2DISPLAY_*` prefix to avoid shadowing names docker compose itself reads (only
   `COMPOSE_PROJECT_NAME` and `COMPOSE_PROFILES` retain the `COMPOSE_` prefix because they're
   compose-native).

8. **Follow the official [Taskfile style guide](https://taskfile.dev/styleguide/).** Section
   ordering (`version` → `vars` → `tasks`), 2-space indent, kebab-case task names, `:`-namespacing
   for groups (`env:*`, `host:*`, `logs:*`, `dev:*`), and external `scripts/*.sh` for any task
   body that can't fit on one line. The shellcheck CI workflow lints the extracted scripts.

### Local development

The fast path is `task dev:install` (see
[Local dev quick start](#local-dev-quick-start) above). Beyond bringing
up the stack, working on this repo has two extras:

- **The `dev` compose profile** activates the `markdownlint`, `prettier`, and `shellcheck`
  services for local linting. The `dev:lint*` Task family wraps them:

  ```bash
  task dev:lint        # Markdown + YAML + Shell check
  task dev:lint:fix    # auto-fix Markdown + YAML (shellcheck has no fix mode)
  ```

  Run these before opening a PR; CI runs the same checks on every push.

- **Alternative cert paths.** The stack only runs in HTTPS mode (Traefik
  forces it). `task dev:install` uses a self-signed cert covering
  `*.localhost` — fine for laptop dev. If you need a real cert chain
  (e.g. testing OIDC against an external provider that won't accept
  self-signed), point at Let's Encrypt staging — needs a public DNS name,
  reachable port 80, and lives with an untrusted staging CA root:

  ```bash
  $EDITOR .env.traefik
  # TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_CASERVER=https://acme-staging-v02.api.letsencrypt.org/directory
  ```

Standard fork-and-PR flow. PRs run four CI workflows (Markdown, YAML, Shell, Compose). The Compose
workflow is the most likely to surface issues — it asserts that every pinned image is
reachable on its registry and every `${VAR}` reference in `docker-compose.yml` resolves.

### Repository layout

```text
.
├── docker-compose.yml                       # canonical stack definition
├── compose.shared-frontend.yml              # opt-in: external frontend network
├── Taskfile.yml                             # operator workflow
│
├── .env.example                             # compose orchestration template
├── .env.php.example              # per-service runtime templates
├── .env.nginx.example
├── .env.mariadb.example
├── .env.traefik.example
│
├── traefik/
│   ├── traefik-letsencrypt.yml              # static config, LE variant
│   ├── traefik-cert-file.yml                # static config, cert-file variant
│   ├── dynamic-conf-letsencrypt.yaml        # dynamic config, LE variant
│   ├── dynamic-conf-cert-file.yaml          # dynamic config, cert-file variant
│   ├── ssl/                                 # operator-supplied custom certs (gitignored)
│   └── letsencrypt/                         # acme.json storage (gitignored)
│
├── scripts/                                 # extracted helpers for the longer
│   ├── host-resources.sh                    # compose tasks; lint via `task dev:lint:sh`
│   ├── host-php.sh
│   ├── logs-disk.sh
│   ├── env-traefik.sh                       # `task env:traefik` — interactive setup
│   ├── env-init.sh                          # `task env:init` — image extract + secret gen
│   ├── install-secrets.sh                   # `task install` step — auto-fill CHANGE_ME
│   ├── dev-cert.sh                          # `task dev:cert` — self-signed local cert
│   └── dev-env.sh                           # `task dev:env`  — localhost env bootstrap
│
├── jwt/                                     # JWT keypair storage (gitignored)
├── media/                                   # media bind mount (gitignored)
├── backup/                                  # task db:backup output (gitignored)
│
├── .github/workflows/                       # CI: markdown.yaml, yaml.yaml,
│                                            # sh.yaml, compose.yaml
│
├── .markdownlint.jsonc                      # linter configs (synced from
├── .markdownlintignore                      # itk-dev/devops_itkdev-docker)
├── .prettierrc.yaml
└── .prettierignore
```

The `traefik-${SERVER_CERT_PROVIDER}.yml` and `dynamic-conf-${SERVER_CERT_PROVIDER}.yaml` files
are mounted via env-var substitution in `docker-compose.yml`'s volume directive. Adding a new
cert provider means adding a new pair of files, not touching compose or Task.

### Linting

Markdown + YAML in CI. The linter services are gated behind the `dev` compose profile so they
don't bloat production starts. Run via Task:

```bash
task dev:lint                  # check Markdown + YAML + Shell
task dev:lint:md               # check Markdown only
task dev:lint:yaml             # check YAML only
task dev:lint:sh               # shellcheck scripts/*.sh (no fix mode)
task dev:lint:fix              # auto-fix Markdown + YAML (review the diff before committing)
task dev:lint:md:fix           # auto-fix Markdown only (markdownlint --fix)
task dev:lint:yaml:fix         # auto-fix YAML only (prettier --write)
```

Or invoke the underlying compose commands directly (what CI uses):

```bash
docker compose --profile dev run --rm markdownlint markdownlint '**/*.md'
docker compose --profile dev run --rm prettier '**/*.{yml,yaml}' --check
```

Configs:

- `.markdownlint.jsonc` + `.markdownlintignore` — line-length 120, table/code-block exempt,
  allows `<details>`/`<summary>`.
- `.prettierrc.yaml` + `.prettierignore` — default Prettier + Symfony `config/` override
  (4-space tabs, single quotes).

Both pairs are copied from
[itk-dev/devops_itkdev-docker](https://github.com/itk-dev/devops_itkdev-docker) — the
file-copy header at the top of each lints config preserves provenance for sync.

### CI workflows

`.github/workflows/`, five static checks plus a release-branch e2e:

- **`markdown.yaml`** — runs markdownlint via `docker compose --profile dev run --rm
  markdownlint`. Catches doc rot.
- **`yaml.yaml`** — runs prettier via the same pattern. Catches YAML drift.
- **`sh.yaml`** — runs shellcheck against `scripts/*.sh` via the `shellcheck` dev-profile
  service. Catches shell footguns in the extracted helpers (unquoted vars, masked exit
  codes, etc.).
- **`tasks.yaml`** — runs `scripts/check-tasks-readme.sh`, asserting the set of task
  names in the README's "All tasks" reference block matches `task --list`. Section
  labels, descriptions, and alias notes stay human-curated; only membership is checked.
- **`compose.yaml`** — three jobs:
  1. `compose-config` — synthesises the stack with example env files + a stub `.env.symfony`.
     Catches typos and dangling `${VAR}` references.
  2. `image-availability` — `docker buildx imagetools inspect` against every pinned image.
     Catches a tag that didn't ship.
  3. `env-coverage` — every bare `${VAR}` reference in `docker-compose.yml` is declared in
     `.env.example` or `.env.traefik.example`. Catches the silent-empty
     substitution case.
- **`e2e.yaml`** — release-branch only (`pull_request` against `release/**`, push to
  `release/**`). Bootstraps env files via `task env:init`, generates a self-signed cert,
  brings the full stack up, runs migrations, creates a tenant + admin user, and curls
  `/admin/` over HTTPS via the cert. Catches install-path regressions the static checks
  can't (image boot, migration replay, Traefik routing). ~5 minutes wall-clock.

All static checks trigger on `pull_request` and pushes to `main` / `develop` /
`release/**`. The e2e workflow runs on release branches only — too slow + too much docker
churn for the casual review cycle.

---

## Reference

### All tasks

```text
Lifecycle
  install              Install the project — first-time setup (interactive)
  update               Pull images, recreate containers, run app:update
  up                   Start the stack; blocks until healthchecks pass
  down                 Remove all containers (preserves named volumes)
  stop                 Stop all containers
  purge                Remove all containers AND named volumes  (prompts)
  reinstall            purge + install                          (prompts)

Bootstrap and env-file tooling
  env:init             Bootstrap .env.symfony from the API image
  env:diff             Compare .env.symfony against the image's shipped example
  env:migrate          Convert a 1.x .env.docker.local to .env.symfony.migrated
  env:traefik          Interactive .env.traefik setup            (alias: traefik_env)

Operations
  logs:follow          Follow service logs                        (alias: logs)
  logs:since           Print logs since a duration without following
  logs:errors          Surface error/critical/fatal/exception lines (last hour)
  logs:access          Tail traefik's JSON access log, one compact line per request
  logs:disk            Docker log disk usage per container + retention policy (Linux only)
  console              Run any bin/console command in os2display  (e.g. `task console -- list`)
  cache:clear          Clear the application cache               (alias: cc)
  php:opcache          Report on the FPM pool's OPcache health (RAW=1 for JSON)
  tenant:add           Add a tenant group (interactive)          (alias: tenant_add)
  user:add             Add a user — editor or admin (interactive)(alias: user_add)
  templates:install    Install bundled templates + screen layouts(alias: load_templates)
  db:backup            Dump the bundled MariaDB to ./backup/<UTC-ts>.sql.gz
  db:upgrade           Run mariadb-upgrade after a MariaDB major bump
  db:metrics           Snapshot of MariaDB operational counters (connections, locks, buffer pool)
  db:processes         SHOW FULL PROCESSLIST — every active connection + its query
  db:errors            Filter mariadb stderr for trouble patterns (last hour)

Host inspection
  host:resources       Recommend mem_limit values for a dedicated host (Linux only)
  host:php             Recommend PHP-FPM pool sizing for a given os2display mem_limit
  host:disk            Stack disk usage vs host disk available
  host:disk:tenants    ./media usage broken down by tenant key

Dev tooling
  dev:lint             Check Markdown + YAML + Shell
  dev:lint:fix         Auto-fix Markdown + YAML (shellcheck has no fix mode)
  dev:lint:md          Check Markdown only
  dev:lint:md:fix      Auto-fix Markdown only
  dev:lint:yaml        Check YAML only (Prettier --check)
  dev:lint:yaml:fix    Auto-fix YAML (Prettier --write)
  dev:lint:sh          Lint scripts/*.sh via shellcheck (no fix mode)
  dev:lint:tasks       Assert task --list and README's "All tasks" agree
  dev:cert             Generate a self-signed cert for local-host development
  dev:env              Bootstrap env files for localhost dev (non-interactive)
  dev:install          Localhost dev quick start — dev:env + dev:cert + install
  dev:teardown         Tear down dev stack: containers + volumes + dev cert (prompts)
```

`task --list` shows the canonical list with aliases. Internal helper tasks
(`bootstrap-env-files`, `show-notes`) are hidden via `internal: true` and only
called from other tasks.

The aliased forms (`tenant_add`, `user_add`, `load_templates`, `cc`, `traefik_env`)
remain as **deprecated aliases** for compatibility with operator scripts written
against earlier releases. Prefer the canonical `:`-namespaced forms going forward.

`task console -- <args>` is the generic Symfony CLI proxy. Use it for any one-off
`bin/console` command that doesn't have its own dedicated task — e.g.:

```bash
task console -- list                                 # list all bin/console commands
task console -- debug:router                         # inspect Symfony routes
task console -- doctrine:migrations:status           # ad-hoc Doctrine ops
```

Tasks like `cache:clear`, `tenant:add`, `user:add`, and `templates:install` that
proxy a single Symfony command are implemented as thin wrappers around
`task console`, so the CLI surface stays consistent.

### Image registries

| Image | Registry | Profile | Auth required |
|---|---|---|---|
| `ghcr.io/os2display/display-api-service` | GHCR | always | none (public) |
| `ghcr.io/os2display/display-api-service-nginx` | GHCR | always | none (public) |
| `ghcr.io/tecnativa/docker-socket-proxy` | GHCR | `traefik` | none (public) |
| `redis:8-alpine` | Docker Hub | always | none, but rate-limited |
| `mariadb:11.4.x` | Docker Hub | `mariadb` | none, but rate-limited |
| `traefik:v3.6` | Docker Hub | `traefik` | none, but rate-limited |
| `peterdavehello/markdownlint` | Docker Hub | `dev` | none, but rate-limited |
| `jauderho/prettier` | Docker Hub | `dev` | none, but rate-limited |

The upstream `redis`, `mariadb`, and `traefik` projects publish only to Docker Hub — there is
no canonical GHCR mirror. See
[Cookbook: authenticate to Docker Hub](#how-do-i-authenticate-to-docker-hub-rate-limits) for
the rate-limit story.
