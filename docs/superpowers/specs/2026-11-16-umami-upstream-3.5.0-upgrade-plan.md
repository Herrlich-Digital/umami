# Upgrade Herrlich-Digital/umami fork to upstream v3.5.0

## Why

Production runs `v3.4.0` (deployed 23.09.2026, Fly release v18). `v3.4.0` ships
a Next.js version with a critical RCE that upstream fixed in `v3.4.1`
(security hotfix, no migration). `v3.5.0` (12.11.2026) includes that fix, so we
go straight to `v3.5.0`.

## What the merge looks like

- `git merge v3.5.0` into the fork: 306 upstream commits, one conflict in
  `.gitignore` (our `backups/` line vs. upstream's `/.review-pr-*/`, kept both).
- `Dockerfile`, `fly.toml`, `.dockerignore`, the `release_command` fix and
  `MCP_ENABLED=1` from the 3.4.0 upgrade all survive unchanged.
- Upstream Dockerfile now pins `node:22.23.4-alpine` (Node security release;
  3.5.0 needs Node 20.19+) and applies the pnpm security overrides in the
  runner stage.
- Next.js `16.3.4` → `16.4.2`.

## Breaking changes and what they mean for us

| Change in 3.5.0 | Impact here |
|---|---|
| `APP_SECRET` is required, no fallback to `DATABASE_URL` (app refuses to start) | **Must be set as Fly secret before deploy** (see below) |
| Migration `27_add_error_tracking` | Additive only: 3 new tables (`error_issue`, `error_event`, `error_rate_limit`), no `DROP`/`RENAME`. Runs via `release_command` (`pnpm exec prisma migrate deploy`). Image rollback stays possible. |
| `/api/config` removed | Not used by the tracker or by our sites (no reference in `src/`). |
| Default admin must change the seed password | Only if the `admin` account still has the seed password `umami`. |
| 2FA enforced server-side | Only matters if 2FA is set to "required". |
| MCP needs `MCP_ENABLED=1` | Already set in `fly.toml` since 23.09. API keys are hashed without `APP_SECRET`, so the MCP key keeps working. |

## APP_SECRET: why the value matters

`secret()` = `hash(APP_SECRET)` feeds into:

- session IDs (`uuid(website, ip, userAgent, salt)` hashes in the secret),
- dashboard login tokens, share tokens and the tracker cache token.

In 3.4.0 the effective secret is `APP_SECRET || DATABASE_URL`.

- **If `APP_SECRET` is already set on Fly:** nothing to do.
- **If it is not set** (likely, the fly.toml never mentions it), there are two ways:
  - **A (recommended now):** set `APP_SECRET` to the exact current
    `DATABASE_URL` value. The effective secret stays identical: no new session
    IDs, nobody is logged out, November numbers stay clean.
  - **B (optional, on/after 01.12.):** rotate to a random value
    (`openssl rand -hex 32`). The monthly salt resets all session IDs on the
    1st anyway, so rotating then costs nothing in the statistics, only a
    re-login in the dashboard.
  - Rotating to a random value mid-month would count every returning visitor
    of November a second time (new session ID) and log everyone out.

## Steps

1. **Backup (Christoph, on GLaDOS):** fresh `pg_dump`, same as 23.09.:
   ```
   fly proxy 5433:5432 -a umami-falling-waterfall-1667-db &
   PGPASSWORD=<password from DATABASE_URL> \
     pg_dump -h localhost -p 5433 -U umami -d umami --no-owner --no-acl --format=plain \
     | gzip -9 > backups/backup-pre-v3.5.0-upgrade-$(date -u +%Y-%m-%dT%H-%M-%SZ).sql.gz
   gunzip -t backups/backup-pre-v3.5.0-upgrade-*.sql.gz
   ```
2. **APP_SECRET (Christoph):**
   ```
   fly secrets list -a umami-falling-waterfall-1667     # APP_SECRET listed?
   # if not (option A), stage it so it applies with the deploy:
   fly secrets set --stage -a umami-falling-waterfall-1667 \
     APP_SECRET="$(fly ssh console -a umami-falling-waterfall-1667 -C 'printenv DATABASE_URL')"
   fly secrets list -a umami-falling-waterfall-1667     # check it is there (staged)
   ```
3. **Merge the PR into `master`** → GitHub Action `fly-deploy.yml` deploys.
   Migration 27 runs in the release machine; if it fails, the old release
   keeps serving (same as v17 on 23.09.).
4. **Check right after the deploy:**
   - `fly logs -a umami-falling-waterfall-1667`: "27 migrations found",
     no `APP_SECRET must be set` error.
   - Dashboard login on analytics.herrlichdigital.de works, version 3.5.0 in the footer/settings.
   - Realtime view: page views arrive for Sharry, Herrlich Digital, Wichtelzeit.
   - "AI Bots" website: next `ai-bot-visit` event arrives (server-side, Herrlich Digital / Wichtelzeit).
   - Umami MCP on GLaDOS: one query (e.g. stats for Sharry today) returns data.
5. **Rollback:** `fly releases -a umami-falling-waterfall-1667`, then
   `fly deploy -a umami-falling-waterfall-1667 --image <image of the previous release>`.
   Migration 27 only adds tables, 3.4.0 ignores them. DB restore from the backup
   only if something unexpected happens.

## Validation (16.11.2026, cloud session, no production access)

See the PR description for `pnpm test` and `pnpm build:docker` results.
