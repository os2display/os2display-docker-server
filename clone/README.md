# Stack clone (standalone)

Self-contained tooling to **clone a running OS2display stack into this checkout** and bring it up on another
domain — typically a staging mirror of production, populated with real data.

The direction matters: **this checkout is the destination.** You check the repo out into a new directory, point
`SOURCE` at the running stack, and the tooling pulls the source's operator state (env files, media, jwt keypair)
in here. The repo files — compose, Taskfile, scripts — come from the checkout itself, so the clone runs whatever
version you checked out. The source is only read (plus one database dump); it is never modified.

This lives outside the main task surface on purpose: it's a standalone add-on, not wired into the root
`Taskfile.yml`, `README.md`, or `docker-compose.yml`.

## What it does

`clone/clone.sh` runs end to end:

1. **Dumps** the source database (`DATABASE_URL` in `SOURCE/.env.symfony`).
2. **Copies** the source's operator state here — top-level env files, `./media` uploads and the `./jwt` keypair.
   Repo files, `backup/` and the source's own `clone/.env.clone` are not copied.
3. **Rewrites** the clone's config in this checkout:
   - `./.env` — new `COMPOSE_PROJECT_NAME` + `OS2DISPLAY_SERVER_DOMAIN`, drops `traefik` from
     `COMPOSE_PROFILES`, and opts into the shared-frontend override (`COMPOSE_FILE` +
     `OS2DISPLAY_FRONTEND_NETWORK`).
   - `./.env.symfony` — the clone's `DATABASE_URL`, plus the old domain rewritten to the new one in CORS /
     `ADMIN_*` / `CLIENT_*` / OIDC redirect values.
   - `./docker-compose.yml` — project-namespaces the traefik router + middleware names so the clone's routes
     don't collide with the source's behind the shared traefik. **This dirties the checkout's git status —
     `git diff` shows exactly what the clone changed.** The source is never modified.
4. **Brings the clone up** on the shared `frontend` network — no second traefik; the running one discovers the
   clone's `nginx-api` and routes the new domain.
5. **Restores** the dump into the clone's database.
6. **Clears** the clone's application cache.

`APP_SECRET`, `JWT_PASSPHRASE` and the `./jwt` keypair are copied verbatim, so the cloned data's existing user
logins and screen tokens keep working. It's a faithful copy of the data — only the domain, project name and
`DATABASE_URL` change.

Repeat runs **refresh the clone in place** (fresh dump, env re-copied and rewritten). As a guard, that's only
allowed when the existing `./.env` carries the clone's own project name — a configured non-clone stack in this
directory is never clobbered.

## Prerequisites

- A **fresh checkout** of this repo as the destination (no `.env` yet — `task env:init` has NOT been run here).
- The **source stack is up** — the clone rides its traefik and shares its `frontend` network.
- A **separate database** for the clone. `CLONE_DATABASE_URL` must point at a different database than the source;
  the script aborts if the two URLs match. The target DB is created if missing (needs `CREATE` privilege) and the
  dump is loaded into it.
- `docker` and `rsync` on the host running the script.

## Usage

The clone reads its config from `clone/.env.clone`, so set the variables once and re-run as often as you like.
Run everything from this checkout's root:

```bash
git clone <repo-url> os2display-staging && cd os2display-staging

task -t clone/Taskfile.yml init        # creates clone/.env.clone from the example
$EDITOR clone/.env.clone               # set SOURCE / DOMAIN (and CLONE_DATABASE_URL)
task -t clone/Taskfile.yml create-db   # optional: provision the clone DB (see below)
task -t clone/Taskfile.yml clone       # repeatable — refreshes the clone in place
```

`cd clone && task <name>` works too (Task auto-discovers the Taskfile). Available tasks: `init`, `create-db`,
`clone`, `dump`, `restore`.

### Provisioning the clone database (same server as the source)

