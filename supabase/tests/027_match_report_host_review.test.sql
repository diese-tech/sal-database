BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(50);

SELECT has_table('public', 'match_report_host_tokens', 'match-report host tokens are durable');
SELECT has_column('public', 'match_reports', 'pending_action_id', 'match reports link to their pending action');
SELECT has_column('public', 'match_reports', 'revision', 'match reports expose an optimistic revision');
SELECT has_column('public', 'match_reports', 'host_discord_id', 'match reports bind one Discord host');
SELECT has_column('public', 'match_reports', 'host_submitted_at', 'match reports record host submission time');
SELECT has_column('public', 'player_stats', 'match_report_id', 'official stats record match-report provenance');
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.match_reports'::regclass
      AND conname = 'match_reports_pending_action_id_key'
      AND contype = 'u'
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.match_report_host_tokens'::regclass
      AND conname = 'match_report_host_tokens_report_host_key'
      AND contype = 'u'
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.match_report_host_tokens'::regclass
      AND conname = 'match_report_host_tokens_token_hash_key'
      AND contype = 'u'
  )
  AND EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'pending_actions_open_match_result_match_key'
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.player_stats'::regclass
      AND conname = 'player_stats_single_provenance_check'
      AND contype = 'c'
  ),
  'report linkage, one live action, stat provenance, host scope, and token hashes are database-enforced'
);
SELECT has_function(
  'public', 'ensure_match_report_for_pending_action', ARRAY['text', 'text'],
  'the recoverable pending-action linkage RPC exists'
);
SELECT has_function(
  'public', 'create_match_result_action_with_report', ARRAY['text', 'text', 'jsonb'],
  'the atomic match-result and report creation RPC exists'
);
SELECT has_function(
  'public', 'issue_match_report_host_token',
  ARRAY['uuid', 'text', 'text', 'timestamp with time zone'],
  'the host-token issue RPC exists'
);
SELECT has_function(
  'public', 'consume_match_report_host_token', ARRAY['text'],
  'the atomic host-token consume RPC exists'
);
SELECT has_function(
  'public', 'match_report_extraction_diagnostics', ARRAY['uuid', 'jsonb'],
  'the match-report identity diagnostics RPC exists'
);
SELECT has_function(
  'public', 'revise_match_report_extraction', ARRAY['uuid', 'text', 'integer', 'jsonb'],
  'the host-scoped optimistic revision RPC exists'
);
SELECT has_function(
  'public', 'submit_match_report_host_review', ARRAY['uuid', 'text', 'integer'],
  'the host submission RPC exists'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.ensure_match_report_for_pending_action(text,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.ensure_match_report_for_pending_action(text,text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.ensure_match_report_for_pending_action(text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.create_match_result_action_with_report(text,text,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.create_match_result_action_with_report(text,text,jsonb)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.create_match_result_action_with_report(text,text,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.issue_match_report_host_token(uuid,text,text,timestamp with time zone)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.issue_match_report_host_token(uuid,text,text,timestamp with time zone)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.issue_match_report_host_token(uuid,text,text,timestamp with time zone)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.consume_match_report_host_token(text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.consume_match_report_host_token(text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.consume_match_report_host_token(text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.match_report_extraction_diagnostics(uuid,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.match_report_extraction_diagnostics(uuid,jsonb)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.match_report_extraction_diagnostics(uuid,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.revise_match_report_extraction(uuid,text,integer,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.revise_match_report_extraction(uuid,text,integer,jsonb)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.revise_match_report_extraction(uuid,text,integer,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.submit_match_report_host_review(uuid,text,integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.submit_match_report_host_review(uuid,text,integer)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.submit_match_report_host_review(uuid,text,integer)', 'EXECUTE'),
  'every host-review SECURITY DEFINER RPC is service-role-only'
);

INSERT INTO public.admin_users (
  discord_id, role, discord_username, display_name
) VALUES (
  'mr-host-admin', 'admin', 'mr-host-admin', 'Match Report Admin'
);

INSERT INTO public.seasons (
  id, name, status, start_date, end_date, is_current
) VALUES (
  'mr-host-season', 'Match Report Host Season', 'active',
  '2026-08-01', '2026-12-31', false
);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient,
  primary_color, accent_gradient
) VALUES
  ('mr-host-home', 'Match Report Home', 'MRH', 'terra', 'MH', 'from-black to-white', '#000000', 'from-black to-white'),
  ('mr-host-away', 'Match Report Away', 'MRA', 'terra', 'MA', 'from-black to-white', '#000000', 'from-black to-white');

INSERT INTO public.season_orgs (season_id, org_id, division_id)
VALUES
  ('mr-host-season', 'mr-host-home', 'terra'),
  ('mr-host-season', 'mr-host-away', 'terra');

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status
)
SELECT
  'mr-host-home-' || player_number,
  'mr-host-home',
  'mr-host-home-' || player_number,
  'MR Home ' || player_number,
  'MH', 'from-black to-white', 'Flex', 'terra', 'active'
FROM generate_series(1, 5) AS player_number
UNION ALL
SELECT
  'mr-host-away-' || player_number,
  'mr-host-away',
  'mr-host-away-' || player_number,
  'MR Away ' || player_number,
  'MA', 'from-black to-white', 'Flex', 'terra', 'active'
FROM generate_series(1, 5) AS player_number;

INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, roster_status
)
SELECT 'mr-host-season', id, org_id, 'terra', 'active'
FROM public.players
WHERE id LIKE 'mr-host-home-%' OR id LIKE 'mr-host-away-%';

INSERT INTO public.matches (
  id, division_id, home_org_id, away_org_id, scheduled_date, scheduled_time,
  status, week, season_id, proof_thread_id
) VALUES (
  'mr-host-match', 'terra', 'mr-host-home', 'mr-host-away',
  '2026-08-20', '19:00', 'scheduled', 1, 'mr-host-season', 'proof-thread-252'
);

INSERT INTO public.matches (
  id, division_id, home_org_id, away_org_id, scheduled_date, scheduled_time,
  status, week, season_id
) VALUES (
  'mr-host-atomic-match', 'terra', 'mr-host-home', 'mr-host-away',
  '2026-08-19', '19:00', 'scheduled', 1, 'mr-host-season'
);
CREATE TEMP TABLE mr_host_atomic_first AS
SELECT public.create_match_result_action_with_report(
  'mr-host-atomic-match', 'mr-host-atomic-discord',
  '{"winnerOrgId":"mr-host-home","score":"1-0","parsed":{"winnerGames":1,"loserGames":0,"gamesPlayed":1,"expectedScreenshots":1}}'::jsonb
) AS result;
CREATE TEMP TABLE mr_host_atomic_retry AS
SELECT public.create_match_result_action_with_report(
  'mr-host-atomic-match', 'mr-host-atomic-discord',
  '{"winnerOrgId":"mr-host-home","score":"1-0","parsed":{"winnerGames":1,"loserGames":0,"gamesPlayed":1,"expectedScreenshots":1}}'::jsonb
) AS result;
SELECT ok(
  (SELECT result ->> 'code' = 'created' AND result ->> 'created' = 'true'
   FROM mr_host_atomic_first)
  AND (SELECT count(*) = 1 FROM public.pending_actions
       WHERE match_id = 'mr-host-atomic-match' AND type = 'match_result')
  AND (SELECT count(*) = 1 FROM public.match_reports
       WHERE match_id = 'mr-host-atomic-match'),
  'atomic creation commits one linked pending action and report'
);
SELECT ok(
  (SELECT result ->> 'code' = 'existing' AND result ->> 'created' = 'false'
   FROM mr_host_atomic_retry)
  AND (SELECT first.result ->> 'actionId' = retry.result ->> 'actionId'
       FROM mr_host_atomic_first first CROSS JOIN mr_host_atomic_retry retry)
  AND NOT EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_type = 'pending_action'
      AND aggregate_id = (SELECT result ->> 'actionId' FROM mr_host_atomic_first)
  ),
  'atomic creation retry recovers the same linkage without duplicate bot-owned projections'
);

INSERT INTO public.pending_actions (
  id, type, requested_by_discord_id, match_id, division_id, payload_json
) VALUES (
  'mr-host-action', 'match_result', 'mr-host-discord', 'mr-host-match', 'terra',
  '{"winnerOrgId":"mr-host-away","score":"2-1","parsed":{"winnerGames":2,"loserGames":1,"gamesPlayed":3,"expectedScreenshots":3}}'::jsonb
);

CREATE TEMP TABLE mr_host_ensure_first AS
SELECT public.ensure_match_report_for_pending_action(
  'mr-host-action', 'mr-host-discord'
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'created'
      AND result ->> 'created' = 'true'
      AND result ->> 'pendingActionId' = 'mr-host-action'
      AND result ->> 'hostDiscordId' = 'mr-host-discord'
    FROM mr_host_ensure_first)
  AND EXISTS (
    SELECT 1 FROM public.match_reports
    WHERE pending_action_id = 'mr-host-action'
      AND match_id = 'mr-host-match'
      AND season_id = 'mr-host-season'
      AND division_id = 'terra'
      AND submitted_by = 'mr-host-discord'
      AND host_discord_id = 'mr-host-discord'
      AND revision = 1
      AND status = 'pending'
  ),
  'ensuring a report derives and links its complete scope from the pending action'
);

CREATE TEMP TABLE mr_host_ensure_retry AS
SELECT public.ensure_match_report_for_pending_action(
  'mr-host-action', 'mr-host-discord'
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'existing'
      AND result ->> 'created' = 'false'
    FROM mr_host_ensure_retry)
  AND (SELECT count(*) = 1 FROM public.match_reports WHERE match_id = 'mr-host-match'),
  'ensuring the same pending-action linkage is idempotent'
);

INSERT INTO public.matches (
  id, division_id, home_org_id, away_org_id, scheduled_date, scheduled_time,
  status, week, season_id
) VALUES (
  'mr-host-repair-match', 'terra', 'mr-host-home', 'mr-host-away',
  '2026-08-22', '19:00', 'scheduled', 1, 'mr-host-season'
);
INSERT INTO public.pending_actions (
  id, type, requested_by_discord_id, match_id, division_id, payload_json
) VALUES (
  'mr-host-repair-action', 'match_result', 'mr-host-repair-discord',
  'mr-host-repair-match', 'terra', '{}'::jsonb
);
INSERT INTO public.match_reports (
  id, match_id, season_id, division_id, status, submitted_by
) VALUES (
  '00000000-0000-0000-0000-000000002521', 'mr-host-repair-match',
  'mr-host-season', 'terra', 'pending', 'mr-host-repair-discord'
);

CREATE TEMP TABLE mr_host_repair AS
SELECT public.ensure_match_report_for_pending_action(
  'mr-host-repair-action', 'mr-host-repair-discord'
) AS result;
SELECT ok(
  (SELECT result ->> 'code' = 'existing'
      AND result ->> 'created' = 'false'
    FROM mr_host_repair)
  AND EXISTS (
    SELECT 1 FROM public.match_reports
    WHERE id = '00000000-0000-0000-0000-000000002521'
      AND pending_action_id = 'mr-host-repair-action'
      AND host_discord_id = 'mr-host-repair-discord'
  ),
  'ensuring a legacy same-match report safely repairs missing action and host linkage'
);

SELECT throws_ok(
  $$SELECT public.ensure_match_report_for_pending_action(
    'mr-host-action', 'not-the-host'
  )$$,
  '42501', 'Only the pending-action requester can host its match report.',
  'a different Discord identity cannot claim the match report'
);

SELECT throws_ok(
  $$SELECT public.resolve_pending_action(
    'mr-host-action', 'mr-host-admin', 'approve', NULL
  )$$,
  '55000',
  'Linked match-result approval must be completed through match-report review.',
  'the legacy Discord approval cannot complete a linked match before official stats'
);

CREATE TEMP TABLE mr_host_report AS
SELECT id AS report_id FROM public.match_reports WHERE pending_action_id = 'mr-host-action';

CREATE TEMP TABLE mr_host_token_issue AS
SELECT public.issue_match_report_host_token(
  (SELECT report_id FROM mr_host_report),
  'mr-host-discord', repeat('a', 64), now() + interval '15 minutes'
) AS result;

SELECT ok(
  (SELECT result ->> 'hostDiscordId' = 'mr-host-discord' FROM mr_host_token_issue)
  AND EXISTS (
    SELECT 1 FROM public.match_report_host_tokens
    WHERE match_report_id = (SELECT report_id FROM mr_host_report)
      AND host_discord_id = 'mr-host-discord'
      AND token_hash = repeat('a', 64)
      AND consumed_at IS NULL
  ),
  'issuing a host token persists only the hash and its bound scope'
);

CREATE TEMP TABLE mr_host_token_consume AS
SELECT public.consume_match_report_host_token(repeat('a', 64)) AS result;

SELECT ok(
  (SELECT result ->> 'matchReportId' = (SELECT report_id::text FROM mr_host_report)
      AND result ->> 'hostDiscordId' = 'mr-host-discord'
    FROM mr_host_token_consume)
  AND EXISTS (
    SELECT 1 FROM public.match_report_host_tokens
    WHERE token_hash = repeat('a', 64) AND consumed_at IS NOT NULL
  ),
  'consuming a valid token atomically returns its report and host scope'
);

SELECT is(
  public.consume_match_report_host_token(repeat('a', 64)),
  NULL::jsonb,
  'replaying a consumed token returns the same uniform null as a miss'
);

SELECT is(
  public.consume_match_report_host_token(repeat('f', 64)),
  NULL::jsonb,
  'an unknown token returns a uniform null'
);

SELECT public.issue_match_report_host_token(
  (SELECT report_id FROM mr_host_report),
  'mr-host-discord', repeat('b', 64), now() + interval '1 second'
);
UPDATE public.match_report_host_tokens
SET expires_at = now() - interval '1 second'
WHERE token_hash = repeat('b', 64);
SELECT is(
  public.consume_match_report_host_token(repeat('b', 64)),
  NULL::jsonb,
  'an expired token returns a uniform null without being consumed'
);

CREATE TEMP TABLE mr_host_games AS
SELECT jsonb_build_array(
  jsonb_build_object(
    'gameNumber', 1,
    'winningSide', 'home',
    'players', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'playerIgn', players.ign,
          'playerId', players.id,
          'side', CASE WHEN players.org_id = 'mr-host-home' THEN 'home' ELSE 'away' END,
          'won', players.org_id = 'mr-host-home',
          'kills', CASE WHEN players.org_id = 'mr-host-home' THEN 5 ELSE 2 END,
          'deaths', CASE WHEN players.org_id = 'mr-host-home' THEN 2 ELSE 5 END,
          'assists', 7,
          'godPlayed', 'Athena',
          'role', 'Flex',
          'damageDealt', 12000,
          'damageMitigated', 9000
        ) ORDER BY players.id
      )
      FROM public.players
      WHERE players.id LIKE 'mr-host-home-%' OR players.id LIKE 'mr-host-away-%'
    )
  )
) AS games;

CREATE TEMP TABLE mr_host_diagnostics AS
SELECT public.match_report_extraction_diagnostics(
  (SELECT report_id FROM mr_host_report), (SELECT games FROM mr_host_games)
) AS result;

SELECT ok(
  (SELECT result ->> 'gameCount' = '1'
      AND result -> 'duplicateIgns' = '[]'::jsonb
      AND result -> 'unlinkedIgns' = '[]'::jsonb
      AND result -> 'ambiguousIgns' = '[]'::jsonb
      AND jsonb_array_length(result -> 'games' -> 0 -> 'players') = 10
    FROM mr_host_diagnostics),
  'identity diagnostics link a complete game against the season-side roster'
);

UPDATE public.match_reports
SET status = 'review', extracted_data = (SELECT games FROM mr_host_games)
WHERE id = (SELECT report_id FROM mr_host_report);

CREATE TEMP TABLE mr_host_revision AS
SELECT public.revise_match_report_extraction(
  (SELECT report_id FROM mr_host_report), 'mr-host-discord', 1,
  (SELECT games FROM mr_host_games)
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'revised'
      AND result ->> 'revision' = '2'
      AND result ->> 'status' = 'review'
    FROM mr_host_revision)
  AND (SELECT revision = 2 FROM public.match_reports
    WHERE id = (SELECT report_id FROM mr_host_report)),
  'the bound host can durably revise extraction at the expected revision'
);

SELECT throws_ok(
  $$SELECT public.revise_match_report_extraction(
    (SELECT report_id FROM mr_host_report), 'mr-host-discord', 1,
    (SELECT games FROM mr_host_games)
  )$$,
  '40001', 'Match report revision is stale.',
  'a stale host revision fails with serialization semantics'
);

SELECT throws_ok(
  $$SELECT public.revise_match_report_extraction(
    (SELECT report_id FROM mr_host_report), 'not-the-host', 2,
    (SELECT games FROM mr_host_games)
  )$$,
  '42501', 'Only the match-report host can revise it.',
  'a different host cannot revise the extraction'
);

CREATE TEMP TABLE mr_host_unlinked_games AS
SELECT jsonb_set(
  (SELECT games FROM mr_host_games),
  '{0,players,0}',
  ((SELECT games FROM mr_host_games) #> '{0,players,0}')
    - 'playerId' || jsonb_build_object('playerIgn', 'Unknown Person')
) AS games;

UPDATE public.match_reports
SET extracted_data = (SELECT games FROM mr_host_unlinked_games)
WHERE id = (SELECT report_id FROM mr_host_report);
SELECT throws_ok(
  $$SELECT public.submit_match_report_host_review(
    (SELECT report_id FROM mr_host_report), 'mr-host-discord', 2
  )$$,
  '23514', 'Every player must be linked before host submission.',
  'host submission blocks an unlinked identity'
);
UPDATE public.match_reports
SET extracted_data = (SELECT games FROM mr_host_games)
WHERE id = (SELECT report_id FROM mr_host_report);

CREATE TEMP TABLE mr_host_submit AS
SELECT public.submit_match_report_host_review(
  (SELECT report_id FROM mr_host_report), 'mr-host-discord', 2
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'submitted'
      AND result ->> 'status' = 'host_review'
      AND jsonb_array_length(result -> 'outboxIds') = 1
    FROM mr_host_submit)
  AND EXISTS (
    SELECT 1 FROM public.match_reports
    WHERE id = (SELECT report_id FROM mr_host_report)
      AND status = 'host_review'
      AND host_submitted_at IS NOT NULL
  )
  AND EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_type = 'match_report'
      AND aggregate_id = (SELECT report_id::text FROM mr_host_report)
      AND topic = 'discord_review_projection'
      AND event_type = 'match_report_host_submitted'
      AND payload ->> 'pendingActionId' = 'mr-host-action'
      AND payload ->> 'proofThreadId' = 'proof-thread-252'
  ),
  'host submission transitions the report and durably projects Discord review work'
);

CREATE TEMP TABLE mr_host_submit_retry AS
SELECT public.submit_match_report_host_review(
  (SELECT report_id FROM mr_host_report), 'mr-host-discord', 2
) AS result;
SELECT ok(
  (SELECT result ->> 'code' = 'already_submitted'
      AND result ->> 'applied' = 'false'
    FROM mr_host_submit_retry)
  AND (SELECT count(*) = 1 FROM public.operation_outbox
    WHERE aggregate_type = 'match_report'
      AND aggregate_id = (SELECT report_id::text FROM mr_host_report)
      AND event_type = 'match_report_host_submitted'),
  'an identical host-submission retry is a no-op with one projection event'
);

SELECT throws_ok(
  $$SELECT public.submit_match_report_host_review(
    (SELECT report_id FROM mr_host_report), 'mr-host-discord', 1
  )$$,
  '40001', 'Match report revision is stale.',
  'an already-submitted report still rejects a different stale revision'
);

SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    (SELECT report_id FROM mr_host_report), 'mr-host-discord',
    (SELECT games FROM mr_host_games)
  )$$,
  '42501', 'Actor is not an authorized administrator.',
  'the host cannot cross the admin-only publication boundary'
);

