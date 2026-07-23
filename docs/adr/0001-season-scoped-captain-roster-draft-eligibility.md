# ADR-0001: Season-Scoped Captain-Roster Draft Eligibility

- Status: Accepted
- Date: 2026-07-22
- Owners: SAL database and SAL site maintainers
- Related findings: DE-00, DE-01, DE-04
- Related issues: diese-tech/sal-site#206, diese-tech/sal-site#210

## Context

SAL conducts a separate captain-roster draft for each competitive division.

The current application allows cross-division drafting but only excludes players
already picked in the current draft room. Consequently, two rooms in the same
season can record picks for the same player.

Player eligibility must be season-scoped. A player may represent a different
organization or division in a later season, but may have only one confirmed
draft assignment within a single season.

Captains should normally browse only players registered in their room's
division. Showing lower-division players in the main pool creates unnecessary
clutter. Captains still need an explicit way to draft an available player upward
from the immediately lower division.

Division drafts are separate events and may be conducted in any order. They are
not expected to run simultaneously. The administrator chooses the order based on
league and production needs. Conducting higher-division drafts first preserves
their opportunity to draft players upward, but this ordering is not a database
requirement.

A player already confirmed by an earlier division draft cannot be taken by a
later draft. Correcting a confirmed assignment requires a separate audited
administrator workflow.

## Decision

### Division hierarchy

The canonical division hierarchy will be stored in `sal-database`.

Each division will have a required numeric `draft_tier`:

| Division | Draft tier |
|---|---:|
| Terra | 1 |
| Solar | 2 |
| Lunar | 3 |

Lower numeric values represent higher competitive divisions.

A player may be drafted into:

- their registered division; or
- the division exactly one tier above their registered division.

Eligibility is defined as:

```text
player registration tier - destination draft tier IN (0, 1)
```

Therefore:

- Terra may draft Terra or Solar players.
- Solar may draft Solar or Lunar players.
- Lunar may draft Lunar players only.
- Terra may not draft Lunar players.
- Players may never be drafted downward.

Draft tiers are controlled through reviewed database migrations. They are not
casually editable through the site administrator interface.

### Season-wide pick uniqueness

`draft_picks` will carry the season identity required to enforce uniqueness
without relying on an application read-before-write check.

The migration will:

1. Add `season_id` to `draft_picks`.
2. Backfill it from each pick's associated `draft_room`.
3. Make `season_id` non-null.
4. Add or retain the relational constraints needed to prove that a pick's
   `season_id` matches its room's season.
5. Add a unique constraint on:

   ```text
   (season_id, player_id)
   ```

The database must reject a second confirmed pick for the same player in the same
season, regardless of which room or application client submits it.

The same player remains eligible in another season.

### Atomic pick submission

The canonical `submit_draft_pick` RPC will:

1. Lock and revalidate the destination draft room.
2. Derive and verify the room's season.
3. Load the destination division's `draft_tier`.
4. Load the player's registered division and its `draft_tier`.
5. Reject a player more than one tier below the destination division.
6. Reject a player above the destination division.
7. Reject a player already picked anywhere in that season.
8. Insert the season-scoped pick.
9. Advance the room in the same transaction.

The database unique constraint remains the final protection if concurrent
requests pass earlier validation.

The RPC remains callable only through the trusted service-role path.

### Concurrent draft rooms

The database will prohibit more than one room in `active` or `paused` status for
the same season.

Multiple rooms may exist in a pre-draft state so administrators can prepare
future division events. Only one room may own the live season draft at a time.

### SAL Site player pool

The normal draft pool will show only:

- players registered in the room's own division;
- players belonging to the room's season; and
- players not already confirmed by another room in that season.

Lower-division players will not appear in the normal pool.

### Draft Up Search

A separate `Draft Up` action will open an autocomplete search.

The search will:

- query only players from the immediately lower division;
- restrict results to the current season;
- exclude every player already confirmed in that season;
- narrow suggestions as the captain types;
- display enough identity information to distinguish similar names; and
- require selection of an existing suggestion.

For example:

- Terra's Draft Up Search includes eligible Solar players.
- Solar's Draft Up Search includes eligible Lunar players.
- Lunar has no Draft Up Search because no lower division exists.
- Terra's Draft Up Search never includes Lunar players.

Arbitrary free-text values cannot be submitted as player identities.

Selecting a suggestion does not commit the pick.

### Pick confirmation

Every pick, whether selected from the normal pool or Draft Up Search, enters a
pending client-side confirmation state.

The pending-pick card will identify:

- player name;
- registered division;
- destination division;
- relevant player role information; and
- organization receiving the pick.

Only `Confirm Pick` calls the atomic pick RPC.

If the turn changes, the room pauses, the player becomes unavailable, or the
submission conflicts, the pending selection is cleared and no pick is recorded.

### Finality

Once a pick is confirmed:

- the player is unavailable to every later draft room in that season;
- a higher division cannot poach the player;
- draft order does not grant an exception; and
- changing the assignment requires a separate audited administrator correction.

Roster finalization must write the resulting assignment to the canonical
season-scoped roster model. The detailed finalization transaction and correction
workflow will be specified separately.

## Consequences

### Positive

- Duplicate cross-room picks become impossible at the database boundary.
- Returning players remain eligible in later seasons.
- Drafting upward one division is supported without cluttering the normal pool.
- Terra cannot bypass Solar and pull directly from Lunar.
- Division names are no longer hardcoded into eligibility comparisons.
- Draft rooms may be prepared independently while only one live draft controls
  the season.
- Accidental autocomplete clicks cannot immediately commit a pick.

### Negative

- `draft_picks` gains denormalized season identity and additional constraints.
- The database RPC and generated consumer contract must change.
- `sal-site` must adopt a new database release before using the updated flow.
- Administrators who conduct lower-division drafts first intentionally reduce
  the pool available to later higher-division drafts.
- Correcting a confirmed pick requires a deliberately separate workflow.

## Implementation ownership

### `diese-tech/sal-database`

- Add and seed `divisions.draft_tier`.
- Add and backfill `draft_picks.season_id`.
- Add relational and season-player uniqueness constraints.
- Update `submit_draft_pick` with the one-tier eligibility rule.
- Enforce one active-or-paused room per season.
- Add database contract and concurrency tests.
- Generate updated TypeScript types.
- Publish a new immutable database release.

### `diese-tech/sal-site`

- Adopt the new database release and generated types.
- Remove hardcoded division-tier eligibility.
- Restrict the normal pool to the room's own division.
- Add one-tier Draft Up Search.
- Add the pending-pick confirmation interface.
- Handle database eligibility and uniqueness conflicts.
- Hide confirmed players from every remaining room in the season.
- Add route, component, integration, and end-to-end coverage.

## Acceptance criteria

1. Two rooms cannot confirm the same player for one season, including under
   concurrent database connections.
2. The same player can be drafted again in a different season.
3. Terra may draft Terra or Solar players.
4. Terra may not draft Lunar players.
5. Solar may draft Solar or Lunar players.
6. Lunar may draft Lunar players only.
7. No player may be drafted downward.
8. The normal pool shows only the room's registered division.
9. Draft Up Search returns only eligible, undrafted players from the immediately
   lower division.
10. Free text that does not resolve to a real eligible player cannot be
    submitted.
11. Selecting a player never commits without explicit confirmation.
12. A confirmed lower-division pick cannot be poached by a later higher-division
    draft.
13. No more than one room per season can be active or paused.
14. Generated database types and the `sal-site` contract lock reference the new
    immutable database release.
