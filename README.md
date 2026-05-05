# OS2display v3 — Docker hosting

Deployment tooling for hosting the [os2display](https://github.com/os2display) v3 API on a single
host. Wraps the upstream
[`display-api-service`](https://github.com/os2display/display-api-service) image (which bundles
the admin UI and screen client in 3.x) with a docker-compose stack, optional bundled MariaDB and
Traefik, and a Taskfile for the operator workflow.

The whole repo is two binaries away: install [Docker](https://docs.docker.com/engine/install/)
with Compose v2 and [Task](https://taskfile.dev/) and you can run any task. No language tooling,
no build step, no shell-script glue beyond the Taskfile.

## Contents

- [Operator guide](#operator-guide)
  - [Prerequisites](#prerequisites)
  - [Quick start: fresh install](#quick-start-fresh-install)
  - [Configuration files](#configuration-files)
  - [Stack composition (compose profiles)](#stack-composition-compose-profiles)
  - [Network topology](#network-topology)
  - [Cookbook](#cookbook)
  - [Caveats and foot-guns](#caveats-and-foot-guns)
  - [Migrating from an older release](#migrating-from-an-older-release)
- [Developer guide](#developer-guide)
  - [Design principles](#design-principles)
  - [Local development](#local-development)
  - [Repository layout](#repository-layout)
  - [Linting](#linting)
  - [CI workflows](#ci-workflows)
- [Reference](#reference)
  - [All tasks](#all-tasks)
  - [Image registries](#image-registries)

---

## Operator guide

### Prerequisites

**Host.**

- Linux host (BSDs untested; the Taskfile uses `sed -i` GNU-style and `mariadb-dump` from the
  Linux mariadb image).
- Docker Engine 20.10+ with Compose v2 (the integrated `docker compose` command, not the
  legacy `docker-compose` Python wrapper).
- [Task](https://taskfile.dev/#/installation) v3+.
- A host user with **UID 1042 / GID 1042** — the os2display container writes media and reads JWT
  keys as `deploy` (UID 1042). Installing as a host user with the same UID prevents bind-mount
  permission surprises. The `nginx-api` container reads `./media` as UID 101 (`nginx-unprivileged`),
  so `./media` must be group-readable as well.

  ```bash
  sudo groupadd -g 1042 deploy
  sudo useradd -u 1042 -g 1042 -m -s /bin/bash deploy
  sudo usermod -aG docker deploy
  ```

**Network and DNS.**

- A fully qualified domain name (FQDN) resolving to the host. Two DNS records by default:
  - `os2display.example.com` (the main api + admin + client domain)
  - `traefik.example.com` (the Traefik dashboard, if exposed)
- Inbound `:80` (Let's Encrypt http-01 challenge + the redirect to https) and `:443` (https).

**Certificates.** Either:

- **Let's Encrypt** (default): Traefik issues per-host on first request via http-01 challenge.
  Operator just supplies an email address and a host that's reachable from the public internet.
- **Custom cert** (`SERVER_CERT_PROVIDER=cert-file`): operator drops `docker.crt` + `docker.key`
  in `traefik/ssl/`. Cert must cover **every** host the stack serves (api domain *and* dashboard
  domain) — see [Caveats](#caveats-and-foot-guns).

### Quick start: fresh install

```bash
git clone git@github.com:os2display/os2display-docker-server.git
cd os2display-docker-server

# 1. Compose orchestration: project name, domain, image versions, profile selection.
cp .env.example .env
$EDITOR .env

# 2. Symfony app config: pull the annotated example from the API image,
#    then edit. APP_SECRET, JWT_PASSPHRASE, DATABASE_URL are required.
task env:init
$EDITOR .env.symfony

# 3. Per-service runtime config. task install will auto-create any you skip.
cp .env.php.production.example     .env.php
cp .env.nginx.production.example   .env.nginx
cp .env.mariadb.production.example .env.mariadb     # only if running bundled mariadb
$EDITOR .env.php .env.mariadb                        # set production credentials, tune as needed

# 4. Traefik dashboard auth + Let's Encrypt email (interactive prompts).
task env:traefik

# 5. Bring the stack up: pulls images, runs migrations, prompts for
#    initial tenant + admin user, installs bundled templates.
task install
```

After `task install` returns, the API + bundled admin UI + screen client are reachable at
`https://<your-domain>/`, `/admin/`, `/client/`. The Traefik dashboard is at
`https://<traefik-host>/traefik/dashboard/` (basic-auth-gated).

### Configuration files

Each service reads its own env file. The checked-in `.production.example` files are the canonical
templates; edit your local copy, never the committed one.

| File | Service | Purpose | Bootstrap |
|---|---|---|---|
| `.env` | (compose) | Compose orchestration: project name, profile, image versions, server domain. Read by `docker compose` for substitution into the YAML before parsing. | `cp .env.example .env` |
| `.env.symfony` | os2display | Symfony app config — `APP_SECRET`, `DATABASE_URL`, `JWT_*`, `INTERNAL_OIDC_*`, `EXTERNAL_OIDC_*`, `ADMIN_*`, `CLIENT_*`, calendar feed, etc. | `task env:init` (extracts `/app/.env` from the API image — the upstream-canonical source) |
| `.env.php` | os2display | PHP-FPM runtime tuning — `PHP_MEMORY_LIMIT`, `PHP_OPCACHE_*`, `PHP_PM_*`. | `cp .env.php.production.example .env.php` |
| `.env.nginx` | nginx-api | Nginx runtime tuning — `NGINX_MAX_BODY_SIZE`, etc. | `cp .env.nginx.production.example .env.nginx` |
| `.env.mariadb` | mariadb | MariaDB credentials. Must match the `DATABASE_URL` user + password + database in `.env.symfony`. | `cp .env.mariadb.production.example .env.mariadb` |
| `.env.traefik` | traefik | Dashboard auth, Let's Encrypt email, cert provider. | `task env:traefik` (interactive) or copy from `.env.traefik.production.example` |

Why this split: each service's compose block has its own `env_file:` referring to one or two of
these files. Vars don't leak across services, the compose file has no translation blocks, and
the operator surface is one file per concern. See [Design principles](#design-principles).

`task env:diff` compares your `.env.symfony` against the example shipped in the currently-pinned
API image — useful when bumping `OS2DISPLAY_VERSION_API` to spot new keys upstream added.

### Stack composition (compose profiles)

`COMPOSE_PROFILES` in `.env` controls which built-in infrastructure services start. Core services
(`os2display`, `nginx-api`, `redis`) always run. The admin UI and screen client are bundled into
the `os2display` image in 3.x and served as Symfony routes — there are no separate `admin` /
`client` containers.

| `COMPOSE_PROFILES` | Built-in services started | Use when |
|---|---|---|
| `mariadb,traefik` | MariaDB + Traefik (default) | Single-host install with no external infra. |
| `traefik` | Traefik only | External database (set `DATABASE_URL` in `.env.symfony` to point at it). |
| `mariadb` | MariaDB only | External proxy in front. |
| (empty) | Neither | Both DB and proxy provided externally. |

`COMPOSE_PROFILES` is read natively by docker compose; no `-f` flags or wrapper scripts.

There is also a `dev` profile for the local linters (`markdownlint`, `prettier`). It's only
activated explicitly via `docker compose --profile dev run …`, never by `task install`.

### Network topology

Three docker networks:

- **`frontend`** (compose-managed by default) — the public-facing network. Traefik attaches here
  on the operator side; nginx-api attaches here so Traefik can route to it. Engine name is
  configurable via `OS2DISPLAY_FRONTEND_NETWORK` in `.env` (default: `frontend`). To share this
  network with other compose projects, see
  [Cookbook: share Traefik with another compose project](#how-do-i-share-traefik-with-another-compose-project).
- **`app`** (internal, compose-managed) — isolates os2display ↔ nginx-api ↔ redis ↔ mariadb.
- **`proxy`** (internal, compose-managed, traefik profile only) — locks down Traefik ↔
  socket-proxy. Read-only docker socket exposure on a network with `internal: true`, no
  bridge to the host.

### Cookbook

#### How do I install fresh?

See [Quick start](#quick-start-fresh-install).

#### How do I upgrade the os2display api + nginx images?

```bash
task db:backup                     # ALWAYS before task update — see Caveats
$EDITOR .env                       # bump OS2DISPLAY_VERSION_API
task update                        # pull, recreate, run app:update (migrations + cache:warmup)
task env:diff                      # check whether the new image added Symfony env keys
                                   # — if yes, edit .env.symfony to match
```

`task update` pulls fresh images, recreates the containers (preserving named volumes), and runs
`bin/console app:update`. Image swaps and container recreation themselves don't touch data.
What does is `app:update` — it applies Doctrine schema migrations from the new image. Some of
those migrations include `DROP COLUMN`, type changes, or data transforms that **aren't
reversible** by running an older image's `app:update` against the upgraded schema. Rolling
back from a botched upgrade is "restore from `task db:backup` first, then revert
`OS2DISPLAY_VERSION_API` and `task up`", not a clean tag swap. See
[Caveats](#caveats-and-foot-guns).

#### How do I upgrade the bundled MariaDB across a major version?

See [UPGRADE.md](UPGRADE.md). The 1.x → 3.x section has the recipe (it covers the 10.x → 11.4
jump that came with the 3.0 release); the same `task db:backup` → `task db:upgrade` →
update `DATABASE_URL` `serverVersion=` flow applies to any future major bump.

#### How do I switch from Let's Encrypt to a custom certificate?

```bash
$EDITOR .env.traefik
# SERVER_CERT_PROVIDER=cert-file
# SERVER_CUSTOM_CERT_FILE=docker.crt
# SERVER_CUSTOM_KEY_FILE=docker.key

cp /path/to/your.crt traefik/ssl/docker.crt
cp /path/to/your.key traefik/ssl/docker.key

task up                            # picks up the new SERVER_CERT_PROVIDER
```

`SERVER_CERT_PROVIDER` selects two files via the volume mounts:
`traefik/traefik-${SERVER_CERT_PROVIDER}.yml` and
`traefik/dynamic-conf-${SERVER_CERT_PROVIDER}.yaml`. The cert-file variants have no Let's
Encrypt resolver — Traefik picks certs from the file provider via SNI matching against the
hostnames in your cert.

**The cert must cover every host the stack serves** — both `OS2DISPLAY_SERVER_DOMAIN` and the
Traefik dashboard `SERVER_DOMAIN`. A wildcard cert (`*.example.com`) is the simplest path. See
[Caveats](#caveats-and-foot-guns).

#### How do I run with an external database?

```bash
$EDITOR .env
# COMPOSE_PROFILES=traefik          # drop "mariadb" — bundled mariadb won't start

$EDITOR .env.symfony
# DATABASE_URL="mysql://user:pass@your-db-host:3306/dbname?serverVersion=mariadb-11.4.10-MariaDB"

task up
```

`.env.mariadb` and `task db:backup` / `task db:upgrade` are no-ops in this configuration — they
operate on the bundled mariadb container, not your external DB. Run your own backup tooling
against the external DB.

#### How do I run with an external Traefik?

```bash
$EDITOR .env
# COMPOSE_PROFILES=mariadb           # drop "traefik"
```

The bundled Traefik and socket-proxy don't start. Your external Traefik must be on a docker
network the nginx-api container can join. By default that's a network named `frontend` —
override the engine name via `OS2DISPLAY_FRONTEND_NETWORK` and use the shared-frontend opt-in
(next recipe).

#### How do I share Traefik with another compose project?

When running multiple compose projects on one host behind a single Traefik, switch the
`frontend` network from compose-managed to external:

```bash
docker network create os2display_shared_frontend     # once on the host

$EDITOR .env
# OS2DISPLAY_FRONTEND_NETWORK=os2display_shared_frontend
# COMPOSE_FILE=docker-compose.yml:compose.shared-frontend.yml
```

Now `task install` (and `docker compose up`) attaches services to the existing engine network
instead of creating one. `task purge` will not remove the shared network.

`compose.shared-frontend.yml` is a one-line override that flips the network to `external: true`.
Compose's auto-loaded `compose.override.yml` is also available for one-off per-host customisation.

#### How do I tune PHP for big imports or long requests?

```bash
$EDITOR .env.php
# PHP_MAX_EXECUTION_TIME=120
# PHP_MEMORY_LIMIT=512M
# PHP_PM_MAX_CHILDREN=32             # if you have lots of concurrent traffic
# PHP_OPCACHE_VALIDATE_TIMESTAMPS=0  # KEEP at 0 in production

task up                              # recreate the os2display container
```

Match `PHP_POST_MAX_SIZE` and `PHP_UPLOAD_MAX_FILESIZE` with `NGINX_MAX_BODY_SIZE` in
`.env.nginx` — see next recipe.

#### How do I tune nginx for large uploads?

```bash
$EDITOR .env.nginx
# NGINX_MAX_BODY_SIZE=500m

$EDITOR .env.php
# PHP_POST_MAX_SIZE=500M             # nginx must be >= php
# PHP_UPLOAD_MAX_FILESIZE=500M

task up
```

Nginx rejects oversized requests at the proxy edge before they reach php-fpm; PHP rejects them
at the parser. Both must be raised together for the larger uploads to actually go through.

#### How do I take a database backup?

```bash
task db:backup
ls backup/
# 20260505T140723Z.sql.gz
```

Online dump (`mariadb-dump --single-transaction --quick --routines --triggers --events`),
gzipped. No service downtime; the `--single-transaction` flag gives a consistent InnoDB
snapshot. The `backup/` directory has its own `.gitignore` keeping all dumps out of git.

#### How do I restore from a backup?

```bash
gunzip < backup/20260505T140723Z.sql.gz \
  | docker compose exec -T mariadb mariadb -u root -p"$(grep ^MARIADB_ROOT_PASSWORD= .env.mariadb | cut -d= -f2-)"
```

Restoring **into** an existing populated database overwrites by default. To restore into a fresh
DB, `task purge` first (destructive — wipes all data and volumes) and re-run `task install`,
then pipe in the dump.

#### How do I add a tenant?

```bash
task tenant:add                      # interactive: prompts for tenant id, title, description
```

Tenants are groups of users sharing configuration (IT, Library, Schools, …). `task install`
prompts for the first tenant during install.

#### How do I add a user?

```bash
task user:add                        # interactive: email, password, role, tenant
```

Roles are `editor` or `admin`. Editors create slides + screens within their tenant; admins
manage tenant-level config too.

#### How do I install or update bundled templates?

```bash
task templates:install
```

Runs `bin/console app:templates:install --all --update` and
`bin/console app:screen-layouts:install --all --update --cleanupRegions` against the bundled
template set in the API image. v3 ships templates inside the image — there's no longer a list
of names or a version pin in `.env`.

Re-run after `task update` when the new image version added templates.

#### How do I authenticate to Docker Hub (rate limits)?

Anonymous Docker Hub pulls are capped at **100 / 6h / IP**. Multi-host operators behind a NAT
hit it during a sequence of `task install` runs.

```bash
docker login docker.io
# Username: <your Docker Hub username>
# Password: <a Docker Hub Personal Access Token>
```

Authenticated free accounts get **200 / 6h / user**. For higher scale, set up a
[pull-through registry mirror](https://docs.docker.com/registry/recipes/mirror/) and point
your daemon at it.

For unattended hosts, configure a credential helper instead of leaving the token in
`~/.docker/config.json` plaintext — `docker-credential-pass` (backed by `pass`) is the usual
pick.

#### How do I authenticate to GHCR?

All `ghcr.io/os2display/*` images this stack uses are public today, so `docker pull` works
without `docker login`. No action needed for a fresh install.

If a future image becomes private or you mirror Docker Hub images into your own private GHCR
namespace, authenticate with a GitHub PAT scoped `read:packages`:

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
# or, if `gh` is set up:
gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin
```

#### How do I read service logs?

```bash
task logs                            # follow all services, last 50 lines
docker compose logs -f os2display    # one service
docker compose logs --since 1h       # bounded by time
```

All services log to docker's `json-file` driver with rotation: max 10 MB per file, 3 files per
service. A runaway container can't fill the host disk.

#### How do I clear the application cache?

```bash
task cache:clear                     # bin/console cache:clear inside os2display
```

Run after editing `.env.symfony` (Doctrine and Symfony cache resolved-config), after upgrading
the image (`task update` already does it), or when troubleshooting stale routes.

### Caveats and foot-guns

A grab-bag of operator gotchas the stack documents but doesn't (and in some cases can't)
prevent.

**Cert-file: cert must cover every served host.** When `SERVER_CERT_PROVIDER=cert-file`,
Traefik selects certs by SNI from the file provider. Your cert must include both
`OS2DISPLAY_SERVER_DOMAIN` (api + admin + client) **and** `SERVER_DOMAIN` (Traefik dashboard) as
SAN entries — or use a wildcard. Without one, the dashboard host gets the file provider's
default cert (the first one declared), which won't match → browser TLS errors. Let's Encrypt
mode handles this automatically (per-host issuance).

**`task update` is not reversible by reverting the image tag.** `app:update` applies the new
image's Doctrine schema migrations. Some migrations include `DROP COLUMN`, type changes, or
data transforms that the previous image's `app:update` doesn't undo (and that Doctrine's
`down()` method, if defined, may not lossly reverse). The on-disk data files are preserved
across the image swap and container recreation, but the *schema* gets rewritten. Rolling back
is `task db:backup`-restore + revert image tag — not a clean tag revert. **Always take a
fresh `task db:backup` before `task update`**, not just relying on yesterday's snapshot.

**Doctrine `serverVersion` mismatch produces wrong SQL.** `DATABASE_URL` in `.env.symfony` has
a `serverVersion=` parameter that Doctrine reads to pick its SQL dialect. After a MariaDB
major bump, this *must* be updated; otherwise queries silently use the wrong dialect (most
visible on JSON columns and date/time functions). The mismatch doesn't error at startup —
queries fail at runtime in production traffic.

**`.env.mariadb` and `.env.symfony` credentials must match.** The bundled mariadb container
initialises with credentials from `.env.mariadb`; Doctrine connects with credentials from
`.env.symfony`'s `DATABASE_URL`. Edit one without the other and the api can't connect. After
the data dir is initialised, mariadb refuses to re-initialise with different credentials —
changing them later requires a manual `ALTER USER` SQL run inside the container.

**`./media` permissions.** The os2display container writes media as UID 1042 (deploy); the
nginx container reads them as UID 101 (nginx-unprivileged). `./media` must be readable by
both. The simplest fix is owning `./media` as group 1042 with mode 750 + `chmod g+rx ./media`.
Symptoms of getting it wrong: thumbnails 404, uploaded images don't render. Always check
`./media` perms first when troubleshooting media issues.

**`PHP_OPCACHE_VALIDATE_TIMESTAMPS=0` in production.** `=1` makes opcache check file mtime on
every request — fine in development for live reloads, terrible in production for performance.
The `.env.php.production.example` defaults to `=0`. If you copied it to `.env.php` and edited
to `=1`, expect significant CPU + I/O overhead.

**Let's Encrypt rate limits.** Production LE allows 50 certificate issuances per registered
domain per week. Hitting it locks you out for 7 days. When iterating on Traefik config, point
at the LE staging server first via
`TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_CASERVER=https://acme-staging-v02.api.letsencrypt.org/directory`
in `.env.traefik`. Switch to production only when the cert flow works end-to-end.

**`task purge` and `task reinstall` delete data.** `purge` runs `docker compose down --volumes`
— the mariadb data volume goes too. `reinstall` is `purge` + `install`. Both destroy the
database. `down` and `stop` preserve volumes.

**`task env:init` with `FORCE=1` overwrites `.env.symfony`.** Without `FORCE=1`, env:init
refuses to run if `.env.symfony` already exists. With `FORCE=1`, it silently overwrites — your
operator-edited secrets included. Always backup first.

**Compose profiles only gate services.** Networks, volumes, and top-level config don't accept
`profiles:`. Switching `COMPOSE_PROFILES=traefik` doesn't tear down the bundled mariadb's data
volume — a previous `mariadb` run leaves data on disk that's idle until the profile's
re-enabled. `task purge` is the only path to actually delete it.

**`NGINX_MAX_BODY_SIZE` ≥ `PHP_UPLOAD_MAX_FILESIZE`.** Nginx rejects oversized requests at the
proxy edge; PHP at the parser. If nginx is lower, large uploads get truncated before PHP sees
them — the operator sees a 413 from nginx, not a clean PHP error.

**`mysql_native_password` deprecation.** MariaDB 11.4 still ships it (and the official image
defaults to it), but the auth plugin is flagged for removal. Operators on default auth will
hit a hard break on 11.5+. Plan to migrate to `caching_sha2_password` before that bump.

**Anonymous Docker Hub rate limit.** 100 pulls / 6h / IP. NAT'd hosts share the cap with every
other anonymous puller behind the same egress. `docker login docker.io` lifts to 200/6h/user;
a registry mirror lifts further. See
[Cookbook: authenticate to Docker Hub](#how-do-i-authenticate-to-docker-hub-rate-limits).

**External `frontend` network requires manual creation.** When using
`compose.shared-frontend.yml`, the network is `external: true`. Compose won't create it. Run
`docker network create <name>` once on the host before `task install`.

**`compose.override.yml` is auto-loaded by compose.** If you have a leftover `compose.override.yml`
from a 2.x deployment or experiment, it will silently apply on top of `docker-compose.yml`.
Inspect with `docker compose config | grep -A 5 <suspicious-service>` to see the merged result.

**Don't edit the committed `.production.example` files for your operator config.** The
production examples are checked-in templates; your operator edits go into `.env.<service>`
(gitignored). Editing the templates means future `task install` invocations bootstrap your
custom values into other operator's checkouts and `git status` is permanently dirty.

### Migrating from an older release

See [UPGRADE.md](UPGRADE.md) for the step-by-step 1.x → 3.x migration recipe (this repo skips
2.x to align its major version with upstream `display-api-service`).

---

## Developer guide

### Design principles

The repo is a thin wrapper around upstream tooling. The constraints we work under:

1. **Only Task and docker compose required locally.** No make, no Python tooling, no
   shell-script glue beyond the Taskfile. The Taskfile itself is a thin wrapper that exists for
   ergonomics (lifecycle commands, env-file bootstrap), not because it carries logic the stack
   couldn't otherwise express. Adding a new dependency to the local dev workflow needs a strong
   justification.

2. **Build on stack standards. Don't reinvent.** Where compose, Task, or the upstream images
   already provide a feature, use it directly. Concretely:
   - **Compose profiles** (`COMPOSE_PROFILES`) for optional services. Not custom `-f` flag
     juggling, not Taskfile-side compose-file synthesis.
   - **Compose's `env_file:`** for service env. Not `environment:` translation blocks that
     substitute from `.env` — those silently shadow `env_file:` values.
   - **Compose's `name:`** on networks for engine-name configurability. Not `${VAR}`
     substitution into `services.X.networks:` (which is the wrong layer).
   - **Compose's `COMPOSE_FILE`** for opt-in overrides. Not custom Taskfile branches that
     decide which files to load.
   - **The image's annotated `/app/.env`** as the canonical Symfony env source. Not a
     parallel checked-in copy that drifts against upstream.
   - **Native YAML anchors** (`x-logging`) for repeated config blocks.

3. **Per-service env files.** One file per service, named `.env.<service>`, with a checked-in
   `.env.<service>.production.example` template. No mega-file mixing Symfony app config with
   PHP runtime tuning with MariaDB credentials. Compose `environment:` translation blocks
   (`- APP_X=${APP_X}`) are forbidden — they shadow `env_file:` and create a split surface.

4. **Production examples are canonical.** The `.production.example` files in this repo are the
   source of truth for runtime/deployment config. Symfony app config is the asymmetric
   exception — the upstream API image's `/app/.env` is canonical there, and
   `task env:init` extracts it. We don't duplicate upstream content.

5. **Compose-managed by default; cross-stack sharing is opt-in.** Networks, volumes, and
   services are compose-controlled out of the box. Sharing infrastructure across compose
   projects (one Traefik fronting several stacks) is explicit operator opt-in via
   `compose.shared-frontend.yml` (or a similarly-scoped override file), never the default.

6. **No bash glue when compose can do it.** If the question is "how do operators activate X",
   the answer should be a compose feature (profile, env-file, override file), not a Taskfile
   shell block. Network creation, image selection, profile gating, and config file selection
   all belong to compose, not Task.

7. **Use the upstream image's environment contract.** Image-side env vars (`PHP_*`, `NGINX_*`,
   `MARIADB_*`) keep their upstream names. Operator-facing repo-specific vars use the
   `OS2DISPLAY_*` prefix to avoid shadowing names docker compose itself reads (only
   `COMPOSE_PROJECT_NAME` and `COMPOSE_PROFILES` retain the `COMPOSE_` prefix because they're
   compose-native).

### Local development

Working on this repo is the same as running it as an operator, with two extras:

- **The `dev` compose profile** activates the `markdownlint` and `prettier` services for local
  linting. The `dev:lint*` Task family wraps them:

  ```bash
  task dev:lint        # Markdown + YAML check
  task dev:lint:fix    # auto-fix both
  ```

  Run these before opening a PR; CI runs the same checks on every push.

- **Test against a throwaway domain.** The stack only runs in HTTPS mode (Traefik forces it).
  For local-host testing, use the Let's Encrypt staging server (lower rate limit, untrusted
  CA — operating-system trust prompts are normal):

  ```bash
  $EDITOR .env.traefik
  # TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_CASERVER=https://acme-staging-v02.api.letsencrypt.org/directory
  ```

  Or use `SERVER_CERT_PROVIDER=cert-file` with a self-signed cert.

Standard fork-and-PR flow. PRs run three CI workflows (Markdown, YAML, Compose). The Compose
workflow is the most likely to surface issues — it asserts that every pinned image is
reachable on its registry and every `${VAR}` reference in `docker-compose.yml` resolves.

### Repository layout

```text
.
├── docker-compose.yml                       # canonical stack definition
├── compose.shared-frontend.yml              # opt-in: external frontend network
├── Taskfile.yml                             # operator workflow
│
├── .env.example                             # compose orchestration template
├── .env.php.production.example              # per-service runtime templates
├── .env.nginx.production.example
├── .env.mariadb.production.example
├── .env.traefik.production.example
│
├── traefik/
│   ├── traefik-letsencrypt.yml              # static config, LE variant
│   ├── traefik-cert-file.yml                # static config, cert-file variant
│   ├── dynamic-conf-letsencrypt.yaml        # dynamic config, LE variant
│   ├── dynamic-conf-cert-file.yaml          # dynamic config, cert-file variant
│   ├── ssl/                                 # operator-supplied custom certs (gitignored)
│   └── letsencrypt/                         # acme.json storage (gitignored)
│
├── jwt/                                     # JWT keypair storage (gitignored)
├── media/                                   # media bind mount (gitignored)
├── backup/                                  # task db:backup output (gitignored)
│
├── .github/workflows/                       # CI: markdown.yaml, yaml.yaml, compose.yaml
│
├── .markdownlint.jsonc                      # linter configs (synced from
├── .markdownlintignore                      # itk-dev/devops_itkdev-docker)
├── .prettierrc.yaml
└── .prettierignore
```

The `traefik-${SERVER_CERT_PROVIDER}.yml` and `dynamic-conf-${SERVER_CERT_PROVIDER}.yaml` files
are mounted via env-var substitution in `docker-compose.yml`'s volume directive. Adding a new
cert provider means adding a new pair of files, not touching compose or Task.

### Linting

Markdown + YAML in CI. The linter services are gated behind the `dev` compose profile so they
don't bloat production starts. Run via Task:

```bash
task dev:lint                  # check both Markdown and YAML
task dev:lint:md               # check Markdown only
task dev:lint:yaml             # check YAML only
task dev:lint:fix              # auto-fix both (review the diff before committing)
task dev:lint:md:fix           # auto-fix Markdown only (markdownlint --fix)
task dev:lint:yaml:fix         # auto-fix YAML only (prettier --write)
```

Or invoke the underlying compose commands directly (what CI uses):

```bash
docker compose --profile dev run --rm markdownlint markdownlint '**/*.md'
docker compose --profile dev run --rm prettier '**/*.{yml,yaml}' --check
```

Configs:

- `.markdownlint.jsonc` + `.markdownlintignore` — line-length 120, table/code-block exempt,
  allows `<details>`/`<summary>`.
- `.prettierrc.yaml` + `.prettierignore` — default Prettier + Symfony `config/` override
  (4-space tabs, single quotes).

Both pairs are copied from
[itk-dev/devops_itkdev-docker](https://github.com/itk-dev/devops_itkdev-docker) — the
file-copy header at the top of each lints config preserves provenance for sync.

### CI workflows

`.github/workflows/`, three files:

- **`markdown.yaml`** — runs markdownlint via `docker compose --profile dev run --rm
  markdownlint`. Catches doc rot.
- **`yaml.yaml`** — runs prettier via the same pattern. Catches YAML drift.
- **`compose.yaml`** — three jobs:
  1. `compose-config` — synthesises the stack with example env files + a stub `.env.symfony`.
     Catches typos and dangling `${VAR}` references.
  2. `image-availability` — `docker buildx imagetools inspect` against every pinned image.
     Catches a tag that didn't ship.
  3. `env-coverage` — every bare `${VAR}` reference in `docker-compose.yml` is declared in
     `.env.example` or `.env.traefik.production.example`. Catches the silent-empty
     substitution case.

All three trigger on `pull_request` and pushes to `main` / `develop` / `release/**`.

---

## Reference

### All tasks

```text
Lifecycle
  install              Install the project — first-time setup (interactive)
  update               Pull images, recreate containers, run app:update
  up                   Start the stack without recreating containers
  down                 Remove all containers (preserves named volumes)
  stop                 Stop all containers
  purge                Remove all containers AND named volumes  (prompts)
  reinstall            purge + install                          (prompts)

Bootstrap and env-file tooling
  env:init             Bootstrap .env.symfony from the API image
  env:diff             Compare .env.symfony against the image's shipped example
  env:migrate          Convert a 1.x .env.docker.local to .env.symfony.migrated
  env:traefik          Interactive .env.traefik setup            (alias: traefik_env)

Operations
  logs                 Follow docker logs (last 50 lines)
  console              Run any bin/console command in os2display  (e.g. `task console -- list`)
  cache:clear          Clear the application cache               (alias: cc)
  tenant:add           Add a tenant group (interactive)          (alias: tenant_add)
  user:add             Add a user — editor or admin (interactive)(alias: user_add)
  templates:install    Install bundled templates + screen layouts(alias: load_templates)
  db:backup            Dump the bundled MariaDB to ./backup/<UTC-ts>.sql.gz
  db:upgrade           Run mariadb-upgrade after a MariaDB major bump

Dev tooling
  dev:lint             Check Markdown + YAML
  dev:lint:fix         Auto-fix Markdown + YAML
  dev:lint:md          Check Markdown only
  dev:lint:md:fix      Auto-fix Markdown only
  dev:lint:yaml        Check YAML only (Prettier --check)
  dev:lint:yaml:fix    Auto-fix YAML (Prettier --write)
```

`task --list` shows the canonical list with aliases. Internal helper tasks
(`bootstrap-env-files`, `show-notes`) are hidden via `internal: true` and only
called from other tasks.

The aliased forms (`tenant_add`, `user_add`, `load_templates`, `cc`, `traefik_env`)
remain as **deprecated aliases** for compatibility with operator scripts written
against earlier releases. Prefer the canonical `:`-namespaced forms going forward.

`task console -- <args>` is the generic Symfony CLI proxy. Use it for any one-off
`bin/console` command that doesn't have its own dedicated task — e.g.:

```bash
task console -- list                                 # list all bin/console commands
task console -- debug:router                         # inspect Symfony routes
task console -- doctrine:migrations:status           # ad-hoc Doctrine ops
```

Tasks like `cache:clear`, `tenant:add`, `user:add`, and `templates:install` that
proxy a single Symfony command are implemented as thin wrappers around
`task console`, so the CLI surface stays consistent.

### Image registries

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

The upstream `redis`, `mariadb`, and `traefik` projects publish only to Docker Hub — there is
no canonical GHCR mirror. See
[Cookbook: authenticate to Docker Hub](#how-do-i-authenticate-to-docker-hub-rate-limits) for
the rate-limit story.
