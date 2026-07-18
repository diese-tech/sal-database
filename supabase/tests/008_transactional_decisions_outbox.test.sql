BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(61);

SELECT has_table('public', 'operation_outbox', 'the durable operation outbox exists');
SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.operation_outbox'::regclass),
  'RLS is enabled on the operation outbox'
);
SELECT has_function(
  'public', 'create_pending_action', ARRAY['text', 'text', 'text', 'text', 'jsonb'],
  'the pending-action creation RPC exists'
);
SELECT has_function(
  'public', 'resolve_pending_action', ARRAY['text', 'text', 'text', 'text'],
  'the pending-action decision RPC exists'
);
SELECT has_function(
  'public', 'resolve_pending_stat_record', ARRAY['text', 'text', 'text', 'text'],
  'the stat decision RPC exists'
);
SELECT has_function(
  'public', 'claim_operation_outbox', ARRAY['text', 'integer'],
  'the outbox claim RPC exists'
);
SELECT has_function(
  'public', 'complete_operation_outbox', ARRAY['uuid', 'text', 'text'],
  'the outbox completion RPC exists'
);
SELECT has_function(
  'public', 'fail_operation_outbox', ARRAY['uuid', 'text', 'text', 'integer'],
  'the outbox failure RPC exists'
);
SELECT has_function(
  'public', 'enqueue_operation_outbox', ARRAY['text', 'text', 'text', 'text', 'text', 'jsonb'],
  'the idempotent outbox enqueue helper exists'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'create_pending_action', 'resolve_pending_action', 'resolve_pending_stat_record',
        'claim_operation_outbox', 'complete_operation_outbox',
        'fail_operation_outbox', 'enqueue_operation_outbox'
      )
      AND (
        has_function_privilege('anon', p.oid, 'EXECUTE')
        OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
      )
  ),
  'client roles cannot execute the decision or outbox RPCs'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'create_pending_action', 'resolve_pending_action', 'resolve_pending_stat_record',
        'claim_operation_outbox', 'complete_operation_outbox',
        'fail_operation_outbox', 'enqueue_operation_outbox'
      )
      AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
  ),
  'service_role can execute every decision and outbox RPC'
);
SELECT ok(
  NOT has_table_privilege('anon', 'public.operation_outbox', 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated', 'public.operation_outbox', 'SELECT,INSERT,UPDATE,DELETE'),
  'client roles have no direct outbox privileges'
);
SELECT ok(
  has_table_privilege('service_role', 'public.operation_outbox', 'SELECT,INSERT,UPDATE,DELETE'),
  'service_role owns the outbox data boundary'
);

INSERT INTO public.admin_users (
  discord_id, role, discord_username, display_name
) VALUES (
  'db01-admin', 'admin', 'db01-admin', 'DB01 Admin'
);

INSERT INTO public.seasons (
  id, name, status, start_date, end_date, is_current
) VALUES (
  'db01-season', 'DB01 Test Season', 'pre-season', '2026-01-01', '2026-12-31', false
);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
) VALUES
  ('db01-home', 'DB01 Home', 'D1H', 'terra', 'DH', 'from-black to-white', '#000000', 'from-black to-white'),
  ('db01-away', 'DB01 Away', 'D1A', 'terra', 'DA', 'from-black to-white', '#000000', 'from-black to-white');

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status
) VALUES (
  'db01-player', 'db01-home', 'db01-player', 'DB01 Player', 'DP',
  'from-black to-white', 'Support', 'terra', 'active'
);

INSERT INTO public.season_orgs (season_id, org_id, division_id)
VALUES
  ('db01-season', 'db01-home', 'terra'),
  ('db01-season', 'db01-away', 'terra');

