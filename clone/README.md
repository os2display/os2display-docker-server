# Stack clone (standalone)

Self-contained tooling to make a **faithful 1:1 copy of a 1.x (v1 itk-dev) OS2display install** into this
checkout — its database, uploads, JWT keypair and operator env — retargeted to a new domain and a separate
database. Typically used to stand up a staging copy of production for rehearsing the v3 upgrade against real data.

**It does not convert anything to v3.** Clone and convert are deliberately separate: the clone is an exact,
re-runnable snapshot, and the v3 migration tooling that ships in this checkout (`task env:migrate`, then
`task up` + `app:update`) converts it afterwards. See [UPGRADE.md](../UPGRADE.md) for the full 1.x → 3.x recipe.

The direction matters: **this checkout is the destination.** You check the repo out into a new directory, point
`SOURCE` at the running v1 install, and the tooling pulls the source's operator state in here. The source is only
read (plus one database dump); it is never modified.

This lives outside the main task surface on purpose: it's a standalone add-on, not wired into the root
`Taskfile.yml`, `README.md`, or `docker-compose.yml`.

## What it does

`clone/clone.sh` runs end to end:

1. **Dumps** the source database (`APP_DATABASE_URL` in the v1 source's `.env.docker.local`).
2. **Copies** the source's operator state here 1:1 — the v1 env files (`.env`, `.env.local`,
   `.env.docker.local`), `./media` uploads and the `./jwt` keypair. Repo files (compose, Taskfile, scripts) stay
   out — this checkout provides them.
3. **Retargets** the copied v1 env: `COMPOSE_PROJECT_NAME`, `COMPOSE_SERVER_DOMAIN`, `APP_DATABASE_URL` → the
   clone database, and every other occurrence of the old domain → the new one (`APP_API_ENDPOINT`, CORS, OIDC
   redirect URIs, …). `APP_SECRET`, `APP_JWT_PASSPHRASE` and the keypair are kept verbatim — it's a faithful copy.
4. **Restores** the dump into the clone database.

