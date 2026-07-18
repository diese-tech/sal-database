# Database contract tests

The baseline contract includes these pgTAP suites:

- `001_schema_contract.test.sql` for constraints, functions, and triggers;
- `002_security_contract.test.sql` for RLS, grants, and function execution
  boundaries;
- `003_realtime_contract.test.sql` for publication membership;
- `004_storage_contract.test.sql` for buckets and storage policies.

A `contract.json` is rejected until all four suites exist. CI runs
them against a clean local reset, and the protected deployment runs them
against the linked database after a successful push and before publication.
