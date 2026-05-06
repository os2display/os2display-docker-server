# Changelog

## [Unreleased] — release/3.0.0

This repo's previous major was 1.x. **2.x is skipped** — internal canonical work on a
`release/2.0.0` branch never shipped as a tagged release, and we're aligning this repo's
major version with upstream
[`display-api-service`](https://github.com/os2display/display-api-service) (which is at 3.x)
so operators see one major-version number per stack. The `display-api-service` image bundles
the admin and screen-client UIs in 3.x; this repo's compose stack is consolidated, hardened,
and aligned to the v3 image's env contract. **For 1.x → 3.x operators: see
[UPGRADE.md](UPGRADE.md)** for the step-by-step migration recipe.

### Added

- `task env:init` — extracts the annotated `.env` shipped at `/app/.env` in the API image and
  writes it to `.env.symfony`. Auto-generates random `APP_SECRET` + `JWT_PASSPHRASE` (32-byte
  hex via `alpine/openssl rand`) and bumps `DATABASE_URL` `serverVersion` to match the mariadb
  image pinned in `docker-compose.yml`. Replaces the previous checked-in `.env.local.example`;
  the image is now the single source of truth for the operator-facing env surface.
- `task env:diff` — diffs your `.env.local` against the example in the currently-pinned image.
- `task env:migrate` — rewrites a 2.x `.env.docker.local` (or an APP_-prefixed `.env.local`) to
  v3 bare-name format, output to `.env.local.migrated` for review.
- `task update` — pulls fresh images, recreates containers, runs `app:update`. Replaces the old
  ad-hoc `restart.sh`.
- `task db:backup` — `mariadb-dump --all-databases --single-transaction` piped through gzip to
  `./backup/<timestamp>.sql.gz`. Online; no service downtime.
- `task db:upgrade` — runs `mariadb-upgrade` explicitly. Idempotent, belt-and-suspenders over the
  entrypoint's auto-run on first start with new data.
- Global JSON-file log rotation via the `x-logging` anchor (10MB × 3 files per service). Applied
  to every service so a runaway container can't fill the host disk. Tunable via
  `LOG_MAX_SIZE` / `LOG_MAX_FILE` in `.env`.
- `task logs:*` namespace consolidating log inspection: `logs:follow` (alias `logs`,
  parameterised by `S=<service>` and `lines=<n>`) replaces the bare `logs` task; `logs:since`
  prints non-following history (`T=1h S=os2display`); `logs:errors` greps the last hour for
  error/critical/fatal/exception/stacktrace; `logs:access` projects traefik's JSON access log
  to a compact line per request via `jq`; `logs:disk` shows per-container json-file log size
  and the effective retention policy (reads via a transient `alpine` container with a read-only
  `/var/lib/docker` mount; Linux only).
- Healthchecks on `os2display` (PHP TCP probe to fpm 9000), `nginx-api` (`wget /health`), `redis`
  (`redis-cli ping`), `mariadb` (`healthcheck.sh --connect --innodb_initialized`), and
  `socket-proxy` (`wget /version`). `nginx-api.depends_on.os2display.condition: service_healthy`
  so `task install` actually waits for fpm before declaring the stack up.
- Markdown and YAML linting via the `dev` compose profile (`markdownlint` and `prettier`
  services). Configs adopted from
  [itk-dev/devops_itkdev-docker](https://github.com/itk-dev/devops_itkdev-docker).
- GitHub Actions workflows: `Markdown`, `YAML`, `Shell`, `Compose` (synthesis +
  image-availability + env-coverage), and `Tasks` (asserts the README's "All tasks" reference
  block lists the same task names `task --list` exposes). Pre-merge gates that catch dangling
  `${VAR}` references, missing image tags, lint regressions, shell footguns, and README/Taskfile
  drift.
- New **`task dev:lint:tasks`** + `scripts/check-tasks-readme.sh` (folded into the `dev:lint`
  aggregate) — set-membership comparison of `task --list` against the README block. Section
  headings, descriptions, and alias notes in the README stay human-curated; only the SET of
  task names is checked. Caught the missing `dev:teardown` entry in the existing block.
- `scripts/` directory: extracted helpers for the longer Taskfile bodies that the upstream
  [Taskfile style guide](https://taskfile.dev/styleguide/) recommends moving out
  ("Prefer using external scripts instead of multi-line commands"). `host-resources.sh`,
  `host-php.sh`, `logs-disk.sh`, `env-traefik.sh`, `env-init.sh`, `install-secrets.sh`, and
  `dev-cert.sh` replace inline blocks (or implement new behavior); their Taskfile entries
  shrink to a single `./scripts/<name>.sh` invocation. All scripts run under
  `set -euo pipefail` and are linted by `shellcheck` via the `shellcheck` dev-profile service
  and the `task dev:lint:sh` / `Shell` CI workflow. Borderline tasks (`host:disk`,
  `db:backup`, `env:diff`, etc.) stay inline.
- `task dev:cert` — generates a self-signed certificate at `traefik/ssl/dev.{crt,key}` for
  local-host development with `SERVER_CERT_PROVIDER=cert-file`. Wraps an `openssl req -x509`
  invocation in a transient `alpine/openssl` container (no host openssl needed); SANs cover
  `OS2DISPLAY_SERVER_DOMAIN`, `SERVER_DOMAIN`, `localhost`, and `127.0.0.1`, defaulting to
  `*.localhost` when env files haven't been bootstrapped. `FORCE=1` to overwrite. Cookbook
  recipe: "How do I run the stack on localhost without a public domain?".
- `task install` auto-generates random MariaDB credentials. `.env.mariadb.example` now ships
  `MARIADB_PASSWORD=CHANGE_ME` / `MARIADB_ROOT_PASSWORD=CHANGE_ME` sentinels. The new
  `scripts/install-secrets.sh` runs as the first step of `task install`, detects the
  sentinels, replaces them with random 32-character hex values, and syncs the application-user
  password into `DATABASE_URL` in `.env.symfony`. Operators who set explicit values before
  running install have them preserved. Removes one manual edit from the install recipe.
- `task env:traefik` now prompts for cert provider (letsencrypt vs cert-file) and writes the
  matching `SERVER_CERT_PROVIDER`, `SERVER_CUSTOM_CERT_FILE`, and `SERVER_CUSTOM_KEY_FILE`
  values. The htpasswd hash is generated via `alpine/openssl passwd -apr1 -stdin` rather than
  a host `htpasswd` binary, dropping the `apache2-utils` / `httpd-tools` dependency. Operators
  on a fresh Debian/Alpine host now need only `task` and `docker` — no host openssl, no
  apache utils.
- **Per-service `.env.<svc>.local` override layer.** Each service's compose `env_file:` block
  now reads two files — `.env.<svc>` (operator's primary config) and `.env.<svc>.local`
  (`required: false`, loaded on top, overrides earlier values). Same pattern for
  `.env.symfony.local`. Use `.local` files for site-specific overrides (host-specific PHP
  worker count, mariadb buffer pool size, debug flags) without forking the committed
  `.env.<svc>` template — `task env:init` may bootstrap `.env.<svc>` from the example on a
  fresh install, so keeping site-specific tuning out of that file makes re-bootstraps clean.
  All `*.local` files are gitignored. Cookbook recipe: "How do I override env config locally
  without committing?".

### Changed (breaking)

- `socket-proxy` service hardened: image moved from unpinned
  `itkdev/docker-socket-proxy` (Docker Hub) to
  `ghcr.io/tecnativa/docker-socket-proxy:v0.4.2` (upstream, version-pinned).
  Dropped `user: root`, added `read_only: true` + `tmpfs: [/run, /tmp]`,
  `security_opt: [no-new-privileges:true]`, and a healthcheck against
  `/version`. (`/tmp` was added after end-to-end testing showed the
  upstream entrypoint generates `/tmp/haproxy.cfg` from a template at
  start; without a writable `/tmp` the container restarted forever.)
- **Operator env config split into one file per service.** Previously runtime
  tunables (`PHP_*`, `NGINX_*`, `MARIADB_*`) lived in `.env` and were
  substituted into compose `environment:` blocks; Symfony app config lived in
  `.env.local`. That gave a split surface and let compose silently override
  env_file values — opposite of what env_file was for. New layout:

  | File           | Service env                   | Canonical example                                              |
  | -------------- | ----------------------------- | -------------------------------------------------------------- |
  | `.env.symfony` | os2display Symfony app config | image-extracted via `task env:init`                            |
  | `.env.php`     | os2display PHP-FPM runtime    | `.env.php.example`                                  |
  | `.env.nginx`   | nginx-api runtime             | `.env.nginx.example`                                |
  | `.env.mariadb` | mariadb credentials           | `.env.mariadb.example`                              |
  | `.env.traefik` | traefik config                | `.env.traefik.example`                              |
  | `.env`         | compose orchestration         | `.env.example` (shrunk)                                        |

  Each compose service reads its own `env_file:` list. No cross-service env
  leakage. The compose-level `environment:` blocks on `os2display`, `nginx-api`,
  and `mariadb` are gone. `task env:init` produces `.env.symfony` (was
  `.env.local`); `task env:diff` and `task env:migrate` updated to match.
  `task install`'s `_env_files` dep auto-creates any missing per-service env
  file from its `.example` template.

### Fixed

- **`scripts/env-traefik.sh` portability + compose-escape.** Surfaced by
  end-to-end localhost testing on macOS: `sed -i` used GNU-only syntax
  (BSD sed wants `-i.bak`), and the htpasswd `$` characters weren't
  escaped to `$$` for compose interpolation, so the dashboard auth header
  was mangled (`$apr1$...` got read as undefined env vars and substituted
  to empty). Both fixed; the script now works on macOS dev hosts and
  produces a compose-safe `SERVER_DASHBOARD_AUTH` value.
- **Cert resolver hardcoded to Let's Encrypt for cert-file operators.** The traefik dashboard
  router carried `tls.certresolver=letsencrypt` regardless of `SERVER_CERT_PROVIDER`, and the
  static `traefik.yml` set `letsencrypt` as the default `certResolver` on the websecure
  entrypoint — so cert-file operators had Traefik attempting Let's Encrypt issuance against the
  dashboard host even though their cert came from a local file. Split `traefik.yml` into
  `traefik-letsencrypt.yml` (entrypoint default `certResolver: letsencrypt`, ACME resolver
  declared) and `traefik-cert-file.yml` (no entrypoint default, certs come from the file
  provider's `tls.certificates:` via SNI). Volume mount selects the right one via
  `SERVER_CERT_PROVIDER`, mirroring the existing `dynamic-conf-*.yaml` pattern. The redundant
  `tls.certresolver=letsencrypt` label on the dashboard router is replaced with `tls=true`;
  the entrypoint default handles resolver selection.
- **Routing bug for `/admin` and `/client` paths.** While the v2 admin/client services were still
  in compose alongside the v3 API image, their Traefik labels
  (`Host(domain) && PathPrefix(/admin|/client)`) won the longest-match rule and routed those paths
  to v2 frontend containers — which can't speak the v3 API contract. The v3 API image bundles both
  UIs and serves them as Symfony routes via nginx-api; removing the separate services restores
  correct routing.
- **Traefik dashboard `PathPrefix`** was misspelled `/treafik/dashboard`, so the dashboard router
  never matched. Corrected to `/traefik/dashboard`.
- **`${SERVER_*}` substitutions in Traefik labels** previously resolved empty because compose
  didn't read `.env.traefik` for substitution. The Taskfile `COMPOSE` var now passes
  `--env-file .env.traefik` to every compose invocation.

### Security

- Added the three TLS 1.3 cipher suites (`TLS_AES_256_GCM_SHA384`, `TLS_AES_128_GCM_SHA256`,
  `TLS_CHACHA20_POLY1305_SHA256`) to the modern TLS profile so 1.3 negotiations have an explicit
  allow-list. Both `traefik/dynamic-conf-letsencrypt.yaml` and `traefik/dynamic-conf-cert-file.yaml`.
- Removed `serversTransport.insecureSkipVerify: true` from `traefik/traefik.yml`. The setting
  globally disabled backend certificate validation for every router. Backends in this stack speak
  plain HTTP internally so the flag was inert in practice, but it shadowed the default-deny
  posture and would silently weaken any future HTTPS backend.

### Removed

- `admin` and `client` services from `docker-compose.yml`. The v3 `display-api-service` image
  bundles both UIs and serves them as Symfony routes; the upstream `os2display-admin-client` and
  `os2display-client` repos are being archived (per upstream `UPGRADE.md` § 2).
- From `.env.example`: `OS2DISPLAY_VERSION_ADMIN`, `OS2DISPLAY_VERSION_CLIENT`,
  `OS2DISPLAY_SCREEN_CLIENT_PATH`, `API_PATH`, `APP_TOUCH_BUTTON_REGIONS`,
  `APP_REJSEPLANEN_API_KEY`, `APP_PREVIEW_CLIENT`, `APP_SHOW_SCREEN_STATUS`. All replaced by
  `ADMIN_*` / `CLIENT_*` keys in `.env.local`. `OS2DISPLAY_ADMIN_CLIENT_PATH` is retained —
  `nginx-api`'s `/` → `/admin` redirect middleware still uses it.
- `.env.docker.example` — split into `.env.example` (orchestration) and the image-shipped
  `/app/.env` (extracted by `task env:init`).
- `.env.local.example` — operators bootstrap from the image via `task env:init`. The image's
  `/app/.env` is the single source of truth.
- `TASK_VERSION_TEMPLATES`, `TASK_TEMPLATES`, `TASK_SCREEN_LAYOUTS` from `.env.example` —
  obsolete with v3's bundled templates.
- `load-templates-prod.sh`, `load-templates-develop.sh` — duplicated by `task load_templates`.
- `restart.sh` — replaced by `task update`.

### Changed (operator surface) — frontend network

- The `frontend` network is now compose-managed by default (was `external: true`). Compose
  creates and removes it as part of `docker compose up` / `down`. The manual
  `docker network create frontend` boilerplate in `task install` and the matching `network rm`
  in `task purge` are gone.
- The actual docker engine network name is now configurable via `OS2DISPLAY_FRONTEND_NETWORK`
  in `.env` (defaults to `frontend`). Services reference the network by the literal alias
  `frontend` regardless of its engine name. Previously, the `${SERVER_FRONTEND_NETWORK:-frontend}`
  substitution on `traefik.networks` was the wrong hook — services' `networks:` list takes a
  compose-internal alias, not an engine name; the substitution produced silent breakage if any
  operator actually set it.
- `compose.shared-frontend.yml` shipped as the canonical opt-in for cross-stack frontend
  sharing. Operators include it via `COMPOSE_FILE=docker-compose.yml:compose.shared-frontend.yml`
  in `.env`; that flips the network back to `external: true` so multiple compose projects can
  attach to one shared engine network.
- Removed `SERVER_FRONTEND_NETWORK` from `.env.traefik.example`. The corresponding
  substitution on `traefik.networks` is gone.

### Changed — Taskfile dotenv + bootstrap consolidation

- Taskfile loads `.env`, `.env.mariadb`, and `.env.traefik` via
  [`dotenv:`](https://taskfile.dev/docs/guide#env-files) at the top level. Tasks and scripts
  reference orchestration vars directly via `$OS2DISPLAY_VERSION_API` / `$MARIADB_USER` /
  `$SERVER_DOMAIN` / `$LOG_MAX_SIZE` etc. instead of `grep ^X= .env | cut -d= -f2`. Greps
  removed from `env:diff`, `host:disk`, and all `scripts/*.sh`. `.env.symfony` is kept out of
  the dotenv list — exposing `APP_SECRET` / `JWT_PASSPHRASE` / OAuth tokens to every subshell
  would be more surface than the convenience justifies. Missing dotenv files are silently
  ignored, so fresh checkouts still work before `task env:init` runs.
- **`task env:init` is now the single bootstrap entry point.** It creates `.env` (prompting for
  the public domain, defaulting `os2display.localhost`), copies missing per-service env files
  from their `.example` templates, and extracts `.env.symfony` from the API image with random
  APP_SECRET / JWT_PASSPHRASE and a serverVersion matched to the mariadb compose pin. The
  previous internal `bootstrap-env-files` task is gone; `task install` / `up` / `update` now
  precondition on `.env.symfony` directly — running `env:init` is the explicit gate that
  unlocks them.
- New **`task dev:teardown`** (prompt-gated): `compose down --volumes --remove-orphans` plus
  removes `traefik/ssl/dev.{crt,key}`. Bind mounts and operator env files are preserved. Uses
  plain `docker compose` (no `--env-file` flags) so the task works even if env files were
  partially wiped.
- **`.env.traefik.example` ships `SERVER_DASHBOARD_AUTH=CHANGE_ME`** instead of the previous
  plaintext `admin:password` placeholder (which wasn't htpasswd-formatted and would have
  silently rejected every login). Matches the `MARIADB_*=CHANGE_ME` sentinel pattern from
  B22. `task install` precondition refuses to run while the sentinel is in place, pointing
  operators at `task env:traefik` (the canonical setup path; auto-generates the apr1 hash via
  `alpine/openssl passwd`). Operators who prefer to set the htpasswd value manually can do so
  in `.env.traefik` and the precondition passes.

### Changed (operator surface) — Taskfile conventions

- Task names follow the [official Taskfile guide](https://taskfile.dev/docs/guide) conventions:
  `:`-namespaced for grouping, kebab-case for multi-word. Renames:

  | Old | New | Old still works as |
  |---|---|---|
  | `cc` | `cache:clear` | alias |
  | `tenant_add` | `tenant:add` | alias |
  | `user_add` | `user:add` | alias |
  | `load_templates` | `templates:install` | alias |
  | `traefik_env` | `env:traefik` | alias |

  Old names are kept as deprecated aliases for compatibility with operator scripts written
  against earlier releases. Prefer the canonical `:`-namespaced forms going forward.
- Internal helper tasks marked with `internal: true` instead of the `_`-prefix convention.
  `_show_notes` → `show-notes`; `_env_files` → `bootstrap-env-files`. Hidden from
  `task --list`; only callable from other tasks.
- `purge` and `reinstall` now use Taskfile's
  [warning prompts](https://taskfile.dev/docs/guide#warning-prompts). Both are destructive
  (delete the bundled MariaDB volume) and require operator confirmation. Bypass via
  `task --yes purge` for automation.

### Added — host inspection tasks

- **`task host:resources`** — reads host CPU + RAM via `docker info` (cross-platform: works on
  Linux deploy hosts, macOS Docker Desktop, and Docker Desktop on Windows / WSL2 — values
  reflect the VM allocation on Desktop, which is correct since containers can't escape the
  VM). Prints a compose override with `mem_limit` for every service. Fixed ceilings for the
  bounded workloads (nginx-api, redis at 384 MiB above the in-process `--maxmemory`, traefik,
  socket-proxy); 50%/30% of the dynamic allocation for os2display and mariadb. Operator
  captures stdout into `compose.resource-limits.yml` (gitignored) and opts in via
  `COMPOSE_FILE=docker-compose.yml:compose.resource-limits.yml`. Assumes dedicated host; fails
  loudly with a useful error on hosts smaller than ~2.3 GiB.
- **`task host:php -- <mem_limit_mb>`** — derive PHP-FPM pool sizing
  (`PHP_PM_MAX_CHILDREN`, `PHP_PM_START_SERVERS`, `PHP_PM_MIN/MAX_SPARE_SERVERS`,
  `PHP_OPCACHE_MEMORY_CONSUMPTION`) from a given os2display container `mem_limit`. Heuristic:
  60 MiB per Symfony+Doctrine worker, 50 MiB FPM overhead, OPcache 64/128/256 MiB depending on
  container size. For 256 MiB → 2 workers + 64 MiB OPcache; 1024 MiB → 11 workers + 256 MiB
  OPcache. Containers smaller than 256 MiB fail with an explicit error.
- **`task host:disk`** — bind-mount sizes (`./media`, `./jwt`, `./backup`), named-volume sizes
  (detected by `${COMPOSE_PROJECT_NAME}_*` prefix), host filesystem free-space on the project's
  mount point (covers bind mounts), and a docker-managed storage summary (images, containers,
  volumes, and build cache: used and reclaimable). On Linux the host filesystem and docker
  storage are usually the same partition; on Docker Desktop they're separate (the VM-allocated
  disk is often the surprising bottleneck for named-volume growth, default 60 GB on Mac).
- **`task host:disk:tenants`** — `./media` usage broken down by tenant subdirectory, sorted
  descending. The v3 image's Vich uploader stores each tenant's uploads at
  `./media/<tenantKey>/`, so the task reads the filesystem directly — no DB query.
- `.gitignore` adds `compose.resource-limits.yml`.

### Added — generic Symfony CLI proxy

- `task console` runs any `bin/console` command in the `os2display` container, e.g.
  `task console -- debug:router`. Accepts `EXEC_FLAGS` for `docker compose exec`-level
  flags (`-T`, `--user deploy`) and `CLI_ARGS` for the bin/console arguments.
- `cache:clear`, `tenant:add`, `user:add`, and `templates:install` reimplemented as thin
  wrappers around `task: console` instead of carrying their own
  `{{.COMPOSE}} exec … bin/console …` lines. The compose-exec recipe lives in one
  place; tasks are pure metadata + arg passing.
- The `bin/console app:update` and `bin/console lexik:jwt:generate-keypair` calls inside
  `task install` and `task update` also route through `task console`.

### Added — dev-tooling task family

- `dev:lint`, `dev:lint:md`, `dev:lint:md:fix`, `dev:lint:yaml`, `dev:lint:yaml:fix`,
  `dev:lint:fix`. Wraps the existing `markdownlint` and `prettier` `dev`-profile services.
  CI workflows still call docker compose directly (no Task dependency on runners); the Task
  wrappers are local-dev convenience.

### Changed — image WORKDIR restored to `/app`

- Image-tag pin bumped from `3.0.0-rc1` to `3.0.0-rc2`. Upstream
  [`display-api-service` PR #430](https://github.com/os2display/display-api-service/pull/430)
  restored the image's `WORKDIR` from `/var/www/html` (silent drift in rc1) to `/app`, matching
  the 2.x layout and existing operator deployments. We flip our paths to follow.
- `docker-compose.yml`: bind mounts `./jwt:/app/config/jwt:rw` and `./media:/app/public/media:rw`
  on the `os2display` and `nginx-api` services (was `/var/www/html/...`).
- `task env:init` and `task env:diff`: read `/app/.env` from the image (was `/var/www/html/.env`).
- `.env.nginx.example`: `NGINX_WEB_ROOT` documented default `/app/public`
  (was `/var/www/html/public`).
- README + CHANGELOG path references updated.

### Documentation

- **README polish pass.** Quick Start condensed from five manual `cp`/`$EDITOR` steps to three
  task invocations (`task env:init` → `task env:traefik` → `task install`) — `task env:init`
  now creates `.env` (prompting for the domain), copies per-service templates, and bootstraps
  `.env.symfony`, so the manual `cp` steps are redundant. Cookbook gets a TOC linking all 24
  recipes; the duplicate "How do I read service logs?" stub merged into "How do I tail and
  triage logs?". Caveats and foot-guns gets per-topic `####` sub-headings + a TOC. New
  Configuration files preamble explicitly states three project-wide conventions: shipped
  examples are sane production defaults (sentinels for what can't be defaulted), all
  configuration options are documented in the `.env.<X>.example` files, `env_file:` per
  service (not compose `environment:`) for clean isolation. Design principles add an
  explicit reference to the [Taskfile style guide](https://taskfile.dev/styleguide/) the
  Taskfile follows.
- Prerequisites tightened: `task db:backup` clarified to run `mariadb-dump` *inside* the
  mariadb container (no host-side mariadb-dump dep). Production deploy target stays Linux,
  but the no-host-tooling promise is explicit.
- README rewritten end-to-end. Split into **Operator guide** (prerequisites, quick start,
  per-service config files, stack composition, network topology, cookbook, caveats &
  foot-guns, 2.x→3.x migration) and **Developer guide** (design principles, local dev,
  repository layout, linting, CI). Plus a **Reference** section (all tasks, image
  registries).
- New **Cookbook** with How-do-I sections covering install, upgrade, MariaDB major bump,
  cert-provider switch, external DB / proxy, shared frontend network, PHP/nginx tuning,
  backup + restore, tenant + user creation, template install, registry auth, log + cache.
- New **Caveats and foot-guns** section enumerating the operator gotchas the stack documents
  but doesn't (and in some cases can't) prevent: cert-file SAN coverage, Doctrine
  `serverVersion` mismatch, `.env.mariadb` ↔ `.env.symfony` credential coupling, `./media`
  permission contract, `PHP_OPCACHE_VALIDATE_TIMESTAMPS=0` in production, Let's Encrypt
  rate limits, destructive vs non-destructive task semantics, `task env:init FORCE=1`,
  compose profile gating only applies to services, `NGINX_MAX_BODY_SIZE` ≥
  `PHP_UPLOAD_MAX_FILESIZE`, `mysql_native_password` deprecation horizon, Docker Hub
  anonymous rate limits, external `frontend` network manual creation, auto-loaded
  `compose.override.yml`, editing committed `.example` templates.
- New **Design principles** section articulating the two repo-level constraints we work
  under: only Task and docker compose required locally; build on stack standards (don't
  reinvent features compose / Task / the upstream image already provide).
- README "Image registries and authentication" section with the registry inventory (3 images on
  GHCR, 5 on Docker Hub), Docker Hub anon rate-limit guidance, GHCR auth recipe (PAT and `gh`
  variants), and a `docker/login-action` snippet for CI if one of the GHCR images flips private.

### Migration from older releases

See [UPGRADE.md](UPGRADE.md) for the step-by-step 1.x → 3.x recipe.

## v1.0.0 - Initial Release

- Introduced a Docker-based deployment tool for hosting the OS2display application.
- Provided pre-configured files and task automation for simplifying deployment and management.
- Added support for secure mode (HTTPS on port 443) with domain name and SSL certificate
  requirements.
- Included a `Taskfile.yml` with tasks for installation, tenant/user management, template
  loading, and maintenance.
- Documented prerequisites and setup instructions for Docker, Docker Compose, and Taskfile CLI.