CREATE TEMP TABLE mr_host_resolve AS
SELECT public.resolve_match_report_review(
  (SELECT report_id FROM mr_host_report), 'mr-host-admin',
  (SELECT games FROM mr_host_games)
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'applied' FROM mr_host_resolve)
  AND (SELECT count(*) = 10 FROM public.player_stats WHERE match_id = 'mr-host-match')
  AND NOT EXISTS (
    SELECT 1 FROM public.player_stats
    WHERE match_id = 'mr-host-match'
      AND match_report_id IS DISTINCT FROM (SELECT report_id FROM mr_host_report)
  )
  AND EXISTS (
    SELECT 1 FROM public.pending_actions
    WHERE id = 'mr-host-action'
      AND status = 'approved'
      AND payload_json ->> 'winnerOrgId' = 'mr-host-home'
      AND payload_json ->> 'score' = '1-0'
      AND payload_json #>> '{parsed,gamesPlayed}' = '1'
      AND payload_json #>> '{parsed,expectedScreenshots}' = '1'
  )
  AND EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE entity_type = 'match_report'
      AND entity_id = (SELECT report_id::text FROM mr_host_report)
      AND action_type = 'match_report_stats_published'
      AND new_value_json ->> 'producer' = 'match_report'
  )
  AND EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE entity_type = 'pending_action'
      AND entity_id = 'mr-host-action'
      AND action_type = 'pending_action_approved_via_match_report'
  )
  AND (SELECT host_submitted_at IS NOT NULL FROM public.match_reports
    WHERE id = (SELECT report_id FROM mr_host_report))
  AND NOT EXISTS (
    SELECT 1 FROM public.player_stats
    WHERE match_id = 'mr-host-match'
      AND (season_id IS DISTINCT FROM 'mr-host-season'
        OR division_id IS DISTINCT FROM 'terra'
        OR org_id IS NULL
        OR org_id NOT IN ('mr-host-home', 'mr-host-away'))
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.players players
    WHERE (players.id LIKE 'mr-host-home-%' OR players.id LIKE 'mr-host-away-%')
      AND players.stats IS DISTINCT FROM jsonb_build_object(
        'kills', CASE WHEN players.org_id = 'mr-host-home' THEN 5 ELSE 2 END,
        'deaths', CASE WHEN players.org_id = 'mr-host-home' THEN 2 ELSE 5 END,
        'assists', 7,
        'gamesPlayed', 1,
        'wins', CASE WHEN players.org_id = 'mr-host-home' THEN 1 ELSE 0 END
      )
  ),
  'admin approval publishes owned official stats, refreshes aggregates, and finalizes the corrected linked action'
);

