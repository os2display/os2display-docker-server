# OS2display v3 Hosting and Deployment

This is a deployment tool designed for hosting the OS2display application using Docker. It
provides a Docker Compose based setup, pre-configured files, and task automation to simplify the
deployment and management of the application.

## Prerequisites

Before you begin, ensure you have the following installed on your system:

1. **Docker**: Install Docker Engine (version 20.10 or later).
2. **Docker Compose**: Use Docker Compose v2 (integrated with the `docker compose` command).
3. **Task**: Install the Taskfile CLI tool. You can find installation instructions at
   [taskfile.dev](https://taskfile.dev/#/installation).

Make sure your user has the necessary permissions to run Docker commands (e.g., being part of the
`docker` group).

### Check Prerequisites

Run the following commands to verify that the prerequisites are installed:

```bash
# Check Docker installation
docker --version

# Check Docker Compose installation
docker compose version

# Check Taskfile CLI installation
task --version
```

## Create the deploy-user

The bind mounts have two readers/writers with different UIDs:

- The `os2display` (api) container writes media and reads JWT keys as **UID 1042** (`deploy`).
- The `nginx-api` container reads media to serve them as **UID 101** (`nginx-unprivileged`).

To prevent permission issues, install the application as a host user with UID 1042 and GID 1042 —
that user will own everything written into `./media` and `./jwt`. The host directory must also be
readable by UID 101 (nginx); the simplest setup is to make `./media` group-readable with group
1042, since UID 101 inside the nginx container can read group-readable files via the
supplementary-group bridge that `chmod g+r` provides on a typical Linux host. If you see broken
thumbnails or 404s on uploaded images, double-check the `./media` permissions before anything
else.

Create a host user with UID 1042 and GID 1042 (any name works — `deploy` by convention):

```bash
# Create group and user with UID/GID 1042
sudo groupadd -g 1042 deploy
sudo useradd -u 1042 -g 1042 -m -s /bin/bash deploy
sudo passwd deploy

# Add the user to the docker group
sudo usermod -aG docker deploy
```

## Traefik Configuration

### Secure Mode Requirement

This project can only run in secure mode using HTTPS (port 443). A Traefik reverse proxy will
handle HTTPS using either:

- Let's encrypt certificates (default)
- Custom certificate/key files

### Steps to Configure Secure Mode

1. **Domain Name**: Use a fully qualified domain name (FQDN) that resolves to your server's IP
   address.
2. **SSL Certificate**, either:
   - Let traefik generate a certificate using Let's Encrypt (default).
   - Place the certificate file (`docker.crt`) and the private key file (`docker.key`) in the
     `traefik/ssl` directory.
3. **Update Configuration**: Ensure the domain name is correctly configured in `.env`
   (`OS2DISPLAY_SERVER_DOMAIN`).

Without a valid domain name and SSL certificate, the project will not function as expected.

## Configuration files

This setup separates orchestration config (read by docker compose) from application config (passed
to the API container):

| File | Purpose | Bootstrap |
|---|---|---|
| `.env` | Orchestration: project name, domain, image versions, profile toggles, MariaDB credentials, PHP runtime tuning. Read by `docker compose` for variable substitution. | `cp .env.example .env` |
| `.env.local` | Application config for the API service: `APP_SECRET`, `DATABASE_URL`, JWT, OIDC, Redis, calendar feed, admin/client settings, etc. Mounted into the `os2display` container via `env_file:`. | `task env:init` (extracts the annotated example shipped in the API image) |
| `.env.traefik` | Traefik dashboard auth, Let's Encrypt email, cert provider. | `task traefik_env` (interactive) or `cp .env.traefik.example .env.traefik` |

Edit each file before running `task install`.

`task env:diff` compares your `.env.local` against the example shipped in the currently-pinned
API image. `task env:migrate` rewrites a 2.x `.env.docker.local` (or an APP_-prefixed
`.env.local`) into the v3 bare-name format — output goes to `.env.local.migrated` for review
before applying.

### Stack composition

`COMPOSE_PROFILES` in `.env` controls which built-in infrastructure services start. Core services
(`os2display`, `nginx-api`, `redis`) always run. The admin UI and screen client are bundled into
the `os2display` image in 3.x and served as Symfony routes — there are no separate `admin` /
`client` containers.

| `COMPOSE_PROFILES` value | Built-in services started | Use when |
|---|---|---|
| `mariadb,traefik` | MariaDB + Traefik (default) | Single-host install with no external infra |
| `traefik` | Traefik only | External database (set `APP_DATABASE_URL` in `.env.local` to point at it) |
| `mariadb` | MariaDB only | External proxy in front |
| (empty) | Neither | Both DB and proxy provided externally |

`COMPOSE_PROFILES` is read natively by docker compose; no `-f` flags or wrapper scripts.

## Available Tasks

The project uses a `Taskfile.yml` to simplify common operations. Below is a list of the most
important tasks you can run:

### Installation and Setup

- **`task traefik_env`**: Configures Traefik to use Let's Encrypt certificates or custom
  certificates.
- **`task install`**: Installs the project, pulls Docker images, sets up the database, and
  initializes the environment.
- **`task reinstall`**: Reinstalls the project from scratch, removing all containers, volumes, and
  the database.
- **`task up`**: Starts the environment without altering the existing state of the containers.
- **`task down`**: Stops and removes all containers and volumes.

### Tenant and User Management

- **`task tenant_add`**: Adds a new tenant group. A tenant is a group of users that share the same
  configuration.
- **`task user_add`**: Adds a new user (editor or admin) to a tenant.

### Templates and Screen Layouts

- **`task load_templates`**: Installs the templates and screen layouts bundled in the API image
  (`app:templates:install --all --update` and `app:screen-layouts:install --all --update
  --cleanupRegions`). 3.x ships templates inside the image — there is no longer a list of names or
  a version pin in `.env`.

### Maintenance

- **`task logs`**: Follows the logs from the Docker containers.
- **`task cc`**: Clears the cache in the application.

### Pre-installation Notes

Before running `task install`, ensure the following:

1. `cp .env.example .env` and set your `OS2DISPLAY_SERVER_DOMAIN`, `OS2DISPLAY_VERSION_API`, and
   MariaDB credentials.
2. `task env:init` to extract the annotated `.env.local` from the API image. Then edit it: set
   `APP_SECRET`, `JWT_PASSPHRASE`, `DATABASE_URL`, OIDC values, plus any `ADMIN_*` / `CLIENT_*`
   overrides you need (login methods, color scheme, screen-status visibility, etc.). The defaults
   from the image are sane enough to install and log in. (Operators upgrading from 2.x: run
   `task env:migrate` first to rename `APP_*` keys.)
3. Run `task traefik_env` to configure the Traefik dashboard credentials and Let's Encrypt email
   (or copy `.env.traefik.example` to `.env.traefik` and edit by hand).
4. If using a custom SSL certificate (`SERVER_CERT_PROVIDER=cert-file`), place `docker.crt` and
   `docker.key` in `traefik/ssl/`.

For a full list of tasks, run:

```bash
task --list
```

## Image registries and authentication

This stack pulls from two registries. Today every image is **public** and no
authentication is required to install. The recipes below cover the cases an
operator runs into in practice: Docker Hub anonymous rate limits, and the
possibility that an upstream image flips to private later.

### Registry inventory

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

The upstream `redis`, `mariadb`, and `traefik` projects publish only to Docker
Hub — there is no canonical GHCR mirror.

### Docker Hub: rate limits

Anonymous pulls from Docker Hub are capped at **100 per 6h per IP**. A multi-
host operator behind a shared NAT or NATted egress can run into this on
`task install` after a sequence of `docker compose pull` runs across hosts.

Authenticate to your free Docker Hub account to lift the cap to **200 per 6h
per user**:

```bash
docker login docker.io
# Username: <your Docker Hub username>
# Password: <a Docker Hub Personal Access Token, https://app.docker.com/settings/personal-access-tokens>
```

For unattended hosts, configure a credential helper instead of leaving the
token in `~/.docker/config.json` plaintext. On Linux servers,
`docker-credential-pass` (backed by `pass`) is the usual pick; see
[Docker's credential-store docs](https://docs.docker.com/engine/reference/commandline/login/#credential-stores).

If your operator scale is high enough that the 200/6h ceiling is also tight,
set up a [pull-through registry mirror](https://docs.docker.com/registry/recipes/mirror/)
(or use a managed one like AWS ECR pull-through cache or
[depot.dev](https://depot.dev/)) and point the host's Docker daemon at it.

### GHCR: pulling the os2display images

All `ghcr.io/os2display/*` images this stack uses are **public** today, so
`docker pull` works without `docker login`. No action required for a fresh
install.

If a future image becomes private (or you mirror Docker Hub images into your
own private GHCR namespace), authenticate with a GitHub Personal Access Token
that has the `read:packages` scope:

```bash
# Create a classic PAT with read:packages scope at:
#   https://github.com/settings/tokens/new?scopes=read:packages
echo "$GHCR_PAT" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
```

Or, if `gh` is installed and you've already run `gh auth login`:

```bash
gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin
```

The login persists in `~/.docker/config.json`; subsequent `docker compose pull`
calls on the same host pick it up automatically.

### GitHub Actions: pulling private GHCR images from CI

The `compose.yaml` workflow's `image-availability` job runs
`docker buildx imagetools inspect` against every pinned image. Public images
work without any setup. If we ever switch one of the os2display images to
private, add a `docker/login-action` step before the inspect job:

```yaml
- name: Log in to GHCR
  uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}
```

`GITHUB_TOKEN` automatically has `read:packages` for packages in the same org,
so no PAT management is needed.

## Linting

Markdown and YAML are linted in CI. To run the same checks locally:

```bash
docker compose --profile dev run --rm markdownlint markdownlint '**/*.md'
docker compose --profile dev run --rm prettier '**/*.{yml,yaml}' --check
```

Configs: `.markdownlint.jsonc` + `.markdownlintignore` and `.prettierrc.yaml` + `.prettierignore`.
Both are copies of the upstream
[itk-dev/devops_itkdev-docker](https://github.com/itk-dev/devops_itkdev-docker) templates.

## Upgrading the bundled MariaDB across a major version

A MariaDB major-version bump (e.g. 10.11 → 11.4) is binary-compatible at the data-file level —
MariaDB 11 reads 10.x InnoDB tablespaces — but it is not a one-shot container restart. Three
things have to happen for a clean cut:

1. **Take a backup.** `task db:backup` writes `./backup/<timestamp>.sql.gz` using
   `mariadb-dump --single-transaction`, no service downtime.
2. **Pull the new image, restart the DB, run the upgrade.** The official `mariadb` image's
   entrypoint auto-runs `mariadb-upgrade` when it detects a version bump on existing data, but
   running it explicitly afterwards via `task db:upgrade` is a cheap belt-and-suspenders sanity
   step. Errors in `mariadb-upgrade` surface only at query time later if skipped.
3. **Update `DATABASE_URL` `serverVersion=` in `.env.local`.** Doctrine uses this to pick its SQL
   dialect — a mismatch produces subtly wrong queries (most often: incorrect JSON or function
   syntax). For 11.4: `serverVersion=11.4.10-MariaDB`.

Recipe:

```bash
task db:backup                    # ./backup/<ts>.sql.gz
task stop                         # bring down dependents (api, nginx)

# Edit OS2DISPLAY_VERSION_API / mariadb tag in docker-compose.yml or rely on this branch's pin.
docker compose pull mariadb
docker compose up -d mariadb
docker compose logs -f mariadb    # wait until you see "ready for connections"

task db:upgrade                   # idempotent; safe to re-run

# Edit DATABASE_URL serverVersion in .env.local to match the new MariaDB version.
$EDITOR .env.local

task up                           # bring everything back up
task cc                           # flush Doctrine's cached metadata
```

If `task db:upgrade` reports incompatible objects, restore from the dump
(`gunzip < backup/<ts>.sql.gz | docker compose exec -T mariadb mariadb -u root -p$MARIADB_ROOT_PASSWORD`)
and roll back to the previous image before debugging.
