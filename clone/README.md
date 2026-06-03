# Stack clone (standalone)

Self-contained tooling to **clone a running OS2display stack** into a new directory and bring it up on another
domain — typically a staging mirror of production, populated with real data.

This lives outside the main task surface on purpose: it's a standalone add-on, not wired into the root
`Taskfile.yml`, `README.md`, or `docker-compose.yml`. Drop the `clone/` directory into a stack root and run the
scripts directly.

## What it does

`clone/clone.sh` runs end to end:

1. **Dumps** the source database (`DATABASE_URL` in `./.env.symfony`).
2. **Copies** the project to `DEST` — env files, `./media` uploads and the `./jwt` keypair included; `.git` and
   `./backup` excluded.
3. **Rewrites** the clone's config:
   - `DEST/.env` — new `COMPOSE_PROJECT_NAME` + `OS2DISPLAY_SERVER_DOMAIN`, drops `traefik` from
     `COMPOSE_PROFILES`, and opts into the shared-frontend override (`COMPOSE_FILE` +
     `OS2DISPLAY_FRONTEND_NETWORK`).
   - `DEST/.env.symfony` — the clone's `DATABASE_URL`, plus the old domain rewritten to the new one in CORS /
     `ADMIN_*` / `CLIENT_*` / OIDC redirect values.
   - `DEST/docker-compose.yml` — project-namespaces the traefik router + middleware names so the clone's routes
     don't collide with the source's behind the shared traefik. **Only the copy is touched — the source compose
     is never modified.**
4. **Brings the clone up** on the shared `frontend` network — no second traefik; the running one discovers the
   clone's `nginx-api` and routes the new domain.
5. **Restores** the dump into the clone's database.
6. **Clears** the clone's application cache.

`APP_SECRET`, `JWT_PASSPHRASE` and the `./jwt` keypair are copied verbatim, so the cloned data's existing user
logins and screen tokens keep working. It's a faithful copy — only the domain, project name and `DATABASE_URL`
change.

## Prerequisites

- The **source stack is up** — the clone rides its traefik and shares its `frontend` network.
- A **separate database** for the clone. `CLONE_DATABASE_URL` must point at a different database than the source;
  the script aborts if the two URLs match. The target DB is created if missing (needs `CREATE` privilege) and the
  dump is loaded into it.
- `docker` and `rsync` on the host running the script.

## Usage

The clone reads its config from `clone/.env.clone`, so set the variables once and re-run as often as you like.
Run everything from the stack root (the directory holding `.env` / `.env.symfony` / `docker-compose.yml`):

```bash
task -t clone/Taskfile.yml init      # creates clone/.env.clone from the example
$EDITOR clone/.env.clone             # set DEST / DOMAIN / CLONE_DATABASE_URL
task -t clone/Taskfile.yml clone     # repeatable — reuses clone/.env.clone
```

`cd clone && task <name>` works too (Task auto-discovers the Taskfile). Available tasks: `init`, `clone`, `dump`,
`restore`.

### Configuration (`clone/.env.clone`)

| Variable             | Required | Default                         | Purpose                                         |
| -------------------- | -------- | ------------------------------- | ----------------------------------------------- |
| `DEST`               | yes      | —                               | Target directory (created; must be new/empty).  |
| `DOMAIN`             | yes      | —                               | Public domain the clone serves.                 |
| `CLONE_DATABASE_URL` | yes      | —                               | The clone's database — must differ from source. |
| `CLONE_PROJECT`      | no       | sanitised basename of `DEST`    | Compose project (container/volume) namespace.   |
| `FRONTEND_NETWORK`   | no       | source's value, else `frontend` | The network the running traefik is attached to. |

`clone/.env.clone` is gitignored. For a one-off variation, set the variable in the environment — it overrides the
file for that run:

```bash
DOMAIN=other.example.com task -t clone/Taskfile.yml clone
```

You can also bypass Task entirely and call the script directly (it loads `clone/.env.clone` the same way):

```bash
clone/clone.sh
```

The clone is a normal stack in `DEST` afterwards — manage it from there with `docker compose` (or `task`) like
any other install.

## The dump / restore scripts

`clone.sh` uses these two; both are usable on their own (as `task -t clone/Taskfile.yml dump` / `restore`, or
directly). Unlike execing `mariadb-dump` inside the bundled container (a no-op for external databases), they
parse `DATABASE_URL` and drive a transient `mariadb` client, so they work wherever the database lives — external
**or** bundled.

```bash
clone/db-dump.sh                         # → ./backup/<UTC-ts>.sql.gz
clone/db-dump.sh backup/my-dump.sql.gz   # explicit output path

clone/db-restore.sh backup/<ts>.sql.gz   # load a dump back in (DESTRUCTIVE — overwrites matching tables)
```

`clone/lib-db-url.sh` is the shared helper (DATABASE_URL parsing, project / image-tag / network resolution); it's
sourced, not executed.

## Notes and limitations

- **Same host, shared traefik** is the supported topology. For a different host, copy `DEST` across and bring it
  up there with its own traefik instead.
- The transient `mariadb` client attaches to the project's `<project>_app` network when it exists (so a bundled
  `host=mariadb` URL resolves); otherwise it runs on the default bridge, which still has egress for an external
  host.
- Run multiple clones by giving each a distinct `DEST` (and thus `CLONE_PROJECT`); their routes and
  containers/volumes stay isolated.
- If the image added Doctrine migrations since the dump was taken, run `app:update` in the clone afterwards (the
  script prints the exact command on completion).
