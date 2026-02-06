# Changelog

## v1.1.2

- Bump os2display version from 2.5.1 to 2.6.0. Client updated from 2.2.1 to 2.3.0.
- Update TASK_TEMPLATES in .env.docker.example to include 'brnd'
- Bring CHANGELOG.md up-to-date with mensions of version v1.1.0 and v1.1.1
- Update CHANGELOG.md

## v1.1.1

- Assume install by user where UID and GID is1042. The README contains further details.
- Install the vimeo-template as default
- Add the screen layout two-boxes-vertical-reversed as default
- Extend wait for db, so that install will work on slow hardware/VM
- A new env var APP_KEY_VAULT_JSON has been added

## v1.1.0 

- BUGFIX: Fix value of COMPOSE_SCREEN_CLIENT_PATH. Default was set to "/screen". Should be "/client".
- Bump os2display version from 2.4.0 to 2.5.1
- Improved task menu
- Env var changes now take effect if you do "task down" and then "task up".

## v1.0.0 - Initial Release

- Introduced a Docker-based deployment tool for hosting the OS2display application.
- Provided pre-configured files and task automation for simplifying deployment and management.
- Added support for secure mode (HTTPS on port 443) with domain name and SSL certificate requirements.
- Included a `Taskfile.yml` with tasks for installation, tenant/user management, template loading, and maintenance.
- Documented prerequisites and setup instructions for Docker, Docker Compose, and Taskfile CLI.