CREATE TEMP TABLE mr_host_resolve_retry AS
SELECT public.resolve_match_report_review(
  (SELECT report_id FROM mr_host_report), 'mr-host-admin',
  (SELECT games FROM mr_host_games)
) AS result;
SELECT ok(
  (SELECT result ->> 'code' = 'already_processed' FROM mr_host_resolve_retry)
  AND (SELECT count(*) = 10 FROM public.player_stats WHERE match_id = 'mr-host-match')
  AND (SELECT count(*) = 1 FROM public.operation_outbox
    WHERE aggregate_type = 'match_report'
      AND aggregate_id = (SELECT report_id::text FROM mr_host_report)
      AND topic = 'standings_recalculation'),
  'admin re-resolution is idempotent for official stats and standings work'
);

UPDATE public.pending_actions
SET status = 'pending', approved_by_discord_id = NULL, approved_at = NULL
WHERE id = 'mr-host-action';
SELECT throws_ok(
  $$SELECT public.resolve_pending_action(
    'mr-host-action', 'mr-host-admin', 'approve', NULL
  )$$,
  '55000',
  'Linked match-result approval must be completed through match-report review.',
  'even a linked completed report cannot be stale-cancelled through the legacy approval path'
);
SELECT public.resolve_match_report_review(
  (SELECT report_id FROM mr_host_report), 'mr-host-admin', NULL
);
SELECT ok(
  (SELECT status = 'approved' FROM public.pending_actions WHERE id = 'mr-host-action'),
  'a completed-report retry repairs and finalizes an unexpectedly open linked action'
);

