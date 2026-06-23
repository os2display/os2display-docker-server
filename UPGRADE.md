# Upgrade guide

Operator-facing migration recipes between major versions of this repo. For routine
within-major upgrades (e.g., bumping `OS2DISPLAY_VERSION_API` to a new patch release), see the
[Cookbook](README.md#cookbook) in the README. For the full list of changes in any given
release, see [CHANGELOG.md](CHANGELOG.md).

## Version history

- **1.x** — initial Docker hosting tooling. v1.0.0 was the initial release; see
  [CHANGELOG.md](CHANGELOG.md).
- **3.x** — current line. Aligns this repo's major version with upstream
  [`display-api-service`](https://github.com/os2display/display-api-service), which is at 3.x.
- **(no 2.x.)** Internal canonical work on a `release/2.0.0` branch never shipped as a tagged
  release. We skip 2.x so operators see one major-version number per stack — this docker-server
  3.x runs the upstream API 3.x. No re-numbering across boundaries.

## 1.x → 3.x migration

A serious migration. Plan a maintenance window, take backups, walk the steps end-to-end on a
staging host before touching production. The on-disk data files survive the upgrade in place
(MariaDB 11 reads 10.x InnoDB tablespaces; the JWT keys and uploaded media don't move), but the
schema gets rewritten by Doctrine migrations and the operator env layout is restructured.

### Table of contents

- [What's changed at a glance](#whats-changed-at-a-glance)
- [Pre-upgrade checklist (while still on 1.x)](#pre-upgrade-checklist-while-still-on-1x)
- [Step 1 — Stop the 1.x stack](#step-1--stop-the-1x-stack)
- [Step 2 — Update the repo](#step-2--update-the-repo)
- [Step 3 — Rewrite the env configuration](#step-3--rewrite-the-env-configuration)
- [Step 4 — Upgrade MariaDB 10.x to 11.4](#step-4--upgrade-mariadb-10x-to-114)
- [Step 5 — First boot](#step-5--first-boot)
- [Post-upgrade validation](#post-upgrade-validation)
- [Rollback](#rollback)

### What's changed at a glance

The full breaking-change list is in [CHANGELOG.md](CHANGELOG.md) under
`[Unreleased] — release/3.0.0`. The handful of changes that matter most for this migration:

- **API + admin + screen-client are one image.** v1 had three images (`os2display-api-service`,
  `os2display-admin-client`, `os2display-client`). v3 bundles the admin UI and screen client
  into the API image and serves them as Symfony routes (`/admin`, `/client`). The two separate
  services + their `OS2DISPLAY_VERSION_ADMIN` / `OS2DISPLAY_VERSION_CLIENT` pins are gone.
- **Symfony env vars lose the `APP_` prefix** (except `APP_ENV` and `APP_SECRET`, which Symfony
  defines). `APP_DATABASE_URL` becomes `DATABASE_URL`, `APP_JWT_PASSPHRASE` becomes
  `JWT_PASSPHRASE`, etc. The 2.8 API ships `app:utils:convert-env-to-3x`, which does the rename
  for you (and converts the admin/client `config.json`) — this repo's `task env_migrate` (on the
  1.x branch) runs it; see the pre-upgrade checklist below.
- **One env file per service.** The single `.env.docker.local` is gone, replaced by
  `.env.symfony` + `.env.php` + `.env.nginx` + `.env.mariadb` + `.env.traefik` + the
  compose-orchestration `.env`. See [README § Configuration files](README.md#configuration-files).
- **MariaDB 10.x → 11.4 LTS.** Major version bump, binary-compatible at the data file level
  (MariaDB 11 reads 10.x InnoDB tablespaces). The 3.x mariadb service sets `MARIADB_AUTO_UPGRADE=1`,
  so `mariadb-upgrade` runs automatically on the first 11.4 boot against the carried-over data;
  you still update `serverVersion` in `DATABASE_URL`.
- **Compose profiles replace `INTERNAL_DATABASE` / `INTERNAL_PROXY`.** Use
  `COMPOSE_PROFILES=mariadb,traefik` (default), or drop a token to run with external infra.
- **Image registry switched** from `itkdev/os2display-*` (Docker Hub) to
  `ghcr.io/os2display/display-api-service{,-nginx}` (GHCR).

### Pre-upgrade checklist (while still on 1.x)

Everything in this section runs on the **1.x** checkout, with the stack **still up**. The
configuration export (`task env_migrate`) reads the running application and fetches the live
admin/client `config.json` — it cannot run once the stack is stopped. Confirm prerequisites
first:

```bash
docker --version              # 20.10+
docker compose version        # v2 (the integrated subcommand, not legacy docker-compose)
task --version                # v3+
id                            # confirm UID 1042 / GID 1042 if you've followed the README
df -h .                       # headroom for the database dump
```

Read the [Caveats and foot-guns](README.md#caveats-and-foot-guns) section in the README before
proceeding. The cert-file SAN-coverage caveat and the `DATABASE_URL` `serverVersion=` caveat
in particular bite operators on this migration.

Then, on the 1.x stack:

- [ ] **Be on the final 1.x release running 2.8 API images.** The export command ships with
  `os2display-api-service` 2.8.0. Set `COMPOSE_VERSION_API=2.8.0` (or a later 2.x) in
  `.env.docker.local` and `task install` to pull and recreate. The last 1.x release of this repo
  (v1.2.0) provides `task upgrade_check` / `task env_migrate`; upgrade to it first if you are on
  an earlier 1.x.
- [ ] **Run the pre-flight check:** `task upgrade_check`. It confirms the api image provides
  `app:utils:convert-env-to-3x` and prints the bundled MariaDB volume name
  (`<COMPOSE_PROJECT_NAME>_mariadb`). **Record that volume name** — the 3.x stack reuses it in
  place, and only does so when the 3.x `.env` keeps the same `COMPOSE_PROJECT_NAME`. A different
  project name silently boots an *empty* database (see step 4).
- [ ] **Back up the database:** `task backup_db` (1.x), and keep the dump somewhere off-host.
- [ ] **Export the configuration in 3.x shape:** `task env_migrate` (1.x). It writes
  `.env.symfony.migrated` — the loaded env converted to 3.x names *plus* the admin/client
  `config.json` conversion. A trailing advisory block lists infrastructure variables
  (`COMPOSE_*`, `PHP_*`, `NGINX_*`, `MARIADB_*`) that move to per-service files in 3.x, never
  into the application env.
- [ ] **Copy env files + JWT keys aside** in case a rollback is needed:

  ```bash
  mkdir -p /tmp/os2display-1x-backup
  cp .env .env.docker.local .env.local .env.symfony.migrated /tmp/os2display-1x-backup/  # whatever subset you have
  cp -r jwt/ /tmp/os2display-1x-backup/
  ```

`.env.symfony.migrated` contains every application secret (`APP_SECRET`, database and OIDC
credentials, ...). It is gitignored on both branches; treat it like a credentials file and it
will survive the branch switch in step 2 untouched.

You do **not** need to copy `./media/` aside for the rollback. It's a host bind-mount, not a
docker named volume — `task purge`, `task down --volumes`, and `docker compose down --volumes`
all leave it on disk. The `./media` directory survives the upgrade-then-rollback round-trip in
place; the v1 database dump's filename references still match the files on disk after a restore.

That said, the media bind-mount is also where uploaded user data lives. If you have a snapshot
tool (LVM, ZFS, btrfs, cloud volume snapshots), take a host-level snapshot here for paranoia
— protects against unrelated disk failures during the maintenance window, not against the
upgrade itself. Same for `./jwt/`: bind-mounted, preserved across compose lifecycle, but a copy
aside in `/tmp/os2display-1x-backup/` is cheap.

### Step 1 — Stop the 1.x stack

```bash
task stop                     # bring containers down; preserves volumes
```

Don't run `task purge` or `task down --volumes` — those delete the database.

This is the **last shutdown of the 10.x MariaDB**; the next process to read its data files is
11.4. A server SIGKILLed mid-flush leaves a dirty data dir, and crash recovery across a major
version is unsupported. The 1.x compose has no extended stop grace, so confirm the shutdown was
clean before continuing:

```bash
docker compose -f docker-compose.yml logs mariadb | tail -n 20   # expect "mariadbd: Shutdown complete"
```

If the log shows the server was killed before completing shutdown (large or busy database), bring
it back up under 1.x (`task up`), let it settle, and stop it again giving the container more time
(`docker compose -f docker-compose.yml stop -t 120 mariadb`).

### Step 2 — Update the repo

```bash
git fetch
rm -f docker-compose.yml      # see note
git checkout release/3.0.0
```

The 1.x stack generated an untracked `docker-compose.yml` (via `task _dc_compile`). The 3.x
branch *tracks* a file at that path, so `git checkout` aborts with "untracked working tree files
would be overwritten" unless you remove the generated one first. It is regenerated from the
tracked compose file in 3.x — nothing of value is lost. (1.x v1.2.0 gitignores this file, but an
already-present untracked copy still blocks the checkout, so the `rm` is needed regardless of
which 1.x you came from.)

### Step 3 — Rewrite the env configuration

The 1.x layout was a single `.env.docker.local` consumed by compose substitution. v3 uses
per-service `env_file:` directives:

| File | Purpose |
|---|---|
| `.env` | Compose orchestration: project name, profile, image versions, server domain. |
| `.env.symfony` | Symfony app config for the os2display container. |
| `.env.php` | PHP-FPM runtime tuning. |
| `.env.nginx` | Nginx runtime tuning. |
| `.env.mariadb` | MariaDB credentials. |
| `.env.traefik` | Traefik dashboard auth, Let's Encrypt email, cert provider. |

Build `.env.symfony` from the `.env.symfony.migrated` you exported in the pre-upgrade checklist
(it survives the branch switch — gitignored on both branches), then bootstrap the rest:

```bash
# 1. Application config. task env:migrate finds the .env.symfony.migrated produced by 'task
#    env_migrate' on 1.x and splits its trailing infrastructure advisory into
#    .env.symfony.infra-advisory, leaving the clean application env in .env.symfony.migrated.
task env:migrate
$EDITOR .env.symfony.migrated             # sanity check
mv .env.symfony.migrated .env.symfony

# 2. Per-service files + .env. task env:init creates .env (prompts for the domain) and the
#    per-service .env.{php,nginx,mariadb,traefik} from their .example templates. It sees the
#    .env.symfony you just wrote and leaves it untouched (no FORCE=1 needed).
task env:init

# 3. Finish .env: port over your old image version and profile selection.
$EDITOR .env
# OS2DISPLAY_VERSION_API=<latest 3.x tag>       (was COMPOSE_VERSION_API; see .env.example)
# COMPOSE_PROFILES=mariadb,traefik              (replaces INTERNAL_DATABASE / INTERNAL_PROXY)
# COMPOSE_PROJECT_NAME=<your 1.x value>         (MUST match — see step 4; from task upgrade_check)

# 4. Finish .env.symfony.
$EDITOR .env.symfony
# - Set DATABASE_URL serverVersion to "11.4.10-MariaDB" (post-MariaDB upgrade — see step 4).
#   The converter carries the old 10.x serverVersion through verbatim; this is the one value
#   env:migrate leaves for you.
# - Distribute the keys from .env.symfony.infra-advisory: COMPOSE_* -> .env, PHP_* -> .env.php,
#   NGINX_* -> .env.nginx, MARIADB_* -> .env.mariadb.

# 5. Match the bundled MariaDB credentials to the existing data dir.
$EDITOR .env.mariadb
# MARIADB_USER / MARIADB_PASSWORD / MARIADB_DATABASE / MARIADB_ROOT_PASSWORD MUST equal the
# values baked into the carried-over data dir (i.e. what 1.x used, and what DATABASE_URL
# encodes). On a non-empty data dir the mariadb entrypoint IGNORES these — it does not
# re-initialise — so a mismatch does not error at container start; it surfaces later as
# Doctrine/tooling auth failures. Set them to the 1.x values.

# 6. Traefik: re-run the interactive setup, or edit .env.traefik by hand.
task env:traefik

# 7. Spot any keys the pinned image added that you haven't set.
task env:diff
```

<details>
<summary>Manual fallback (no `.env.symfony.migrated` — pre-2.8 images, or stack already stopped)</summary>

If you never produced `.env.symfony.migrated` (the 1.x install predates the converter, or the
stack was already down), `task env:migrate` falls back to a sed conversion of `.env.docker.local`:
it strips the `APP_` prefix from every key except the framework-defined trio (`APP_ENV` /
`APP_SECRET` / `APP_DEBUG`) and writes `.env.symfony.migrated`. This path **cannot** see the
admin/client `config.json`, so you also convert those by hand and apply the per-site renames the
converter would have done:

```bash
task env:migrate                                  # sed path when .env.symfony.migrated is absent
diff -u .env.docker.local .env.symfony.migrated
$EDITOR .env.symfony.migrated
```

- Strip any 1.x compose-orchestration block (`COMPOSE_*`, `INTERNAL_*`) from the top — those
  belong in `.env` (`COMPOSE_PROJECT_NAME` / `COMPOSE_PROFILES`), not `.env.symfony`.
- Rename per-site customisation keys to their v3 prefixes:

  ```text
  TOUCH_BUTTON_REGIONS    → ADMIN_TOUCH_BUTTON_REGIONS
  REJSEPLANEN_API_KEY     → ADMIN_REJSEPLANEN_APIKEY
  SHOW_SCREEN_STATUS      → ADMIN_SHOW_SCREEN_STATUS
  DATA_PULL_INTERVAL      → CLIENT_PULL_STRATEGY_INTERVAL
  SCHEDULING_INTERVAL     → CLIENT_SCHEDULING_INTERVAL
  ```

- Convert your old admin/client `config.json` with the 3.x command (after first boot, or in a
  one-off container): `bin/console app:utils:convert-config-json-to-env --type=admin <path>`
  and `--type=client <path>`.

The image's bundled `.env` supplies sane `ADMIN_*` / `CLIENT_*` defaults; the renames above are
only needed for keys you'd customised in 1.x. Then `mv .env.symfony.migrated .env.symfony` and
rejoin the main path at step 2 (`task env:init`).

</details>

#### Media upload size: align all three layers

v3 adds an app-level cap on media uploads, `MEDIA_MAX_UPLOAD_SIZE_MB` (default `200`,
in MiB), enforced by the Symfony validator on `Media::$file`. Because uploads cross
nginx → PHP-FPM → Symfony, all three layers must agree, or the lowest wins (and the
operator sees a confusing 413 / `UPLOAD_ERR_INI_SIZE` instead of the app's clear
"file exceeds N MiB" error). Defaults shipped in `.env.php.example` and
`.env.nginx.example` are aligned to `200`; if you've customised any of them, keep
the inequality intact:

```text
NGINX_MAX_BODY_SIZE  >=  PHP_POST_MAX_SIZE  >=  PHP_UPLOAD_MAX_FILESIZE  >=  MEDIA_MAX_UPLOAD_SIZE_MB
```

`MEDIA_MAX_UPLOAD_SIZE_MB` comes from the image's bundled `.env`, which `task env:init` extracts
into `.env.symfony` (the converter export carries it too). Verify with `task env:diff` after
`env:init` — if the diff shows the key only on the image side, copy the line over by hand.

### Step 4 — Upgrade MariaDB 10.x to 11.4

The bundled MariaDB is `mariadb:11.4.10` in 3.x (was `mariadb:10.x` in 1.x). The 3.x mariadb
service sets `MARIADB_AUTO_UPGRADE=1`, so the system-table upgrade runs automatically; you just
bring the new image up against the carried-over data and verify.

```bash
# 1. Confirm the backup from the pre-upgrade checklist is recent and readable.
ls -lh backup/ db_backups/ 2>/dev/null                  # 1.x writes to db_backups/
gunzip -t backup/<the latest>.sql.gz 2>/dev/null || true

# 2. Confirm the data volume carried over and the project name matches.
#    A mismatched COMPOSE_PROJECT_NAME resolves a DIFFERENT (empty) volume — the
#    stack would come up green with no data. The name below must be the one
#    task upgrade_check recorded on 1.x.
docker volume ls | grep mariadb

# 3. Pull the new image and start the DB container alone. With MARIADB_AUTO_UPGRADE=1 the
#    entrypoint version-compares the data dir and runs mariadb-upgrade before accepting
#    connections; on a large database this can take a while, so watch the log.
docker compose pull mariadb
docker compose up -d mariadb
docker compose logs -f mariadb                          # wait for the upgrade to finish and
                                                        # "ready for connections"

# 4. Optional explicit re-run / verification. Idempotent — a no-op if the auto-upgrade already
#    ran.
task db:upgrade
```

Then confirm the `DATABASE_URL` `serverVersion` edit from step 3 reads `11.4.10-MariaDB`.
Doctrine uses it to pick its SQL dialect; a mismatch produces wrong queries (most often
incorrect JSON or function syntax).

If the upgrade reports incompatible objects, **stop here.** Restore from the dump, revert the
mariadb image tag, and debug on a non-prod box. The common cause is custom stored procedures or
views with reserved-word identifiers in 11.4 that were valid in 10.x — Doctrine + Symfony won't
typically have any, but custom feed types and admin commands sometimes do.

### Step 5 — First boot

```bash
task install                  # pulls the rest of the images, runs `bin/console app:update`
                              # (Doctrine migrations + cache:warmup) in a one-off container
                              # BEFORE bringing the web tier up, then brings up the full
                              # stack, ensures the JWT keypair matches JWT_PASSPHRASE
                              # (regenerating only on mismatch), and interactively prompts
                              # for tenant + admin user (skip these if you already have
                              # them — your old data is still there).
```

`task install` reuses the existing data: the bundled mariadb's named volume from 1.x carries
across, and `app:update` applies any net-new migrations from 3.x on top. It runs that migration
in a one-off `compose run` container (starting only the DB/redis dependencies) **before** the
nginx/screen-client tier comes up, so the stack never serves traffic against an un-migrated
schema. The interactive tenant + user prompts can be skipped (Ctrl-D) if your existing tenants /
admin user are already in the data.

### Post-upgrade validation

Walk through these checks in order. Any failure → roll back from the backup before debugging
further.

- [ ] `docker compose ps` shows all profile-active services `healthy`.
- [ ] `https://<your-domain>/admin/` loads the admin UI. **It's now served from the os2display
      container, not a separate admin container** — confirms the v2 admin/client route-stealing
      is gone.
- [ ] Log in as your existing admin user. Authentication works against the upgraded JWT keys
      and OIDC config.
- [ ] Open an existing slide; thumbnails render. If they 404, check `./media` permissions
      (UID 1042 owner, group-readable for UID 101 nginx — see
      [README § Prerequisites](README.md#prerequisites)).
- [ ] `https://<your-domain>/client/` loads the screen client, can authenticate as a screen,
      pulls and displays content.
- [ ] (If you exposed it) `https://<traefik-host>/traefik/dashboard/` loads after basic-auth.
- [ ] `task logs` for 5 minutes — no recurring errors.

### Rollback

If validation fails and the issue isn't an obvious env-config typo:

```bash
task purge                              # WIPES the bundled mariadb data volume — required
                                        # because we're about to restore from backup. ALSO
                                        # wipes the redis cache (harmless; it rebuilds).
                                        # Does NOT touch ./media or ./jwt — those are
                                        # bind mounts, preserved through compose lifecycle.
rm -f docker-compose.yml                # 3.x tracks it; remove before checking out 1.x
git checkout <previous 1.x ref>         # the tag or branch you came from

# Restore the 1.x env files first — `task up` regenerates the 1.x compose file
# (task _dc_compile) from them, and the restore below reads credentials from
# .env.docker.local. jwt/ and media/ are still on disk; nothing to copy back.
cp /tmp/os2display-1x-backup/.env.docker.local .
cp /tmp/os2display-1x-backup/.env.local .                     # if it existed

task up                                 # 1.x: regenerates docker-compose.yml and starts the
                                        # stack with a fresh (empty) mariadb volume
docker compose -f docker-compose.yml logs -f mariadb   # wait for "ready for connections"

# Load the dump taken in the pre-upgrade checklist. `task backup_db` (1.x) writes a plain,
# single-database SQL file to db_backups/ — restore it into that same database.
docker compose -f docker-compose.yml exec -T mariadb \
  mariadb -u root -p"$(grep ^MARIADB_ROOT_PASSWORD= .env.docker.local | cut -d= -f2-)" \
  "$(grep ^MARIADB_DATABASE= .env.docker.local | cut -d= -f2-)" \
  < /path/to/db_backups/db_backup_<ts>.sql

task cc                                 # clear the 1.x app cache against the restored data
```

What survives the rollback in place:

- **`./media/`** — host bind-mount, untouched by `task purge`. The restored v1 database's
  filename references still point at the same files on disk. Any uploads or thumbnail-cache
  rebuilds that happened during the brief v3 test window are orphaned but harmless on the
  v1 side (v1's LiipImagineBundle regenerates its own cache as needed).
- **`./jwt/`** — host bind-mount. Same JWT keys before and after.
- **`traefik/letsencrypt/`** — bind-mount. Existing LE certs still valid.

What gets destroyed and restored:

- **MariaDB** — named volume, removed by `task purge`, restored by loading the dump back in.
  **This is why the database backup in the pre-upgrade checklist is non-negotiable** — without
  it, the rollback path can't reach v1's data.
- **Redis cache** — named volume, removed and rebuilt empty. v1 application repopulates on
  first request.

Don't try to roll back without restoring the dump — `app:update`'s 3.x migrations may have
applied schema changes that 1.x's `app:update` doesn't reverse, so a "tag revert + bring the
3.x-mutated DB up under 1.x" path will fail silently (wrong queries, missing columns) or
loudly (Doctrine refusing to start). Note too that once 11.4 has upgraded the data dir in place
(step 4), the 10.x server can no longer read it — the rollback restores the dump into a fresh
volume rather than reusing the upgraded files.

## Future migrations

When 4.0 (or some later major) ships, an analogous section will land here. The pattern is the
same: pre-flight, backup, env restructure if any, image upgrades, run migrations, validate,
rollback recipe.