It does **not** bring a stack up. You then **boot the clone in v1 mode** to verify it (`clone/compose.v1.yml`
runs the same legacy images against the cloned DB under the new URL — see [Run the clone in v1 mode](#run-the-clone-in-v1-mode)),
and once verified, convert it in place to v3 (the script prints the steps) and bring it up with the normal v3 tasks.

## Prerequisites

- A **checkout** of this repo as the destination (its own directory).
- The **v1 source** install, reachable on disk, with `.env.docker.local` (`APP_DATABASE_URL`).
- A **separate database** for the clone. `CLONE_DATABASE_URL` must differ from the source; the script aborts if
  they match. `create-db` (below) can provision it on the source's own DB server.
- A **`mariadb` client** + `gzip` + `rsync` on the host. The DB tooling runs the host's `mariadb` /
  `mariadb-dump` directly (no container) and connects from the host itself.

## Usage

The clone reads its config from `clone/.env.clone`, so set the variables once and re-run as often as you like.
Run everything from this checkout's root:

```bash
task -t clone/Taskfile.yml init        # creates clone/.env.clone from the example
$EDITOR clone/.env.clone               # set SOURCE / DOMAIN
task -t clone/Taskfile.yml create-db   # provision the clone DB (prompts for root pw)
task -t clone/Taskfile.yml clone       # 1:1 clone; prompts for the DB admin password
task -t clone/Taskfile.yml v1:up       # boot in v1 mode and verify (see below)
```

`cd clone && task <name>` works too (Task auto-discovers the Taskfile). Available tasks: `init`, `create-db`,
`clone`, `reclone`, `dump`, `restore`, `v1:up`, `v1:env-migrate`, `v1:pull`, `v1:down`, `v1:logs`, `v1:ps`.

To start a clone over from scratch (e.g. after a v3 conversion), use [`reclone`](#re-running-a-clone) instead of
`clone` — it tears the stale state down first.

After verifying the clone in v1 mode (next section), convert the **same** clone in place to v3. This is the
clone-shaped run of [UPGRADE.md](../UPGRADE.md) (itself the “Option A” supplement to the authoritative
[display-api-service guide](https://github.com/os2display/display-api-service/blob/main/UPGRADE.md)) — read that
for the *why*; the clone deltas are spelled out below.

```bash
# 1. Export the config in 3.x shape WHILE the v1 clone is still up, on 2.8.0+ images.
#    (Set COMPOSE_VERSION_API=2.8.0 in .env.docker.local and re-run v1:up if it isn't — the
#     converter ships in the 2.8 API.) This is the clone's stand-in for the guide's `task env_migrate`.
task -t clone/Taskfile.yml v1:env-migrate          # -> .env.symfony.migrated (env + admin/client config.json)
task -t clone/Taskfile.yml v1:down                 # stop the v1 stack

# 2. Rewrite env (UPGRADE.md Step 4).
task env:migrate                                   # splits the infra advisory out of .env.symfony.migrated
$EDITOR .env.symfony.migrated                      # sanity check, then:
mv .env.symfony.migrated .env.symfony
task env:init                                      # create the per-service files (leaves .env.symfony alone)
$EDITOR .env                                       # OS2DISPLAY_VERSION_API, COMPOSE_PROFILES, keep COMPOSE_PROJECT_NAME
$EDITOR .env.symfony                               # distribute .env.symfony.infra-advisory; DATABASE_URL serverVersion = your external DB

# 3. Migrate the schema in a one-off container (DB/redis only, no web tier), BEFORE `up`.
task console:run -- doctrine:migrations:rollup --no-interaction   # consolidate the cloned 2.x history
task console:run -- app:update                     # migrate the DB schema to v3 + install templates/layouts
task up                                            # bring the v3 stack up — schema already current
task jwt:ensure                                    # validate the carried-over JWT keypair
```

**Env conversion requires the converter export — there is no sed fallback.** `task env:migrate` now only splits
the infrastructure advisory out of a `.env.symfony.migrated` produced by the 2.8 API's
`app:utils:convert-env-to-3x`; it errors if that file is absent. `v1:env-migrate` runs that converter in the
clone's v1 `api` container (so the v1 stack must be on 2.8.0+ images) — it carries over **both** the env vars and
the admin/client `config.json` settings (Rejseplanen key, touch regions, pull/scheduling intervals, release-check
timeout, …). Then distribute the keys env:migrate split into `.env.symfony.infra-advisory` (`COMPOSE_*` → `.env`,
`PHP_*` → `.env.php`, `NGINX_*` → `.env.nginx`, `MARIADB_*` → `.env.mariadb`). The clone uses the external
`create-db` schema, so UPGRADE.md's bundled-MariaDB 10→11 auto-upgrade (Step 5) does not apply — leave
`DATABASE_URL` `serverVersion` matching the external DB.

Migrate via `console:run` (a throwaway `compose run` container that starts only the DB/redis
dependencies) **before** `task up`, so the v3 stack never serves against an un-migrated schema. The cloned
DB carries the full 2.x migration history that 3.0 consolidated into a single migration, so roll the version
table up before `app:update` (running `migrate` directly fails on the orphaned version rows). A fresh DB with no
2.x history would use `migrate` via `app:update` instead — check the `status` output.

**`mv .env.symfony.migrated .env.symfony` before `task env:init` is required.** `env:init` only fills in
**missing** files; with `.env.symfony` already in place it leaves it (and the migrated `JWT_PASSPHRASE`) alone.
Skip the `mv` and `env:init` instead generates a fresh `.env.symfony` with a **new random** `JWT_PASSPHRASE`,
which no longer matches the carried-over keypair. The v1 keypair itself carries over untouched (`env:init` no
longer wipes `./jwt`), so screens authorized in v1 keep working; `task jwt:ensure` validates it after boot and
**only** regenerates if the v3 image can't read the v1 key — in which case screens must re-authorize. See
[UPGRADE.md](../UPGRADE.md) for the full 1.x → 3.x recipe.

### Re-running a clone

`clone` refreshes a clone in place, but a checkout that's already been **converted to v3** carries generated env
files (`.env.symfony`, `.env.php`, …) and possibly a running stack, which make `clone` abort ("this directory
already carries env for COMPOSE_PROJECT_NAME=…") or boot the wrong stack. `reclone` starts over cleanly:

```bash
task -t clone/Taskfile.yml reclone
```

It brings down any running clone containers (v1 + v3), deletes the env files that clone/convert generate — the v1
`.env` / `.env.local` / `.env.docker.local` that `clone` re-copies and the stale v3 per-service files and
`*.local` overrides — then re-runs `clone` (re-dump, re-copy media/jwt/env, re-restore the clone DB). It leaves
`clone/.env.clone` untouched, so `SOURCE` / `DOMAIN` / `CLONE_DATABASE_URL` carry over. The clone DB is overwritten
in place, not recreated, so you don't need `create-db` again.

## Run the clone in v1 mode

The cloned config is a v1 install, so it must boot on the **v1 images** — not this checkout's v3 stack.
`clone/compose.v1.yml` is a faithful resurrection of the 1.x `docker-compose.server.yml` (the `api`, `nginx-api`,
`admin`, `client` and `redis` services on the `itkdev/os2display-*` images), with two deltas so it can run
**beside** the production v1 on the same host:

- Traefik router/middleware names are project-namespaced with `${COMPOSE_PROJECT_NAME}-` (the 1.x names were
  static and would collide on the shared production Traefik).
- `api` maps `host.docker.internal` → `host-gateway`, so a clone DB reached at `host.docker.internal` (the
  `create-db` schema on the source's DB server) is reachable from inside the container.

It ships **no** `mariadb` (the clone reuses the `create-db` schema) and **no** `traefik` (the production Traefik
routes the clone via the external `frontend` network). Image tags interpolate from the cloned `.env.docker.local`,
so the clone runs the **same** images as the source.

```bash
task -t clone/Taskfile.yml v1:up       # pull + start; prints the verify URL
task -t clone/Taskfile.yml v1:ps       # api/nginx-api/admin/client/redis should be up
task -t clone/Taskfile.yml v1:logs     # SERVICE=api to scope
```

Then open `https://<DOMAIN>/admin`, log in with the source's users (it's a faithful copy), create a screen,
authorize it and confirm it plays. Production v1 on its own domain is unaffected. When done verifying, stop it
with `task -t clone/Taskfile.yml v1:down` and convert to v3 (above).

Requirements: the `itkdev/os2display-*` tags named in the cloned `.env.docker.local` must still be pullable from
Docker Hub; the external `frontend` network (the one the production Traefik watches) must exist — override its
name with `FRONTEND_NETWORK=…` if it isn't `frontend`; and a DNS record for the new domain must point at this host.

### Provisioning the clone database (same server as the source)

`create-db` provisions the clone DB on the source's **own database server** instead of you hand-crafting
`CLONE_DATABASE_URL`. It runs the host's `mariadb` client and connects from the host; a `host.docker.internal`
URL (a DB on the docker host) is reached from the host itself at `127.0.0.1`:

```bash
task -t clone/Taskfile.yml create-db   # prompts for the DB admin (root) password
```

It reads the source database URL (`APP_DATABASE_URL` from `.env.docker.local` / `.env.local`, or `DATABASE_URL`
from `.env.symfony`), parses the server and app user, connects as the admin user (default `root` — **you are
prompted for the password**), then on that same server:

- creates the clone database (default name `<source-db>_clone`, override with `CLONE_DB_NAME=…`), mirroring the
  source DB's charset/collation;
- ensures the source's app user exists as `<user>@'%'` and grants it access to the clone DB.

The clone reuses the source's application credentials — only the schema name differs — so production data is never
touched. The resulting `CLONE_DATABASE_URL` is written into `clone/.env.clone`, ready for the `clone` task.
Override the admin user with `DB_ADMIN_USER=…`, or skip the prompt in CI with `DB_ADMIN_PASSWORD=…`.

### Configuration (`clone/.env.clone`)

| Variable             | Required | Default                          | Purpose                                          |
| -------------------- | -------- | -------------------------------- | ------------------------------------------------ |
| `SOURCE`             | yes      | —                                | Root of the v1 install to clone FROM.            |
| `DOMAIN`             | yes      | —                                | Public domain the converted clone will serve.    |
| `CLONE_DATABASE_URL` | yes      | —                                | The clone's database — must differ from source.  |
| `CLONE_PROJECT`      | no       | sanitised name of this directory | Compose project name written into the clone env. |

`clone/.env.clone` is gitignored. For a one-off variation, set the variable in the environment — it overrides the
file for that run:

```bash
DOMAIN=other.example.com task -t clone/Taskfile.yml clone
```

You can also bypass Task and call the scripts directly (they load `clone/.env.clone` the same way): `clone/clone.sh`.

## The dump / restore scripts

`clone.sh` uses these two; both are usable on their own (as `task -t clone/Taskfile.yml dump` / `restore`, or
directly). They find the database URL across layouts — `APP_DATABASE_URL` (v1) or `DATABASE_URL` (v3) — and run
the **host's** `mariadb` / `mariadb-dump` directly (no container). They operate on **this** stack root by
default; `STACK_ROOT=<dir>` points them at another stack (that's how `clone.sh` dumps the source).

```bash
clone/db-dump.sh                         # → ./backup/<UTC-ts>.sql.gz
clone/db-dump.sh backup/my-dump.sql.gz   # explicit output path

clone/db-restore.sh backup/<ts>.sql.gz   # load a dump back in (DESTRUCTIVE — overwrites matching tables)
```

`clone/lib-db-url.sh` is the shared helper (URL parsing, layout-aware URL/var lookup, client-binary + connect-host
resolution); it's sourced, not executed.

## Notes and limitations

- **The host's `mariadb` client is used directly** — no transient container. A `host.docker.internal` URL (a DB
  on the docker host) is reached from the host itself at `127.0.0.1`; real hostnames are used as-is.
- **Host-side ops connect as the DB admin, not the app user.** The v1 application user is typically granted only
  for the docker network (so the containers can connect), not from the host — so dumping the source and
  restoring the clone from the host must use an account that can, i.e. `root`. Both `create-db` and `clone`
  prompt for the admin password (default user `root`, override with `DB_ADMIN_USER=`, skip the prompt with
  `DB_ADMIN_PASSWORD=`). The connection is evaluated for the **host** (`root@127.0.0.1` / `root@'%'`), not a
  container gateway IP — which is what made root access work here.
- **Reaching the clone DB from inside the containers.** When `CLONE_DATABASE_URL` points at `host.docker.internal`
  (a DB on the docker host), both stacks map it to the host gateway out of the box — `clone/compose.v1.yml` on the
  v1 `api` service, and the v3 `docker-compose.yml` on `os2display` — so no override is needed. This assumes the
  DB server is reachable from the host (an external server, or a bundled mariadb publishing a port); a source DB
  living in an unpublished container is not reachable this way.
- Run multiple clones by giving each its own checkout (and thus `CLONE_PROJECT`).