DELETE FROM public.player_stats
WHERE match_id = 'mr-host-match'
  AND player_id = 'mr-host-home-1'
  AND game_number = 1;
UPDATE public.players SET stats = '{}'::jsonb WHERE id = 'mr-host-home-1';
SELECT public.resolve_match_report_review(
  (SELECT report_id FROM mr_host_report), 'mr-host-admin', NULL
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.player_stats
    WHERE match_id = 'mr-host-match'
      AND player_id = 'mr-host-home-1'
      AND game_number = 1
      AND match_report_id = (SELECT report_id FROM mr_host_report)
  )
  AND (SELECT stats ->> 'gamesPlayed' = '1' FROM public.players WHERE id = 'mr-host-home-1'),
  'a completed-report retry repairs a missing owned canonical row and aggregate'
);

INSERT INTO public.player_stats (
  match_id, player_id, match_report_id, game_number, won,
  kills, deaths, assists, season_id, org_id, division_id
) VALUES (
  'mr-host-match', 'mr-host-home-1', (SELECT report_id FROM mr_host_report),
  2, true, 99, 99, 99, 'mr-host-season', 'mr-host-home', 'terra'
);
UPDATE public.players SET stats = '{"gamesPlayed":999}'::jsonb WHERE id = 'mr-host-home-1';
SELECT public.resolve_match_report_review(
  (SELECT report_id FROM mr_host_report), 'mr-host-admin', NULL
);
SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM public.player_stats
    WHERE match_id = 'mr-host-match'
      AND player_id = 'mr-host-home-1'
      AND game_number = 2
  )
  AND (SELECT stats ->> 'gamesPlayed' = '1' FROM public.players WHERE id = 'mr-host-home-1'),
  'report publication is a set replacement that deletes stale owned rows and refreshes removed-player aggregates'
);

