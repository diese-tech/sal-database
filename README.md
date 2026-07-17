# SAL database contract

This repository is the intended canonical database-delivery boundary for the
SAL platform. It will own the shared Supabase configuration, forward-only
migrations, generated TypeScript database types, drift checks, and manually
approved production pushes used by `diese-tech/sal-site` and
`diese-tech/lab-salbot`.

## Current status: recovery-gated bootstrap

The repository is deliberately **not deployable yet**. The production backup
and restore drill tracked by
[`diese-tech/sal-site#156`](https://github.com/diese-tech/sal-site/issues/156)
has not been evidenced in this environment. Until it passes:

- `supabase/migrations/` must contain no active SQL migration;
- `contract.json` and `generated/database.types.ts` must not be published;
- `supabase/tests/` must contain no executable SQL test until it can target the
  reconciled baseline;
- no production migration ledger may be repaired;
- the production workflow must refuse to deploy.

This fail-closed state prevents a repository-derived schema from being
mistaken for a verified snapshot of production.

## Planned v1 contract

After the recovery gate passes, the first release will be `db-v1.0.0` and will
contain one canonical schema-only baseline produced from a reconciled scratch
restore. Consumers will vendor generated types and pin the exact release
commit through `db-contract.lock.json`; Git submodules are not used.

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

Once a verified baseline exists, CI additionally runs local Supabase reset,
database lint, schema assertions, and generated-type drift checks.
