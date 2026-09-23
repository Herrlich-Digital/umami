# Upgrade Herrlich-Digital/umami fork to upstream v3.4.0

## Context

The fork's `master` has been stuck on `v3.0.3` since 17.07.2026 — 1235 commits
behind upstream. A prior attempt (`upgrade/umami-3.2.0`, with a design spec
and deploy runbook dated 17.07.2026) merged upstream `v3.2.0` locally but was
never pushed, reviewed, or deployed.

This upgrade was picked back up on 23.09.2026 while debugging a real, live
bug: the Umami MCP tool `get_event_data_values` (used daily for Sharry
analytics) was returning the same aggregated numbers regardless of which
`eventName` was requested — e.g. querying `webrtc-connected` and
`webrtc-connection-failed` for the `stun_reachable` property returned
identical values. Root-caused to the self-hosted API itself, not the MCP
client: in `v3.0.3`, `src/queries/sql/events/getEventDataValues.ts`'s
relational (PostgreSQL) query variant never joined on `website_event.event_name`
at all — the parameter didn't exist in the function signature. Commit
`00c02735` ("fix clickhouse filtering on event_name", 01.05.2026) added it
correctly; that commit is included starting `v3.2.0` (confirmed via
`gh api .../compare/v3.1.0...00c02735` = ahead, `.../compare/v3.2.0...00c02735`
= behind).

## Decision: target v3.4.0, not v3.2.0

The already-merged `upgrade/umami-3.2.0` branch gets the fix above, but going
further to the current latest release (`v3.4.0`, 17.09.2026) was chosen
instead of stopping at `v3.2.0`, because:

- It was explicitly asked for ("einige neue Features sind dazugekommen").
- The 6 additional Prisma migrations between `v3.2.0` and `v3.4.0`
  (`21_add_session_link` .. `26_add_api_key`) are all additive — no `DROP`/
  `RENAME`, checked against the upstream diff — so there's no repeat of the
  `v3.2.0` upgrade's `share_id`-drop trap.
- Upstream `v3.4.0` ships an official `@umami/mcp` + `@umami/api-client`
  package pair — a first-party Umami MCP server. This is a plausible
  replacement for the third-party `@mikusnuz/umami-mcp` currently in use,
  which is the tool that surfaced this whole investigation. Not adopted in
  this PR (out of scope — a separate MCP-config change, done by Christoph, not
  a code change to this repo), but worth evaluating once this deploy lands.

## What changed vs. the 17.07.2026 plan

- Target release: `v3.4.0` instead of `v3.2.0` (see above).
- Conflict surface: still only `Dockerfile` (one hunk — upstream added `COPY`
  steps for the two new workspace packages' `package.json`/`bin` so
  `pnpm install --frozen-lockfile` in the `deps` stage can resolve them).
  `package.json` merged cleanly this time (no conflict), unlike the `v3.2.0`
  attempt.
- New: two workspace packages (`packages/api-client`, `packages/mcp`) need
  their own `tsup` build step. This is already wired into the root
  `pnpm run build` / `build:docker` scripts upstream added
  (`build:packages` step) — no fork-specific change needed, just something to
  be aware of if debugging a build failure that looks like a missing
  `@umami/api-client` import.
- Script names changed from hyphens to colons upstream (`build-docker` →
  `build:docker`, etc.) between the fork's baseline and now. Anyone reusing
  old command snippets (including from the 17.07.2026 docs) needs to update
  them.
- pnpm engine requirement bumped from `10.15.1` to `12.3.4` in the Dockerfile
  (`ARG PNPM_VERSION`). `pnpm test` enforces this via `engines.pnpm` and fails
  hard on a mismatch — install the pinned version locally before validating.

## Validation performed (23.09.2026, in a local git worktree, no production access)

All run against `DATABASE_URL="postgresql://user:pass@localhost:5432/dummy"`
(same dummy value the Dockerfile's `builder` stage uses — sufficient for
`prisma generate` and static generation, no real DB needed):

| Step | Result |
|---|---|
| `pnpm install` | clean |
| `pnpm build:docker` | passes — builds both new workspace packages, then `next build --turbo`, all 70 pages generate |
| `pnpm test` | **118 test files / 882 tests pass** |
| `pnpm lint` | 6 errors, all inside brand-new upstream code (Boards, Recorder route, new SVG icon assets) that this fork never touched — not a regression from this merge. Plus one pre-existing false-positive (`not-found.tsx`, an anonymous default-exported page component that Biome's `useHookAtTopLevel` rule doesn't recognize as a component) already present in `v3.2.0`. |

