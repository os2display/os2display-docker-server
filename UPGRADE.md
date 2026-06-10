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

### What's changed at a glance

The full breaking-change list is in [CHANGELOG.md](CHANGELOG.md) under
`[Unreleased] — release/3.0.0`. The handful of changes that matter most for this migration:

- **API + admin + screen-client are one image.** v1 had three images (`os2display-api-service`,
  `os2display-admin-client`, `os2display-client`). v3 bundles the admin UI and screen client
  into the API image and serves them as Symfony routes (`/admin`, `/client`). The two separate
  services + their `OS2DISPLAY_VERSION_ADMIN` / `OS2DISPLAY_VERSION_CLIENT` pins are gone.
- **Symfony env vars lose the `APP_` prefix** (except `APP_ENV` and `APP_SECRET`, which Symfony
  defines). `APP_DATABASE_URL` becomes `DATABASE_URL`, `APP_JWT_PASSPHRASE` becomes
  `JWT_PASSPHRASE`, etc. Full 56-key rename list in upstream `display-api-service`'s `UPGRADE.md`
  § 2.1; `task env:migrate` performs the rename automatically.
- **One env file per service.** The single `.env.docker.local` is gone, replaced by
  `.env.symfony` + `.env.php` + `.env.nginx` + `.env.mariadb` + `.env.traefik` + the
  compose-orchestration `.env`. See [README § Configuration files](README.md#configuration-files).
- **MariaDB 10.x → 11.4 LTS.** Major version bump. Binary-compatible at the data file level
  (MariaDB 11 reads 10.x InnoDB tablespaces) but requires `mariadb-upgrade` and a `serverVersion`
  update in `DATABASE_URL`.
- **Compose profiles replace `INTERNAL_DATABASE` / `INTERNAL_PROXY`.** Use
  `COMPOSE_PROFILES=mariadb,traefik` (default), or drop a token to run with external infra.
- **Image registry switched** from `itkdev/os2display-*` (Docker Hub) to
  `ghcr.io/os2display/display-api-service{,-nginx}` (GHCR).

### Step-by-step

#### 1. Pre-flight

On the production host, before touching anything:

```bash
# Confirm prerequisites are in place.
docker --version              # 20.10+
docker compose version        # v2 (the integrated subcommand, not legacy docker-compose)
task --version                # v3+
id                            # confirm UID 1042 / GID 1042 if you've followed the README

# Confirm the host has disk headroom for backups.
df -h .
```

Read the [Caveats and foot-guns](README.md#caveats-and-foot-guns) section in the README before
proceeding. The cert-file SAN-coverage caveat and the `DATABASE_URL` `serverVersion=` caveat
in particular bite operators on this migration.

#### 2. Take backups

```bash
# Database — full dump, gzipped, online (no service downtime).
task db:backup
ls -lh backup/
# 20260505T141522Z.sql.gz

# Env files + JWT keys — copy aside in case a rollback is needed.
mkdir -p /tmp/os2display-1x-backup
cp .env .env.docker.local .env.local /tmp/os2display-1x-backup/  # whatever subset you have
cp -r jwt/ /tmp/os2display-1x-backup/
```

You do **not** need to copy `./media/` aside for the rollback. It's a host bind-mount, not a
docker named volume — `task purge`, `task down --volumes`, and `docker compose down --volumes`
all leave it on disk. The `./media` directory survives the upgrade-then-rollback round-trip in
place; the v1 database dump's filename references still match the files on disk after a
restore.

That said, the media bind-mount is also where uploaded user data lives. If you have a snapshot
tool (LVM, ZFS, btrfs, cloud volume snapshots), take a host-level snapshot here for paranoia
— protects against unrelated disk failures during the maintenance window, not against the
upgrade itself. Same for `./jwt/`: bind-mounted, preserved across compose lifecycle, but a
copy aside in `/tmp/os2display-1x-backup/` is cheap.

#### 3. Stop the 1.x stack

```bash
task stop                     # bring containers down; preserves volumes
```

Don't run `task purge` or `task down --volumes` — those delete the database.

#### 4. Update the repo

```bash
git fetch
git checkout release/3.0.0
```

#### 5. Rewrite env config

The 1.x layout was a single `.env.docker.local` consumed by compose substitution. v3 uses
per-service `env_file:` directives. Walk the new layout once:

| File | Purpose |
|---|---|
| `.env` | Compose orchestration: project name, profile, image versions, server domain. |
| `.env.symfony` | Symfony app config for the os2display container. |
| `.env.php` | PHP-FPM runtime tuning. |
| `.env.nginx` | Nginx runtime tuning. |
| `.env.mariadb` | MariaDB credentials. |
| `.env.traefik` | Traefik dashboard auth, Let's Encrypt email, cert provider. |

Bootstrap each:

```bash
# Compose orchestration: copy from the example, then port over your old domain, image
# versions, and (the renamed) profile selection.
cp .env.example .env
$EDITOR .env
# OS2DISPLAY_SERVER_DOMAIN=...                  (was COMPOSE_SERVER_DOMAIN in 1.x)
# OS2DISPLAY_VERSION_API=<latest 3.x tag>       (was COMPOSE_VERSION_API; see
#                                                .env.example for the current pin)
# COMPOSE_PROFILES=mariadb,traefik              (replaces INTERNAL_DATABASE=true and
#                                                INTERNAL_PROXY=true; combine into a profile
#                                                list)

# Symfony app config: convert your old .env.docker.local. task env:migrate strips the
# APP_ prefix from every key except the framework-defined trio (APP_ENV / APP_SECRET /
# APP_DEBUG, all of which Symfony recognises by name), writing the result to
# .env.symfony.migrated for review.
task env:migrate
diff -u .env.docker.local .env.symfony.migrated      # sanity check
$EDITOR .env.symfony.migrated
# - Strip any 1.x compose-orchestration block at the top of the file
#   (COMPOSE_PROJECT_NAME, COMPOSE_VERSION_API, COMPOSE_SERVER_DOMAIN,
#    INTERNAL_DATABASE, INTERNAL_PROXY). Those don't belong in .env.symfony —
#   their v3 equivalents live in .env (created above).
# - Set DATABASE_URL serverVersion to "11.4.10-MariaDB" (post-MariaDB upgrade — see step 6).
# - Rename per-site customisation keys to their v3 prefixes (the script can't
#   infer this — only the APP_ → bare-name strip is automatic):
#     TOUCH_BUTTON_REGIONS    → ADMIN_TOUCH_BUTTON_REGIONS
#     REJSEPLANEN_API_KEY     → ADMIN_REJSEPLANEN_APIKEY
#     SHOW_SCREEN_STATUS      → ADMIN_SHOW_SCREEN_STATUS
#     DATA_PULL_INTERVAL      → CLIENT_PULL_STRATEGY_INTERVAL
#     SCHEDULING_INTERVAL     → CLIENT_SCHEDULING_INTERVAL
# - The image's bundled .env supplies sane ADMIN_* / CLIENT_* defaults; the renames
#   above are only needed for keys you'd customised in 1.x.
mv .env.symfony.migrated .env.symfony

# Run `task env:diff` after editing to spot any keys upstream added that you haven't set.

# Per-service runtime config + Traefik: task env:init creates the per-service env files
# (.env.php, .env.nginx, .env.mariadb, .env.traefik) from .env.<svc>.example. It detects
# .env.symfony already exists from env:migrate and skips it (no FORCE=1 needed).
task env:init

$EDITOR .env.mariadb
# Match credentials to the user/password/database in your old .env.docker.local —
# they MUST equal the user / password / db in DATABASE_URL above. Mismatched credentials
# means Doctrine can't connect, AND mariadb won't re-initialise its data dir with new ones.

# Traefik: re-run the interactive setup task, or edit .env.traefik by hand.
task env:traefik
```

##### Media upload size: align all three layers

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

`task env:migrate` carries `MEDIA_MAX_UPLOAD_SIZE_MB` over from the image's bundled
`.env`, so it lands in `.env.symfony` automatically. Verify with `task env:diff` after
`env:init` — if the diff shows the key only on the image side, your migrated file
predates this var and you should copy the line over by hand.

#### 6. MariaDB 10.x → 11.4 upgrade

The bundled MariaDB is `mariadb:11.4.10` in 3.x (was `mariadb:10.x` in 1.x). Three things must
happen for a clean cut:

```bash
# 1. Backup is done from step 2. Verify it's recent and readable:
ls -lh backup/
gunzip -t backup/<the latest>.sql.gz                    # checks gzip integrity

# 2. Pull the new mariadb image, restart the DB container alone, run mariadb-upgrade.
docker compose pull mariadb
docker compose up -d mariadb
docker compose logs -f mariadb                          # wait for "ready for connections"

task db:upgrade                                         # idempotent; also auto-runs by the
                                                        # mariadb image entrypoint on first
                                                        # start with new data, but explicit
                                                        # is better here.

# 3. The DATABASE_URL serverVersion edit in .env.symfony from step 5 above must match
#    11.4.10-MariaDB now. Doctrine reads it to pick its SQL dialect; mismatch → wrong
#    queries (most often: incorrect JSON or function syntax).
```

If `task db:upgrade` reports incompatible objects, **stop here**. Restore from the dump (step
2), revert the mariadb image tag in `docker-compose.yml`, and debug on a non-prod box. The
common cause is custom stored procedures or views with reserved-word identifiers in 11.4 that
were valid in 10.x — Doctrine + Symfony won't typically have any, but custom feed types and
admin commands sometimes do.

#### 7. First boot

```bash
task install                  # pulls the rest of the images, runs `bin/console app:update`
                              # (Doctrine migrations + cache:warmup) in a one-off container
                              # BEFORE bringing the web tier up, then brings up the full
                              # stack, generates the JWT keypair if missing, and interactively
                              # prompts for tenant + admin user (skip these if you already
                              # have them — your old data is still there).
```

`task install` reuses the existing data: the bundled mariadb's named volume from 1.x carries
across, and `app:update` applies any net-new migrations from 3.x on top. It runs that migration
in a one-off `compose run` container (starting only the DB/redis dependencies) **before** the
nginx/screen-client tier comes up, so the stack never serves traffic against an un-migrated
schema. The interactive tenant + user prompts can be skipped (Ctrl-D) if your existing tenants /
admin user are already in the data.

#### 8. Validation

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
git checkout <previous 1.x ref>         # the tag or branch you came from
docker compose up -d mariadb            # bring up the OLD mariadb alone
docker compose logs -f mariadb          # wait for "ready for connections"

# Restore the dump.
gunzip < /path/to/backup/<the dump>.sql.gz \
  | docker compose exec -T mariadb mariadb -u root -p"$(grep ^MARIADB_ROOT_PASSWORD= .env.docker.local | cut -d= -f2-)"

# Restore the rest of your old config (jwt/ and media/ are still on disk —
# nothing to copy back).
cp /tmp/os2display-1x-backup/.env.docker.local .
cp /tmp/os2display-1x-backup/.env.local .                     # if it existed

# Bring the rest of the 1.x stack up.
task install                            # under the 1.x release that's now checked out
```

What survives the rollback in place:

- **`./media/`** — host bind-mount, untouched by `task purge`. The restored v1 database's
  filename references still point at the same files on disk. Any uploads or thumbnail-cache
  rebuilds that happened during the brief v3 test window are orphaned but harmless on the
  v1 side (v1's LiipImagineBundle regenerates its own cache as needed).
- **`./jwt/`** — host bind-mount. Same JWT keys before and after.
- **`traefik/letsencrypt/`** — bind-mount. Existing LE certs still valid.

What gets destroyed and restored:

- **MariaDB** — named volume, removed by `task purge --volumes`, restored by piping the dump
  back in. **This is why `task db:backup` at step 2 is non-negotiable** — without it, the
  rollback path can't reach v1's data.
- **Redis cache** — named volume, removed and rebuilt empty. v1 application repopulates on
  first request.

Don't try to roll back without restoring the dump — `app:update`'s 3.x migrations may have
applied schema changes that 1.x's `app:update` doesn't reverse, so a "tag revert + bring the
3.x-mutated DB up under 1.x" path will fail silently (wrong queries, missing columns) or
loudly (Doctrine refusing to start).

## Future migrations

When 4.0 (or some later major) ships, an analogous section will land here. The pattern is the
same: pre-flight, backup, env restructure if any, image upgrades, run migrations, validate,
rollback recipe.
