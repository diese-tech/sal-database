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

`20260809120000_organization_identity_merge.sql` adds a service-role-only,
fail-closed organization deduplication workflow. Preview reports every typed
reference and ambiguity; apply rechecks under locks, transfers live history to
the canonical identity, preserves immutable evidence, records the superadmin
actor, and deletes the duplicate in one transaction. Exact retries return the
recorded result instead of applying a second mutation.

`20260818120000_match_report_host_review.sql` connects official result capture
to public season statistics. It adds recoverable pending-action/report linkage,
private one-time host capabilities, roster-scoped identity diagnostics,
optimistic host correction and submission, and an atomic action/report creation
RPC for the synchronous bot projection flow. Final admin approval owns both the
linked action and report. Its idempotent, provenance-guarded set replacement
writes `player_stats`, refreshes every affected `players.stats` aggregate,
repairs safe legacy completed reports, and preserves audited Discord and
standings outbox events. Denied reports retain an audited snapshot before a
later result can rebind the match's unique report slot.

`20260822120000_roster_trade_workflow.sql` adds the transport-neutral trade
ledger, immutable revisions, exact-revision consent, linked pending actions,
atomic season-roster execution, captain and organization role mappings, durable
proposal/admin/bulletin/role projections, and an explicit outbox
`needs_reconciliation` state for ambiguous Discord sends. An administrator can
then link the confirmed Discord message or authorize one explicit retry through
`reconcile_operation_outbox`; both outcomes are audited. Only the `trade`
transaction slice ships here; claims, drops, draft-position swaps, reversals,
and historical reconciliation execution remain future contracts.

The mutation RPCs are service-role-only. Discord or web role authorization is
therefore resolved by the trusted caller; actor identifiers are persisted for
audit, revision authorship, and consent without requiring player/OAuth/roster
identity linkage at the database boundary.

`20260822123000_roster_trade_player_merge_compatibility.sql` extends the
existing fail-closed player identity merge to recognize, conflict-check, count,
lock, and redirect typed roster-transaction movement references. Transaction
rows remain intact while duplicate player identities consolidate safely.

`20260823120000_scoped_team_roles_and_roster_drops.sql` corrects the Discord
roster-role projection boundary by storing a team role for the full
`(season_id, division_id, org_id)` identity. The legacy organization-owner role
table remains available for older consumers but is no longer a roster
projection contract. An audited bulk RPC applies reviewed mapping artifacts.
The same migration extends the existing roster transaction ledger with drops:
authorized organization submission creates a revision, consent, and pending admin action without
changing a roster; an administrator must select the private post-drop
eligibility state; successful execution atomically writes canonical roster and
eligibility state plus durable transaction-bulletin and Discord-role outbox
events. Claim consumers must consult `season_player_eligibility` before adding a
free agent to a roster.

`20260823123000_player_eligibility_merge_compatibility.sql` extends the
fail-closed player identity merge again for the authoritative post-transaction
eligibility reference. It blocks conflicting same-season eligibility rows and
otherwise transfers the source row to the canonical player without losing the
private administrator decision.

`20260823130000_organization_role_mapping_merge_compatibility.sql` keeps both
organization-wide owner/advisor roles and season-team projection roles attached
when a superadmin consolidates duplicate organization identities. Existing
canonical target mappings win; otherwise the source mapping is re-keyed before
the duplicate parent rows are removed.

`20260901120000_match_report_result_corrections.sql` adds the post-publication
repair path for completed match reports. `resolve_match_report_review` stays
deliberately terminal -- a report already `done` returns `already_processed`
with `applied = false` and writes nothing, so a retried or duplicated approval
can never silently overwrite a published league result -- and correcting a
published result is therefore its own explicit admin-only RPC, mirroring the
scouter correction path added in `20260805031500`. One correction names the
revision it expects, carries a reason, replaces the complete stat set, updates
the still-completed match, republishes official stats, and enqueues its own
standings recalculation. Every change writes an immutable receipt plus full
before-and-after audits; an exact retry returns the recorded receipt instead of
applying a second mutation. The reviewed-payload rules are factored into
`private.validate_match_report_games` so a correction cannot accept anything
approval would reject.