Not validated (needs Fly/S3 credentials this session doesn't have — see "Still
needed" below): restoring a real backup into a throwaway Postgres and running
`prisma migrate deploy` against it end-to-end.

## Rollback plan

Unlike the `v3.2.0` upgrade's `share_id`-drop trap, no migration between the
fork's current production schema and `v3.4.0` drops or renames a column the
currently-deployed `v3.0.3` code depends on (checked the full migration diff,
`v3.0.3` → `v3.4.0`, for `DROP`/`RENAME`/destructive `ALTER`). This means a
plain image rollback (redeploy the previous Fly release) stays a valid escape
hatch even after the migrations run — a meaningfully lower-risk profile than
the `v3.2.0` plan had to account for. Still take a fresh manual backup
immediately before deploying regardless (see "Still needed").

## Backup strategy — decided 23.09.2026: local pg_dump, not S3/Tigris

The `fly.backup.toml` / `docker/backup/backup.sh` S3-cron setup from
17.07.2026 was never actually deployed (`fly apps list` after logging in
confirmed only `umami-falling-waterfall-1667` and `-db` exist, no
`-backup` app). Rather than set up recurring off-site backups (would need a
new AWS account + IAM user, or a Fly Tigris bucket) for what is a one-time
pre-deploy safety net, Christoph chose the simpler option: a single manual
`pg_dump` taken right before the deploy, stored locally.

Done on 23.09.2026:
```
fly proxy 5433:5432 -a umami-falling-waterfall-1667-db &
PGPASSWORD=<from `fly ssh console -a umami-falling-waterfall-1667 -C "printenv DATABASE_URL"`> \
  pg_dump -h localhost -p 5433 -U umami -d umami --no-owner --no-acl --format=plain \
  | gzip -9 > backups/backup-pre-v3.4.0-upgrade-<timestamp>.sql.gz
```
Result: `backups/backup-pre-v3.4.0-upgrade-2026-09-23T11-07-02Z.sql.gz` (5.8MB,
14 tables, gzip-verified). `backups/` is gitignored (commit `a70b45696` on
`master`) — never commit a raw DB dump.

**Restore procedure, if the deploy needs to be rolled back to data:**
```
fly proxy 5433:5432 -a umami-falling-waterfall-1667-db &
gunzip -c backups/backup-pre-v3.4.0-upgrade-<timestamp>.sql.gz \
  | PGPASSWORD=<same password> psql -h localhost -p 5433 -U umami -d umami
```
This only matters for scenario B in the rollback decision tree below (a
migration actually changed data in an incompatible way) — given the "no
DROP/RENAME" finding above, this branch shouldn't trigger, but the backup
exists in case something unexpected happens anyway.

**Not set up, and intentionally deferred:** recurring automated backups
(S3/Tigris cron). If this deploy goes well and the fork stays on a
current-ish version going forward, revisit whether a recurring backup is
worth the setup cost — for now, a fresh manual `pg_dump` before each future
upgrade is the accepted tradeoff.

## Still needed before this can go to production (needs Christoph)

1. **Review [PR #6](https://github.com/Herrlich-Digital/umami/pull/6)** —
   the actual diff, not just this doc.
2. **Deploy**: `git checkout master && git merge --no-ff upgrade/umami-3.4.0
   && git push && fly deploy -a umami-falling-waterfall-1667`, then watch logs
   per the runbook's "Monitor immediately after" section.
3. **After deploy**: re-verify the original bug is actually fixed — query
   `get_event_data_values` for two Sharry events that share a property name
   (e.g. `webrtc-connected` vs. `webrtc-connection-failed`, property
   `stun_reachable`) and confirm the two calls now return different numbers.
4. **Optional follow-up, not part of this PR**: evaluate switching the Umami
   MCP config from `@mikusnuz/umami-mcp` (third-party) to upstream's own
   `@umami/mcp` package now that it's available — separate task, no code
   change needed in this repo, just an MCP server config change wherever
   Christoph's Umami MCP is registered.
