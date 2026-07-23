# ADR-0002: Roster Transactions and Public Bulletin

- Status: Accepted
- Date: 2026-07-22
- Owners: SAL database and SAL site maintainers
- Related ADRs:
  - [ADR-0001: Season-Scoped Captain-Roster Draft Eligibility](0001-season-scoped-captain-roster-draft-eligibility.md)
  - [ADR-009: Roster Transactions Discord Workflow](https://github.com/diese-tech/lab-salbot/blob/main/docs/adrs/ADR-009-roster-transactions-discord-workflow.md)
- Related findings: DE-00
- Related issues: diese-tech/sal-site#210

## Context

SAL needs a consistent way to change season rosters after their initial
assignment.

The required workflows include:

- claiming an available player;
- dropping a rostered player;
- trading players between organizations;
- swapping complete draft positions before a draft starts;
- filling a roster vacancy created by a skipped draft pick; and
- reversing an incorrect completed transaction.

These changes currently risk becoming direct edits to `season_rosters` without a
complete domain record explaining who requested the change, who agreed, who
approved it, or how the public roster changed.

SAL also needs a public transactions bulletin. The bulletin should communicate
completed roster movement cleanly without exposing private administrative
reasons, sanctions, pending negotiations, rejected requests, or approval
metadata.

The canonical transaction record belongs in `sal-database`. `sal-site` owns the
captain and administrator web workflows and the public web bulletin projection.
`lab-salbot` owns the Discord command, consent, administrator-review, role
synchronization, and transactions-channel projections defined by ADR-009.

## Decision

### Canonical transaction ledger

`sal-database` will own an immutable roster-transaction ledger.

A transaction records:

- transaction type;
- season;
- division;
- involved organizations;
- involved players;
- initiating captain or administrator;
- required captain approvals;
- administrator decision;
- status;
- creation, acceptance, approval, execution, and cancellation timestamps;
- links to prior proposal revisions;
- links to reversed or corrective transactions;
- private administrative reason fields;
- public-safe display data; and
- durable audit and outbox references.

Completed transaction records are never edited or deleted.

### Transaction types

The initial transaction types are:

- `claim`;
- `drop`;
- `trade`;
- `draft_position_swap`; and
- `reversal`.

A skipped draft slot is remediated through a `claim`. It does not require a
separate public transaction type.

### Transaction statuses

Transactions use explicit lifecycle states:

- `proposed`;
- `awaiting_acceptance`;
- `awaiting_admin`;
- `blocked`;
- `completed`;
- `withdrawn`;
- `denied`;
- `conflicted`;
- `superseded`; and
- `reversed`.

Only a completed transaction changes canonical roster or draft-order state.

Only completed transactions and completed reversals appear in the public
bulletin.

### Shared pending-action orchestration

Every submitted roster transaction creates a linked `pending_actions` record.

The roster-transaction ledger remains the canonical domain record. The
`pending_actions` row is the shared approval-pipeline envelope used for claim,
dispatch, administrator review, retries, and operational visibility.

Captain acceptance and counteroffers update the exact linked transaction
revision. Administrator approval or denial is claimed and dispatched through the
existing pending-action pipeline rather than a second transaction-specific
approval system.

The transaction revision, pending-action state, administrator decision,
immutable `audit_logs` row, roster mutation, and outbox event remain consistent
through authoritative database functions.

### Captain consent

Captain consent remains revocable until administrator execution.

Before execution:

- a claim requester may withdraw the claim;
- a drop requester may withdraw the drop;
- a trade proposer may withdraw the proposal;
- either trade participant may revoke acceptance;
- either Draft Position Swap participant may revoke acceptance; and
- a counteroffer supersedes the previous proposal revision.

Once an administrator commits a transaction, it is final. Undoing its effects
requires a new linked reversal or corrective transaction.

Players involved in claims, drops, or trades do not approve transactions through
the software. Any required player consultation remains a league-administration
responsibility.

### Claims

A claim assigns one available player to one organization without a corresponding
drop.

A claim requires:

- an available and eligible player;
- an open roster slot;
- a requesting captain or authorized administrator;
- administrator approval;
- season and division transaction availability; and
- successful database revalidation at execution.

Claims may fill vacancies caused by:

- a skipped draft pick;
- an uneven trade;
- an earlier drop; or
- another approved league roster adjustment.

Pending claims do not reserve a player.

Multiple organizations may hold pending claims for the same player. Claim
timestamps are retained as evidence but do not automatically determine the
winner.

When administrators review competing claims, the interface presents:

- current official standings;
- relative team seed;
- claim timestamps;
- roster capacity; and
- player eligibility.

Lower-seeded and underperforming teams normally receive waiver priority.
Administrators select the successful claim according to league rules. The
software does not impose a claim window or automatically approve the earliest
request.

The successful claim is revalidated and committed atomically. Other pending
claims for the assigned player become `conflicted`.

### Drops

A drop removes one player from an organization's active season roster.

A drop requires:

- the current captain or authorized administrator;
- administrator approval;
- a currently valid roster assignment; and
- open drop transactions for the season.

During approval, the administrator selects the player's post-drop eligibility:

- `eligible`;
- `suspended_until`, with a timestamp; or
- `ineligible_for_season`.

An eligible dropped player immediately becomes a free agent in the same season
and division.

Self-drops, conduct issues, suspensions, and bans remain private administrative
data. They are not displayed in the public transactions bulletin. Public
discipline, when required, is handled through a separate ruling or announcement.

A completed drop does not automatically execute a waiting trade. The trade must
be deliberately revalidated and executed afterward.

### Trades

A trade exchanges one or more players between exactly two organizations.

Trades:

- are restricted to one season;
- are restricted to one division;
- may never move players across divisions;
- may contain equal or uneven player counts;
- require both captains to accept the exact proposal revision;
- require final administrator approval; and
- execute all roster changes atomically.

The database calculates both resulting rosters before committing.

A trade is blocked if either resulting roster exceeds the configured maximum
roster size. Minimum roster size is not enforced during trades. An uneven trade
may create a vacancy, which can later be filled through a separate claim.

Administrator approval does not bypass:

- season identity;
- same-division requirements;
- player ownership;
- player eligibility;
- transaction availability; or
- roster capacity.

A counteroffer creates a new immutable proposal revision linked to the previous
revision. The prior revision becomes `superseded`, and all prior acceptance is
invalidated.

### Draft Position Swaps

A Draft Position Swap exchanges the complete snake-draft positions of exactly
two organizations in the same draft room.

For example, exchanging positions `#1` and `#8` changes each organization's
position throughout the full snake sequence. It does not exchange a single
round's pick.

A Draft Position Swap:

- involves exactly two organizations;
- is restricted to one draft room;
- is restricted to a room that has not started;
- requires both captains to accept the exact proposal;
- requires final administrator approval;
- updates `base_order` atomically;
- closes automatically when the draft room starts; and
- produces a completed ledger and bulletin entry.

Draft Position Swaps may not include:

- players;
- claims;
- future considerations;
- off-platform promises; or
- any other compensation.

Player trades and Draft Position Swaps remain separate transactions.

### Transaction availability

Each season has administrator-controlled availability for:

- claims;
- drops;
- trades; and
- Draft Position Swaps.

Captains cannot submit a new transaction of a closed type.

Administrators may resolve transactions submitted before closure.

Draft Position Swaps also close automatically when their draft room starts.

An emergency administrator override requires a private reason and an audit
record. It does not bypass database invariants such as player ownership,
same-division trades, or roster capacity.

### Database execution

Every completed transaction executes through a dedicated database function.

Execution must:

1. Lock the transaction.
2. Verify its current revision and approval state.
3. Lock affected players, organizations, draft rooms, and season-roster rows in
   a deterministic order.
4. Revalidate season and division identity.
5. Revalidate player ownership and eligibility.
6. Revalidate roster capacity.
7. Apply every roster or draft-order change atomically.
8. Append the immutable transaction result.
9. Append the private audit record.
10. Enqueue the public-safe bulletin projection in the existing operation
    outbox.

If any validation fails, no roster or draft-order mutation commits.

### Discord role synchronization

A completed roster transaction emits durable role-synchronization work through
the operation outbox.

Role changes follow the resulting canonical season roster:

- a claim adds the claiming organization's Discord role to the player;
- a drop removes the releasing organization's Discord role from the player;
- a trade removes each moved player's former organization role and adds the
  receiving organization role;
- a reversal reconciles every affected player's roles to the resulting canonical
  roster; and
- a Draft Position Swap does not change player roles.

The database transaction commits before Discord role synchronization begins.
Discord permissions, availability, or API failures never roll back a valid
database transaction.

Role synchronization is idempotent and retryable. A failed role update remains
pending or failed for reconciliation and posts an alert to the private
administrator channel. The alert identifies the transaction and affected player
without exposing private administrative reasons publicly.

The public transaction bulletin may still publish while role synchronization is
pending because it represents the committed canonical roster state.

### Public transactions bulletin

`sal-site` will expose a public transactions bulletin containing only:

- completed claims;
- completed drops;
- completed trades;
- completed Draft Position Swaps; and
- completed reversals.

Pending, withdrawn, denied, conflicted, blocked, and superseded transactions are
private.

Each bulletin headline begins with one division badge:

```text
[SOLAR] Eternal Vanguard claimed XGN Ninja
[SOLAR] Food Fighters traded Crow to The Crew for The_Expert133
[SOLAR] Food Fighters and Eternal Vanguard swapped draft positions #1 and #8
[SOLAR] Food Fighters released Crow
```

The headline does not include an approval, division, and season footer.

On desktop:

- organizations use their full public names.

On constrained mobile layouts:

- organizations use their canonical `org.tag`;
- full names remain available through links and accessibility labels.

Example:

```text
[SOLAR] FF traded Crow to TC for The_Expert133
```

Organization and player names are linked when public pages exist.

Timestamp and public transaction details may appear as subdued secondary
information. Private administrative reasons and disciplinary details never
appear in the bulletin projection.

### Reversals and corrections

Completed transactions are never removed from the public ledger.

A reversal creates a new linked transaction and bulletin entry:

```text
[SOLAR] Trade between FF and TC was reversed
[SOLAR] EV claim of XGN Ninja was reversed
[SOLAR] FF release of Crow was reversed
```

The original entry remains visible.

The transaction detail view links the original transaction and its reversal.

A reversal restores prior roster state only when that state is still valid. If
restoration would violate player ownership, eligibility, or roster capacity,
administrators must use explicit follow-up claims, drops, or trades.

Private reversal reasons remain in the administrative audit record.

## Consequences

### Positive

- Every roster mutation has one authoritative domain record.
- Claims, drops, trades, and draft-position changes use consistent approval and
  audit behavior.
- Uneven trades are supported without bypassing roster capacity.
- Waiver decisions retain standings and timestamp evidence without hardcoding an
  automatic policy.
- Counteroffers and revoked consent cannot execute stale proposals.
- Public transaction history remains concise and understandable.
- Private sanctions and administrative reasoning are not exposed publicly.
- The existing durable outbox projects completed transactions to the web
  bulletin, the consolidated Discord transactions channel, and Discord role
  synchronization.

### Negative

- The transaction state machine and relational model are substantially more
  complex than direct roster edits.
- Administrators remain responsible for waiver adjudication.
- Uneven trades can create roster vacancies requiring later claims.
- Reversals may require follow-up transactions when direct restoration is no
  longer valid.
- `sal-site` requires new captain negotiation, administrator review, and public
  bulletin interfaces.

## Implementation ownership

### `diese-tech/sal-database`

- Add the canonical transaction, revision, participant, player-movement,
  acceptance, and decision records.
- Add season-level transaction-availability configuration.
- Add player post-drop eligibility state.
- Add atomic execution functions for every transaction type.
- Add deterministic locking and concurrency tests.
- Add public-safe outbox projections.
- Add reversal linkage and immutable-history guarantees.
- Generate updated consumer types.
- Publish a new immutable database release.

### `diese-tech/sal-site`

- Adopt the new database release.
- Add captain claim, drop, trade, counteroffer, withdrawal, and Draft Position
  Swap workflows.
- Add administrator transaction review and execution tools.
- Show standings, timestamps, roster capacity, and eligibility during claim
  adjudication.
- Add administrator-controlled transaction availability.
- Add the public transactions bulletin and detail views.
- Use full organization names on desktop and canonical organization tags on
  constrained mobile layouts.
- Add route, state-machine, integration, concurrency, and end-to-end tests.
- Link its audit and architecture documentation to this canonical ADR.

### `diese-tech/lab-salbot`

- Adopt the transaction and outbox contracts published by `sal-database`.
- Implement the ephemeral claim, drop, trade, counteroffer, withdrawal, and
  Draft Position Swap command workflows defined by ADR-009.
- Keep all transaction setup, selection, validation, counteroffer, and review
  interactions ephemeral until the captain explicitly submits or posts them.
- Post public trade proposals only after the initiating captain selects
  **Post Proposal**.
- Route accepted proposals and submitted roster mutations to the private
  administrator-review channel.
- Consume transaction and role-synchronization outbox events through a
  lease-based worker.
- Reconcile affected players' Discord organization roles to the resulting
  canonical season rosters after claims, drops, trades, and reversals.
- Treat role synchronization as idempotent, retryable follow-up work that cannot
  roll back a committed database transaction.
- Post failed role-synchronization alerts to the private administrator channel
  for reconciliation.
- Publish completed transactions once to the consolidated Discord transactions
  channel.
- Use the division chip and canonical organization tags in mobile-safe
  transaction messages.
- Record delivery idempotency so retries cannot duplicate public messages.
- Link its Discord workflow documentation to this canonical database ADR.

## Acceptance criteria

1. No transaction mutates a roster or draft order before required approval.
2. Captain consent can be revoked until execution.
3. Counteroffers invalidate every acceptance of the superseded revision.
4. Claims require an open roster slot and an eligible available player.
5. Pending claims never reserve a player.
6. Competing claims expose standings, seed, and timestamp evidence to
   administrators.
7. Exactly one competing claim can assign the player.
8. Eligible dropped players immediately become same-division free agents.
9. Suspended or season-ineligible dropped players cannot be claimed.
10. Sanction details remain private.
11. Trades may be equal or uneven.
12. Trades are always same-season and same-division.
13. Trades execute every player movement atomically.
14. Trades exceeding roster capacity are blocked.
15. Draft Position Swaps exchange complete snake-draft positions.
16. Draft Position Swaps contain no additional compensation.
17. Draft Position Swaps cannot execute after the room starts.
18. Closed transaction types reject new captain requests.
19. Completed transactions produce one immutable audit record and one public-safe
    outbox event.
20. The bulletin shows one division badge at the start of each headline.
21. Mobile headlines use canonical organization tags.
22. Pending and unsuccessful transactions never appear publicly.
23. Reversals preserve and link the original public transaction.
24. Cross-division captain trades are rejected at the database boundary.
25. Every completed transaction is available to both web and Discord bulletin
    consumers through the durable outbox.
26. Discord delivery retries cannot create duplicate transaction posts.
27. Incomplete or unposted Discord transaction workflows create no public
    proposal or completed-transaction message.
28. Claims, drops, trades, and reversals enqueue Discord role synchronization
    matching the resulting canonical season rosters.
29. Draft Position Swaps never change player organization roles.
30. Discord role failures never roll back completed database transactions.
31. Failed role synchronization remains retryable and posts an actionable alert
    to the private administrator channel.
32. Every submitted transaction has a linked `pending_actions` orchestration
    record.
33. Administrator decisions use the shared pending-action claim and dispatch
    pipeline.
34. Every completed roster mutation appends an immutable `audit_logs` row with
    the actor and old/new values in the authoritative transaction.
