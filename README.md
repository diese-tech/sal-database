# SAL database contract

This repository is the canonical database-delivery boundary for the SAL
platform. It owns the shared Supabase configuration, forward-only
migrations, generated TypeScript database types, drift checks, and manually
approved production pushes used by `diese-tech/sal-site` and
`diese-tech/lab-salbot`.

## Current status: active immutable contract

The original `db-v1.0.0` baseline was adopted and immutable releases are now
active. The current repository contract is declared in
[`contract.json`](contract.json); as of 2026-07-23 it is `db-v1.3.0` at
migration head `20260719220000`. Production planning and deployment remain
fail-closed unless the checked-in recovery attestation, protected environment,
and empty-or-reviewed plan gates pass.

See [`docs/audit-status.md`](docs/audit-status.md) for the current public
readiness findings, owners, and closure gates.

## v1 contract

Consumers vendor generated types and pin an exact immutable release commit
through `db-contract.lock.json`; Git submodules are not used.

`diese-tech/smite-content-sync` proposes reviewed SMITE reference-data updates
to `supabase/seeds/smite2-gods.sql` and, beginning with the gated
`db-v1.1.0` item-catalog change, `supabase/seeds/smite2-items.sql`. It does not
target `sal-site` or write directly to production. A production content change
still requires a reviewed forward database release.

See the runbooks under [`docs/runbooks`](docs/runbooks) before adding schema or
enabling deployment. The release commit must also include a current
`recovery-attestation.json` derived from
[`docs/recovery-attestation.example.json`](docs/recovery-attestation.example.json);
an absent, expired, or mismatched attestation keeps production fail-closed.

The accepted draft, roster-transaction, failure-recovery, and cross-repository
ownership decisions are summarized in plain English in
[`docs/platform-decisions.md`](docs/platform-decisions.md).

## Local commands

```text
npm ci
npm run lint
npm run typecheck
npm test
npm run build
npm audit --audit-level=high
```

CI also runs a clean local Supabase reset, database lint, schema assertions,
and generated-type drift checks for the current contract.