INSERT INTO public.matches (
  id, division_id, home_org_id, away_org_id, scheduled_date, scheduled_time,
  status, week, season_id, proof_thread_id
) VALUES
  ('db01-result', 'terra', 'db01-home', 'db01-away', '2026-08-01', '19:00', 'scheduled', 1, 'db01-season', 'db01-proof'),
  ('db01-stale', 'terra', 'db01-home', 'db01-away', '2026-08-02', '19:00', 'scheduled', 1, 'db01-season', NULL),
  ('db01-reschedule', 'terra', 'db01-home', 'db01-away', '2026-08-03', '19:00', 'scheduled', 1, 'db01-season', NULL),
  ('db01-deny', 'terra', 'db01-home', 'db01-away', '2026-08-04', '19:00', 'scheduled', 1, 'db01-season', NULL),
  ('db01-rollback', 'terra', 'db01-home', 'db01-away', '2026-08-05', '19:00', 'scheduled', 1, 'db01-season', NULL),
  ('db01-outbox-rollback', 'terra', 'db01-home', 'db01-away', '2026-08-05', '20:00', 'scheduled', 1, 'db01-season', NULL),
  ('db01-stat', 'terra', 'db01-home', 'db01-away', '2026-08-06', '19:00', 'completed', 1, 'db01-season', NULL);

UPDATE public.matches
SET winner_org_id = 'db01-home', home_score = 2, away_score = 0, score = '2-0'
WHERE id = 'db01-stat';

CREATE TEMP TABLE db01_state (
  key text PRIMARY KEY,
  value text NOT NULL,
  result jsonb
);

INSERT INTO db01_state (key, value, result)
SELECT 'result_action', result ->> 'actionId', result
FROM (
  SELECT public.create_pending_action(
    'match_result', 'db01-captain', 'db01-result', 'terra',
    '{"winnerOrgId":"db01-home","score":"2-1","parsed":{"winnerGames":2,"loserGames":1,"gamesPlayed":3,"expectedScreenshots":6}}'::jsonb
  ) AS result
) created;

SELECT is(
  (SELECT result ->> 'created' FROM db01_state WHERE key = 'result_action'),
  'true',
  'creating a new action reports that it was created'
);
SELECT is(
  (SELECT status FROM public.pending_actions WHERE id = (SELECT value FROM db01_state WHERE key = 'result_action')),
  'pending',
  'a created action starts pending'
);
SELECT is(
  (SELECT count(*)::integer FROM public.audit_logs
    WHERE pending_action_id = (SELECT value FROM db01_state WHERE key = 'result_action')
      AND action_type = 'pending_action_created'),
  1,
  'action creation writes its lifecycle audit'
);
SELECT is(
  (SELECT count(*)::integer FROM public.operation_outbox
    WHERE aggregate_id = (SELECT value FROM db01_state WHERE key = 'result_action')),
  2,
  'action creation transactionally enqueues review and receipt projections'
);

SELECT throws_ok(
  format(
    'SELECT public.resolve_pending_action(%L, %L, %L, NULL)',
    (SELECT value FROM db01_state WHERE key = 'result_action'), 'not-an-admin', 'approve'
  ),
  '42501', 'Actor is not an authorized administrator.',
  'an unregistered actor cannot decide an action'
);
SELECT throws_ok(
  format(
    'SELECT public.resolve_pending_action(%L, %L, %L, NULL)',
    (SELECT value FROM db01_state WHERE key = 'result_action'), 'db01-admin', 'needs_info'
  ),
  '22023', 'A note is required for denial and Needs Info.',
  'Needs Info requires a note'
);

UPDATE db01_state
SET result = public.resolve_pending_action(value, 'db01-admin', 'needs_info', 'Upload the missing detail screen.')
WHERE key = 'result_action';
SELECT is(
  (SELECT status FROM public.pending_actions WHERE id = (SELECT value FROM db01_state WHERE key = 'result_action')),
  'pending_info',
  'Needs Info transitions a pending action to pending_info'
);

UPDATE db01_state
SET result = public.resolve_pending_action(value, 'db01-admin', 'approve', 'Evidence complete.')
WHERE key = 'result_action';
SELECT is(
  (SELECT result ->> 'finalStatus' FROM db01_state WHERE key = 'result_action'),
  'approved',
  'an action can be approved directly from pending_info'
);
SELECT ok(
  (SELECT status = 'completed'
      AND winner_org_id = 'db01-home'
      AND home_score = 2
      AND away_score = 1
      AND score = '2-1'
    FROM public.matches WHERE id = 'db01-result'),
  'result approval applies the validated match mutation'
);
SELECT is(
  (SELECT count(*)::integer FROM public.audit_logs
    WHERE pending_action_id = (SELECT value FROM db01_state WHERE key = 'result_action')
      AND action_type IN ('match_result_recorded', 'pending_action_approved')),
  2,
  'result approval writes both domain and lifecycle audits'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_id = 'db01-result' AND topic = 'standings_recalculation'
  )
  AND EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_id = 'db01-result' AND topic = 'proof_thread_closure'
  ),
  'result approval enqueues standings and proof-thread projections'
);

