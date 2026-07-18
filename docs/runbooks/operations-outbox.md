# Transactional decisions and operation outbox

This runbook covers the Release A decision RPCs and durable projection queue
introduced by migration `20260718230000_transactional_decisions_outbox.sql`.
The migration is tracked by `diese-tech/sal-database#40`. It is not a release,
deployment, or authorization to push production by itself.

## Safety contract

- Call every RPC with a service-role Supabase client. `PUBLIC`, `anon`, and
  `authenticated` have no execution or table privileges.
- Never update `matches`, `player_stats`, `pending_actions`, or
  `pending_stat_records` in an application approval handler. Call the matching
  decision RPC.
- A decision's domain mutation, lifecycle/domain audits, and outbox rows commit
  together. Any error means the entire decision rolled back.
- `alias_change` approval intentionally raises `0A000` and leaves the action
  unchanged until a dedicated identity migration defines that mutation.
- Terminal decisions are idempotent. A repeated request returns
  `already_processed` and does not add audits or outbox rows.
- A result or reschedule whose match is no longer `scheduled` becomes
  `cancelled` with code `stale_cancelled`; it is never falsely approved.

## Decision RPCs

### Create an action

```sql
select public.create_pending_action(
  p_type := 'match_result',
  p_requested_by_discord_id := '123456789',
  p_match_id := 'match-id',
  p_division_id := 'terra',
  p_payload := '{
    "winnerOrgId": "winner-org-id",
    "score": "2-1",
    "parsed": {
      "winnerGames": 2,
      "loserGames": 1,
      "gamesPlayed": 3,
      "expectedScreenshots": 6
    }
  }'::jsonb
);
```

Active result/reschedule duplicates for the same match and type return the
existing action with `created=false`.

### Resolve an action

```sql
select public.resolve_pending_action(
  p_action_id := 'pending-action-id',
  p_actor_discord_id := 'admin-discord-id',
  p_decision := 'approve', -- approve | deny | needs_info
  p_note := null
);
```

Approval and denial are valid from `pending` or `pending_info`. `needs_info` is
valid only from `pending`. Denial and Needs Info require a non-empty note.

### Resolve a stat record

```sql
select public.resolve_pending_stat_record(
  p_record_id := 'pending-stat-record-id',
  p_actor_discord_id := 'admin-discord-id',
  p_decision := 'approve', -- approve | deny
  p_note := 'Verified both screenshots.'
);
```

Approval requires a known player, a completed match, a winner, a positive
integer `game_number`, and non-negative integer counters. It upserts
`player_stats`, refreshes `players.stats`, audits both records, and enqueues
projections in the same transaction. Denial requires a note.

## Worker contract

1. Give each bot process a stable instance-scoped worker ID.
2. Poll every five seconds and immediately drain again after a successful
   decision or delivery.
3. Claim at most the number of messages the process can start promptly:

   ```sql
   select * from public.claim_operation_outbox('railway-instance-id', 25);
   ```

4. Each returned row is leased for exactly 60 seconds. Start work immediately.
5. Make external delivery idempotent:
   - edit Discord messages by their stored message ID;
   - use the outbox UUID as the marker/deduplication identity for sends;
   - send standings requests with `Idempotency-Key`, `outboxId`, and
     `seasonId` from the payload.
6. After success, persist any Discord/external identifier:

   ```sql
   select public.complete_operation_outbox(
     'outbox-uuid'::uuid,
     'railway-instance-id',
     'discord-message-id'
   );
   ```

7. On failure, calculate jittered exponential backoff in the worker and pass
   the delay. PostgreSQL caps it at 900 seconds. The tenth claimed attempt
   dead-letters the row:

   ```sql
   select public.fail_operation_outbox(
     'outbox-uuid'::uuid,
     'railway-instance-id',
     'sanitized error text',
     120
   );
   ```

8. On SIGTERM, stop claiming, finish or fail the current delivery within its
   lease, destroy the Discord client, and exit. An abandoned lease becomes
   claimable after 60 seconds.

Supported initial topics are:

- `discord_review_projection`
- `discord_receipt_projection`
- `discord_captain_notification`
- `proof_thread_closure`
- `standings_recalculation`

Unknown topics must be failed with a sanitized error rather than acknowledged.

## Inspection

Run these through a protected operator connection. Do not expose payloads or
errors in public logs because they may contain admin notes or Discord IDs.

Queue depth and oldest age:

```sql
select
  state,
  count(*) as rows,
  min(created_at) as oldest_created_at,
  max(now() - created_at) as oldest_age
from public.operation_outbox
where state in ('pending', 'processing', 'dead_letter')
group by state
order by state;
```

Expired leases:

```sql
select id, topic, aggregate_type, aggregate_id, attempts, lease_owner,
       lease_expires_at
from public.operation_outbox
where state = 'processing'
  and lease_expires_at <= now()
order by lease_expires_at;
```

Dead letters:

```sql
select id, topic, aggregate_type, aggregate_id, attempts, last_error,
       created_at, updated_at
from public.operation_outbox
where state = 'dead_letter'
order by updated_at desc;
```

Structured bot logs must report queue age, topic, outbox ID, attempts, lease
owner, and dead-letter transitions. They must not log full payloads, tokens, or
raw private notes.

## Audited retry procedure

Before retrying a dead letter, confirm that the external side effect did not
already occur. If it did, claim the row through a controlled operator worker
and complete it with the discovered external ID. Otherwise record the incident
ticket and reason, then requeue exactly one row:

```sql
begin;

insert into public.admin_audit_log (action, entity_type, entity_id, payload)
values (
  'operation_outbox_requeued',
  'operation_outbox',
  'outbox-uuid',
  jsonb_build_object(
    'operatorDiscordId', 'operator-discord-id',
    'reason', 'incident-or-ticket-reference'
  )
);

update public.operation_outbox
set state = 'pending',
    attempts = 0,
    available_at = now(),
    lease_owner = null,
    lease_expires_at = null,
    completed_at = null,
    last_error = null,
    updated_at = now()
where id = 'outbox-uuid'::uuid
  and state = 'dead_letter';

commit;
```

The worker's stable deduplication key and the target-specific external marker
remain authoritative. Never delete an outbox row to clear an incident.

## Release acceptance

Before enabling consumers:

- reset an empty local database and run every pgTAP suite;
- confirm client roles cannot execute the RPCs or read the outbox;
- run concurrent action decisions and verify one mutation/audit pair;
- force audit and outbox failures and verify complete rollback;
- demonstrate two workers cannot claim one row;
- demonstrate expired-lease recovery, completion idempotency, retry, and the
  tenth-attempt dead-letter transition;
- verify generated types and `contract.json` at the migration head;
- deploy the database release before either consumer calls the new RPCs.