UPDATE public.player_stats
SET match_report_id = NULL
WHERE match_id = 'mr-host-match'
  AND player_id = 'mr-host-home-1'
  AND game_number = 1;
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    (SELECT report_id FROM mr_host_report), 'mr-host-admin', NULL
  )$$,
  '23505',
  'Official player stats already exist for this match from another or ambiguous producer.',
  'a report never overwrites official rows with ambiguous or different provenance'
);
UPDATE public.player_stats
SET match_report_id = (SELECT report_id FROM mr_host_report)
WHERE match_id = 'mr-host-match'
  AND player_id = 'mr-host-home-1'
  AND game_number = 1;

INSERT INTO public.matches (
  id, division_id, home_org_id, away_org_id, scheduled_date, scheduled_time,
  status, week, season_id
) VALUES (
  'mr-host-rebind-match', 'terra', 'mr-host-home', 'mr-host-away',
  '2026-08-23', '19:00', 'scheduled', 1, 'mr-host-season'
);
CREATE TEMP TABLE mr_host_rebind_first AS
SELECT public.create_match_result_action_with_report(
  'mr-host-rebind-match', 'mr-host-rebind-old',
  '{"winnerOrgId":"mr-host-home","score":"1-0","parsed":{"winnerGames":1,"loserGames":0,"gamesPlayed":1,"expectedScreenshots":1}}'::jsonb
) AS result;
UPDATE public.match_reports
SET screenshot_urls = ARRAY['https://example.com/rebind-proof.png'],
    extracted_data = '{"games":[{"gameNumber":1}]}'::jsonb
