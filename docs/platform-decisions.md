# SAL Draft and Roster Decisions in Plain English

This guide explains what the accepted SAL platform ADRs mean without requiring
readers to interpret schema or concurrency language. It is a product and
implementation guide, not a replacement for the canonical ADRs.

## What this repository owns

`sal-database` owns the rules that must remain true regardless of whether an
action comes from the website, SALBot, a retrying worker, or two users acting at
the same time:

- season and division draft eligibility;
- room, slot, timer, pick, skip, undo, redo, and finalization state;
- roster transactions and approvals;
- immutable audit history;
- durable events consumed by the site and bot; and
- generated types and immutable releases used by both consumers.

The site owns the web experience. SALBot owns Discord intake and delivery.
Neither consumer may invent a second version of a database rule.

## Draft eligibility

- Every division runs its own draft room.
- Drafts may run in either direction, although the league will normally run the
  highest division first.
- Only one room in a season may be live or paused at a time.
- A player can be drafted only once in a season, even across different division
  rooms.
- That player can join a different team in a later season.
- A confirmed player cannot be poached by a room that runs later.

The competitive order is Terra, Solar, Lunar from highest to lowest:

| Draft room | Normal pool | Manual Draft Up search |
| --- | --- | --- |
| Terra | Terra players | Solar players |
| Solar | Solar players | Lunar players |
| Lunar | Lunar players | None |

Players may move up exactly one division. They may never be drafted downward,
and Terra cannot reach past Solar to draft Lunar.

The normal pool stays uncluttered by showing only the room's own division.
Drafting up uses a separate autocomplete that returns real, available,
season-eligible players. Typed text alone is never a player identity.

## Picks, timeouts, and skipped slots

Selecting a player stages the choice. Confirming commits it immediately.

If time expires:

- a still-valid staged player is automatically picked; or
- no valid staged player produces a recorded skipped slot.

A skip is permanent history, not a delayed pick. The team loses that value pick
at that moment and waits until the draft ends to ask administrators to fill the
vacancy through the normal claim process.

The database resolves confirm, timeout, and skip against the expected room
version and slot. Only one competing action can win.

## Draft rooms and access

Each room belongs to one season and one division. Before opening it, admins
configure the number of rounds and the predetermined order using drag-and-drop
with accessible up/down controls. A draft-position swap may change the base
order before the room starts.

Captains do not receive permanent person-specific draft links. Access is based
on Discord OAuth plus:

- the Captain role for the room's division; and
- the organization role for the team occupying that division seat.

This allows captaincy changes and lets one organization field a different team
in every division. Ambiguous or missing role mappings block access. Emergency
codes are short-lived, bound to one room and one organization, hashed,
revocable, and audited. An emergency code grants only that organization seat's
captain access and can never grant administrator access.

Admins open the room, wait for captains to become ready, and start when
production is ready. Disconnects do not reset the room or timer. Clients
reconnect to authoritative server state and fall back to polling if realtime
delivery fails.

## Undo and redo

Undo behaves like a real history cursor, not a one-time correction button.
While paused, an admin may undo repeatedly and redo repeatedly.

History is never deleted. Reversed picks and skips remain immutable events, and
the current canonical branch determines the live result. A private reason is
optional but encouraged. Public views receive only safe correction events.

## Ending a draft

Resolving the last slot does not publish rosters immediately. The room enters
completion review so admins can inspect picks, skips, ghost/staged state, and
audit history.

**End Draft & Publish Rosters** then performs one atomic operation:

- verifies every slot;
- writes the canonical season rosters;
- preserves vacancies caused by skips;
- finalizes the room permanently; and
- emits one durable division draft-conclusion event.

Retries cannot publish duplicate rosters or duplicate conclusion events.

## Claims, drops, trades, and draft-position swaps

All roster changes require admin approval, including captain-approved trades.
Only a completed transaction changes canonical state.

- Claims do not reserve a player while pending.
- Admins may weigh timestamps and current standings, normally favoring the
  lower-seeded team, but the database does not automatically select a waiver
  winner.
- Drops may optionally carry a private ban or suspension decision.
- Trades may be uneven, but every resulting roster must have enough open slots.
- Player trades stay within one season and division.
- Counteroffers create a new revision and invalidate consent to the old one.
- Draft-position swaps exchange complete base positions, allow no other
  compensation, and close when the room starts.

Completed transactions write an immutable audit record and a public-safe ledger
event. Pending, rejected, blocked, withdrawn, and private disciplinary details
are not public.

## Public bulletin and Discord roles

The public ledger starts with one division label. Desktop may show full
organization names; constrained mobile layouts use canonical tags:

```text
[SOLAR] FF traded Crow to TC for The_Expert133
[LUNAR] EV claimed XGN Ninja
```

SALBot consumes durable events, posts the consolidated Discord transaction, and
reconciles organization roles to the resulting canonical roster. A Discord
failure never rolls back a database transaction. Ambiguous delivery or failed
role movement is retried or sent to the private admin channel for remediation.

Normal draft picks are not posted as transactions. Successful End Draft
publication produces one conclusion message linking to the division rosters.

## Canonical references

- [ADR-0001: Season-scoped captain-roster draft eligibility](adr/0001-season-scoped-captain-roster-draft-eligibility.md)
- [ADR-0002: Roster transactions and public bulletin](adr/0002-roster-transactions-and-public-bulletin.md)
- [ADR-0003: Draft room lifecycle, authorization, and failure recovery](adr/0003-draft-room-lifecycle-authorization-and-failure-recovery.md)
- [SAL Site audience and production ADR](https://github.com/diese-tech/sal-site/blob/main/docs/adr/0001-audience-specific-draft-views-and-production-board.md)
- [SALBot Discord transaction ADR](https://github.com/diese-tech/lab-salbot/blob/main/docs/adrs/ADR-009-roster-transactions-discord-workflow.md)
