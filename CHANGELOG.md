# Changelog

## [Unreleased] — release/3.0.0

See [UPGRADE.md](UPGRADE.md) for the step-by-step 1.x → 3.x recipe.
See the [v2.x.x — Skipped](#v2xx---skipped) entry below for why this major skips 2.x.

### Application

- v3 `display-api-service` image bundles the admin and screen-client UIs as Symfony routes
  — the separate `admin` and `client` compose services are gone.
- Bump bundled MariaDB from 10.x to 11.4 LTS.
- All images now pull from `ghcr.io/os2display/*` (was Docker Hub / itk-dev).

### Operator surface

- Quick start is three commands: `task env:init` → `task env:traefik` → `task install`.
- Env config split per-service: `.env` (orchestration), `.env.symfony` (app),
  `.env.php`, `.env.nginx`, `.env.mariadb`, `.env.traefik`. `task env:init` bootstraps
  every file in one go — extracts `.env.symfony` from the API image (the canonical source
  for app config), generates random `APP_SECRET` + `JWT_PASSPHRASE`, copies per-service
  templates.
- `task env:diff` compares your `.env.symfony` against the example shipped in the
  currently-pinned API image.
- `task env:migrate` rewrites a 1.x `.env.docker.local` into the v3 layout.
- Per-service `.env.<svc>.local` override layer for site-specific tuning; gitignored.
- Compose profiles (`COMPOSE_PROFILES=mariadb,traefik`) gate built-in services — drop
  `mariadb` for an external DB, drop `traefik` for an external proxy.
- Task names `:`-namespaced (`cache:clear`, `tenant:add`, `user:add`, `templates:install`,
  `env:traefik`); old names (`cc`, `tenant_add`, `user_add`, `load_templates`,
  `traefik_env`) kept as deprecated aliases.
- `task purge` and `task reinstall` are prompt-gated; bypass with `task --yes`.
- README rewritten end-to-end into Operator guide, Developer guide, and Reference sections.

### Operations

- All services get healthchecks. `task up / install / update` block on `compose up --wait`
  — return only when the stack is genuinely ready (no more `sleep 20` race).
- New `task db:backup` (online `mariadb-dump` to `./backup/<ts>.sql.gz`) and `task db:upgrade`
  (idempotent `mariadb-upgrade`).
- New MariaDB diagnostics: `task db:metrics`, `db:processes`, `db:errors`.
- New host inspection family: `task host:resources` (recommend `mem_limit`s), `host:php`
  (PHP-FPM pool sizing), `host:disk`, `host:disk:tenants`.
- New log inspection namespace: `task logs` (follow), `logs:since`, `logs:errors`,
  `logs:access`, `logs:disk`.
- Global JSON-file log rotation (10MB × 3 files per service), tunable via `LOG_MAX_SIZE` /
  `LOG_MAX_FILE`.
- Aligned media-upload limits with the upstream 3.0.0 app cap: `.env.php.example` ships
  `PHP_UPLOAD_MAX_FILESIZE=200M` / `PHP_POST_MAX_SIZE=210M` and `.env.nginx.example` ships
  `NGINX_MAX_BODY_SIZE=210m`, matching the new `MEDIA_MAX_UPLOAD_SIZE_MB=200` Symfony validator
  ceiling that 3.0.0 introduces. UPGRADE.md §5 explains the four-layer alignment rule.

### Local development

- `task dev:install` brings up the stack on `*.localhost` with a self-signed cert — one
  command from clone to admin UI, no public DNS needed.
- `task dev:teardown` resets containers, volumes, JWT keypair, dev cert, and bootstrapped
  env files for a clean rebuild.

### Security

- Hardened `socket-proxy`: read-only filesystem, `no-new-privileges`, version-pinned to
  the upstream Tecnativa image.
- Hardened Traefik: TLS 1.3 cipher suites, HSTS, no public dashboard port, dashboard
  behind basic auth, HTTPS redirect at entrypoint.
- `task install` auto-generates random MariaDB credentials and syncs the application-user
  password into `DATABASE_URL`. Operator-supplied values are preserved.

### CI

- New workflows: `Markdown`, `YAML`, `Shell`, `Compose` (synthesis + image-availability +
  env-coverage), `Tasks` (README ↔ Taskfile drift), and `E2E` on release branches (full
  stack boot + admin route smoke test).

### Removed

- `admin` and `client` compose services — bundled into the v3 API image.
- `.env.docker.example`, `.env.local.example` — replaced by per-service `.env.<svc>.example`
  templates + image-extracted `.env.symfony`.
- `load-templates-prod.sh`, `load-templates-develop.sh` — replaced by
  `task templates:install`.
- `restart.sh` — replaced by `task update`.

## v2.x.x - Skipped

No 2.x release was ever tagged. Internal canonical work happened on a `release/2.0.0`
branch but never shipped publicly. The next public major after the 1.x line is 3.0.0,
chosen to align with upstream
[`display-api-service`](https://github.com/os2display/display-api-service) (at 3.x) so
operators see one major-version number per stack.

## v1.1.2 - 2026-02-06

- Bump os2display version from 2.5.1 to 2.6.0. Client updated from 2.2.1 to 2.3.0.
- Update `TASK_TEMPLATES` in `.env.docker.example` to include `brnd`.
- Bring CHANGELOG up-to-date with v1.1.0 and v1.1.1 entries.

## v1.1.1 - 2025-08-20

- Assume install by user where UID and GID is 1042. The README contains further details.
- Install the vimeo-template as default.
- Add the screen layout `two-boxes-vertical-reversed` as default.
- Extend wait-for-db so install works on slow hardware / VMs.
- New env var `APP_KEY_VAULT_JSON` added.

## v1.1.0 - 2025-06-24

- **Bugfix:** `COMPOSE_SCREEN_CLIENT_PATH` default was `/screen`, should be `/client`.
- Bump os2display version from 2.4.0 to 2.5.1.
- Improved task menu.
- Env var changes now take effect after `task down` followed by `task up`.

## v1.0.0 - 2025-04-08

- Introduced a Docker-based deployment tool for hosting the OS2display application.
- Provided pre-configured files and task automation for simplifying deployment and management.
- Added support for secure mode (HTTPS on port 443) with domain name and SSL certificate
  requirements.
- Included a `Taskfile.yml` with tasks for installation, tenant/user management, template
  loading, and maintenance.
- Documented prerequisites and setup instructions for Docker, Docker Compose, and Taskfile CLI.