UPDATE db01_state
SET result = public.resolve_pending_action(value, 'db01-admin', 'approve', NULL)
WHERE key = 'result_action';
SELECT is(
  (SELECT result ->> 'code' FROM db01_state WHERE key = 'result_action'),
  'already_processed',
  'repeating a terminal decision returns idempotently'
);
SELECT is(
  (SELECT count(*)::integer FROM public.audit_logs
    WHERE pending_action_id = (SELECT value FROM db01_state WHERE key = 'result_action')
      AND action_type = 'pending_action_approved'),
  1,
  'terminal idempotency does not duplicate lifecycle audits'
);

INSERT INTO db01_state (key, value, result)
SELECT 'stale_action', result ->> 'actionId', result
FROM (
  SELECT public.create_pending_action(
    'match_result', 'db01-captain', 'db01-stale', 'terra',
    '{"winnerOrgId":"db01-home","score":"2-0","parsed":{"winnerGames":2,"loserGames":0,"gamesPlayed":2,"expectedScreenshots":4}}'::jsonb
  ) AS result
) created;
UPDATE public.matches
SET status = 'completed', winner_org_id = 'db01-away', home_score = 0, away_score = 2, score = '2-0'
WHERE id = 'db01-stale';
UPDATE db01_state
SET result = public.resolve_pending_action(value, 'db01-admin', 'approve', NULL)
WHERE key = 'stale_action';
SELECT is(
  (SELECT result ->> 'code' FROM db01_state WHERE key = 'stale_action'),
  'stale_cancelled',
  'an approval against a stale match cancels the action'
);
SELECT ok(
  (SELECT status = 'completed' AND winner_org_id = 'db01-away'
    FROM public.matches WHERE id = 'db01-stale'),
  'stale cancellation does not overwrite the existing match result'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE pending_action_id = (SELECT value FROM db01_state WHERE key = 'stale_action')
      AND action_type = 'pending_action_cancelled'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE pending_action_id = (SELECT value FROM db01_state WHERE key = 'stale_action')
      AND action_type = 'match_result_recorded'
  ),
  'stale cancellation is audited without a false domain audit'
);

INSERT INTO db01_state (key, value, result)
SELECT 'alias_action', result ->> 'actionId', result
FROM (
  SELECT public.create_pending_action(
    'alias_change', 'db01-player', NULL, 'terra',
    '{"targetPlayerId":"db01-player","oldIgn":"Old","newIgn":"New","proofScreenshotUrl":"https://example.invalid/proof"}'::jsonb
  ) AS result
) created;
SELECT throws_ok(
  format(
    'SELECT public.resolve_pending_action(%L, %L, %L, NULL)',
    (SELECT value FROM db01_state WHERE key = 'alias_action'), 'db01-admin', 'approve'
  ),
  '0A000', 'Alias change approval is not implemented.',
  'unsupported alias approval fails without mutation'
);
SELECT is(
  (SELECT status FROM public.pending_actions WHERE id = (SELECT value FROM db01_state WHERE key = 'alias_action')),
  'pending',
  'a rejected alias implementation remains pending'
);

INSERT INTO db01_state (key, value, result)
SELECT 'deny_action', result ->> 'actionId', result
FROM (
  SELECT public.create_pending_action(
    'reschedule', 'db01-captain', 'db01-deny', 'terra',
    '{"newDate":"2026-09-01","newTime":"20:00","reason":"Test"}'::jsonb
  ) AS result
) created;
SELECT throws_ok(
  format(
    'SELECT public.resolve_pending_action(%L, %L, %L, NULL)',
    (SELECT value FROM db01_state WHERE key = 'deny_action'), 'db01-admin', 'deny'
  ),
  '22023', 'A note is required for denial and Needs Info.',
  'action denial requires a note'
);
UPDATE db01_state
SET result = public.resolve_pending_action(value, 'db01-admin', 'deny', 'Teams did not agree.')
WHERE key = 'deny_action';
SELECT is(
  (SELECT status FROM public.pending_actions WHERE id = (SELECT value FROM db01_state WHERE key = 'deny_action')),
  'denied',
  'denial is terminal'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE pending_action_id = (SELECT value FROM db01_state WHERE key = 'deny_action')
      AND action_type = 'pending_action_denied'
  )
  AND EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_id = (SELECT value FROM db01_state WHERE key = 'deny_action')
      AND event_type = 'pending_action_denied'
  ),
  'denial writes its audit and notification outbox rows'
);

