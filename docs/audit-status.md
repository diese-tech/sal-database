# Database delivery audit status

**Baseline source snapshot:** `diese-tech/sal-database@372dcf613cd219e74fbdcacc3226fc160f692eb3`

**Last reviewed:** 2026-07-23

This is the current public status for the SAL database-delivery repository. It
contains SAL findings only. Detailed cross-platform comparison material and
non-public recovery evidence are maintained outside the public repositories.

## 2026-07-23 status correction

The baseline-adoption statements below are retained as historical evidence, but
they no longer describe current `main`. The repository now publishes immutable
contracts through `db-v1.3.0`, `contract.json` declares migration head
`20260719220000`, and a current recovery attestation is checked in.

The accepted draft and roster ADRs describe future implementation work, not
already deployed schema. Their plain-English product and ownership summary is
[`platform-decisions.md`](platform-decisions.md).

## Ownership boundary

`diese-tech/sal-database` is the sole owner of active Supabase
migrations, generated database types, schema-contract releases, drift checks,
and production database pushes.

The `db-v1.0.0` baseline was adopted. Production remains fail-closed by design:
the workflow rejects deployment without a current matching recovery
attestation, protected approval, and an acceptable production plan.

The site and bot SQL copies are archived under `history/pre-v1/` as evidence.
They are not a sequence that may be pushed to production.

## Historical baseline findings

| ID | Priority | State | Finding | Closure evidence |
|---|---|---|---|---|
| `SAL-OPS-01` | P0 | Partially verified | Encrypted recurring logical backups and an isolated restore are verified; managed Supabase PITR is unavailable on the current plan. | Keep weekly backup verification healthy and attach measured RPO/RTO evidence to [`diese-tech/sal-site#156`](https://github.com/diese-tech/sal-site/issues/156). |
| `SAL-DB-01` | P1 | Baseline verified; adoption pending | The canonical candidate rebuilds cleanly and matches the captured production `public` schema exactly, but the production ledger and immutable release are unchanged. | Complete the protected bookkeeping-only adoption in [#3](https://github.com/diese-tech/sal-database/issues/3), prove an empty push plan, then release `db-v1.0.0`. |
| `SAL-CONTRACT-01` | P1 | Blocked by `db-v1.0.0` | The site and bot do not yet vendor generated types or pin an immutable database release. | Complete [`sal-site#175`](https://github.com/diese-tech/sal-site/issues/175) and [`lab-salbot#41`](https://github.com/diese-tech/lab-salbot/issues/41). |
| `SAL-OPS-02` | P1 | Blocked by `db-v1.0.0` | Approval and stat-review mutations are not yet one database transaction with a durable outbox. | Complete [#4](https://github.com/diese-tech/sal-database/issues/4) and the linked consumer work after both contract pins land. |
| `SAL-DB-DEPLOY-01` | P1 | Partially verified | Docker-backed reset, lint, pgTAP, type generation, and captured-schema parity pass; authenticated protected planning and production ledger parity remain unverified. | Attach successful protected-plan and production workflow runs to #3. |

## Verified repository controls

- The initial recovery-gated scaffold is published at
  [`4c50ec6486ab18646d9833c52f9915efbff4a983`](https://github.com/diese-tech/sal-database/commit/4c50ec6486ab18646d9833c52f9915efbff4a983).
- The baseline evidence, hashes, and non-sensitive verification results are in
  [`docs/baseline-evidence.md`](baseline-evidence.md).
- Bootstrap CI passed repository-state and secret-scan checks in
  [run `29556338868`](https://github.com/diese-tech/sal-database/actions/runs/29556338868).
- `main` requires pull requests, current checks, resolved conversations, and
  administrator enforcement. Force pushes and branch deletion are disabled.
- The protected `production-plan` and `production` environments require the
  repository owner. Production deployment is manual and serialized.
- Active tag ruleset `19086798` permits creation but blocks updates and
  deletion of tags matching `db-v*`, making released contract tags immutable.
- Private vulnerability reporting is enabled. The repository includes the
  approved proprietary notice, `SECURITY.md`, CODEOWNERS, and grouped weekly
  dependency updates.

## Release gate

Do not repair production migration history or tag `db-v1.0.0` until all of the
following are true:

1. Migration `025` is explicitly recorded as absent and non-equivalent; it is
   not applied or inserted into production history. The related site deployment
   is observed.
2. An isolated restore passes schema, data, RLS, function, storage, Realtime,
   site-read, and bot-read checks.
3. The production schema and migration ledger are captured and preserved.
4. A blank reset from the candidate baseline passes, and its `public` schema
   dump is byte-identical to the captured production dump.
5. The protected adoption plan reports exact ledger parity and no pending
   production push.

Any failed gate stops adoption. Applied schema corrections are forward-only.
