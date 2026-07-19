BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS dblink WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(88);

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
    CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) acl
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'create_pending_action', 'resolve_pending_action', 'resolve_pending_stat_record',
        'claim_operation_outbox', 'complete_operation_outbox',
        'fail_operation_outbox', 'enqueue_operation_outbox'
      )
      AND acl.grantee = 0
      AND acl.privilege_type = 'EXECUTE'
  ),
  'PUBLIC has no implicit execution grant on decision or outbox RPCs'
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
  NOT EXISTS (
    SELECT 1
    FROM pg_class c
    CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) acl
    WHERE c.oid = 'public.operation_outbox'::regclass
      AND acl.grantee = 0
  ),
  'PUBLIC has no implicit table privilege on the operation outbox'
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
  ('db01-stale', 'terra', 'db01-home', 'db01-away', '2026-08-02', '19:00', 'scheduled', 1, 'db01-season', 'db01-stale-proof'),
  ('db01-reschedule', 'terra', 'db01-home', 'db01-away', '2026-08-03', '19:00', 'scheduled', 1, 'db01-season', NULL),
  ('db01-deny', 'terra', 'db01-home', 'db01-away', '2026-08-04', '19:00', 'scheduled', 1, 'db01-season', NULL),
  ('db01-result-deny', 'terra', 'db01-home', 'db01-away', '2026-08-04', '20:00', 'scheduled', 1, 'db01-season', 'db01-denied-proof'),
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
SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_id = 'db01-result' AND topic = 'proof_thread_closure'
  ),
  'Needs Info keeps the match-result proof thread open'
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
  )
  AND EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_id = 'db01-stale'
      AND topic = 'proof_thread_closure'
      AND event_type = 'pending_action_cancelled'
  ),
  'stale cancellation is audited and closes proof without a false domain audit'
);

INSERT INTO db01_state (key, value, result)
SELECT 'alias_action', result ->> 'actionId', result
FROM (
  SELECT public.create_pending_action(
    'alias_change', 'db01-player', NULL, 'terra',
    '{"targetPlayerId":"db01-player","oldIgn":"Old","newIgn":"New","proofScreenshotUrl":"https://example.invalid/proof"}'::jsonb
  ) AS result
) created;
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_id = (SELECT value FROM db01_state WHERE key = 'alias_action')
      AND topic = 'discord_requester_notification'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_id = (SELECT value FROM db01_state WHERE key = 'alias_action')
      AND topic IN ('discord_receipt_projection', 'discord_captain_notification')
  ),
  'private alias intake uses requester notification without a public receipt'
);
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
SELECT 'admin_review_action', result ->> 'actionId', result
FROM (
  SELECT public.create_pending_action(
    'admin_review', 'db01-player', NULL, 'terra',
    '{"issueType":"other","description":"Private review test"}'::jsonb
  ) AS result
) created;
UPDATE db01_state
SET result = public.resolve_pending_action(value, 'db01-admin', 'approve', 'Resolved privately.')
WHERE key = 'admin_review_action';
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_id = (SELECT value FROM db01_state WHERE key = 'admin_review_action')
      AND topic = 'discord_requester_notification'
      AND event_type = 'pending_action_approved'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_id = (SELECT value FROM db01_state WHERE key = 'admin_review_action')
      AND topic IN ('discord_receipt_projection', 'discord_captain_notification')
  ),
  'private admin review resolution does not enter public or captain channels'
);

INSERT INTO db01_state (key, value, result)
SELECT 'result_deny_action', result ->> 'actionId', result
FROM (
  SELECT public.create_pending_action(
    'match_result', 'db01-captain', 'db01-result-deny', 'terra',
    '{"winnerOrgId":"db01-home","score":"2-0","parsed":{"winnerGames":2,"loserGames":0,"gamesPlayed":2,"expectedScreenshots":4}}'::jsonb
  ) AS result
) created;
UPDATE db01_state
SET result = public.resolve_pending_action(value, 'db01-admin', 'deny', 'Evidence did not support the result.')
WHERE key = 'result_deny_action';
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_id = 'db01-result-deny'
      AND topic = 'proof_thread_closure'
      AND event_type = 'pending_action_denied'
  ),
  'a denied match result closes its proof thread through the outbox'
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
  'dedupe_row',
  public.enqueue_operation_outbox(
    'db01_test', 'db01_test', 'dedupe', 'dedupe', 'db01:test:dedupe',
    '{"immutable":true}'::jsonb
  )::text
);
SELECT is(
  public.enqueue_operation_outbox(
    'db01_test', 'db01_test', 'dedupe', 'dedupe', 'db01:test:dedupe',
    '{"immutable":true}'::jsonb
  )::text,
  (SELECT value FROM db01_state WHERE key = 'dedupe_row'),
  'an exact immutable outbox retry returns the existing row'
);
SELECT throws_ok(
  $$SELECT public.enqueue_operation_outbox(
    'db01_test', 'db01_test', 'dedupe', 'dedupe', 'db01:test:dedupe',
    '{"immutable":false}'::jsonb
  )$$,
  '23505', 'Outbox deduplication key is already bound to a different immutable event.',
  'a reused outbox key cannot silently replace different payload data'
);
UPDATE public.operation_outbox
SET available_at = now() + interval '1 day'
WHERE id = (SELECT value::uuid FROM db01_state WHERE key = 'dedupe_row');
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