WHERE id = (SELECT (result ->> 'reportId')::uuid FROM mr_host_rebind_first);
SELECT public.issue_match_report_host_token(
  (SELECT (result ->> 'reportId')::uuid FROM mr_host_rebind_first),
  'mr-host-rebind-old', repeat('d', 64), now() + interval '15 minutes'
);
SELECT public.resolve_pending_action(
  (SELECT result ->> 'actionId' FROM mr_host_rebind_first),
  'mr-host-admin', 'deny', 'Incorrect result.'
);
SELECT ok(
  (SELECT status = 'cancelled' FROM public.match_reports
   WHERE id = (SELECT (result ->> 'reportId')::uuid FROM mr_host_rebind_first))
  AND public.consume_match_report_host_token(repeat('d', 64)) IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.match_report_host_tokens
    WHERE match_report_id = (SELECT (result ->> 'reportId')::uuid FROM mr_host_rebind_first)
  ),
  'denial terminally cancels the linked report and invalidates its host capabilities'
);

CREATE TEMP TABLE mr_host_rebind_second AS
SELECT public.create_match_result_action_with_report(
  'mr-host-rebind-match', 'mr-host-rebind-new',
  '{"winnerOrgId":"mr-host-away","score":"1-0","parsed":{"winnerGames":1,"loserGames":0,"gamesPlayed":1,"expectedScreenshots":1}}'::jsonb
) AS result;
SELECT ok(
  (SELECT result ->> 'code' = 'created'
      AND result ->> 'hostDiscordId' = 'mr-host-rebind-new'
    FROM mr_host_rebind_second)
  AND (SELECT first.result ->> 'reportId' = second.result ->> 'reportId'
       FROM mr_host_rebind_first first CROSS JOIN mr_host_rebind_second second)
  AND EXISTS (
    SELECT 1 FROM public.match_reports
    WHERE id = (SELECT (result ->> 'reportId')::uuid FROM mr_host_rebind_second)
      AND pending_action_id = (SELECT result ->> 'actionId' FROM mr_host_rebind_second)
      AND host_discord_id = 'mr-host-rebind-new'
      AND status = 'pending'
      AND revision = 2
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.player_stats
    WHERE match_report_id = (SELECT (result ->> 'reportId')::uuid FROM mr_host_rebind_second)
  )
  AND EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE action_type = 'match_report_rebound'
      AND entity_id = (SELECT result ->> 'reportId' FROM mr_host_rebind_second)
      AND old_value_json -> 'screenshot_urls' = '["https://example.com/rebind-proof.png"]'::jsonb
      AND old_value_json -> 'extracted_data' = '{"games":[{"gameNumber":1}]}'::jsonb
      AND jsonb_typeof(old_value_json -> 'playerMatchStats') = 'array'
  ),
  'a later result atomically rebinds the cancelled report without stale official stats'
);