If the clone should live on the **same database server** as the source, `create-db` provisions it for you instead
of you hand-crafting `CLONE_DATABASE_URL`. The database server is assumed **external** — reachable over the
network from this host (the script warns if the source URL points at a docker-internal hostname like the bundled
`mariadb`):

```bash
task -t clone/Taskfile.yml create-db   # prompts for the DB admin (root) password
```

It reads the source `DATABASE_URL` from the first of `SOURCE/.env.local`, `SOURCE/.env.docker.local` (1.x
layouts) or `SOURCE/.env.symfony` (v3 layout) that defines it — so the source can be an old production install
or an already-migrated v3 stack. It parses that URL for the server and app user, connects as the admin user
(default `root` — **you are prompted for the password**), then on that same server:

- creates the clone database (default name `<source-db>_clone`, override with `CLONE_DB_NAME=…`), mirroring the
  source DB's charset/collation;
- ensures the source's app user exists as `<user>@'%'` and grants it access to the clone DB.

The clone reuses the source's application credentials — only the schema name differs — so production data is never
touched. The resulting `CLONE_DATABASE_URL` is written into `clone/.env.clone`, ready for the `clone` task.
Override the admin user with `DB_ADMIN_USER=…`, or skip the prompt in CI with `DB_ADMIN_PASSWORD=…`.

### Configuration (`clone/.env.clone`)

| Variable             | Required | Default                          | Purpose                                          |
| -------------------- | -------- | -------------------------------- | ------------------------------------------------ |
| `SOURCE`             | yes      | —                                | Root of the running stack to clone FROM.         |
| `DOMAIN`             | yes      | —                                | Public domain the clone serves.                  |
| `CLONE_DATABASE_URL` | yes      | —                                | The clone's database — must differ from source.  |
| `CLONE_PROJECT`      | no       | sanitised name of this directory | Compose project (container/volume) namespace.    |
| `FRONTEND_NETWORK`   | no       | source's value, else `frontend`  | The network the running traefik is attached to.  |

`clone/.env.clone` is gitignored. For a one-off variation, set the variable in the environment — it overrides the
file for that run:

```bash
DOMAIN=other.example.com task -t clone/Taskfile.yml clone
```

You can also bypass Task entirely and call the script directly (it loads `clone/.env.clone` the same way):

```bash
clone/clone.sh
```

The clone is a normal stack in this checkout afterwards — manage it with `docker compose` (or `task`) like any
other install.

## The dump / restore scripts

`clone.sh` uses these two; both are usable on their own (as `task -t clone/Taskfile.yml dump` / `restore`, or
directly). Unlike execing `mariadb-dump` inside the bundled container (a no-op for external databases), they
parse `DATABASE_URL` and drive a transient `mariadb` client, so they work wherever the database lives — external
**or** bundled.

They operate on **this** stack root by default; `STACK_ROOT=<dir>` points them at another stack (that's how
`clone.sh` dumps the source).

```bash
clone/db-dump.sh                         # → ./backup/<UTC-ts>.sql.gz
clone/db-dump.sh backup/my-dump.sql.gz   # explicit output path

clone/db-restore.sh backup/<ts>.sql.gz   # load a dump back in (DESTRUCTIVE — overwrites matching tables)
```

`clone/lib-db-url.sh` is the shared helper (DATABASE_URL parsing, project / image-tag / network resolution); it's
sourced, not executed.

## Notes and limitations

- **Same host, shared traefik** is the supported topology. For a different host, take a dump + copy the operator
  state across and bring the checkout up there with its own traefik instead.
- The clone runs the **checkout's** compose and image pin, not the source's. If the checkout's pin is newer than
  the source's and the image added Doctrine migrations, run `app:update` in the clone afterwards (the script
  prints the exact command on completion).
- The transient `mariadb` client attaches to the project's `<project>_app` network when it exists (so a bundled
  `host=mariadb` URL resolves); otherwise it runs on the default bridge, which still has egress for an external
  host.
- Run multiple clones by giving each its own checkout (and thus `CLONE_PROJECT`); their routes and
  containers/volumes stay isolated.
