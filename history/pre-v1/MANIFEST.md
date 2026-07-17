# Pre-v1 migration evidence manifest

Historical migrations are evidence, not an active sequence. The archived
files below match their source Git blobs exactly; `SHA256SUMS` records their
portable content hashes.

## sal-site

- Source repository: `diese-tech/sal-site`
- Snapshot: `8096b1498c5aac9aa4b84044fee7df4a045af538`
- Historical inputs: `supabase/schema.sql` and `supabase/migrations/001` through
  `025`

## lab-salbot

- Source repository: `diese-tech/lab-salbot`
- Snapshot: `dbe67fd346e0003a6c11b58fc1720d2cf09ba766`
- Historical inputs: the four SQL files under `database/migrations/`

The site schema plus 25 site migrations and four bot migrations are present in
repository-specific subdirectories. Retain the production migration-ledger
export in private recovery evidence; never commit a production database dump.
