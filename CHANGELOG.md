# Changelog

## [Unreleased] — release/3.0.0

This is the operator-facing 2.x → 3.x cut. The `display-api-service` image bundles the admin and
screen-client UIs in 3.x; this repo's compose stack is consolidated, hardened, and aligned to the
v3 image's env contract. Skim the **Migration from 2.x** section at the bottom before upgrading.

### Added

- `task env:init` — extracts the annotated `.env` shipped at `/var/www/html/.env` in the API
  image and writes it to `.env.local`. Replaces the previous checked-in `.env.local.example`; the
  image is now the single source of truth for the operator-facing env surface.
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
  to every service so a runaway container can't fill the host disk.
- Healthchecks on `os2display` (PHP TCP probe to fpm 9000), `nginx-api` (`wget /health`), `redis`
  (`redis-cli ping`), `mariadb` (`healthcheck.sh --connect --innodb_initialized`), and
  `socket-proxy` (`wget /version`). `nginx-api.depends_on.os2display.condition: service_healthy`
  so `task install` actually waits for fpm before declaring the stack up.
- Markdown and YAML linting via the `dev` compose profile (`markdownlint` and `prettier`
  services). Configs adopted from
  [itk-dev/devops_itkdev-docker](https://github.com/itk-dev/devops_itkdev-docker).
- GitHub Actions workflows: `Markdown`, `YAML`, `Compose` (synthesis + image-availability +
  env-coverage). Pre-merge gates that catch dangling `${VAR}` references, missing image tags,
  and lint regressions.

### Changed (breaking)

- `socket-proxy` service hardened: image moved from unpinned
  `itkdev/docker-socket-proxy` (Docker Hub) to
  `ghcr.io/tecnativa/docker-socket-proxy:v0.4.2` (upstream, version-pinned).
  Dropped `user: root`, added `read_only: true` + `tmpfs: [/run]`,
  `security_opt: [no-new-privileges:true]`, and a healthcheck against
  `/version`.
- **Operator env config split into one file per service.** Previously runtime
  tunables (`PHP_*`, `NGINX_*`, `MARIADB_*`) lived in `.env` and were
  substituted into compose `environment:` blocks; Symfony app config lived in
  `.env.local`. That gave a split surface and let compose silently override
  env_file values — opposite of what env_file was for. New layout:

  | File           | Service env                   | Canonical example                                              |
  | -------------- | ----------------------------- | -------------------------------------------------------------- |
  | `.env.symfony` | os2display Symfony app config | image-extracted via `task env:init`                            |
  | `.env.php`     | os2display PHP-FPM runtime    | `.env.php.production.example`                                  |
  | `.env.nginx`   | nginx-api runtime             | `.env.nginx.production.example`                                |
  | `.env.mariadb` | mariadb credentials           | `.env.mariadb.production.example`                              |
  | `.env.traefik` | traefik config                | `.env.traefik.production.example` (renamed from `.env.traefik.example`) |
  | `.env`         | compose orchestration         | `.env.example` (shrunk)                                        |

  Each compose service reads its own `env_file:` list. No cross-service env
  leakage. The compose-level `environment:` blocks on `os2display`, `nginx-api`,
  and `mariadb` are gone. `task env:init` produces `.env.symfony` (was
  `.env.local`); `task env:diff` and `task env:migrate` updated to match.
  `task install`'s `_env_files` dep auto-creates any missing per-service env
  file from its `.production.example` template.

### Fixed

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
  `/var/www/html/.env` (extracted by `task env:init`).
- `.env.local.example` — operators bootstrap from the image via `task env:init`. The image's
  `/var/www/html/.env` is the single source of truth.
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
- Removed `SERVER_FRONTEND_NETWORK` from `.env.traefik.production.example`. The corresponding
  substitution on `traefik.networks` is gone.

### Documentation

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
  `compose.override.yml`, editing committed `.production.example` templates.
- New **Design principles** section articulating the two repo-level constraints we work
  under: only Task and docker compose required locally; build on stack standards (don't
  reinvent features compose / Task / the upstream image already provide).
- README "Image registries and authentication" section with the registry inventory (3 images on
  GHCR, 5 on Docker Hub), Docker Hub anon rate-limit guidance, GHCR auth recipe (PAT and `gh`
  variants), and a `docker/login-action` snippet for CI if one of the GHCR images flips private.

### Migration from 2.x

1. `git fetch && git checkout release/3.0.0`
2. `task stop` to bring the 2.x stack down.
3. **Backup**: `task db:backup` (writes `./backup/<timestamp>.sql.gz`). And keep your old
   `.env.docker.local` somewhere safe.
4. **Orchestration env**: `cp .env.example .env`. Copy over your old domain, image versions,
   MariaDB credentials. The `INTERNAL_DATABASE` / `INTERNAL_PROXY` toggles are gone — use
   `COMPOSE_PROFILES=mariadb,traefik` (or drop a token if running external infra).
5. **Application env**: `task env:migrate` to translate your old `.env.docker.local` into a
   v3-shaped `.env.local.migrated`. Review the diff (`diff -u .env.docker.local
   .env.local.migrated`), then `mv .env.local.migrated .env.local`. Or, for a clean start:
   `task env:init` to pull the annotated example from the image, then edit by hand.
6. **Set `serverVersion`** in `DATABASE_URL` (in `.env.local`) to `11.4.10-MariaDB` for the bumped
   MariaDB.
7. **Set `ADMIN_*` and `CLIENT_*`** keys in `.env.local` to match your previous admin/client
   container config (login methods, color scheme, etc.). The image defaults suffice for a
   working install.
8. `task install` re-creates the stack against the new file layout. The mariadb container's
   entrypoint will run `mariadb-upgrade` automatically on the existing 10.x data; running
   `task db:upgrade` afterwards is a cheap belt-and-suspenders sanity step.
9. `task cc` to flush Doctrine's cached metadata.

## v1.0.0 - Initial Release

- Introduced a Docker-based deployment tool for hosting the OS2display application.
- Provided pre-configured files and task automation for simplifying deployment and management.
- Added support for secure mode (HTTPS on port 443) with domain name and SSL certificate
  requirements.
- Included a `Taskfile.yml` with tasks for installation, tenant/user management, template
  loading, and maintenance.
- Documented prerequisites and setup instructions for Docker, Docker Compose, and Taskfile CLI.
