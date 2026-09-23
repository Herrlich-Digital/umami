# Upgrade Herrlich-Digital/umami fork to upstream v3.2.0

## Context

Herrlich-Digital/umami is a fork of umami-software/umami, extended with 12
Fly.io-specific deployment commits (Dockerfile, fly.toml, fly.postgres.toml,
fly.backup.toml, unmanaged Postgres config, daily S3 backup cron, single-machine
pinning, pnpm build-script fixes). The fork's `master` was 888 commits / one
minor version (3.0.3 -> 3.2.0) behind `upstream/master`, which is effectively
identical to the `v3.2.0` tag (1 commit apart).

`upstream/master..master` conflict surface is small: of the ~908 files that
differ between the two histories, only two files that exist in both were also
touched by the fork's local commits: `Dockerfile` and `package.json`. Every
other fork-specific file (`fly*.toml`, `docker/backup/backup.sh`, `dbsetup.js`)
is a new file that doesn't exist upstream, so it merges without conflict.

Upstream added 6 Prisma migrations since the fork's baseline: `15_add_share`,
`16_boards`, `17_remove_duplicate_key`, `18_add_performance`,
`19_add_session_replay`, `20_add_heatmap`. `scripts/check-db.js` runs
`prisma migrate deploy` automatically as part of `start-docker`, so these run
automatically the moment the new image boots in production — there is no
manual migration trigger step.

## Goal

Bring the fork's `master` up to date with upstream `v3.2.0` while preserving
all Fly.io-specific infrastructure, without breaking the live production
deployment on Fly.io (`umami-falling-waterfall-1667`).

## Approach

1. Land the already-validated pnpm v11 `allowBuilds` fix on `master`
   independently first (small, tested, unblocks deploys immediately)
   — done in commit `2ed5927e0`, deployed separately from this upgrade.
2. Branch `upgrade/umami-3.2.0` from `master`.
3. `git merge v3.2.0` (tag, not `upstream/master`, to pin to a stable release).
4. Resolve the two conflicting files:
   - `Dockerfile`: adopt upstream's pnpm-version-pinning approach
     (`ARG PNPM_VERSION`, and its `strictDepBuilds: false` override written
     into the image at build time) instead of relying on an unpinned
     `npm install -g pnpm` + workspace allowlist, which is what caused the
     original outage. Re-apply Fly-specific Dockerfile pieces (env vars,
     runner stage adjustments) on top.
   - `package.json`: take upstream's dependency versions as-is (this is what
     already built successfully against the local pnpm fix). Drop the dead
     `pnpm.onlyBuiltDependencies` field (already removed).
5. Validate locally: `pnpm install`, `pnpm build` (or `build-docker`),
   `pnpm lint`, `pnpm check`, `pnpm test`.
6. Validate the DB migration path against a copy of the data, not production
   directly: restore the latest S3/pg_dump backup into a throwaway local
   Postgres, run `prisma migrate deploy` against it, boot the app against
   that copy and confirm it reads existing data correctly and the 6 new
   migrations apply cleanly.
7. Build the actual Docker image locally (mirroring what Fly will build) to
   catch anything a plain `pnpm build` wouldn't.
8. Push the branch, open a PR against `master` describing the upgrade,
   conflict resolutions, and migration test results, for review before
   merging and deploying to production.

## Explicitly out of scope

- No separate staging Fly app / Postgres instance (chose the lighter
  branch-plus-local-test path over a full staging environment).
- No audit of upstream's application-level behavior changes beyond what the
  build, lint, test, and migration validation surface.
- No change to `upstream/master` tracking cadence going forward — this is a
  one-time catch-up merge, not a recurring sync process (not addressed here).

## Rollback plan

- Previous Fly release/image remains available via `fly releases`; can
  redeploy the prior image or restart machines on the previous version if the
  new release misbehaves.
- Daily S3 `pg_dump` backup (plus a fresh manual backup taken immediately
  before the production deploy) is the fallback if a migration corrupts data.