INSERT INTO db01_state (key, value, result)
SELECT 'reschedule_action', result ->> 'actionId', result
FROM (
  SELECT public.create_pending_action(
    'reschedule', 'db01-captain', 'db01-reschedule', 'terra',
    '{"newDate":"2026-09-02","newTime":"20:30","reason":"Test"}'::jsonb
  ) AS result
) created;
UPDATE db01_state
SET result = public.resolve_pending_action(value, 'db01-admin', 'approve', NULL)
WHERE key = 'reschedule_action';
SELECT ok(
  (SELECT scheduled_date = '2026-09-02'::date AND scheduled_time = '20:30'::time
    FROM public.matches WHERE id = 'db01-reschedule'),
  'reschedule approval updates the existing date and time columns'
);

INSERT INTO public.pending_stat_records (
  id, match_id, player_id, screenshot_url, extracted_json, stats_json, confidence
) VALUES
  (
    'db01-stat-approve', 'db01-stat', 'db01-player', 'https://example.invalid/stat-approve.png',
    '{}'::jsonb,
    '{"game_number":1,"org_id":"db01-home","kills":5,"deaths":2,"assists":8,"damage_dealt":12345,"damage_mitigated":6000,"god_played":"Athena","role":"Support"}'::jsonb,
    0.990
  ),
  (
    'db01-stat-invalid', 'db01-stat', 'db01-player', 'https://example.invalid/stat-invalid.png',
    '{"kills":1}'::jsonb, NULL, 0.800
  ),
  (
    'db01-stat-deny', 'db01-stat', 'db01-player', 'https://example.invalid/stat-deny.png',
    '{"game_number":2,"kills":1}'::jsonb, NULL, 0.800
  );

INSERT INTO db01_state (key, value, result)
VALUES (
  'stat_result', 'db01-stat-approve',
  public.resolve_pending_stat_record('db01-stat-approve', 'db01-admin', 'approve', 'Verified screenshots.')
);
SELECT is(
  (SELECT status FROM public.pending_stat_records WHERE id = 'db01-stat-approve'),
  'approved',
  'stat decision transitions the source record atomically'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.player_stats
    WHERE pending_stat_record_id = 'db01-stat-approve'
      AND match_id = 'db01-stat'
      AND player_id = 'db01-player'
      AND game_number = 1
      AND won IS TRUE
      AND kills = 5
      AND deaths = 2
      AND assists = 8
  ),
  'stat approval writes the official player stat row'
);
SELECT ok(
  (SELECT stats @> '{"kills":5,"deaths":2,"assists":8,"gamesPlayed":1,"wins":1}'::jsonb
    FROM public.players WHERE id = 'db01-player'),
  'stat approval refreshes the player aggregate in the same transaction'
);
SELECT ok(
  (SELECT count(*) = 2 FROM public.audit_logs
    WHERE entity_id IN (
      'db01-stat-approve',
      (SELECT id FROM public.player_stats WHERE pending_stat_record_id = 'db01-stat-approve')
    ) AND action_type = 'stat_approved')
  AND EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE deduplication_key = 'pending_stat_record:db01-stat-approve:approved:standings_recalculation'
  ),
  'stat approval writes lifecycle/domain audits and standings projection'
);

UPDATE db01_state
SET result = public.resolve_pending_stat_record(value, 'db01-admin', 'approve', NULL)
WHERE key = 'stat_result';
SELECT is(
  (SELECT result ->> 'code' FROM db01_state WHERE key = 'stat_result'),
  'already_processed',
  'stat terminal decisions are idempotent'
);
SELECT throws_ok(
  $$SELECT public.resolve_pending_stat_record('db01-stat-invalid', 'db01-admin', 'approve', NULL)$$,
  '22023', 'Stat payload requires a positive integer game_number.',
  'invalid stat payloads fail before publication'
);
SELECT ok(
  (SELECT status = 'pending' FROM public.pending_stat_records WHERE id = 'db01-stat-invalid')
    AND NOT EXISTS (
      SELECT 1 FROM public.player_stats WHERE pending_stat_record_id = 'db01-stat-invalid'
    ),
  'invalid stat approval rolls back all source and domain changes'
);
SELECT throws_ok(
  $$SELECT public.resolve_pending_stat_record('db01-stat-deny', 'db01-admin', 'deny', NULL)$$,
  '22023', 'A note is required for stat denial.',
  'stat denial requires a note'
);
SELECT is(
  public.resolve_pending_stat_record(
    'db01-stat-deny', 'db01-admin', 'deny', 'Unreadable screenshot.'
  ) ->> 'finalStatus',
  'rejected',
  'stat denial records the rejected terminal state'
);

