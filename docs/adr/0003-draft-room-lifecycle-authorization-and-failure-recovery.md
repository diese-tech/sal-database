# ADR-0003: Draft Room Lifecycle, Authorization, and Failure Recovery

- Status: Accepted
- Date: 2026-07-23
- Owners: SAL database, site, and bot maintainers
- Related ADRs:
  - [ADR-0001: Season-Scoped Captain-Roster Draft Eligibility](0001-season-scoped-captain-roster-draft-eligibility.md)
  - [ADR-0002: Roster Transactions and Public Bulletin](0002-roster-transactions-and-public-bulletin.md)
  - [ADR-009: Roster Transactions Discord Workflow](https://github.com/diese-tech/lab-salbot/blob/main/docs/adrs/ADR-009-roster-transactions-discord-workflow.md)
  - [SAL Site ADR-0001: Audience-Specific Draft Views and Production Board](https://github.com/diese-tech/sal-site/blob/main/docs/adr/0001-audience-specific-draft-views-and-production-board.md)
- Related findings: DE-00, DE-02, DE-03, DE-06
- Related issues:
  - diese-tech/sal-site#207
  - diese-tech/sal-site#208

## Context

SAL runs a separate draft room for each season division. Drafts may occur in any
division order but do not run simultaneously.

The draft must remain simple for administrators and captains while safely
handling:

- pre-draft configuration;
- captain readiness;
- picks and skips racing for the same slot;
- selected but unconfirmed players at timeout;
- captain and administrator disconnects;
- realtime transport failures;
- platform outages;
- Discord OAuth outages;
- timer expiration;
- configuration changes;
- repeatable draft-history undo and redo;
- audience-specific projections;
- caster and production authorization;
- revocable broadcast overlays;
- role-based captain replacement;
- atomic roster publication; and
- recovery from incomplete finalization.

No browser, captain, administrator, realtime subscription, or Discord process
hosts the authoritative room state. The database remains authoritative.

## Decision

### One room per season division

Each draft room belongs to exactly one season and one division.

Only one room in `pending`, `open`, `active`, `paused`, `recovery_paused`, or
`completion_review` state may exist for a season and division.

Only one room in a season may be `active`, `paused`, `recovery_paused`, or
`completion_review` at a time.

Division drafts may run in any order. The expected operational order is normally
Terra, Solar, then Lunar, but the system does not hard-code that order.

### Minimal room setup

Creating a room requires only:

- the division;
- the number of rounds; and
- the predetermined initial organization order.

The active season is derived automatically.

The room derives participating organizations from active `season_orgs` rows for
the selected season and division.

League defaults remain versioned system configuration rather than routine room
form fields. These defaults include:

- pick-timer duration;
- snake-order behavior;
- eligibility hierarchy;
- maximum roster size;
- readiness behavior;
- timeout behavior; and
- failure-recovery thresholds.

The administrator room-creation form exposes division and rounds. It does not
expose the normal pick-timer value.

### Initial draft-order editor

Before opening the room, administrators arrange every participating organization
in one ordered list.

The editor:

- includes every participating organization exactly once;
- supports drag-and-drop on compatible desktop clients;
- provides up and down controls for keyboard, assistive-technology, and mobile
  use;
- updates visible position numbers immediately;
- blocks duplicate or missing organizations; and
- saves through one explicit **Save Draft Order** action.

Approved Draft Position Swaps update the saved order before room start according
to ADR-0002.

### Configuration snapshot and immutability

When the room starts, the database records an immutable configuration snapshot
containing:

- season;
- division;
- participating organizations;
- base draft order;
- round count;
- expanded snake sequence;
- pick-timer duration;
- eligibility-rule version;
- division-tier configuration;
- maximum roster size;
- captain-role mapping version; and
- organization-role mapping version.

Before room start, administrators may change rounds and draft order.

Any material pre-start change clears all organization readiness states.

After room start, the configuration snapshot cannot be edited.

If a material configuration error is discovered after room start, administrators
pause and void the room. A corrected replacement room is created with an
explicit link to the voided room. Active draft history is never rewritten by
changing its configuration.

### Room lifecycle

Draft rooms use explicit states:

- `pending`;
- `open`;
- `active`;
- `paused`;
- `recovery_paused`;
- `completion_review`;
- `complete`;
- `voided`; and
- `replaced`.

`pending` allows configuration but does not allow captain access.

An administrator moves the room to `open` when production is ready for captains
to join and synchronize.

Each organization seat reports:

- no authorized captain connected;
- connected;
- ready;
- offline or reconnecting; or
- authorization misconfigured.

An authorized captain explicitly marks the organization seat ready.

Readiness belongs to the organization seat, not to an individual browser
session.

`Start Draft` remains disabled until every participating organization is ready.

An audited `Start Without All Ready` override is available for production
emergencies. It requires confirmation and a private administrative reason.

Starting the room:

1. revalidates the complete configuration;
2. records the immutable snapshot;
3. closes Draft Position Swaps for the room;
4. activates the first slot;
5. records its authoritative deadline; and
6. commits the transition atomically.

### Captain authorization

Captains authenticate through Discord OAuth.

Draft authorization requires:

- the Discord captain role mapped to the room's division;
- exactly one Discord organization role mapped to an organization participating
  in the room;
- current participation of that organization in the room's season and division;
  and
- a valid room-bound server session.

Examples:

- `Solar Captain` plus `Eternal Vanguard` authorizes Eternal Vanguard's Solar
  seat;
- `Lunar Captain` plus `Eternal Vanguard` authorizes Eternal Vanguard's Lunar
  seat; and
- `Terra Captain` plus `Eternal Vanguard` authorizes Eternal Vanguard's Terra
  seat.

This supports one organization fielding separate teams in every division.

The database owns canonical mappings for:

- each division-specific captain Discord role; and
- each organization's Discord role.

Existing ordinary division-role mappings remain separate and continue to support
player division-role synchronization.

If a member has the required division-captain role but multiple participating
organization roles, authorization is denied as ambiguous and administrators see
a configuration warning.

Multiple people may be authorized for one organization seat. The database
serializes their actions, so only one conflicting pick or skip can succeed.

Removing a required Discord role revokes access when authorization refreshes.

### Staff authorization and broadcast overlays

Caster and production staff authenticate through Discord OAuth.

The database owns audited mappings for:

- the configured Caster Discord role; and
- the configured Production Discord role.

These mappings grant only the read-only production projection defined by SAL
Site ADR-0001. They do not grant captain or administrator mutations.

The database also owns broadcast-overlay credentials.

Each overlay credential is:

- stored only as a cryptographic hash;
- bound to one draft room;
- restricted to the broadcast-safe projection;
- assigned an expiration;
- revocable;
- rotatable;
- invalid after room conclusion; and
- privately audited.

Plaintext overlay credentials are returned only when generated and are never
stored.

Only an authorized administrator may generate, rotate, or revoke an overlay
credential. Caster and Production roles remain read-only consumers.

### Discord OAuth outage and emergency access

Existing sessions that were verified before a Discord or OAuth outage may
continue operating for the current room during a limited configured grace
period.

The system does not revoke an existing session merely because Discord cannot be
reached.

New normal sessions cannot be established while Discord OAuth is unavailable.

An administrator may issue a temporary emergency access code that is:

- bound to one room;
- bound to one organization;
- unable to grant administrator access;
- privately audited;
- immediately revocable; and
- expired when its maximum lifetime ends, the room concludes, or Discord
  verification recovers.

When Discord recovers, normal roles are revalidated and unauthorized sessions
terminate.

### Shared administrator control

No administrator owns or hosts a room.

Any authorized administrator may operate the room from any authenticated
session.

Administrator disconnects do not reset, pause, or otherwise alter:

- room state;
- captain readiness;
- timer state;
- captain sessions; or
- configuration.

Start, pause, resume, skip, void, and finalization actions use atomic database
transitions.

If administrators submit conflicting actions, only the first valid state
transition succeeds. Later requests receive the current room state.

Every administrator action records the acting administrator. The interface shows
who last started, paused, resumed, skipped, voided, or finalized the room.

A manual pause remains active until an authorized administrator explicitly
resumes it.

### Authoritative room version

Every room mutation includes:

- the room identifier;
- expected room version;
- expected current slot;
- authenticated actor; and
- mutation-specific input.

The database rejects stale room versions or stale slots and returns the current
authoritative state.

Clients never infer that a mutation succeeded from local state.

### Staged player selection

Selecting a player creates a server-persisted staged selection for the current
organization and slot.

The interface clearly labels the selected player:

**Will auto-pick when time expires**

The authorized organization may change or clear the staged player before the
deadline.

A staged selection:

- survives refresh and reconnect;
- belongs only to its room and slot;
- does not create a draft pick;
- does not stop the timer;
- does not reserve the player across division rooms; and
- is replaced by the organization's most recent valid staged selection.

Selecting a player is distinct from confirming a player.

Explicit confirmation attempts to commit the staged player immediately.

When the authoritative deadline expires:

- a valid and still-available staged player is atomically committed as the pick;
- no staged player produces a recorded timeout skip; and
- a staged player that became unavailable produces a recorded timeout skip.

A captain may use the established post-draft claim or ticket process after a
skipped slot. A captain may later trade an automatically committed player through
the transaction workflow in ADR-0002.

### Atomic pick and skip resolution

Confirmed picks, timeout auto-picks, captain-requested skips, and
administrator-requested skips use one database slot-resolution function.

The function:

1. locks the draft room and current slot;
2. verifies room state, room version, slot, and deadline;
3. verifies actor authorization for actor-initiated actions;
4. revalidates the player when resolving a pick;
5. enforces ADR-0001 season and division eligibility;
6. records exactly one resolution for the slot;
7. advances the draft exactly once;
8. records the next authoritative deadline when another slot exists; and
9. enters `completion_review` when the final slot is resolved.

A pick and skip racing for the same slot cannot both succeed.

The losing request receives the newly current authoritative state.

A skipped slot permanently records its temporary forfeiture and roster vacancy.
It is never rewritten as a later draft pick.

Skip records identify their source:

- `captain_requested`;
- `admin_requested`;
- `timer_expired`; or
- `platform_recovery`.

### Authoritative timer

The database stores the current slot's authoritative deadline.

Client countdowns are display-only.

A server worker resolves expired slots. If the worker is delayed, the next room
refresh or mutation reconciles the expired slot before processing later actions.

Multiple workers or clients detecting the same expiration still resolve the slot
only once.

A captain cannot submit a pick after the authoritative deadline. The timeout
auto-pick or skip is resolved first.

### Pause and resume

Pausing records the remaining pick time in the database and clears the active
deadline.

Resuming creates a new deadline from the stored remaining time.

A captain disconnect does not automatically pause the room. The interface marks
the organization seat offline or reconnecting, the timer continues, and an
administrator decides whether a manual pause is warranted.

Reconnecting restores the captain to the current organization seat and
authoritative room state.

A stale browser cannot submit against a slot that advanced during the
disconnect.

### Repeatable undo and redo

Administrators may navigate canonical draft history while the room is paused or
in `completion_review`.

Each **Undo Resolution** action:

1. identifies the latest canonical pick or skip;
2. appends a linked reversal event;
3. marks that resolution non-canonical without deleting it;
4. releases a reversed picked player back to the eligible pool;
5. removes a reversed skipped-slot vacancy;
6. moves the canonical current slot backward;
7. clears staged selections for displaced later slots;
8. records the acting administrator; and
9. records an optional but encouraged private reason.

Administrators may repeat Undo Resolution back to the first resolved slot.

Undoing from `completion_review` returns the room to `paused`.

Each **Redo Resolution** action:

1. identifies the next resolution on the abandoned canonical branch;
2. revalidates player availability, eligibility, room configuration, and slot;
3. appends a linked redo event;
4. restores the resolution only when it remains valid; and
5. advances the canonical current slot.

Administrators may repeat Redo Resolution while the room remains paused and no
new staged selection, pick, or skip has created a new canonical branch.

If a prior resolution is no longer valid, redo stops and reports the conflict.

After a new staged selection, pick, or skip creates a new branch, the abandoned
branch remains in immutable audit history but cannot become canonical again.

No pick timer runs while administrators navigate history.

Resuming after undo restores the full configured pick timer for the reopened
slot.

Public-safe correction events update spectator and production ledgers. Canonical
team cards and current-slot calculations use only the active history branch.

Private undo and redo reasons are never included in public projections.

### Realtime degradation

Realtime subscriptions are an optimization and are never authoritative.

If realtime disconnects:

- clients switch automatically to short polling;
- the interface displays **Live connection degraded — refreshing
  automatically**;
- authoritative actions remain available through server endpoints; and
- polling stops only after realtime reconnects and state is synchronized.

Before enabling a mutation, the client refreshes the current room version.

If both realtime and polling fail, mutation controls disable and the interface
shows **Connection lost**. The client never guesses the current draft state.

Spectators may receive delayed updates without affecting authoritative room
operation.

### Verified platform outage

Picks are never queued locally or accepted without a database commit.

If the authoritative SAL API or database becomes unavailable:

- clients display **Draft service unavailable**;
- mutation controls disable; and
- the system records service-health evidence outside the unavailable request
  path.

On recovery, the system determines whether a verified platform outage overlapped
the active slot's deadline.

If a verified outage overlapped the deadline:

- the slot is not automatically forfeited;
- the room enters `recovery_paused`;
- remaining time is restored from the last verified healthy timestamp;
- a configured minimum recovery allowance is applied;
- the recovery decision is audited; and
- an administrator reviews and explicitly resumes the room.

If no verified platform outage overlapped the deadline, normal timeout resolution
applies.

An individual captain's device or internet failure is not a platform outage.

### Completion review and atomic roster publication

Resolving the final slot moves the room into `completion_review`.

During `completion_review`:

- pick and skip submissions stop;
- no pick timer runs;
- canonical season rosters remain unpublished;
- administrators review every pick, skip, vacancy, and resulting roster;
- administrators may repeatedly undo and redo; and
- private reminders continue until an administrator concludes the room.

An authorized administrator concludes the room with:

**End Draft & Publish Rosters**

The action requires explicit confirmation. A private reason is not required.

End Draft invokes the shared idempotent finalization function.

Finalization:

1. locks the room;
2. verifies the room is in `completion_review`;
3. verifies every draft slot is resolved by a canonical pick or recorded skip;
4. verifies the immutable configuration snapshot;
5. revalidates every canonical selected player;
6. publishes every canonical pick to `season_rosters` atomically;
7. preserves skipped slots as roster vacancies;
8. marks the room complete;
9. records completion and publication timestamps;
10. permanently closes undo and redo;
11. appends the immutable audit result; and
12. enqueues one durable division draft-conclusion event.

Normal draft picks do not create individual public transactions-channel entries.

The draft-conclusion event follows ADR-009 and links to the canonical division
roster page.

No captain, spectator, caster, production client, or overlay publishes rosters.

### Recovery-only finalization

Administrators receive a recovery finalization action only when:

- every slot has a canonical resolution;
- the room reached `completion_review`;
- canonical publication remains incomplete; and
- the room is eligible for idempotent recovery.

The action calls the same finalization function used by **End Draft & Publish
Rosters**. It does not maintain a second publication path.

It refuses to publish while any slot is unresolved.

If the room is already finalized, it safely returns the existing result.

Every recovery-finalization attempt is audited.

## Verification contract

Draft-engine verification uses three layers.

### Database integration

`sal-database` runs the complete migration sequence against a disposable
Postgres/Supabase environment in CI.

Database integration tests call the real draft functions through independent
database connections. They do not replace concurrency behavior with mocked
application helpers.

Required race tests include:

- pick versus pick for one slot;
- pick versus skip for one slot;
- confirmed pick versus timeout resolution;
- timeout auto-pick versus skip;
- undo versus a new pick;
- competing season-scoped picks for one player across division rooms;
- simultaneous claim or roster publication conflicts; and
- duplicate End Draft requests.

Each race test proves:

- exactly one canonical result where exclusivity is required;
- deterministic conflict responses for losing operations;
- no partial roster, slot, timer, or audit mutation;
- immutable event history;
- correct room version advancement; and
- idempotent retry behavior.

Every migration that changes draft behavior adds or updates a database integration
test before release.

### Site contract and interface tests

`sal-site` tests authorization, request validation, audience projections,
privacy boundaries, stale versions, error mapping, and responsive interaction
against the published database contract.

Unit and route tests may mock the database boundary. They do not claim to verify
Postgres locking or transactional concurrency.

Required site coverage includes:

- pick-sequence generation;
- turn-ownership rejection;
- division-tier eligibility;
- staged selection and confirmation;
- timeout auto-pick messaging;
- pick and skip conflict responses;
- repeatable undo and redo;
- completion review and End Draft;
- spectator, captain, administrator, production, and overlay field filtering;
- ghost-pick privacy;
- Discord role authorization;
- realtime-to-polling degradation;
- reconnect behavior;
- responsive production-board zoom and mobile fallback; and
- accessible keyboard and touch controls.

### Cross-repository end-to-end tests

A cross-repository suite runs the built `sal-site` application against the
disposable migrated database.

It verifies complete workflows for:

- captain authentication and organization-seat authorization;
- room opening, readiness, and start;
- staging and confirming a pick;
- staged-player timeout auto-pick;
- timeout skip without a staged player;
- manual pause and resume;
- repeated undo and redo;
- administrator-submitted emergency picks;
- completion review;
- End Draft roster publication;
- spectator and production projections; and
- durable draft-conclusion event creation.

### Production safety

Production verification remains read-only.

CI and local verification scripts must reject draft mutations when configured
against a production database.

Production smoke tests may verify schema contracts, required functions, safe
views, and read-only health checks. They never create rooms, stage players,
resolve slots, alter rosters, or publish draft conclusions.

## Consequences

### Positive

- Draft setup exposes only the choices administrators actually need.
- Predetermined organization order remains easy to inspect and rearrange.
- Active draft rules and history cannot change mid-draft.
- Captain turnover is handled through Discord roles without issuing secret
  links.
- One organization can field independently authorized teams in every division.
- Captain and administrator reconnects do not depend on one host browser.
- Staged selections protect captains who selected but did not confirm before
  timeout.
- Picks, skips, auto-picks, and finalization share atomic database boundaries.
- Realtime transport failures degrade without becoming data-integrity failures.
- Verified platform outages do not unfairly forfeit an active pick.
- Roster publication and draft conclusion become idempotent and recoverable.
- Administrators can repeatedly undo and redo draft history without deleting
  audit evidence.
- Production receives an explicit review boundary before roster publication.
- Caster, Production, and overlay authorization use canonical audited mappings
  and credentials.

### Negative

- Discord captain-role and organization-role mappings become required
  operational configuration.
- Existing verified sessions need carefully bounded behavior during Discord
  outages.
- Persisted staged selections add server writes before final confirmation.
- Platform-outage protection requires trustworthy service-health evidence.
- Drag-and-drop requires an accessible non-drag fallback.
- Administrators remain responsible for deciding whether an individual
  disconnect warrants a manual pause.
- A staged player becoming unavailable before timeout still results in a skipped
  slot.
- Explicit End Draft publication can remain pending if administrators leave the
  room in completion review.
- Repeatable undo and redo require an event-backed canonical history model.
- Rewinding clears displaced staged selections and may require captains to
  reselect players.

## Implementation ownership

### `diese-tech/sal-database`

- Add canonical division-captain-role mappings.
- Add canonical organization-role mappings.
- Add room configuration snapshots and versioning.
- Add organization-seat readiness.
- Add server-persisted staged selections.
- Add atomic slot resolution for confirmed picks, timeout auto-picks, and skips.
- Add authoritative deadlines and stored pause remainder.
- Add room lifecycle, void, replacement, and recovery states.
- Add service-outage recovery evidence and transitions.
- Add event-backed canonical history branches for repeatable undo and redo.
- Add public-safe correction events.
- Add `completion_review` to the room lifecycle.
- Add canonical Caster and Production Discord role mappings.
- Add hashed, room-scoped, expiring, revocable overlay credentials.
- Attribute administrator-submitted emergency picks.
- Add idempotent End Draft finalization and atomic `season_rosters`
  publication from `completion_review`.
- Add durable draft-conclusion outbox events.
- Add deterministic locking, concurrency, timeout, and recovery tests.
- Run the full migration sequence against disposable Postgres/Supabase in CI.
- Test real functions through concurrent independent database connections.
- Reject production-mutating verification commands.
- Publish updated immutable consumer types and a database release.

### `diese-tech/sal-site`

- Reduce room creation to division and rounds.
- Derive the active season and participating organizations.
- Implement the ordered draft-list editor with drag, up, and down controls.
- Implement the open, ready, start, pause, resume, recovery, void, and finalization
  interfaces.
- Authenticate captains through Discord OAuth.
- Authorize organization seats through division-captain and organization roles.
- Implement emergency captain access codes.
- Persist and clearly label staged player selections.
- Implement server-authorized spectator, captain, administrator, production, and
  overlay projections according to SAL Site ADR-0001.
- Implement repeatable Undo Resolution and Redo Resolution controls.
- Implement the completion-review summary and End Draft & Publish Rosters
  confirmation.
- Implement administrator-submitted emergency picks.
- Implement the responsive 1920×1080 production board and secure overlay access.
- Implement realtime-to-polling degradation.
- Show captain presence, readiness, reconnect, degraded connection, and recovery
  states.
- Submit every mutation with the expected room version and slot.
- Link the draft-engine audit and implementation documentation to this ADR.
- Add route, state-machine, authorization, concurrency, timer, reconnect,
  accessibility, outage, and end-to-end tests.
- Maintain contract, privacy, authorization, responsive, accessibility, and
  failure-state tests without overstating mocked concurrency coverage.
- Run cross-repository draft E2E workflows against the disposable migrated
  database.

### `diese-tech/lab-salbot`

- Add audited commands for division-captain-role mappings.
- Add audited commands for organization-role mappings.
- Keep ordinary player division-role mappings separate.
- Add audited commands for Caster and Production role mappings.
- Support authorization refresh and role-change invalidation where bot events are
  used.
- Retry draft-conclusion delivery according to ADR-009.
- Deliver draft-conclusion events only after End Draft publication succeeds.
- Test durable draft-conclusion delivery, retry idempotency, role-mapping
  authorization, and failure alerts against published database event fixtures.
- Link Discord operations documentation to this ADR.

## Acceptance criteria

1. Only one unresolved room exists per season division.
2. Only one room per season is active or paused at a time.
3. Room creation exposes only division and rounds.
4. The active season and participating organizations are derived automatically.
5. The pick timer uses the versioned league default.
6. Every participating organization appears exactly once in the saved order.
7. Draft ordering supports drag-and-drop and accessible up/down controls.
8. Approved Draft Position Swaps update the order only before room start.
9. Material pre-start changes clear every readiness state.
10. Starting creates an immutable configuration snapshot.
11. Active room configuration cannot be edited.
12. Correcting active configuration requires a linked void and replacement.
13. Every organization must be ready before normal start.
14. An emergency start without full readiness requires confirmation, a private
    reason, and an audit record.
15. Captain authorization requires the room division's captain role and exactly
    one participating organization role.
16. One organization may have separately authorized captains in every division.
17. Ambiguous organization roles deny access and warn administrators.
18. Multiple authorized captains cannot resolve one slot twice.
19. Administrator disconnects never alter room state.
20. Conflicting administrator actions serialize at the database boundary.
21. Existing verified sessions receive only the configured Discord-outage grace
    period.
22. Emergency access is room-bound, organization-bound, non-admin, temporary,
    revocable, and audited.
23. Selecting a player persists a staged selection for the current slot.
24. The interface warns that a staged player will auto-pick at expiration.
25. A staged selection survives reconnect but does not reserve the player across
    rooms.
26. Explicit confirmation commits through the atomic slot-resolution function.
27. A valid staged player is automatically picked when the deadline expires.
28. No staged player at expiration creates a timeout skip.
29. An unavailable staged player at expiration creates a timeout skip.
30. A pick and skip racing for one slot cannot both succeed.
31. Every slot advances at most once.
32. A skipped slot remains immutable draft history and a roster vacancy.
33. Client clocks never determine whether a pick is timely.
34. Pausing stores remaining time and resuming establishes a new deadline.
35. Captain disconnects do not automatically pause the room.
36. Reconnecting restores current authoritative state.
37. Realtime failure falls back to polling.
38. Losing both realtime and polling disables mutation controls.
39. No mutation is queued or accepted locally during a platform outage.
40. A verified platform outage overlapping a deadline creates a recovery pause
    instead of a forfeiture.
41. Individual captain connectivity failures do not trigger platform-outage
    protection.
42. Administrators may repeatedly undo canonical resolutions while paused or in
    completion review.
43. Every undo appends a reversal event and preserves the original resolution.
44. Reversed picks release their players and reversed skips remove their
    vacancies.
45. Undo clears staged selections belonging to displaced later slots.
46. Administrators may redo valid abandoned resolutions before a new canonical
    branch is created.
47. Redo stops when the prior resolution is no longer valid.
48. Private undo and redo reasons are optional but encouraged.
49. Public projections show correction events without private reasons.
50. Resolving the final slot enters `completion_review`.
51. Season rosters remain unpublished during completion review.
52. End Draft & Publish Rosters requires explicit administrator confirmation.
53. End Draft invokes the shared idempotent finalization function.
54. Finalization publishes all canonical picks to `season_rosters` atomically.
55. Skipped slots publish as roster vacancies.
56. Successful publication permanently closes undo and redo.
57. Finalization emits exactly one durable division conclusion event.
58. Normal draft picks do not create individual transactions-channel entries.
59. Recovery and normal End Draft publication use the same database function.
60. An already-finalized room returns its existing finalization result safely.
61. Caster and Production role mappings are canonical and audited.
62. Overlay credentials are hashed, room-bound, expiring, revocable, and invalid
    after conclusion.
63. Administrator-submitted emergency picks use the same atomic slot-resolution
    invariants as captain picks.
64. Database integration tests execute real draft functions against disposable
    migrated Postgres/Supabase.
65. Concurrency tests use independent database connections.
66. Required races prove one canonical result and no partial mutation.
67. Every draft-behavior migration updates database integration coverage.
68. Site tests explicitly distinguish mocked contract coverage from database
    concurrency coverage.
69. Cross-repository E2E tests run the built site against the disposable migrated
    database.
70. Cross-repository E2E covers staging, confirmation, timeout, skip, undo, redo,
    completion review, End Draft, and roster publication.
71. Audience-projection tests prove ghost picks and private audit data never
    reach unauthorized clients.
72. Production verification is read-only and rejects draft mutations.
