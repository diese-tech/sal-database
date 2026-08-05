# Active migration sequence

The active sequence starts with
`20260717143900_production_baseline.sql`, a schema-only export of the verified
production state at the 2026-07-17 schema freeze.

The baseline was not assembled by concatenating the historical site and bot
migration directories. Migrations `019` through `025` from the archived site
sequence were not recorded in production and their effects were not all
present, so they must not be applied or marked as completed during adoption.

All later changes are reviewed, forward-only 14-digit migrations owned here.
Production deployment remains disabled until the protected baseline-adoption
procedure and recovery attestation are complete.

`20260718053000_clear_preseason_assignments.sql` adds a service-role-only,
idempotent reset for pre-seasons with no matches or draft rooms. Its one-time
production call removes only inherited `season_orgs` and `season_rosters` rows
from `preseason-s2`; organization/player identities and every historical season
remain intact.

`20260804045313_captain_onboarding.sql` adds the canonical captain-onboarding
operation. It requires explicit season, player, Discord, organization, division,
and admin-actor mappings; verifies Discord identity was linked separately; and
idempotently creates only season-scoped organization/captain state with immutable
audits. It never updates `players.is_captain` or grants `admin_users` access.
Every `season_orgs` lookup is scoped by `(season_id, org_id, division_id)`, not
just `(season_id, org_id)`, so onboarding a captain for one of an organization's
divisions never collides with its other divisions.

`20260804231500_scouter_game_review_drafts.sql` separates OCR extraction from
canonical scouter ingestion. It adds private, durable, host-scoped drafts with
optimistic revisions and identity diagnostics. Revision and cancellation never
write canonical stats; explicit confirmation is the only transition that calls
the existing atomic `ingest_scouter_game` RPC. This pre-persist safeguard is not
the later ADR-008 reviewable-publication lifecycle tracked by sal-site #198.

`20260805031500_scouter_game_corrections.sql` adds the post-persist repair path
for confirmed scouter games. One admin-only RPC replaces the complete existing
ten-player snapshot, requires explicit canonical player and god IDs, rejects a
stale revision, and preserves source-image keys and match membership. Each
successful change writes an immutable idempotency receipt plus a full before and
after audit; an exact retry performs no second mutation.
