# Changelog

## [Unreleased] — release/3.0.0

### Changed (breaking) — MariaDB major version bump

- **`mariadb:10.11.16` → `mariadb:11.4.10`** (LTS-to-LTS).
  - Operators must take a backup, run the upgrade, and update `DATABASE_URL` `serverVersion=` in `.env.local` (e.g. `serverVersion=11.4.10-MariaDB`). Doctrine uses `serverVersion` to pick its SQL dialect; a mismatch produces wrong queries.
  - Full recipe in README § "Upgrading the bundled MariaDB across a major version".
  - `task db:backup` and `task db:upgrade` automate the steps that are container-local; the `serverVersion` edit and the dependent-service stop/start are still operator actions.

### Added

- Global JSON-file log rotation via `x-logging` anchor (10MB × 3 files per service). Applied to every service so a runaway container can't fill the host disk.
- Healthchecks on `os2display` (PHP TCP probe to fpm 9000), `nginx-api` (`wget /health`), `redis` (`redis-cli ping`), and `mariadb` (`healthcheck.sh --connect --innodb_initialized`). `nginx-api.depends_on.os2display.condition: service_healthy` so `task install` actually waits for fpm before declaring the stack up.

### Changed

- Pinned `redis` to `8-alpine` (was floating `redis:6`). Added `--maxmemory 256mb --maxmemory-policy allkeys-lru --save 60 1000 --appendonly yes` to `command:` so the cache has a memory ceiling, an eviction policy, and persistence to a named `redis-data` volume.
- Bumped `mariadb` from `10.11.11` to `10.11.16` (current 10.11 LTS patch).
- nginx env-var contract aligned with the v3 image: `NGINX_FPM_UPLOAD_MAX` → `NGINX_MAX_BODY_SIZE`. The obsolete `PHP_FPM_SERVER` override removed (image's `NGINX_FPM_SERVICE=os2display` default is correct).

### Documentation

- README documents the UID 1042 (deploy, api) / UID 101 (nginx-unprivileged) permission contract for the `./media` and `./jwt` bind mounts. Added a hint about debugging broken thumbnails.

### Fixed

- Traefik dashboard `PathPrefix` was misspelled `/treafik/dashboard`, so the dashboard router never matched. Corrected to `/traefik/dashboard`.

### Security

- Added the three TLS 1.3 cipher suites (`TLS_AES_256_GCM_SHA384`, `TLS_AES_128_GCM_SHA256`, `TLS_CHACHA20_POLY1305_SHA256`) to the modern TLS profile so 1.3 negotiations have an explicit allow-list. Both `traefik/dynamic-conf-letsencrypt.yaml` and `traefik/dynamic-conf-cert-file.yaml`.
- Removed `serversTransport.insecureSkipVerify: true` from `traefik/traefik.yml`. The setting globally disabled backend certificate validation for every router. Backends in this stack speak plain HTTP internally so the flag was inert in practice, but it shadowed the default-deny posture and would silently weaken any future HTTPS backend.

### Changed (breaking)

- `socket-proxy` service hardened: image moved from unpinned `itkdev/docker-socket-proxy` (Docker Hub) to `ghcr.io/tecnativa/docker-socket-proxy:v0.4.2` (upstream, version-pinned). Dropped `user: root`, added `read_only: true` + `tmpfs: [/run]`, `security_opt: [no-new-privileges:true]`, and a healthcheck against `/version`.

- API + nginx images switched from `itkdev/os2display-api-service{,-nginx}` (Docker Hub) to `ghcr.io/os2display/display-api-service{,-nginx}` (GHCR), pinned at `3.0.0-rc1`.
- `.env.local` keys are bare Symfony names (no `APP_` prefix) — every `APP_X` from a 2.x deployment becomes `X`, **except** `APP_ENV` and `APP_SECRET` which are Symfony-defined and keep the prefix. Full rename list in upstream `display-api-service` `UPGRADE.md` § 2.1.
- `task install` runs `bin/console app:update` (was `doctrine:schema:create`).
- `task update` runs `bin/console app:update` (was `doctrine:migrations:migrate --no-interaction`).
- `task load_templates` collapsed to `app:templates:install --all --update` and `app:screen-layouts:install --all --update --cleanupRegions`. v3 bundles templates in the image — no more URL fetching, no `TASK_VERSION_TEMPLATES` / `TASK_TEMPLATES` / `TASK_SCREEN_LAYOUTS` in `.env`.

### Added

- `task env:init` — extracts the annotated `.env` shipped at `/var/www/html/.env` in the API image and writes it to `.env.local`.
- `task env:diff` — diffs your `.env.local` against the example in the currently-pinned image.
- `task env:migrate` — rewrites a 2.x `.env.docker.local` (or APP_-prefixed `.env.local`) to v3 bare-name format, output to `.env.local.migrated` for review.

### Removed

- `.env.local.example` — operators bootstrap from the image via `task env:init`. The image's `/var/www/html/.env` is the single source of truth.
- `TASK_VERSION_TEMPLATES`, `TASK_TEMPLATES`, `TASK_SCREEN_LAYOUTS` from `.env.example` — obsolete with v3's bundled templates.

- Compose stack consolidated into a single `docker-compose.yml`. The split into `docker-compose.server.yml` + `docker-compose.mariadb.yml` + `docker-compose.traefik.yml` is gone, along with the Taskfile `_dc_compile` synthesis step that merged them.
- Built-in MariaDB and Traefik are now activated via `COMPOSE_PROFILES` (read natively by docker compose) instead of `INTERNAL_DATABASE` / `INTERNAL_PROXY` flags. Default `COMPOSE_PROFILES=mariadb,traefik` reproduces the prior behavior. To use external DB or proxy, drop the matching token.
- Screen-client URLs (`APP_API_ENDPOINT`, etc.) are now derived from `OS2DISPLAY_SERVER_DOMAIN` directly in `docker-compose.yml`. Operators no longer hand-edit five `https://demo.os2display.dk` lines in `.env`.

- Operator config split into two files: `.env` for orchestration (read by docker compose) and `.env.local` for application config (passed to the `os2display` container via `env_file:`). The single `.env.docker.local` is gone.
- Project-specific orchestration variables renamed from `COMPOSE_*` to `OS2DISPLAY_*` to avoid shadowing names docker compose itself reads. `COMPOSE_PROJECT_NAME` and `COMPOSE_PROFILES` keep their `COMPOSE_` prefix because they are native to docker compose. Renames: `COMPOSE_SERVER_DOMAIN` → `OS2DISPLAY_SERVER_DOMAIN`, `COMPOSE_ADMIN_CLIENT_PATH` → `OS2DISPLAY_ADMIN_CLIENT_PATH`, `COMPOSE_SCREEN_CLIENT_PATH` → `OS2DISPLAY_SCREEN_CLIENT_PATH`, `COMPOSE_VERSION_API` → `OS2DISPLAY_VERSION_API`, `COMPOSE_VERSION_ADMIN` → `OS2DISPLAY_VERSION_ADMIN`, `COMPOSE_VERSION_CLIENT` → `OS2DISPLAY_VERSION_CLIENT`.
- The `api` service is renamed to `os2display`.
- The giant `APP_*` translation block on the API service is replaced with `env_file: [.env.local]`. Adding new Symfony env vars no longer requires touching `docker-compose.server.yml`.
- Taskfile invocations no longer pass `--env-file .env.docker.local`; docker compose reads `.env` natively.
- `restart.sh` folded into a new `task update` (pulls images, recreates containers, runs `doctrine:migrations:migrate`).

### Removed

- `.env.docker.example` — split into `.env.example` (orchestration) and `.env.local.example` (app config).
- `load-templates-prod.sh`, `load-templates-develop.sh` — duplicated by `task load_templates`.
- `restart.sh` — replaced by `task update`.

### Migration from 2.x

1. `git fetch && git checkout release/3.0.0`
2. Stop the stack: `task stop`
3. `cp .env.docker.local /tmp/env.docker.local.backup`
4. `cp .env.example .env` and copy your old orchestration values (`COMPOSE_*`, `MARIADB_*`, `INTERNAL_*`, `TASK_*`, admin/client `APP_*`) over.
5. `cp .env.local.example .env.local` and copy your old API-service values (`APP_SECRET`, `APP_DATABASE_URL`, `APP_JWT_*`, `APP_INTERNAL_OIDC_*`, etc.) over.
6. `task install` re-creates the stack against the new file layout.

## v1.0.0 - Initial Release

- Introduced a Docker-based deployment tool for hosting the OS2display application.
- Provided pre-configured files and task automation for simplifying deployment and management.
- Added support for secure mode (HTTPS on port 443) with domain name and SSL certificate requirements.
- Included a `Taskfile.yml` with tasks for installation, tenant/user management, template loading, and maintenance.
- Documented prerequisites and setup instructions for Docker, Docker Compose, and Taskfile CLI.