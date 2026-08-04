# ADR-0004: Multi-Division Season Team Identity

- Status: Accepted
- Date: 2026-08-03
- Owners: SAL database and SAL site maintainers
- Related issue: diese-tech/sal-site#237

## Context

An organization is a league-wide identity and brand. It may field a team in
every division, in some divisions, or in no division during a given season.
The legacy `orgs.division_id` column cannot express that relationship.

The original `season_orgs` primary key used `(season_id, org_id)`. That key,
the match foreign keys, captain uniqueness, and application lookups therefore
collapsed every organization to one division per season. Preseason also needs
to record captain candidates before an organization or team is selected.

## Decision

The canonical season-team identity is:

```text
(season_id, org_id, division_id)
```

The database enforces the following rules:

1. One organization may have at most one team in each division of a season.
2. The same organization may have teams in multiple divisions of that season.
3. A match's home and away organizations must reference teams in the match's
   own season and division.
4. An assigned player references exactly one existing season team through the
   same three columns.
5. Each divisional season team has at most one active captain.
6. A free-agent preseason player may be marked as a captain candidate without
   an organization. Multiple unassigned candidates are allowed.

`orgs.division_id` remains only as a legacy/default display value for older
identity-editing surfaces. It is not authoritative for season participation.
`orgs.captain_id` likewise cannot represent divisional captains; canonical
captain reads and writes use `season_rosters`.

## Data transition

Existing rows retain their current division when the primary key changes.
Before the stricter match foreign keys are installed, the migration adds any
missing historical divisional team rows evidenced by matches, preserving the
existing assignment status. The operation is idempotent.

## Consequences

- Admin enrollment and removal operations must always include a division.
- Player assignment lookups must specify both organization and division; a
  season-and-organization-only `.single()` lookup is invalid.
- Standings, captains, React keys, team links, draft publication, and preseason
  ingest must use the composite team identity.
- Global organization records remain reusable and must never be duplicated to
  represent another division or season.
