# Canonical baseline adoption

## Entry conditions

- A logical backup has been restored into isolated PostgreSQL 17 and passed
  row-count, database-object, site-read, and bot-read checks.
- Production schema writes are frozen; ordinary row-level league operations
  may continue.
- Production schema and migration-ledger exports are stored privately.
- Migration `025` has a recorded disposition. As captured on 2026-07-17 it was
  absent from the live ledger and was not schema-equivalent, so it must not be
  applied or repaired into history.

## Procedure

1. Generate one 14-digit schema-only baseline from the captured production
   schema. Preserve observed production state exactly; hardening belongs in
   later forward migrations.
2. Record application-owned managed-schema objects, including Storage and
   Realtime configuration, that the `public` schema dump excludes.
3. Add deterministic reference fixtures separately to `seed.sql`.
4. Prove empty local reset, database lint, schema/RLS/Realtime assertions, and
   generated type stability.
5. Require a normalized local-versus-production schema diff with no changes.
6. If any difference exists, stop and create a forward reconciliation
   migration; do not edit the production migration ledger.
7. Dispatch `Adopt production database baseline` against the exact commit at
   the tip of protected `main`. Its `production-plan` job compares the linked
   ledger with `baseline-adoption.json`, proves the `public` schema diff is
   empty, and emits a reviewable bookkeeping-only plan.
8. Approve the protected `production` job only when the plan lists the 14
   captured historical versions, baseline `20260717143900`, `schema-ddl=none`,
   and no other operation. The workflow marks only those allowlisted versions
   reverted and the equivalent baseline applied. It never executes baseline
   DDL and never changes league rows. Do not add absent versions `019`-`025`.
9. Require exact linked migration parity, an empty push dry-run, linked pgTAP,
   and a second empty schema diff before the workflow creates `db-v1.0.0`.
10. Preserve the old ledger export so the bookkeeping-only change can be
   reversed without changing schema objects.

The baseline PR completed steps 1-6 only. Steps 7-10 require the protected
maintenance workflow and explicit maintainer approval.

## Tooling references

- [Supabase local development workflow](https://supabase.com/docs/guides/local-development/cli-workflows)
- [Supabase CLI configuration reference](https://supabase.com/docs/guides/local-development/cli/config)
- [Supabase CLI database commands](https://supabase.com/docs/reference/cli/supabase-db)
