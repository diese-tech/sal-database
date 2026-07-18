# SAL database contract

This repository is the intended canonical database-delivery boundary for the
SAL platform. It will own the shared Supabase configuration, forward-only
migrations, generated TypeScript database types, drift checks, and manually
approved production pushes used by `diese-tech/sal-site` and
`diese-tech/lab-salbot`.

## Current status: verified baseline candidate

The repository contains a schema-only `db-v1.0.0` candidate captured from the
production PostgreSQL 17 database during the schema freeze that began on
2026-07-17. It contains no production rows. A clean local rebuild, database
lint, 30 contract assertions, generated-type stability, and byte-for-byte
`public` schema parity have been verified. See
[`docs/baseline-evidence.md`](docs/baseline-evidence.md).

The candidate is deliberately **not deployable yet**:

- no production migration ledger has been repaired;
- the baseline DDL has not been executed against production;
- `recovery-attestation.json` remains absent; and
- the production workflow must therefore refuse credentialed planning or
  deployment.

This keeps the candidate reviewable without turning a successful local proof
into permission to mutate production.

See [`docs/audit-status.md`](docs/audit-status.md) for the current public
readiness findings, owners, and closure gates.

## v1 contract

The first release candidate is `db-v1.0.0`. Consumers will vendor generated
types and pin the exact release commit through `db-contract.lock.json`; Git
submodules are not used.

`diese-tech/smite-content-sync` proposes reviewed SMITE reference-data updates
to `supabase/seeds/smite2-gods.sql` in this repository. It does not target
`sal-site` or write directly to production. A production content change still
requires a reviewed forward database release.

See the runbooks under [`docs/runbooks`](docs/runbooks) before adding schema or
enabling deployment. The release commit must also include a current
`recovery-attestation.json` derived from
[`docs/recovery-attestation.example.json`](docs/recovery-attestation.example.json);
the bootstrap intentionally omits that file so production stays fail-closed.

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
and generated-type drift checks for this candidate.
