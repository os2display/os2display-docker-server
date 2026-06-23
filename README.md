# OS2display v2 Hosting and Deployment

This is a deployment tool designed for hosting the OS2display v2 application using Docker. It provides a Docker-based setup, pre-configured files, and task automation to simplify the deployment and management of the application.

## Prerequisites

Before you begin, ensure you have the following installed on your system:
1. **Docker**: Install Docker Engine (version 20.10 or later).
2. **Docker Compose**: Use Docker Compose v2 (integrated with the `docker compose` command).
3. **Task**: Install the Taskfile CLI tool. You can find installation instructions [here](https://taskfile.dev/#/installation).

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

## Secure Mode Requirement

This project can only run in secure mode using HTTPS (port 443). To ensure proper functionality, you must provide a valid domain name and an SSL certificate.

### Steps to Configure Secure Mode:
1. **Domain Name**: Use a fully qualified domain name (FQDN) that resolves to your server's IP address.
2. **SSL Certificate**: Provide a valid SSL certificate and private key for the domain.
   - Place the certificate file (`docker.crt`) and the private key file (`docker.key`) in the `traefik/ssl` directory.
3. **Update Configuration**: Ensure the domain name is correctly configured in the `.env.docker.local` file.

Without a valid domain name and SSL certificate, the project will not function as expected.

## Available Tasks

The project uses a `Taskfile.yml` to simplify common operations. Below is a list of the most important tasks you can run:

### Installation and Setup
- **`task install`**: Installs the project, pulls Docker images, sets up the database, and initializes the environment.
- **`task reinstall`**: Reinstalls the project from scratch, removing all containers, volumes, and the database.
- **`task up`**: Starts the environment without altering the existing state of the containers.
- **`task down`**: Stops and removes all containers and volumes.

### Tenant and User Management
- **`task tenant_add`**: Adds a new tenant group. A tenant is a group of users that share the same configuration.
- **`task user_add`**: Adds a new user (editor or admin) to a tenant.

### Templates and Screen Layouts
- **`task load_templates`**: Loads templates and screen layouts based on the configuration in `.env.docker.local`.

### Maintenance
- **`task logs`**: Follows the logs from the Docker containers.
- **`task cc`**: Clears the cache in the application.
- **`task backup_db`**: Dumps the bundled MariaDB database to `db_backups/`.

### Upgrading to 3.x
- **`task upgrade_check`**: Pre-flight checks before the upgrade — verifies the api image
  provides `app:utils:convert-env-to-3x` and records the bundled MariaDB volume name. Run it
  before `task env_migrate`.
- **`task env_migrate`**: Converts the configuration of the running 2.x installation
  (loaded env vars plus the served admin/client `config.json`) to a 3.x-shaped
  `.env.symfony.migrated` on the host, via the api console command
  `app:utils:convert-env-to-3x` (requires display-api-service >= 2.8). The site's
  public URL is taken from `COMPOSE_SERVER_DOMAIN`; extra arguments are forwarded,
  e.g. `task env_migrate -- --skip-config-json`. Review the result before using it
  as the starting point for the 3.x application env.

### Pre-installation Notes
Before running `task install`, ensure the following:
1. Update `.env.docker.local` with your domain name (replace all 5 instances) and set secure passwords.
2. Place your SSL certificate files (`docker.crt` and `docker.key`) in the `traefik/ssl` directory.

For a full list of tasks, run:
```bash
task --list
```

## Preparing an upgrade to 3.x

This is the last planned 1.x release of this repository. The 3.x line (the
`release/3.0.0` branch, `main` once released) runs the upstream
[`display-api-service`](https://github.com/os2display/display-api-service) 3.x
images, which bundle the admin and screen client into the API image. The full
migration recipe lives in `UPGRADE.md` on the 3.x branch; this release ships
the tooling that prepares it, driven by the `app:utils:convert-env-to-3x`
command that the 2.8 API images provide.

The command converts the configuration of the *running* installation — the
values the application has actually loaded, plus the live admin and client
`config.json` — to 3.x environment configuration. Because it reads the running
application, the preparation must happen **before** the 1.x stack is stopped.

While the stack is up:

```bash
# 1. Be on 2.8 images: set COMPOSE_VERSION_API=2.8.0 (or a later 2.x)
#    in .env.docker.local, then pull and recreate.
task install

# 2. Verify the prerequisites (converter available, mariadb volume found):
task upgrade_check

# 3. Take a database backup and keep it somewhere safe:
task backup_db

# 4. Convert the configuration to 3.x format:
task env_migrate
```

`task env_migrate` writes `.env.symfony.migrated`, the starting point for the
3.x `.env.symfony`. It contains every application secret (APP_SECRET, database
and OIDC credentials, ...) — it is gitignored, treat it like a credentials
file. The converter's notes on stderr flag infrastructure variables
(`COMPOSE_*`, `PHP_*`, `NGINX_*`, `MARIADB_*`) that move to the per-service env
files of the 3.x layout instead.

With `.env.symfony.migrated` and the database dump in hand, continue with
[UPGRADE.md](https://github.com/os2display/os2display-docker-server/blob/release/3.0.0/UPGRADE.md)
on the 3.x branch.



