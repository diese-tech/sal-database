# Database delivery audit status

**Repository snapshot:** `diese-tech/sal-database@4c50ec6486ab18646d9833c52f9915efbff4a983`

**Last reviewed:** 2026-07-17

This is the current public status for the SAL database-delivery repository. It
contains SAL findings only. Detailed cross-platform comparison material and
non-public recovery evidence are maintained outside the public repositories.

## Ownership boundary

`diese-tech/sal-database` is the designated sole owner of active Supabase
migrations, generated database types, schema-contract releases, drift checks,
and production database pushes. That ownership becomes operational only after
the restore-backed `db-v1.0.0` baseline passes every gate below.

Until then, this repository stays fail-closed:

- `supabase/migrations/` contains no active SQL migration;
- `contract.json` and `generated/database.types.ts` do not exist;
- no database release has been tagged;
- no production migration ledger has been repaired; and
- the production workflow rejects deployment without verified recovery and
  contract inputs.

The site and bot SQL copies are archived under `history/pre-v1/` as evidence.
They are not a sequence that may be pushed to production.

## Current findings

| ID | Priority | State | Finding | Closure evidence |
|---|---|---|---|---|
| `SAL-OPS-01` | P0 | Blocked | Backup retention, PITR, and scratch restoration have not been verified. | Complete [`diese-tech/sal-site#156`](https://github.com/diese-tech/sal-site/issues/156) with non-sensitive restore evidence and measured RPO/RTO. |
| `SAL-DB-01` | P1 | Blocked by recovery | No restore-verified canonical baseline or immutable database contract exists. | Complete [#3](https://github.com/diese-tech/sal-database/issues/3), prove an empty reset and normalized schema parity, then release `db-v1.0.0`. |
| `SAL-CONTRACT-01` | P1 | Blocked by `db-v1.0.0` | The site and bot do not yet vendor generated types or pin an immutable database release. | Complete [`sal-site#175`](https://github.com/diese-tech/sal-site/issues/175) and [`lab-salbot#41`](https://github.com/diese-tech/lab-salbot/issues/41). |
| `SAL-OPS-02` | P1 | Blocked by `db-v1.0.0` | Approval and stat-review mutations are not yet one database transaction with a durable outbox. | Complete [#4](https://github.com/diese-tech/sal-database/issues/4) and the linked consumer work after both contract pins land. |
| `SAL-DB-DEPLOY-01` | P1 | Partially verified | Repository and secret-scan bootstrap checks pass, but Docker-backed reset, authenticated push planning, and production parity are not verified. | Attach successful protected-plan and production workflow runs to #3. |

## Verified repository controls

- The initial recovery-gated scaffold is published at
  [`4c50ec6486ab18646d9833c52f9915efbff4a983`](https://github.com/diese-tech/sal-database/commit/4c50ec6486ab18646d9833c52f9915efbff4a983).
- Bootstrap CI passed repository-state and secret-scan checks in
  [run `29556338868`](https://github.com/diese-tech/sal-database/actions/runs/29556338868).
- `main` requires pull requests, current checks, resolved conversations, and
  administrator enforcement. Force pushes and branch deletion are disabled.
- The protected `production-plan` and `production` environments require the
  repository owner. Production deployment is manual and serialized.
- Private vulnerability reporting is enabled. The repository includes the
  approved proprietary notice, `SECURITY.md`, CODEOWNERS, and grouped weekly
  dependency updates.

## Release gate

Do not add a baseline migration, generate a contract, repair production
migration history, or tag `db-v1.0.0` until all of the following are true:

1. Production migration `025` and the related site deployment are observed.
2. A scratch restore passes schema, data, RLS, function, storage, Realtime,
   site-read, and bot-read checks.
3. The production schema and migration ledger are captured and preserved.
4. A blank reset from the candidate baseline passes, and its normalized diff
   against the restored production schema is empty.
5. The protected adoption plan reports exact ledger parity and no pending
   production push.

Any failed gate stops adoption. Applied schema corrections are forward-only.
