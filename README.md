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

### Pre-installation Notes
Before running `task install`, ensure the following:
1. Update `.env.docker.local` with your domain name (replace all 5 instances) and set secure passwords.
2. Place your SSL certificate files (`docker.crt` and `docker.key`) in the `traefik/ssl` directory.

For a full list of tasks, run:
```bash
task --list
```