-- Multi-session concurrency harness. These named dblink sessions execute and
-- commit independently of the pgTAP transaction, so they exercise real row
-- locks and SKIP LOCKED behavior rather than sequential calls in one session.
SELECT is(
  dblink_connect('db01_setup', 'dbname=' || current_database()),
  'OK',
  'the concurrency setup session connects to the same PostgreSQL database'
);
SELECT is(
  dblink_connect('db01_worker_a', 'dbname=' || current_database()),
  'OK',
  'the first concurrent worker session connects'
);
SELECT is(
  dblink_connect('db01_worker_b', 'dbname=' || current_database()),
  'OK',
  'the second concurrent worker session connects'
);

SELECT ok(
  dblink_exec('db01_setup', $db01_setup$
    DROP FUNCTION IF EXISTS public.db01_capture_stat_resolution(text, text);

    DELETE FROM public.audit_logs
    WHERE pending_action_id LIKE 'db01-conc-%'
       OR entity_id LIKE 'db01-conc-%'
       OR actor_discord_id = 'db01-conc-admin';
    DELETE FROM public.operation_outbox
    WHERE aggregate_id LIKE 'db01-conc-%'
       OR deduplication_key LIKE 'db01:conc:%';
    DELETE FROM public.player_stats WHERE match_id LIKE 'db01-conc-%';
    DELETE FROM public.pending_stat_records WHERE id LIKE 'db01-conc-%';
    DELETE FROM public.pending_actions WHERE id LIKE 'db01-conc-%';
    DELETE FROM public.matches WHERE id LIKE 'db01-conc-%';
    DELETE FROM public.season_rosters WHERE season_id = 'db01-conc-season';
    DELETE FROM public.players WHERE id = 'db01-conc-player';
    DELETE FROM public.season_orgs WHERE season_id = 'db01-conc-season';
    DELETE FROM public.orgs WHERE id IN ('db01-conc-home', 'db01-conc-away');
    DELETE FROM public.seasons WHERE id = 'db01-conc-season';
    DELETE FROM public.admin_users WHERE discord_id = 'db01-conc-admin';

    INSERT INTO public.admin_users (
      discord_id, role, discord_username, display_name
    ) VALUES (
      'db01-conc-admin', 'admin', 'db01-conc-admin', 'DB01 Concurrency Admin'
    );

    INSERT INTO public.seasons (
      id, name, status, start_date, end_date, is_current
    ) VALUES (
      'db01-conc-season', 'DB01 Concurrency Season', 'pre-season',
      '2026-01-01', '2026-12-31', false
    );

    INSERT INTO public.orgs (
      id, name, tag, division_id, logo_initials, logo_gradient,
      primary_color, accent_gradient
    ) VALUES
      (
        'db01-conc-home', 'DB01 Concurrency Home', 'DCH', 'terra', 'CH',
        'from-black to-white', '#000000', 'from-black to-white'
      ),
      (
        'db01-conc-away', 'DB01 Concurrency Away', 'DCA', 'terra', 'CA',
        'from-black to-white', '#000000', 'from-black to-white'
      );

    INSERT INTO public.season_orgs (season_id, org_id, division_id)
    VALUES
      ('db01-conc-season', 'db01-conc-home', 'terra'),
      ('db01-conc-season', 'db01-conc-away', 'terra');

    INSERT INTO public.players (
      id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
      primary_role, division_id, status
    ) VALUES (
      'db01-conc-player', 'db01-conc-home', 'db01-conc-player',
      'DB01 Concurrency Player', 'CP', 'from-black to-white',
      'Support', 'terra', 'active'
    );

    INSERT INTO public.matches (
      id, division_id, home_org_id, away_org_id, scheduled_date,
      scheduled_time, status, week, season_id, winner_org_id,
      home_score, away_score, score
    ) VALUES
      (
        'db01-conc-action', 'terra', 'db01-conc-home', 'db01-conc-away',
        '2026-10-01', '19:00', 'scheduled', 1, 'db01-conc-season',
        NULL, NULL, NULL, NULL
      ),
      (
        'db01-conc-stat-a', 'terra', 'db01-conc-home', 'db01-conc-away',
        '2026-10-02', '19:00', 'completed', 1, 'db01-conc-season',
        'db01-conc-home', 2, 0, '2-0'
      ),
      (
        'db01-conc-stat-b', 'terra', 'db01-conc-home', 'db01-conc-away',
        '2026-10-03', '19:00', 'completed', 1, 'db01-conc-season',
        'db01-conc-home', 2, 0, '2-0'
      ),
      (
        'db01-conc-stat-dup', 'terra', 'db01-conc-home', 'db01-conc-away',
        '2026-10-04', '19:00', 'completed', 1, 'db01-conc-season',
        'db01-conc-home', 2, 0, '2-0'
      );

    INSERT INTO public.pending_actions (
      id, type, status, requested_by_discord_id, match_id, division_id,
      payload_json
    ) VALUES (
      'db01-conc-action', 'match_result', 'pending', 'db01-conc-captain',
      'db01-conc-action', 'terra',
      '{
        "winnerOrgId":"db01-conc-home",
        "score":"2-0",
        "parsed":{
          "winnerGames":2,
          "loserGames":0,
          "gamesPlayed":2,
          "expectedScreenshots":4
        }
      }'::jsonb
    );

    INSERT INTO public.pending_stat_records (
      id, match_id, player_id, screenshot_url, extracted_json,
      stats_json, confidence
    ) VALUES
      (
        'db01-conc-stat-record-a', 'db01-conc-stat-a', 'db01-conc-player',
        'https://example.invalid/conc-a.png', '{}'::jsonb,
        '{"game_number":1,"org_id":"db01-conc-home","kills":3,"deaths":1,"assists":5}'::jsonb,
        0.990
      ),
      (
        'db01-conc-stat-record-b', 'db01-conc-stat-b', 'db01-conc-player',
        'https://example.invalid/conc-b.png', '{}'::jsonb,
        '{"game_number":1,"org_id":"db01-conc-home","kills":7,"deaths":2,"assists":4}'::jsonb,
        0.990
      ),
      (
        'db01-conc-stat-dup-a', 'db01-conc-stat-dup', 'db01-conc-player',
        'https://example.invalid/conc-dup-a.png', '{}'::jsonb,
        '{"game_number":1,"org_id":"db01-conc-home","kills":11,"deaths":3,"assists":2}'::jsonb,
        0.990
      ),
      (
        'db01-conc-stat-dup-b', 'db01-conc-stat-dup', 'db01-conc-player',
        'https://example.invalid/conc-dup-b.png', '{}'::jsonb,
        '{"game_number":1,"org_id":"db01-conc-home","kills":99,"deaths":9,"assists":9}'::jsonb,
        0.990
      );

    INSERT INTO public.operation_outbox (
      id, topic, aggregate_type, aggregate_id, event_type,
      deduplication_key, payload
    ) VALUES
      (
        '00000000-0000-0000-0000-00000000c001', 'db01_concurrency',
        'db01_test', 'db01-conc-claim-1', 'claim', 'db01:conc:claim:1', '{}'::jsonb
      ),
      (
        '00000000-0000-0000-0000-00000000c002', 'db01_concurrency',
        'db01_test', 'db01-conc-claim-2', 'claim', 'db01:conc:claim:2', '{}'::jsonb
      ),
      (
        '00000000-0000-0000-0000-00000000c003', 'db01_concurrency',
        'db01_test', 'db01-conc-recover', 'recover', 'db01:conc:recover', '{}'::jsonb
      );

    CREATE OR REPLACE FUNCTION public.db01_capture_stat_resolution(
      p_record_id text,
      p_actor_id text
    ) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $capture$
    BEGIN
      RETURN jsonb_build_object(
        'ok', true,
        'result', public.resolve_pending_stat_record(
          p_record_id, p_actor_id, 'approve', 'concurrency test'
        )
      );
    EXCEPTION WHEN OTHERS THEN
      RETURN jsonb_build_object(
        'ok', false,
        'sqlstate', SQLSTATE,
        'message', SQLERRM
      );
    END;
    $capture$;
  $db01_setup$) IS NOT NULL,
  'the independent concurrency fixtures are committed'
);

