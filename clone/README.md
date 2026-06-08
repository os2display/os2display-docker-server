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

It does **not** bring a stack up: the copied config is v1 and this checkout is v3. Convert it next (the script
prints the steps), then bring it up with the normal v3 tasks.

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
```

`cd clone && task <name>` works too (Task auto-discovers the Taskfile). Available tasks: `init`, `create-db`,
`clone`, `dump`, `restore`.

After `clone`, convert the v1 copy to v3:

```bash
task env:migrate                                   # .env.docker.local -> .env.symfony.migrated
# review, then: mv .env.symfony.migrated .env.symfony
task env:init                                      # fill in any missing per-service env files
task up                                            # bring the v3 stack up
task console -- --user deploy app:update           # migrate the DB schema to v3
```

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
- **The eventual v3 stack** (after conversion) runs in containers, so it still needs `host.docker.internal` mapped
  at runtime — add `extra_hosts: ["host.docker.internal:host-gateway"]` to the `os2display` service (e.g. via a
  compose override) when you bring the converted clone up.
- Run multiple clones by giving each its own checkout (and thus `CLONE_PROJECT`).