INSERT INTO public.matches (
  id, division_id, home_org_id, away_org_id, scheduled_date, scheduled_time,
  status, week, season_id
) VALUES (
  'mr-host-unlinked-match', 'terra', 'mr-host-home', 'mr-host-away',
  '2026-08-21', '19:00', 'scheduled', 1, 'mr-host-season'
);
INSERT INTO public.match_reports (
  id, match_id, season_id, division_id, status, submitted_by,
  host_discord_id, revision
) VALUES (
  '00000000-0000-0000-0000-000000002522', 'mr-host-unlinked-match',
  'mr-host-season', 'terra', 'review', 'mr-host-discord', 'mr-host-discord', 1
);
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-000000002522', 'mr-host-admin',
    (SELECT games FROM mr_host_unlinked_games)
  )$$,
  '23514', 'Every official player stat must be linked before approval.',
  'admin approval cannot publish an unlinked IGN'
);

CREATE FUNCTION pg_temp.mr_host_reject_publication() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.match_id = 'mr-host-unlinked-match' THEN
    RAISE EXCEPTION 'forced official publication failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER mr_host_force_publication_failure
BEFORE INSERT OR UPDATE ON public.player_stats
FOR EACH ROW EXECUTE FUNCTION pg_temp.mr_host_reject_publication();

SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-000000002522', 'mr-host-admin',
    (SELECT games FROM mr_host_games)
  )$$,
  'P0001', 'forced official publication failure',
  'a canonical player_stats publication failure aborts approval'
);
SELECT ok(
  (SELECT status = 'scheduled' FROM public.matches
    WHERE id = 'mr-host-unlinked-match')
  AND (SELECT status = 'review' FROM public.match_reports
    WHERE id = '00000000-0000-0000-0000-000000002522')
  AND NOT EXISTS (
    SELECT 1 FROM public.player_match_stats
    WHERE match_report_id = '00000000-0000-0000-0000-000000002522'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.player_stats WHERE match_id = 'mr-host-unlinked-match'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_type = 'match_report'
      AND aggregate_id = '00000000-0000-0000-0000-000000002522'
  ),
  'a publication failure rolls back report, match, staged stats, audits, and standings work'
);
DROP TRIGGER mr_host_force_publication_failure ON public.player_stats;

SELECT private.resolve_match_report_review_unpublished(
  '00000000-0000-0000-0000-000000002522', 'mr-host-admin',
  (SELECT games FROM mr_host_unlinked_games)
);
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-000000002522', 'mr-host-admin', NULL
  )$$,
  '23514',
  'Completed match report does not have one fully linked 5v5 stat set per game.',
  'a legacy completed report with an unlinked identity never partially publishes canonical stats'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM public.player_stats WHERE match_id = 'mr-host-unlinked-match'
  ),
  'a non-publishable legacy completed report leaves the canonical stat set untouched'
);

SELECT * FROM finish();
ROLLBACK;