CREATE TEMP TABLE db01_concurrent_action_results (
  worker text,
  result jsonb
);
DO $action_race_begin$
BEGIN
  PERFORM dblink_exec('db01_worker_a', 'BEGIN');
  PERFORM locked.id
  FROM dblink(
    'db01_worker_a',
    $$SELECT id FROM public.pending_actions
      WHERE id = 'db01-conc-action'
      FOR UPDATE$$
  ) AS locked(id text);
  PERFORM dblink_send_query(
    'db01_worker_b',
    $$SELECT public.resolve_pending_action(
      'db01-conc-action', 'db01-conc-admin', 'approve', NULL
    )::text$$
  );
  PERFORM pg_sleep(0.1);
END;
$action_race_begin$;
SELECT is(
  dblink_is_busy('db01_worker_b'),
  1,
  'the second action decision is blocked behind worker A row lock'
);
INSERT INTO db01_concurrent_action_results
SELECT 'worker-a', result::jsonb
FROM dblink(
  'db01_worker_a',
  $$SELECT public.resolve_pending_action(
    'db01-conc-action', 'db01-conc-admin', 'approve', NULL
  )::text$$
) AS response(result text);
DO $action_race_commit$
BEGIN
  PERFORM dblink_exec('db01_worker_a', 'COMMIT');
