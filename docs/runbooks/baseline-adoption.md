# Canonical baseline adoption

## Entry conditions

- The restore drill passed.
- Migration `025` is recorded in production.
- Production schema writes are frozen for the maintenance window.
- A production schema export and migration-ledger export are stored privately.

## Procedure

1. Reconcile the scratch restore to the intended application contract using
   forward SQL only.
2. Generate one 14-digit schema-only baseline from scratch.
3. Add deterministic reference fixtures separately to `seed.sql`.
4. Prove empty local reset, database lint, schema/RLS/Realtime assertions, and
   generated type stability.
5. Require a normalized scratch-versus-production schema diff with no changes.
6. If any difference exists, stop and create a forward reconciliation
   migration; do not edit the production migration ledger.
7. During the approved window, mark only captured historical ledger versions
   as reverted and the equivalent baseline version as applied. Do not execute
   baseline DDL against the equivalent production schema.
8. Require exact linked migration parity and an empty push dry-run.
9. Preserve the old ledger export so the bookkeeping-only change can be
   reversed without changing schema objects.

## Tooling references

- [Supabase local development workflow](https://supabase.com/docs/guides/local-development/cli-workflows)
- [Supabase CLI configuration reference](https://supabase.com/docs/guides/local-development/cli/config)
- [Supabase CLI database commands](https://supabase.com/docs/reference/cli/supabase-db)
