# Changelog

## [Unreleased] — release/3.0.0

### Changed (breaking)

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