UPDATE public.operation_outbox
SET available_at = now() + interval '1 day'
WHERE state = 'pending';
INSERT INTO db01_state (key, value)
VALUES (
  'claim_row',
  public.enqueue_operation_outbox(
    'db01_test', 'db01_test', 'claim', 'claim', 'db01:test:claim', '{}'::jsonb
  )::text
);
CREATE TEMP TABLE db01_claims AS
SELECT * FROM public.claim_operation_outbox('worker-a', 1);
SELECT is(
  (SELECT count(*)::integer FROM db01_claims),
  1,
  'the first worker claims the available row'
);
SELECT is(
  (SELECT count(*)::integer FROM public.claim_operation_outbox('worker-b', 1)),
  0,
  'a second worker cannot claim the leased row'
);
SELECT ok(
  (SELECT lease_expires_at > now() + interval '50 seconds'
      AND lease_expires_at <= now() + interval '60 seconds'
    FROM public.operation_outbox
    WHERE id = (SELECT value::uuid FROM db01_state WHERE key = 'claim_row')),
  'claims use a fixed 60-second lease'
);
SELECT throws_ok(
  format(
    'SELECT public.complete_operation_outbox(%L::uuid, %L, NULL)',
    (SELECT value FROM db01_state WHERE key = 'claim_row'), 'worker-b'
  ),
  '55000', 'Worker does not own an active lease for this outbox row.',
  'a worker cannot complete another worker lease'
);
SELECT is(
  public.complete_operation_outbox(
    (SELECT value::uuid FROM db01_state WHERE key = 'claim_row'),
    'worker-a', 'discord-message-1'
  ) ->> 'code',
  'completed',
  'the lease owner can complete delivery'
);
SELECT is(
  public.complete_operation_outbox(
    (SELECT value::uuid FROM db01_state WHERE key = 'claim_row'),
    'worker-a', 'discord-message-1'
  ) ->> 'code',
  'already_completed',
  'completion is idempotent'
);

INSERT INTO db01_state (key, value)
VALUES (
  'recover_row',
  public.enqueue_operation_outbox(
    'db01_test', 'db01_test', 'recover', 'recover', 'db01:test:recover', '{}'::jsonb
  )::text
);
CREATE TEMP TABLE db01_recover_claim AS
SELECT * FROM public.claim_operation_outbox('worker-a', 1);
UPDATE public.operation_outbox
SET lease_expires_at = now() - interval '1 second'
WHERE id = (SELECT value::uuid FROM db01_state WHERE key = 'recover_row');
SELECT is(
  (SELECT lease_owner FROM public.claim_operation_outbox('worker-b', 1)),
  'worker-b',
  'an expired lease is recoverable by another worker'
);
SELECT is(
  public.fail_operation_outbox(
    (SELECT value::uuid FROM db01_state WHERE key = 'recover_row'),
    'worker-b', 'temporary Discord failure', 900
  ) ->> 'code',
  'retry_scheduled',
  'a failed attempt returns the row to pending with capped retry metadata'
);

