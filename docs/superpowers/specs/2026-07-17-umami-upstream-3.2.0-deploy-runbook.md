# Deploy runbook: merging PR #5 (upstream v3.2.0 upgrade) to production

This supersedes the "Rollback plan" section of
`2026-07-17-umami-upstream-3.2.0-upgrade-design.md`, which assumed a plain
image rollback would always be safe. It isn't — see below.

## Why this isn't a simple "merge, and roll back if it breaks"

`prisma migrate deploy` runs automatically as part of the app's startup
(`scripts/check-db.js`, invoked by `start-docker`), and Fly also runs it as a
separate `release_command` step before updating the app machine. Of the 6 new
migrations, 5 are safe (additive, or touch tables that don't exist yet on the
old schema). One is not:

- `15_add_share/migration.sql` runs `ALTER TABLE "website" DROP COLUMN
  "share_id"`. The **currently deployed** app code (v3.0.3) actively reads
  `share_id` in `/api/websites`, `/api/websites/[websiteId]`,
  `WebsiteSettings.tsx`, `WebsiteShareForm.tsx`, the `/share/[...shareId]`
  pages, and `useShareTokenQuery.ts`.

Consequence: once this migration has run, redeploying the *old* image does
**not** restore the old behavior — the old code will error on every code path
that touches `share_id`, most importantly the website API routes. A plain
"redeploy previous image" rollback only works cleanly if the migration step
itself never ran (see decision tree below).

## Fly's existing safety net (already true today, no action needed)

Confirmed empirically during today's incident: Fly runs `prisma migrate
deploy` as an isolated one-off `release_command` machine *before* touching the
running app machine. If that step fails, Fly does not proceed to update the
app machine — the old version keeps serving traffic throughout. So a failed
migration is already safe by default. The risk this runbook is for is the
migration *succeeding* and something else breaking afterward.

## Pre-deploy checklist

1. Confirm PR #5 has been reviewed and approved.
2. Take a fresh manual backup (don't rely solely on the daily cron):
   ```
   fly ssh console --app umami-falling-waterfall-1667-backup -C /usr/local/bin/backup.sh
   ```
3. Note the current release image, so the exact rollback target is known
   ahead of time:
   ```
   fly releases -a umami-falling-waterfall-1667 --json | head -20
   ```
4. Pick a low-traffic window if minimizing lost analytics events during the
   ~10-15s restart matters. The instance runs on a single pinned Fly machine
   (deliberate design choice, no redundancy), so every deploy has a brief
   real gap regardless of timing — check your own umami dashboard's
   hourly/realtime chart for your tracked sites' actual quiet hours rather
   than guessing; this agent has no visibility into your traffic without
   querying production data directly, which was intentionally not done.

## Deploy

```
git checkout master && git pull
git merge --no-ff upgrade/umami-3.2.0   # or merge the PR via GitHub UI
git push origin master
fly deploy -a umami-falling-waterfall-1667
```

## Monitor immediately after

```
fly logs -a umami-falling-waterfall-1667 --no-tail
fly status -a umami-falling-waterfall-1667
curl -s -o /dev/null -w "HTTP: %{http_code}\n" https://umami-falling-waterfall-1667.fly.dev
```

Watch for: the release_command's migration output (should list `15_add_share`
through `20_add_heatmap` applying cleanly), then the app machine reaching
`started` state, then a sustained HTTP 200 (check twice, ~15-20s apart, to
rule out a crash-loop restart being mistaken for success — this is exactly
what happened during today's incident).

## Rollback decision tree

**A. `release_command` (migration) fails:**
Nothing to do — Fly already left the old app machine running untouched.
Investigate the migration error, fix, redeploy. No data at risk.

**B. Migration succeeds, but the app then crash-loops or errors:**
Do **not** just redeploy the previous image — `share_id` is already gone and
old code depends on it. Instead:
1. Restore the fresh backup taken in step 2 above into the production
   database (this is the actual rollback — accept the data-loss window
   between backup and restore).
2. Redeploy the previous image (from the release list noted in step 3).
3. Investigate the break against a local reproduction before trying again.

**C. Migration succeeds, app is healthy, but a specific feature misbehaves:**
No rollback needed — roll forward with a fix. The schema and code are in sync;
this is an ordinary bug, not a rollback scenario.

## Sharry compatibility (verified, no action needed)

Sharry integrates via the standard tracker API (`window.umami.track(name,
data)`, unchanged signature) and a direct server-side POST to `/api/send`
(`server/analytics.ts`). Compared v3.0.3 vs. the merged v3.2.0 branch's
`src/app/api/send/route.ts`:

- The payload fields Sharry sends (`website`, `hostname`, `url`, `name`,
  `data`) are all still accepted.
- New in v3.2.0: `name`/`tag` may not start with `= + - @ \t \r` (CSV-injection
  guard). All of Sharry's event names (`session-created`,
  `screen-share-ended`, `login`, etc.) start with a letter — unaffected.
- Bot detection is unchanged (`isbot` on the User-Agent header); Sharry's
  documented browser-like User-Agent workaround keeps working.
- Sharry treats non-OK responses as fire-and-forget (`tryCatch`, log and
  swallow) — even an unforeseen incompatibility degrades gracefully rather
  than breaking Sharry itself.

No Sharry-side changes are required for this upgrade.
