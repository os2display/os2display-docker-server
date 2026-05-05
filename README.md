# OS2display v3 Hosting and Deployment

This is a deployment tool designed for hosting the OS2display application using Docker. It provides a Docker Compose 
based setup, pre-configured files, and task automation to simplify the deployment and management of the application.

## Prerequisites

Before you begin, ensure you have the following installed on your system:
1. **Docker**: Install Docker Engine (version 20.10 or later).
2. **Docker Compose**: Use Docker Compose v2 (integrated with the `docker compose` command).
3. **Task**: Install the Taskfile CLI tool. You can find installation instructions at [taskfile.dev](https://taskfile.dev/#/installation).

Make sure your user has the necessary permissions to run Docker commands (e.g., being part of the `docker` group).

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
Files inside the `os2display-api-service` container are owned by a user with UID 1042 and GID 1042. To prevent permission issues with bind mounts (the `media` and `jwt` volumes), it’s best to install the application using a user with the same UID and GID.

To set this up on your server, create a new user (for example, `deploy`). You can choose a different username if you prefer, but make sure to assign UID and GID 1042.

Here’s how to create the user:

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

This project can only run in secure mode using HTTPS (port 443). A Traefik reverse proxy will handle HTTPS using either
* Let's encrypt certificates (default) 
* Custom certificate/key files

### Steps to Configure Secure Mode:
1. **Domain Name**: Use a fully qualified domain name (FQDN) that resolves to your server's IP address.
2. **SSL Certificate**, either:
   - Let traefik generate a certificate using Let's Encrypt (default).
   - Place the certificate file (`docker.crt`) and the private key file (`docker.key`) in the `traefik/ssl` directory.
3. **Update Configuration**: Ensure the domain name is correctly configured in `.env` (`OS2DISPLAY_SERVER_DOMAIN`).

Without a valid domain name and SSL certificate, the project will not function as expected.

## Configuration files

This setup separates orchestration config (read by docker compose) from application config (passed to the API container):

| File | Purpose | Bootstrap |
|---|---|---|
| `.env` | Orchestration: project name, domain, image versions, profile toggles, MariaDB credentials, PHP runtime tuning. Read by `docker compose` for variable substitution. | `cp .env.example .env` |
| `.env.local` | Application config for the API service: `APP_SECRET`, `DATABASE_URL`, JWT, OIDC, Redis, calendar feed, admin/client settings, etc. Mounted into the `os2display` container via `env_file:`. | `task env:init` (extracts the annotated example shipped in the API image) |
| `.env.traefik` | Traefik dashboard auth, Let's Encrypt email, cert provider. | `task traefik_env` (interactive) or `cp .env.traefik.example .env.traefik` |

Edit each file before running `task install`.

`task env:diff` compares your `.env.local` against the example shipped in the currently-pinned API image. `task env:migrate` rewrites a 2.x `.env.docker.local` (or an APP_-prefixed `.env.local`) into the v3 bare-name format — output goes to `.env.local.migrated` for review before applying.

### Stack composition

`COMPOSE_PROFILES` in `.env` controls which built-in infrastructure services start. Core services (`os2display`, `nginx-api`, `redis`, `admin`, `client`) always run.

| `COMPOSE_PROFILES` value | Built-in services started | Use when |
|---|---|---|
| `mariadb,traefik` | MariaDB + Traefik (default) | Single-host install with no external infra |
| `traefik` | Traefik only | External database (set `APP_DATABASE_URL` in `.env.local` to point at it) |
| `mariadb` | MariaDB only | External proxy in front |
| (empty) | Neither | Both DB and proxy provided externally |

`COMPOSE_PROFILES` is read natively by docker compose; no `-f` flags or wrapper scripts.

## Available Tasks

The project uses a `Taskfile.yml` to simplify common operations. Below is a list of the most important tasks you can run:

### Installation and Setup
- **`task traefik_env`**: Configures Traefik to use Let's Encrypt certificates or custom certificates.
- **`task install`**: Installs the project, pulls Docker images, sets up the database, and initializes the environment.
- **`task reinstall`**: Reinstalls the project from scratch, removing all containers, volumes, and the database.
- **`task up`**: Starts the environment without altering the existing state of the containers.
- **`task down`**: Stops and removes all containers and volumes.

### Tenant and User Management
- **`task tenant_add`**: Adds a new tenant group. A tenant is a group of users that share the same configuration.
- **`task user_add`**: Adds a new user (editor or admin) to a tenant.

### Templates and Screen Layouts
- **`task load_templates`**: Installs the templates and screen layouts bundled in the API image (`app:templates:install --all --update` and `app:screen-layouts:install --all --update --cleanupRegions`). 3.x ships templates inside the image — there is no longer a list of names or a version pin in `.env`.

### Maintenance
- **`task logs`**: Follows the logs from the Docker containers.
- **`task cc`**: Clears the cache in the application.

### Pre-installation Notes
Before running `task install`, ensure the following:
1. `cp .env.example .env` and set your `OS2DISPLAY_SERVER_DOMAIN`, `OS2DISPLAY_VERSION_API`, and MariaDB credentials.
2. `task env:init` to extract the annotated `.env.local` from the API image. Then edit it: set `APP_SECRET`, `JWT_PASSPHRASE`, `DATABASE_URL`, and any OIDC values you need. (Operators upgrading from 2.x: run `task env:migrate` first to rename `APP_*` keys.)
3. Run `task traefik_env` to configure the Traefik dashboard credentials and Let's Encrypt email (or copy `.env.traefik.example` to `.env.traefik` and edit by hand).
4. If using a custom SSL certificate (`SERVER_CERT_PROVIDER=cert-file`), place `docker.crt` and `docker.key` in `traefik/ssl/`.

For a full list of tasks, run:
```bash
task --list
```