CREATE TEMP TABLE db01_dead_id AS
WITH inserted AS (
  INSERT INTO public.operation_outbox (
    topic, aggregate_type, aggregate_id, event_type, deduplication_key,
    state, attempts, available_at
  ) VALUES (
    'db01_test', 'db01_test', 'dead', 'dead', 'db01:test:dead',
    'pending', 9, now()
  )
  RETURNING id
)
SELECT id::text AS id FROM inserted;
CREATE TEMP TABLE db01_dead_claim AS
SELECT * FROM public.claim_operation_outbox('worker-dead', 1);
SELECT is(
  public.fail_operation_outbox(
    (SELECT id::uuid FROM db01_dead_id),
    'worker-dead', 'tenth failure', 5
  ) ->> 'state',
  'dead_letter',
  'the tenth failed attempt dead-letters the row'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'create_pending_action', 'resolve_pending_action', 'resolve_pending_stat_record',
        'claim_operation_outbox', 'complete_operation_outbox',
        'fail_operation_outbox', 'enqueue_operation_outbox'
      )
      AND NOT (p.proconfig @> ARRAY['search_path=pg_catalog, public'])
  ),
  'every SECURITY DEFINER entry point pins its search_path'
);
SELECT ok(
  pg_get_functiondef('public.claim_operation_outbox(text, integer)'::regprocedure)
    ILIKE '%FOR UPDATE SKIP LOCKED%',
  'the claim implementation uses FOR UPDATE SKIP LOCKED'
);

INSERT INTO db01_state (key, value, result)
SELECT 'rollback_action', result ->> 'actionId', result
FROM (
  SELECT public.create_pending_action(
    'match_result', 'db01-captain', 'db01-rollback', 'terra',
    '{"winnerOrgId":"db01-home","score":"2-0","parsed":{"winnerGames":2,"loserGames":0,"gamesPlayed":2,"expectedScreenshots":4}}'::jsonb
  ) AS result
) created;

CREATE FUNCTION pg_temp.db01_reject_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.pending_action_id = (SELECT value FROM pg_temp.db01_state WHERE key = 'rollback_action')
    AND NEW.action_type <> 'pending_action_created' THEN
    RAISE EXCEPTION 'forced audit failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER db01_force_audit_failure
BEFORE INSERT ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION pg_temp.db01_reject_audit();

SELECT throws_ok(
  format(
    'SELECT public.resolve_pending_action(%L, %L, %L, NULL)',
    (SELECT value FROM db01_state WHERE key = 'rollback_action'), 'db01-admin', 'approve'
  ),
  'P0001', 'forced audit failure',
  'a forced audit failure aborts the decision'
);
SELECT is(
  (SELECT status FROM public.matches WHERE id = 'db01-rollback'),
  'scheduled',
  'a failed audit rolls back the domain mutation'
);
SELECT is(
  (SELECT status FROM public.pending_actions WHERE id = (SELECT value FROM db01_state WHERE key = 'rollback_action')),
  'pending',
  'a failed audit rolls back the lifecycle transition'
);

DROP TRIGGER db01_force_audit_failure ON public.audit_logs;

INSERT INTO db01_state (key, value, result)
SELECT 'outbox_rollback_action', result ->> 'actionId', result
FROM (
  SELECT public.create_pending_action(
    'match_result', 'db01-captain', 'db01-outbox-rollback', 'terra',
    '{"winnerOrgId":"db01-home","score":"2-0","parsed":{"winnerGames":2,"loserGames":0,"gamesPlayed":2,"expectedScreenshots":4}}'::jsonb
  ) AS result
) created;

CREATE FUNCTION pg_temp.db01_reject_outbox() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.aggregate_id = (SELECT value FROM pg_temp.db01_state WHERE key = 'outbox_rollback_action')
    AND NEW.event_type <> 'pending_action_created' THEN
    RAISE EXCEPTION 'forced outbox failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER db01_force_outbox_failure
BEFORE INSERT ON public.operation_outbox
FOR EACH ROW EXECUTE FUNCTION pg_temp.db01_reject_outbox();

SELECT throws_ok(
  format(
    'SELECT public.resolve_pending_action(%L, %L, %L, NULL)',
    (SELECT value FROM db01_state WHERE key = 'outbox_rollback_action'), 'db01-admin', 'approve'
  ),
  'P0001', 'forced outbox failure',
  'a forced outbox failure aborts the decision'
);
SELECT is(
  (SELECT status FROM public.matches WHERE id = 'db01-outbox-rollback'),
  'scheduled',
  'a failed outbox enqueue rolls back the domain mutation'
);
SELECT is(
  (SELECT status FROM public.pending_actions WHERE id = (SELECT value FROM db01_state WHERE key = 'outbox_rollback_action')),
  'pending',
  'a failed outbox enqueue rolls back the lifecycle transition'
);

SELECT * FROM finish();
ROLLBACK;
