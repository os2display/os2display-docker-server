# Upgrade guide -> 3.0

Operator-facing migration recipes between 1.x -> 3.0 versions (2.8 -> 3.0 of OS2display) of this repo. 
For routine within-major upgrades (e.g., bumping `OS2DISPLAY_VERSION_API` to a new patch release), 
see the [Cookbook](README.md#cookbook) in the README. For the full list of changes in any given release, see 
[CHANGELOG.md](CHANGELOG.md).

## Version history

- **1.x** — initial Docker hosting tooling. v1.0.0 was the initial release; see
  [CHANGELOG.md](CHANGELOG.md). (Note that 1.x of the docker-server setup supported 2.x of Os2display)
- **3.x** — current line. Aligns this repo's major version with upstream
  [`display-api-service`](https://github.com/os2display/display-api-service), which is at 3.x.
- **(no 2.x.)** Internal canonical work on a `release/2.0.0` branch never shipped as a tagged
  release. We skip 2.x so operators see one major-version number per stack — this docker-server
  3.x runs the upstream API 3.x. No re-numbering across boundaries.

## 1.x → 3.x migration

The **authoritative** upgrade guide is
[`display-api-service` `UPGRADE.md`](https://github.com/os2display/display-api-service/blob/main/UPGRADE.md).
Read it first and follow it throughout — it owns *what changed*, the pre-upgrade configuration
export, the database and content migration, and the post-upgrade sanity checks, all of which apply
here unchanged.

This page is the **Option A: os2display-docker-server** supplement that guide points to from its
*Step 2 — Infrastructure configuration*. It fills in only the docker-server-specific mechanics: the
3.0 branch wires up the published images for you, and `task env_migrate` (on 1.x), `task env:migrate`,
`task env:init` and `task env:diff` automate the env migration. It assumes you have followed the
canonical pre-upgrade checklist.

A serious migration: plan a maintenance window, take backups, and rehearse end-to-end on a staging
host before touching production. The on-disk data survives in place — MariaDB 11 reads 10.x InnoDB
tablespaces, there are no database schema changes, and the JWT keys and uploaded media don't move — 
but the database migrations are rolled up to one. 

### Table of contents

- [What this repo adds on top of the canonical changes](#what-this-repo-adds-on-top-of-the-canonical-changes)
- [Step 1 — Pre-upgrade (on 1.x, stack still up)](#step-1--pre-upgrade-on-1x-stack-still-up)
- [Step 2 — Stop the 1.x stack](#step-2--stop-the-1x-stack)
- [Step 3 — Switch the repo to 3.0](#step-3--switch-the-repo-to-30)
- [Step 4 — Rewrite the env configuration](#step-4--rewrite-the-env-configuration)
- [Step 5 — Upgrade MariaDB 10.x to 11.4](#step-5--upgrade-mariadb-10x-to-114)
- [Step 6 — Database migration and first boot](#step-6--database-migration-and-first-boot)
- [Post-upgrade validation](#post-upgrade-validation)
- [Rollback](#rollback)

### What this repo adds on top of the canonical changes

The canonical
[What changed](https://github.com/os2display/display-api-service/blob/main/UPGRADE.md#what-changed)
covers the application-level changes (one image; `config.json` → `ADMIN_*`/`CLIENT_*` env; the
`APP_` prefix dropped; bundled templates; removed feed types). On the hosting side this repo also
changes:

- **One env file per service.** The single 1.x `.env.docker.local` is replaced by per-service files
  (`.env.symfony`, `.env.php`, `.env.nginx`, `.env.mariadb`, `.env.traefik`) plus the
  compose-orchestration `.env`. See [README § Configuration files](README.md#configuration-files).
- **Compose profiles replace `INTERNAL_DATABASE` / `INTERNAL_PROXY`.** `COMPOSE_PROFILES=mariadb,traefik`
  (default), or drop a token to run against an external database and/or proxy.
- **Bundled MariaDB 10.x → 11.4 LTS.** Binary-compatible at the data-file level; the 3.x mariadb
  service sets `MARIADB_AUTO_UPGRADE=1`, so `mariadb-upgrade` runs on the first 11.4 boot.
- **Image registry switched** from `itkdev/os2display-*` (Docker Hub) to
  `ghcr.io/os2display/display-api-service{,-nginx}` (GHCR) — handled by the 3.x compose file.

### Step 1 — Pre-upgrade (on 1.x, stack still up)

These tasks perform the canonical pre-upgrade checklist the docker-server way. Run them on the
**1.x** checkout with the stack **up** — the configuration export reads the running application and
fetches the live admin/client `config.json`, so it cannot run once the stack is stopped.

```bash
task upgrade_check     # confirms the api image (2.8.x) provides app:utils:convert-env-to-3x and
                       # prints the bundled MariaDB volume name (<COMPOSE_PROJECT_NAME>_mariadb)
task backup_db         # database dump; keep a copy off-host
task env_migrate       # writes .env.symfony.migrated — the loaded env + admin/client config.json,
                       # converted to 3.x names, with a trailing infrastructure advisory
```

**Record the `COMPOSE_PROJECT_NAME`** that `task upgrade_check` reports. The 3.x stack reuses the
existing MariaDB volume in place *only* when the 3.x `.env` keeps the same project name — a
different name silently boots an empty database (see step 5).

Then copy the operator state aside in case a rollback is needed (`jwt/` and `media/` are bind-mounts
and stay on disk regardless, but a copy is cheap):

```bash
mkdir -p /tmp/os2display-1x-backup
cp .env .env.docker.local .env.local .env.symfony.migrated /tmp/os2display-1x-backup/  # whatever you have
cp -r jwt/ /tmp/os2display-1x-backup/
```

`.env.symfony.migrated` holds every application secret (`APP_SECRET`, database and OIDC
credentials, ...). It is gitignored on both branches, so it survives the branch switch in step 3
untouched — treat it as a credentials file.

### Step 2 — Stop the 1.x stack

```bash
task stop              # stops containers, preserves volumes — NOT task purge / down --volumes
```

This is the **last shutdown of the 10.x MariaDB** before 11.4 reads its files. A server SIGKILLed
mid-flush leaves a dirty data dir, and crash recovery across a major version is unsupported, so
confirm a clean shutdown:

```bash
docker compose -f docker-compose.yml logs mariadb | tail -n 20   # expect "mariadbd: Shutdown complete"
```

If it was killed before completing shutdown (large or busy database), bring it back up (`task up`),
let it settle, and stop it again with more grace:
`docker compose -f docker-compose.yml stop -t 120 mariadb`.

### Step 3 — Switch the repo to 3.0

```bash
git fetch
rm -f docker-compose.yml      # the 1.x stack leaves an untracked generated docker-compose.yml; the
                              # 3.x branch tracks a file at that path, so the checkout aborts
                              # ("untracked working tree files would be overwritten") unless it's
                              # removed first. It's regenerated in 3.x — nothing of value is lost.
git checkout release/3.0.0
```

### Step 4 — Rewrite the env configuration

The 1.x `.env.docker.local` becomes the per-service `env_file:` layout. Build it from the migrated
export:

```bash
# 1. Application config: split the infra advisory out of the migrated export, then apply it.
task env:migrate                          # .env.symfony.migrated (app env) + .env.symfony.infra-advisory
$EDITOR .env.symfony.migrated             # sanity check
mv .env.symfony.migrated .env.symfony

# 2. Create .env (prompts for the domain) and the per-service files from their .example templates.
#    Sees the .env.symfony you just wrote and leaves it untouched (no FORCE=1 needed).
task env:init

# 3. Finish .env: image version, profile and project name.
$EDITOR .env
# OS2DISPLAY_VERSION_API=<latest 3.x tag>   (was COMPOSE_VERSION_API; see .env.example)
# COMPOSE_PROFILES=mariadb,traefik          (replaces INTERNAL_DATABASE / INTERNAL_PROXY; drop a
#                                            token to run against external DB and/or proxy)
# COMPOSE_PROJECT_NAME=<your 1.x value>     (MUST match — step 1 / step 5)

# 4. Finish .env.symfony and distribute the advisory keys.
$EDITOR .env.symfony
# - Set DATABASE_URL serverVersion to "11.4.10-MariaDB" (post-upgrade — step 5). This is the one
#   value env:migrate leaves for you; the export carries the old 10.x version through verbatim.
# - Distribute .env.symfony.infra-advisory: COMPOSE_* -> .env, PHP_* -> .env.php,
#   NGINX_* -> .env.nginx, MARIADB_* -> .env.mariadb.

# 5. Match the bundled MariaDB credentials to the carried-over data dir.
$EDITOR .env.mariadb
# MARIADB_USER / _PASSWORD / _DATABASE / _ROOT_PASSWORD MUST equal the 1.x values DATABASE_URL
# encodes. On a non-empty data dir the entrypoint IGNORES these (it does not re-initialise), so a
# mismatch does not error at startup — it surfaces later as Doctrine/tooling auth failures.

# 6. Traefik (interactive): set the domain, Let's Encrypt email and dashboard auth in .env.traefik.
task env:traefik
# 7. Sanity check: diff your .env.symfony against the bundled .env in the pinned API image. It
#    surfaces keys the image added or renamed that your migrated file doesn't set yet — copy any
#    you need over by hand. (Read-only; it changes nothing.)
task env:diff
```

#### Media upload size: align all three layers

v3 adds an app-level cap on media uploads, `MEDIA_MAX_UPLOAD_SIZE_MB` (default `200`, in MiB),
enforced by the Symfony validator on `Media::$file`. Because uploads cross nginx → PHP-FPM →
Symfony, all three layers must agree, or the lowest wins (and the operator sees a confusing 413 /
`UPLOAD_ERR_INI_SIZE` instead of the app's clear "file exceeds N MiB" error). Defaults in
`.env.php.example` and `.env.nginx.example` are aligned to `200`; if you customise any of them, keep
the inequality intact:

```text
NGINX_MAX_BODY_SIZE  >=  PHP_POST_MAX_SIZE  >=  PHP_UPLOAD_MAX_FILESIZE  >=  MEDIA_MAX_UPLOAD_SIZE_MB
```

`MEDIA_MAX_UPLOAD_SIZE_MB` comes from the image's bundled `.env`, which `task env:init` extracts into
`.env.symfony` (the converter export carries it too). Verify with `task env:diff` — if the diff shows
the key only on the image side, copy the line over by hand.

### Step 5 — Upgrade MariaDB 10.x to 11.4

The bundled MariaDB is `mariadb:11.4.10` in 3.x (was `mariadb:10.x` in 1.x). The 3.x mariadb service
sets `MARIADB_AUTO_UPGRADE=1`, so the system-table upgrade runs automatically; you bring the new
image up against the carried-over data and verify.

> **External database?** If you run with `COMPOSE_PROFILES` excluding `mariadb` (your DB lives on the
> host or elsewhere), this step is yours to manage — upgrade that server separately and set
> `DATABASE_URL` `serverVersion` to its actual version. The rest of this step applies to the bundled
> MariaDB only.

```bash
# 1. Confirm the backup from step 1 is recent and readable.
ls -lh db_backups/ 2>/dev/null                          # 1.x writes here
gunzip -t db_backups/<the latest>.sql.gz 2>/dev/null || true

# 2. Confirm the data volume carried over and the project name matches. A mismatched
#    COMPOSE_PROJECT_NAME resolves a DIFFERENT (empty) volume — the stack would come up green with
#    no data. The name below must be the one task upgrade_check recorded in step 1.
docker volume ls | grep mariadb

# 3. Pull the new image and start the DB container alone. With MARIADB_AUTO_UPGRADE=1 the entrypoint
#    version-compares the data dir and runs mariadb-upgrade before accepting connections; on a large
#    database this can take a while, so watch the log.
docker compose pull mariadb
docker compose up -d mariadb
docker compose logs -f mariadb                          # wait for the upgrade and "ready for connections"

# 4. Optional explicit re-run / verification. Idempotent — a no-op if the auto-upgrade already ran.
task db:upgrade
```

Confirm the `DATABASE_URL` `serverVersion` edit from step 4 reads `11.4.10-MariaDB`. Doctrine uses it
to pick its SQL dialect; a mismatch produces wrong queries (most often incorrect JSON or function
syntax).

If the upgrade reports incompatible objects, **stop here.** Restore from the dump, revert the mariadb
image tag, and debug on a non-prod box. The common cause is custom stored procedures or views with
reserved-word identifiers in 11.4 that were valid in 10.x.

### Step 6 — Database migration and first boot

The canonical
[Step 3 — Database and content migration](https://github.com/os2display/display-api-service/blob/main/UPGRADE.md#step-3--database-and-content-migration)
owns this — including the deprecated-feed-source cleanup. On docker-server, run it in a one-off
container (DB/redis only, no web tier) so the stack never serves an un-migrated schema:

```bash
# A carried-over DB holds the full 2.x migration history that 3.0 consolidated into one migration.
# Roll the version table up first, or app:update's migrate phase fails on the orphaned rows.
# (A fresh DB with no 2.x history skips this and migrates normally.)
task console:run -- doctrine:migrations:rollup --no-interaction

task install           # pulls images, runs app:update (migrate — now a no-op — plus template/layout
                       # install) in a one-off container BEFORE the web tier, brings the full stack
                       # up, runs jwt:ensure, then prompts for tenant + admin user. Skip those
                       # prompts (Ctrl-D) — your existing tenants and users are in the carried data.
```

`task jwt:ensure` (run by `task install`) validates the carried-over keypair against `JWT_PASSPHRASE`
and regenerates **only** on mismatch, so screens authorized in 1.x keep working. If the report from
step 1 flagged feed sources using removed feed types, clean them up per the canonical step:
`task console:run -- app:feed:remove-deprecated-feed-sources --force`.

### Post-upgrade validation

Run the canonical
[post-upgrade sanity checks](https://github.com/os2display/display-api-service/blob/main/UPGRADE.md#post-upgrade-sanity-checks).
The docker-server extras:

- [ ] `docker compose ps` shows all profile-active services `healthy`.
- [ ] `https://<your-domain>/admin/` and `https://<your-domain>/client/` load — both now served from
      the os2display container, not separate admin/client containers.
- [ ] Existing slide thumbnails render; if they 404, check `./media` ownership (UID 1042 owner,
      group-readable for UID 101 nginx — see [README § Prerequisites](README.md#prerequisites)).
- [ ] (If you exposed it) `https://<traefik-host>/traefik/dashboard/` loads after basic-auth.
- [ ] `task logs` for 5 minutes — no recurring errors.

### Rollback

If validation fails and the issue isn't an obvious env-config typo:

```bash
task purge                              # WIPES the bundled mariadb data volume — required because
                                        # we're about to restore from backup. ALSO wipes the redis
                                        # cache (harmless; it rebuilds). Does NOT touch ./media or
                                        # ./jwt — bind mounts, preserved through compose lifecycle.
rm -f docker-compose.yml                # 3.x tracks it; remove before checking out 1.x
git checkout <previous 1.x ref>         # the tag or branch you came from

# Restore the 1.x env files first — `task up` regenerates the 1.x compose file from them, and the
# restore below reads credentials from .env.docker.local. jwt/ and media/ are still on disk.
cp /tmp/os2display-1x-backup/.env.docker.local .
cp /tmp/os2display-1x-backup/.env.local .                     # if it existed

task up                                 # 1.x: regenerates docker-compose.yml, starts the stack with
                                        # a fresh (empty) mariadb volume
docker compose -f docker-compose.yml logs -f mariadb          # wait for "ready for connections"

# Load the dump from step 1. task backup_db (1.x) writes a plain, single-database SQL file to
# db_backups/ — restore it into that same database.
docker compose -f docker-compose.yml exec -T mariadb \
  mariadb -u root -p"$(grep ^MARIADB_ROOT_PASSWORD= .env.docker.local | cut -d= -f2-)" \
  "$(grep ^MARIADB_DATABASE= .env.docker.local | cut -d= -f2-)" \
  < /path/to/db_backups/db_backup_<ts>.sql

task cc                                 # clear the 1.x app cache against the restored data
```

What survives the rollback in place:

- **`./media/`** — host bind-mount, untouched by `task purge`. The restored v1 database's filename
  references still point at the same files on disk.
- **`./jwt/`** — host bind-mount. Same JWT keys before and after.
- **`traefik/letsencrypt/`** — bind-mount. Existing LE certs still valid.

What gets destroyed and restored:

- **MariaDB** — named volume, removed by `task purge`, restored by loading the dump back in. **This
  is why the database backup in step 1 is non-negotiable** — without it, the rollback path can't
  reach v1's data.
- **Redis cache** — named volume, removed and rebuilt empty. v1 repopulates on first request.

Don't roll back without restoring the dump: 3.x `app:update` migrations may have applied schema
changes 1.x doesn't reverse, so a tag-revert over the 3.x-mutated DB fails silently (wrong queries,
missing columns) or loudly (Doctrine refusing to start). And once 11.4 has upgraded the data dir in
place (step 5), the 10.x server can no longer read it — the rollback restores the dump into a fresh
volume rather than reusing the upgraded files.

