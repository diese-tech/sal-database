# Database contract tests

The recovery-gated bootstrap contains no executable database tests. The
reviewed baseline PR must add these pgTAP suites:

- `001_schema_contract.test.sql` for constraints, functions, and triggers;
- `002_security_contract.test.sql` for RLS, grants, and pinned `search_path`;
- `003_realtime_contract.test.sql` for publication membership;
- `004_storage_contract.test.sql` for buckets and storage policies.

A released `contract.json` is rejected until all four suites exist. CI runs
them against a clean local reset, and the protected deployment runs them
against the linked database after a successful push and before publication.