END;
$action_race_commit$;
INSERT INTO db01_concurrent_action_results
SELECT 'worker-b', result::jsonb
FROM dblink_get_result('db01_worker_b') AS response(result text);

SELECT ok(
  (SELECT count(*) = 1 FROM db01_concurrent_action_results WHERE result ->> 'code' = 'applied')
    AND
  (SELECT count(*) = 1 FROM db01_concurrent_action_results WHERE result ->> 'code' = 'already_processed'),
  'simultaneous decisions yield one mutation and one terminal idempotent result'
);
SELECT ok(
  (SELECT status = 'completed' FROM public.matches WHERE id = 'db01-conc-action')
    AND
  (SELECT count(*) = 1 FROM public.audit_logs
    WHERE pending_action_id = 'db01-conc-action'
      AND action_type = 'match_result_recorded'),
  'simultaneous action approval produces one domain mutation and audit'
);

CREATE TEMP TABLE db01_concurrent_stat_results (
  worker text,
  result jsonb
);
DO $same_player_race_begin$
BEGIN
  PERFORM dblink_exec('db01_worker_a', 'BEGIN');
  PERFORM locked.id
  FROM dblink(
    'db01_worker_a',
    $$SELECT id FROM public.players
      WHERE id = 'db01-conc-player'
      FOR UPDATE$$
  ) AS locked(id text);
  PERFORM dblink_send_query(
    'db01_worker_b',
    $$SELECT public.db01_capture_stat_resolution(
      'db01-conc-stat-record-b', 'db01-conc-admin'
    )::text$$
  );
  PERFORM pg_sleep(0.1);
END;
$same_player_race_begin$;
SELECT is(
  dblink_is_busy('db01_worker_b'),
  1,
  'the second same-player stat approval waits on worker A player lock'
);
INSERT INTO db01_concurrent_stat_results
SELECT 'worker-a', result::jsonb
FROM dblink(
  'db01_worker_a',
  $$SELECT public.db01_capture_stat_resolution(
    'db01-conc-stat-record-a', 'db01-conc-admin'
  )::text$$
) AS response(result text);
DO $same_player_race_commit$
BEGIN
  PERFORM dblink_exec('db01_worker_a', 'COMMIT');
END;
$same_player_race_commit$;
INSERT INTO db01_concurrent_stat_results
SELECT 'worker-b', result::jsonb
FROM dblink_get_result('db01_worker_b') AS response(result text);

