# Backup and restore drill

This runbook implements the launch gate tracked by `sal-site#156`.

1. Record the Supabase plan, backup retention, latest recovery point, and PITR
   availability in private evidence.
2. Restore into a new scratch project. Never restore over production.
3. Record RPO and elapsed RTO.
4. Compare row counts for seasons, divisions, organizations, players, matches,
   standings, pending actions, both audit trails, stat records, and draft data.
5. Verify primary/foreign/unique/check constraints, functions, triggers,
   indexes, grants, RLS policies, storage buckets, and Realtime publication
   membership.
6. Run site read-only smoke tests and one bot database-read smoke test against
   scratch credentials.
7. Record a non-sensitive pass/fail summary and the private evidence location.

Any missing or inconsistent state is a failed drill and blocks baseline work.
