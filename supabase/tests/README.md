# Database contract tests

The database contract includes these pgTAP suites:

- `001_schema_contract.test.sql` for constraints, functions, and triggers;
- `002_security_contract.test.sql` for RLS, grants, and function execution
  boundaries;
- `003_realtime_contract.test.sql` for publication membership;
- `004_storage_contract.test.sql` for buckets and storage policies.
- `005_item_catalog.test.sql` for the public item catalog, fixture, and write
  boundary.
- `006_season_isolation.test.sql` for season-scoped organizations, rosters, and
  current-season switching.
- `007_preseason_reset.test.sql` for the non-destructive preseason assignment
  reset.
- `008_transactional_decisions_outbox.test.sql` for service-role decision
  boundaries, atomic approval/stat mutations, rollback behavior, terminal
  idempotency, stale cancellation, and durable outbox lease/retry/dead-letter
  behavior.

A `contract.json` is rejected until all required suites exist. CI runs
them against a clean local reset, and the protected deployment runs them
against the linked database after a successful push and before publication.