SELECT ok(
  (SELECT count(*) = 2 FROM db01_concurrent_stat_results
    WHERE result ->> 'ok' = 'true'
      AND result #>> '{result,code}' = 'applied'),
  'same-player approvals on different matches both complete under the player lock'
);
SELECT ok(
  (SELECT stats @> '{"kills":10,"deaths":3,"assists":9,"gamesPlayed":2,"wins":2}'::jsonb
    FROM public.players WHERE id = 'db01-conc-player'),
  'serialized same-player approvals preserve the complete aggregate'
);

CREATE TEMP TABLE db01_duplicate_stat_results (
  worker text,
  result jsonb
);
DO $duplicate_stat_race_begin$
BEGIN
  PERFORM dblink_exec('db01_worker_a', 'BEGIN');
  PERFORM locked.id
  FROM dblink(
    'db01_worker_a',
    $$SELECT id FROM public.matches
      WHERE id = 'db01-conc-stat-dup'
      FOR UPDATE$$
  ) AS locked(id text);
  PERFORM dblink_send_query(
    'db01_worker_b',
    $$SELECT public.db01_capture_stat_resolution(
      'db01-conc-stat-dup-b', 'db01-conc-admin'
    )::text$$
  );
  PERFORM pg_sleep(0.1);
END;
$duplicate_stat_race_begin$;
SELECT is(
  dblink_is_busy('db01_worker_b'),
  1,
  'the duplicate source approval waits behind worker A match lock'
);
INSERT INTO db01_duplicate_stat_results
SELECT 'worker-a', result::jsonb
FROM dblink(
  'db01_worker_a',
  $$SELECT public.db01_capture_stat_resolution(
    'db01-conc-stat-dup-a', 'db01-conc-admin'
  )::text$$
) AS response(result text);
DO $duplicate_stat_race_commit$
BEGIN
  PERFORM dblink_exec('db01_worker_a', 'COMMIT');
END;
$duplicate_stat_race_commit$;
INSERT INTO db01_duplicate_stat_results
SELECT 'worker-b', result::jsonb
FROM dblink_get_result('db01_worker_b') AS response(result text);

SELECT ok(
  (SELECT count(*) = 1 FROM db01_duplicate_stat_results
    WHERE result ->> 'ok' = 'true'
      AND result #>> '{result,code}' = 'applied')
    AND
  (SELECT count(*) = 1 FROM db01_duplicate_stat_results
    WHERE result ->> 'ok' = 'false'
      AND result ->> 'sqlstate' = '23505'),
  'concurrent duplicate stat sources yield one approval and one explicit conflict'
);
SELECT ok(
  (SELECT count(*) = 1 FROM public.player_stats
    WHERE match_id = 'db01-conc-stat-dup'
      AND player_id = 'db01-conc-player'
      AND game_number = 1
      AND pending_stat_record_id IN ('db01-conc-stat-dup-a', 'db01-conc-stat-dup-b'))
    AND
  (SELECT count(*) = 1 FROM public.pending_stat_records
    WHERE id IN ('db01-conc-stat-dup-a', 'db01-conc-stat-dup-b')
      AND status = 'approved')
    AND
  (SELECT count(*) = 1 FROM public.pending_stat_records
    WHERE id IN ('db01-conc-stat-dup-a', 'db01-conc-stat-dup-b')
      AND status = 'pending'),
  'the conflicting source cannot overwrite the one official stat row'
);

SELECT ok(
  dblink_exec('db01_setup', $$
    UPDATE public.operation_outbox
    SET available_at = now() + interval '1 day'
    WHERE aggregate_id LIKE 'db01-conc-%';
    UPDATE public.operation_outbox
    SET available_at = CASE id
      WHEN '00000000-0000-0000-0000-00000000c001'::uuid
        THEN now() - interval '2 seconds'
      WHEN '00000000-0000-0000-0000-00000000c002'::uuid
        THEN now() - interval '1 second'
      ELSE available_at
    END
    WHERE id IN (
      '00000000-0000-0000-0000-00000000c001'::uuid,
      '00000000-0000-0000-0000-00000000c002'::uuid
    );
  $$) IS NOT NULL,
  'the worker-race fixtures are the only remotely available outbox rows'
);

CREATE TEMP TABLE db01_disjoint_claim_results (
  worker text,
  result jsonb
);
DO $worker_claim_race_begin$
BEGIN
  PERFORM dblink_exec('db01_worker_a', 'BEGIN');
END;
$worker_claim_race_begin$;
INSERT INTO db01_disjoint_claim_results
SELECT 'worker-a', result::jsonb
FROM dblink(
  'db01_worker_a',
  $$SELECT COALESCE(jsonb_agg(to_jsonb(claimed)), '[]'::jsonb)::text
    FROM public.claim_operation_outbox('db01-concurrent-worker-a', 1) claimed$$
) AS response(result text);
INSERT INTO db01_disjoint_claim_results
SELECT 'worker-b', result::jsonb
FROM dblink(
  'db01_worker_b',
  $$SELECT COALESCE(jsonb_agg(to_jsonb(claimed)), '[]'::jsonb)::text
    FROM public.claim_operation_outbox('db01-concurrent-worker-b', 1) claimed$$
) AS response(result text);

SELECT ok(
  (SELECT result #>> '{0,id}' = '00000000-0000-0000-0000-00000000c001'
    FROM db01_disjoint_claim_results WHERE worker = 'worker-a')
    AND
  (SELECT result #>> '{0,id}' = '00000000-0000-0000-0000-00000000c002'
    FROM db01_disjoint_claim_results WHERE worker = 'worker-b'),
  'worker B skips worker A uncommitted claim and returns the second row'
);
DO $worker_claim_race_commit$
BEGIN
  PERFORM dblink_exec('db01_worker_a', 'COMMIT');
END;
$worker_claim_race_commit$;

SELECT ok(
  dblink_exec('db01_setup', $$
    UPDATE public.operation_outbox
    SET available_at = now()
    WHERE id = '00000000-0000-0000-0000-00000000c003'::uuid;
  $$) IS NOT NULL,
  'the recovery row becomes available after the disjoint-claim race'
);

CREATE TEMP TABLE db01_recovery_first_claim AS
SELECT result::jsonb AS result
FROM dblink(
  'db01_worker_a',
  $$SELECT COALESCE(jsonb_agg(to_jsonb(claimed)), '[]'::jsonb)::text
    FROM public.claim_operation_outbox('db01-recovery-worker-a', 1) claimed$$
) AS response(result text);
SELECT ok(
  dblink_exec('db01_setup', $$
    UPDATE public.operation_outbox
    SET lease_expires_at = now() - interval '1 second'
    WHERE id = '00000000-0000-0000-0000-00000000c003'::uuid
      AND state = 'processing';
  $$) IS NOT NULL,
  'the independent setup session expires the recovery lease'
);
CREATE TEMP TABLE db01_recovery_second_claim AS
SELECT result::jsonb AS result
FROM dblink(
  'db01_worker_b',
  $$SELECT COALESCE(jsonb_agg(to_jsonb(claimed)), '[]'::jsonb)::text
    FROM public.claim_operation_outbox('db01-recovery-worker-b', 1) claimed$$
) AS response(result text);
SELECT ok(
  (SELECT result #>> '{0,id}' = '00000000-0000-0000-0000-00000000c003'
    FROM db01_recovery_first_claim)
    AND
  (SELECT result #>> '{0,id}' = '00000000-0000-0000-0000-00000000c003'
      AND result #>> '{0,lease_owner}' = 'db01-recovery-worker-b'
      AND (result #>> '{0,attempts}')::integer = 2
    FROM db01_recovery_second_claim),
  'an expired lease is reclaimed by another PostgreSQL session'
);

SELECT ok(
  dblink_exec('db01_setup', $db01_cleanup$
    DROP FUNCTION IF EXISTS public.db01_capture_stat_resolution(text, text);
    DELETE FROM public.audit_logs
    WHERE pending_action_id LIKE 'db01-conc-%'
       OR entity_id LIKE 'db01-conc-%'
       OR actor_discord_id = 'db01-conc-admin';
    DELETE FROM public.operation_outbox
    WHERE aggregate_id LIKE 'db01-conc-%'
       OR deduplication_key LIKE 'db01:conc:%';
    DELETE FROM public.player_stats WHERE match_id LIKE 'db01-conc-%';
    DELETE FROM public.pending_stat_records WHERE id LIKE 'db01-conc-%';
    DELETE FROM public.pending_actions WHERE id LIKE 'db01-conc-%';
    DELETE FROM public.matches WHERE id LIKE 'db01-conc-%';
    DELETE FROM public.season_rosters WHERE season_id = 'db01-conc-season';
    DELETE FROM public.players WHERE id = 'db01-conc-player';
    DELETE FROM public.season_orgs WHERE season_id = 'db01-conc-season';
    DELETE FROM public.orgs WHERE id IN ('db01-conc-home', 'db01-conc-away');
    DELETE FROM public.seasons WHERE id = 'db01-conc-season';
    DELETE FROM public.admin_users WHERE discord_id = 'db01-conc-admin';
  $db01_cleanup$) IS NOT NULL,
  'the committed concurrency fixtures are removed'
);
DO $$
BEGIN
  PERFORM dblink_disconnect('db01_worker_a');
  PERFORM dblink_disconnect('db01_worker_b');
  PERFORM dblink_disconnect('db01_setup');
END;
$$;

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
