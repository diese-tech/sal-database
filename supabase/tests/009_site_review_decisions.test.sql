BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS dblink WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(40);

SELECT has_function(
  'public',
  'resolve_registration_review',
  ARRAY['text', 'text', 'text', 'text'],
  'the transactional registration review RPC exists'
);

SELECT has_function(
  'public',
  'resolve_match_report_review',
  ARRAY['uuid', 'text', 'jsonb'],
  'the transactional match-report review RPC exists'
);

INSERT INTO public.admin_users (
  discord_id, role, discord_username, display_name
) VALUES (
  'db02-admin', 'admin', 'db02-admin', 'DB02 Admin'
);

INSERT INTO public.registrations (
  id, discord_id, discord_username, discord_display_name, form_data
) VALUES (
  'db02-reg-create', 'db02-player-discord', 'db02-player', 'DB02 Player',
  '{"ign":"DB02 Player","primary_role":"Support","secondary_role":"Solo"}'::jsonb
);

CREATE TEMP TABLE db02_registration_results AS
SELECT public.resolve_registration_review(
  'db02-reg-create', 'db02-admin', 'approve', 'Eligible for preseason.'
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'applied'
      AND result ->> 'finalStatus' = 'approved'
      AND result ->> 'applied' = 'true'
      AND NOT (result ? 'discordId')
    FROM db02_registration_results)
  AND
  EXISTS (
    SELECT 1
    FROM public.registrations registrations
    JOIN public.players players ON players.id = registrations.player_id
    WHERE registrations.id = 'db02-reg-create'
      AND registrations.status = 'approved'
      AND registrations.reviewer_note = 'Eligible for preseason.'
      AND players.discord_id = 'db02-player-discord'
      AND players.profile_claimed
      AND players.ign = 'DB02 Player'
      AND players.primary_role = 'Support'
      AND players.secondary_roles = '["Solo"]'::jsonb
      AND players.status = 'free-agent'
  )
  AND
  (SELECT count(*) = 1 FROM public.audit_logs
    WHERE entity_type = 'registration'
      AND entity_id = 'db02-reg-create'
      AND action_type = 'registration_approved')
  AND
  (SELECT count(*) = 1 FROM public.admin_audit_log
    WHERE entity_type = 'registration'
      AND entity_id = 'db02-reg-create'
      AND action = 'approve_registration'),
  'registration approval atomically creates and links the player, transitions the review, and writes audit evidence'
);

INSERT INTO public.seasons (
  id, name, status, start_date, end_date, is_current
) VALUES (
  'db02-season', 'DB02 Season', 'pre-season', '2026-01-01', '2026-12-31', false
);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
) VALUES
  ('db02-home', 'DB02 Home', 'D2H', 'terra', 'DH', 'from-black to-white', '#000000', 'from-black to-white'),
  ('db02-away', 'DB02 Away', 'D2A', 'terra', 'DA', 'from-black to-white', '#000000', 'from-black to-white');

INSERT INTO public.season_orgs (season_id, org_id, division_id)
VALUES
  ('db02-season', 'db02-home', 'terra'),
  ('db02-season', 'db02-away', 'terra');

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status
)
SELECT
  'db02-home-' || player_number,
  'db02-home',
  'db02-home-' || player_number,
  'DB02 Home ' || player_number,
  'DH', 'from-black to-white', 'Flex', 'terra', 'active'
FROM generate_series(1, 5) AS player_number
UNION ALL
SELECT
  'db02-away-' || player_number,
  'db02-away',
  'db02-away-' || player_number,
  'DB02 Away ' || player_number,
  'DA', 'from-black to-white', 'Flex', 'terra', 'active'
FROM generate_series(1, 5) AS player_number;

INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, roster_status
)
SELECT 'db02-season', id, org_id, 'terra', 'active'
FROM public.players
WHERE id LIKE 'db02-home-%' OR id LIKE 'db02-away-%';

INSERT INTO public.matches (
  id, division_id, home_org_id, away_org_id, scheduled_date, scheduled_time,
  status, week, season_id
) VALUES (
  'db02-match', 'terra', 'db02-home', 'db02-away', '2026-08-01', '19:00',
  'scheduled', 1, 'db02-season'
);

INSERT INTO public.match_reports (
  id, match_id, season_id, division_id, status, submitted_by
) VALUES (
  '00000000-0000-0000-0000-00000000d201', 'db02-match', 'db02-season',
  'terra', 'review', 'db02-submitter'
);

CREATE TEMP TABLE db02_match_payload AS
SELECT jsonb_build_array(
  jsonb_build_object(
    'gameNumber', 1,
    'winningSide', 'home',
    'players', (
      SELECT jsonb_agg(player ORDER BY player ->> 'playerId')
      FROM (
        SELECT jsonb_build_object(
          'playerIgn', players.ign,
          'playerId', players.id,
          'orgId', players.org_id,
          'side', CASE WHEN players.org_id = 'db02-home' THEN 'home' ELSE 'away' END,
          'won', players.org_id = 'db02-home',
          'kills', CASE WHEN players.org_id = 'db02-home' THEN 5 ELSE 2 END,
          'deaths', CASE WHEN players.org_id = 'db02-home' THEN 2 ELSE 5 END,
          'assists', 7,
          'godPlayed', 'Athena',
          'role', 'Flex',
          'damageDealt', 12000,
          'damageMitigated', 9000
        ) AS player
        FROM public.players
        WHERE players.id LIKE 'db02-home-%' OR players.id LIKE 'db02-away-%'
      ) payload_players
    )
  )
) AS games;

CREATE TEMP TABLE db02_match_results AS
SELECT public.resolve_match_report_review(
  '00000000-0000-0000-0000-00000000d201',
  'db02-admin',
  (SELECT games FROM db02_match_payload)
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'applied'
      AND result ->> 'finalStatus' = 'done'
      AND result ->> 'applied' = 'true'
      AND result ->> 'homeScore' = '1'
      AND result ->> 'awayScore' = '0'
      AND result ->> 'totalGames' = '1'
      AND NOT (result ? 'reviewedBy')
    FROM db02_match_results)
  AND
  EXISTS (
    SELECT 1 FROM public.matches
    WHERE id = 'db02-match'
      AND status = 'completed'
      AND home_score = 1
      AND away_score = 0
      AND winner_org_id = 'db02-home'
      AND score = '1-0'
  )
  AND
  EXISTS (
    SELECT 1 FROM public.match_reports
    WHERE id = '00000000-0000-0000-0000-00000000d201'
      AND status = 'done'
      AND home_score = 1
      AND away_score = 0
      AND total_games = 1
      AND reviewed_by = 'db02-admin'
  )
  AND
  (SELECT count(*) = 10 FROM public.player_match_stats
    WHERE match_report_id = '00000000-0000-0000-0000-00000000d201')
  AND
  (SELECT count(*) = 1 FROM public.audit_logs
    WHERE entity_type = 'match_report'
      AND entity_id = '00000000-0000-0000-0000-00000000d201'
      AND action_type = 'match_report_resolved')
  AND
  (SELECT count(*) = 1 FROM public.admin_audit_log
    WHERE entity_type = 'match_report'
      AND entity_id = '00000000-0000-0000-0000-00000000d201'
      AND action = 'match_report_submitted')
  AND
  (SELECT count(*) = 1 FROM public.operation_outbox
    WHERE aggregate_type = 'match_report'
      AND aggregate_id = '00000000-0000-0000-0000-00000000d201'
      AND topic = 'standings_recalculation'),
  'match-report review atomically validates 5v5 stats, completes the match and report, audits, and enqueues standings'
);

CREATE TEMP TABLE db02_registration_replay AS
SELECT public.resolve_registration_review(
  'db02-reg-create', 'db02-admin', 'approve', 'Ignored replay note.'
) AS result;
SELECT ok(
  (SELECT result ->> 'code' = 'already_processed'
      AND result ->> 'finalStatus' = 'approved'
      AND result ->> 'applied' = 'false'
    FROM db02_registration_replay)
  AND
  (SELECT count(*) = 1 FROM public.audit_logs
    WHERE entity_type = 'registration' AND entity_id = 'db02-reg-create')
  AND
  (SELECT count(*) = 1 FROM public.admin_audit_log
    WHERE entity_type = 'registration' AND entity_id = 'db02-reg-create'),
  'replaying the same registration decision is idempotent and creates no duplicate evidence'
);

SELECT throws_ok(
  $$SELECT public.resolve_registration_review(
    'db02-reg-create', 'db02-admin', 'reject', 'Conflicting replay.'
  )$$,
  '55000',
  'Registration already has a conflicting terminal decision.',
  'a conflicting terminal registration replay is rejected'
);

INSERT INTO public.registrations (
  id, discord_id, discord_username, form_data
) VALUES (
  'db02-reg-reject', 'db02-reject-discord', 'db02-reject',
  '{"ign":"DB02 Reject","primary_role":"Flex"}'::jsonb
);
SELECT throws_ok(
  $$SELECT public.resolve_registration_review(
    'db02-reg-reject', 'db02-admin', 'reject', NULL
  )$$,
  '22023',
  'A reviewer note is required for registration rejection.',
  'registration rejection requires a reason'
);
SELECT is(
  public.resolve_registration_review(
    'db02-reg-reject', 'db02-admin', 'reject', 'Registration is incomplete.'
  ) ->> 'finalStatus',
  'rejected',
  'a valid rejection transitions the registration and records its terminal result'
);

INSERT INTO public.registrations (
  id, discord_id, discord_username, form_data
) VALUES (
  'db02-reg-unauthorized', 'db02-unauthorized-discord', 'db02-unauthorized',
  '{"ign":"DB02 Unauthorized","primary_role":"Flex"}'::jsonb
);
SELECT throws_ok(
  $$SELECT public.resolve_registration_review(
    'db02-reg-unauthorized', 'not-an-admin', 'approve', NULL
  )$$,
  '42501',
  'Actor is not an authorized administrator.',
  'an unauthorized actor cannot review a registration'
);

INSERT INTO public.registrations (
  id, discord_id, discord_username, form_data
) VALUES
  ('db02-reg-no-ign', 'db02-no-ign-discord', 'db02-no-ign', '{"primary_role":"Flex"}'::jsonb),
  ('db02-reg-bad-role', 'db02-bad-role-discord', 'db02-bad-role', '{"ign":"DB02 Bad Role","primary_role":"Wizard"}'::jsonb);
SELECT throws_ok(
  $$SELECT public.resolve_registration_review(
    'db02-reg-no-ign', 'db02-admin', 'approve', NULL
  )$$,
  '22023',
  'Registration IGN must contain between 1 and 64 characters.',
  'approval rejects a registration without a usable IGN'
);
SELECT ok(
  (SELECT status = 'pending' AND player_id IS NULL
    FROM public.registrations WHERE id = 'db02-reg-no-ign')
  AND NOT EXISTS (
    SELECT 1 FROM public.players WHERE discord_id = 'db02-no-ign-discord'
  ),
  'invalid registration data leaves both the registration and player catalog unchanged'
);
SELECT throws_ok(
  $$SELECT public.resolve_registration_review(
    'db02-reg-bad-role', 'db02-admin', 'approve', NULL
  )$$,
  '22023',
  'Registration primary role is invalid.',
  'approval rejects an invalid registration role'
);

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, status, discord_id, profile_claimed
) VALUES (
  'db02-existing-player', 'old-name', 'Existing IGN', 'EI', '',
  'Carry', 'free-agent', 'db02-existing-discord', true
);
INSERT INTO public.registrations (
  id, discord_id, discord_username, form_data
) VALUES (
  'db02-reg-existing', 'db02-existing-discord', 'current-name',
  '{"ign":"Submitted IGN","primary_role":"Support"}'::jsonb
);
CREATE TEMP TABLE db02_existing_registration_result AS
SELECT public.resolve_registration_review(
  'db02-reg-existing', 'db02-admin', 'approve', NULL
) AS result;
SELECT ok(
  (SELECT result ->> 'playerId' = 'db02-existing-player'
    FROM db02_existing_registration_result)
  AND
  (SELECT ign = 'Existing IGN'
      AND discord_username = 'current-name'
      AND profile_claimed
    FROM public.players WHERE id = 'db02-existing-player')
  AND
  (SELECT player_id = 'db02-existing-player' AND status = 'approved'
    FROM public.registrations WHERE id = 'db02-reg-existing'),
  'approval links the verified Discord identity to its existing player without overwriting profile data'
);

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, status, discord_id, profile_claimed
) VALUES (
  'db02-victim-player', 'db02-victim', 'DB02 Victim', 'DV', '',
  'Solo', 'free-agent', 'db02-victim-discord', true
);
INSERT INTO public.registrations (
  id, discord_id, discord_username, player_id, form_data
) VALUES (
  'db02-reg-hijack', 'db02-attacker-discord', 'db02-attacker', 'db02-victim-player',
  '{"ign":"DB02 Attacker","primary_role":"Jungle"}'::jsonb
);
SELECT throws_ok(
  $$SELECT public.resolve_registration_review(
    'db02-reg-hijack', 'db02-admin', 'approve', NULL
  )$$,
  '23505',
  'Registration-linked player belongs to another Discord identity.',
  'a registration cannot claim a player owned by another Discord identity'
);
SELECT ok(
  (SELECT status = 'pending' AND player_id = 'db02-victim-player'
    FROM public.registrations WHERE id = 'db02-reg-hijack')
  AND
  (SELECT discord_id = 'db02-victim-discord'
    FROM public.players WHERE id = 'db02-victim-player'),
  'a blocked identity hijack leaves both records unchanged'
);

INSERT INTO public.registrations (
  id, discord_id, discord_username, form_data
) VALUES (
  'db02-reg-rollback', 'db02-rollback-discord', 'db02-rollback',
  '{"ign":"DB02 Rollback","primary_role":"Mid"}'::jsonb
);
CREATE FUNCTION pg_temp.db02_reject_registration_admin_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.entity_type = 'registration' AND NEW.entity_id = 'db02-reg-rollback' THEN
    RAISE EXCEPTION 'forced registration admin audit failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER db02_force_registration_admin_audit_failure
BEFORE INSERT ON public.admin_audit_log
FOR EACH ROW EXECUTE FUNCTION pg_temp.db02_reject_registration_admin_audit();
SELECT throws_ok(
  $$SELECT public.resolve_registration_review(
    'db02-reg-rollback', 'db02-admin', 'approve', NULL
  )$$,
  'P0001',
  'forced registration admin audit failure',
  'a late registration audit failure aborts the decision'
);
SELECT ok(
  (SELECT status = 'pending' AND player_id IS NULL
    FROM public.registrations WHERE id = 'db02-reg-rollback')
  AND NOT EXISTS (
    SELECT 1 FROM public.players WHERE discord_id = 'db02-rollback-discord'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE entity_type = 'registration' AND entity_id = 'db02-reg-rollback'
  ),
  'a late registration audit failure rolls back the player, transition, and earlier audit write'
);
DROP TRIGGER db02_force_registration_admin_audit_failure ON public.admin_audit_log;

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_proc functions
    JOIN pg_namespace namespaces ON namespaces.oid = functions.pronamespace
    WHERE namespaces.nspname = 'public'
      AND functions.proname IN ('resolve_registration_review', 'resolve_match_report_review')
      AND (
        has_function_privilege('anon', functions.oid, 'EXECUTE')
        OR has_function_privilege('authenticated', functions.oid, 'EXECUTE')
        OR NOT has_function_privilege('service_role', functions.oid, 'EXECUTE')
        OR NOT (functions.proconfig @> ARRAY['search_path=pg_catalog, public'])
      )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_proc functions
    JOIN pg_namespace namespaces ON namespaces.oid = functions.pronamespace
    CROSS JOIN LATERAL aclexplode(COALESCE(functions.proacl, acldefault('f', functions.proowner))) privileges
    WHERE namespaces.nspname = 'public'
      AND functions.proname IN ('resolve_registration_review', 'resolve_match_report_review')
      AND privileges.grantee = 0
      AND privileges.privilege_type = 'EXECUTE'
  ),
  'site-review RPCs are service-role-only and pin the trusted search path'
);

CREATE TEMP TABLE db02_match_replay AS
SELECT public.resolve_match_report_review(
  '00000000-0000-0000-0000-00000000d201',
  'db02-admin',
  (SELECT games FROM db02_match_payload)
) AS result;
SELECT ok(
  (SELECT result ->> 'code' = 'already_processed'
      AND result ->> 'finalStatus' = 'done'
      AND result ->> 'applied' = 'false'
    FROM db02_match_replay)
  AND
  (SELECT count(*) = 10 FROM public.player_match_stats
    WHERE match_report_id = '00000000-0000-0000-0000-00000000d201')
  AND
  (SELECT count(*) = 1 FROM public.audit_logs
    WHERE entity_type = 'match_report'
      AND entity_id = '00000000-0000-0000-0000-00000000d201')
  AND
  (SELECT count(*) = 1 FROM public.operation_outbox
    WHERE aggregate_type = 'match_report'
      AND aggregate_id = '00000000-0000-0000-0000-00000000d201'),
  'replaying a completed match report is idempotent and does not duplicate stats, audit, or outbox rows'
);

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status
) VALUES (
  'db02-away-extra', 'db02-away', 'db02-away-extra', 'DB02 Away Extra',
  'DA', 'from-black to-white', 'Flex', 'terra', 'active'
);
INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, roster_status
) VALUES (
  'db02-season', 'db02-away-extra', 'db02-away', 'terra', 'active'
);

INSERT INTO public.matches (
  id, division_id, home_org_id, away_org_id, scheduled_date, scheduled_time,
  status, week, season_id
) VALUES
  ('db02-partial', 'terra', 'db02-home', 'db02-away', '2026-08-02', '19:00', 'scheduled', 1, 'db02-season'),
  ('db02-duplicate-game', 'terra', 'db02-home', 'db02-away', '2026-08-03', '19:00', 'scheduled', 1, 'db02-season'),
  ('db02-cross-team', 'terra', 'db02-home', 'db02-away', '2026-08-04', '19:00', 'scheduled', 1, 'db02-season'),
  ('db02-negative', 'terra', 'db02-home', 'db02-away', '2026-08-05', '19:00', 'scheduled', 1, 'db02-season'),
  ('db02-win-mismatch', 'terra', 'db02-home', 'db02-away', '2026-08-06', '19:00', 'scheduled', 1, 'db02-season'),
  ('db02-unsafe-optional', 'terra', 'db02-home', 'db02-away', '2026-08-07', '19:00', 'scheduled', 1, 'db02-season'),
  ('db02-stale', 'terra', 'db02-home', 'db02-away', '2026-08-08', '19:00', 'completed', 1, 'db02-season'),
  ('db02-unlinked', 'terra', 'db02-home', 'db02-away', '2026-08-09', '19:00', 'scheduled', 1, 'db02-season'),
  ('db02-fail-stats', 'terra', 'db02-home', 'db02-away', '2026-08-10', '19:00', 'scheduled', 1, 'db02-season'),
  ('db02-fail-match', 'terra', 'db02-home', 'db02-away', '2026-08-11', '19:00', 'scheduled', 1, 'db02-season'),
  ('db02-fail-report', 'terra', 'db02-home', 'db02-away', '2026-08-12', '19:00', 'scheduled', 1, 'db02-season'),
  ('db02-fail-audit', 'terra', 'db02-home', 'db02-away', '2026-08-13', '19:00', 'scheduled', 1, 'db02-season'),
  ('db02-fail-admin-audit', 'terra', 'db02-home', 'db02-away', '2026-08-14', '19:00', 'scheduled', 1, 'db02-season'),
  ('db02-fail-outbox', 'terra', 'db02-home', 'db02-away', '2026-08-15', '19:00', 'scheduled', 1, 'db02-season');

INSERT INTO public.match_reports (
  id, match_id, season_id, division_id, status, submitted_by
) VALUES
  ('00000000-0000-0000-0000-00000000d202', 'db02-partial', 'db02-season', 'terra', 'review', 'db02-submitter'),
  ('00000000-0000-0000-0000-00000000d203', 'db02-duplicate-game', 'db02-season', 'terra', 'review', 'db02-submitter'),
  ('00000000-0000-0000-0000-00000000d204', 'db02-cross-team', 'db02-season', 'terra', 'review', 'db02-submitter'),
  ('00000000-0000-0000-0000-00000000d205', 'db02-negative', 'db02-season', 'terra', 'review', 'db02-submitter'),
  ('00000000-0000-0000-0000-00000000d206', 'db02-win-mismatch', 'db02-season', 'terra', 'review', 'db02-submitter'),
  ('00000000-0000-0000-0000-00000000d207', 'db02-unsafe-optional', 'db02-season', 'terra', 'review', 'db02-submitter'),
  ('00000000-0000-0000-0000-00000000d208', 'db02-stale', 'db02-season', 'terra', 'review', 'db02-submitter'),
  ('00000000-0000-0000-0000-00000000d209', 'db02-unlinked', 'db02-season', 'terra', 'review', 'db02-submitter'),
  ('00000000-0000-0000-0000-00000000d210', 'db02-fail-stats', 'db02-season', 'terra', 'review', 'db02-submitter'),
  ('00000000-0000-0000-0000-00000000d211', 'db02-fail-match', 'db02-season', 'terra', 'review', 'db02-submitter'),
  ('00000000-0000-0000-0000-00000000d212', 'db02-fail-report', 'db02-season', 'terra', 'review', 'db02-submitter'),
  ('00000000-0000-0000-0000-00000000d213', 'db02-fail-audit', 'db02-season', 'terra', 'review', 'db02-submitter'),
  ('00000000-0000-0000-0000-00000000d214', 'db02-fail-admin-audit', 'db02-season', 'terra', 'review', 'db02-submitter'),
  ('00000000-0000-0000-0000-00000000d215', 'db02-fail-outbox', 'db02-season', 'terra', 'review', 'db02-submitter');

CREATE TEMP TABLE db02_invalid_match_payloads AS
SELECT
  jsonb_set(games, '{0,players}', (games #> '{0,players}') - 9) AS partial,
  games || games AS duplicate_game,
  jsonb_set(
    jsonb_set(games, '{0,players,5,playerId}', to_jsonb('db02-away-extra'::text)),
    '{0,players,5,playerIgn}', to_jsonb('DB02 Away Extra'::text)
  ) AS cross_team,
  jsonb_set(games, '{0,players,5,kills}', '-1'::jsonb) AS negative,
  jsonb_set(games, '{0,players,5,won}', 'false'::jsonb) AS win_mismatch,
  jsonb_set(games, '{0,players,5,role}', '{"unsafe":true}'::jsonb) AS unsafe_optional,
  jsonb_set(
    games,
    '{0,players,5}',
    jsonb_set(
      ((games #> '{0,players,5}') - 'playerId' - 'orgId'),
      '{playerIgn}',
      to_jsonb('Unlinked Scout'::text)
    )
  ) AS unlinked
FROM db02_match_payload;

SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d202', 'db02-admin',
    (SELECT partial FROM db02_invalid_match_payloads)
  )$$,
  '22023', 'Every game must contain exactly ten player rows.',
  'a partial player set cannot resolve a match report'
);
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d203', 'db02-admin',
    (SELECT duplicate_game FROM db02_invalid_match_payloads)
  )$$,
  '23505', 'Reviewed payload contains a duplicate game number.',
  'duplicate game numbers cannot resolve a match report'
);
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d204', 'db02-admin',
    (SELECT cross_team FROM db02_invalid_match_payloads)
  )$$,
  '23514', 'Supplied player is not active on the expected organization.',
  'a cross-team player ID cannot be submitted for the opposite side'
);
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d205', 'db02-admin',
    (SELECT negative FROM db02_invalid_match_payloads)
  )$$,
  '22023', 'Kills, deaths, and assists must be nonnegative integers.',
  'negative match statistics are rejected'
);
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d206', 'db02-admin',
    (SELECT win_mismatch FROM db02_invalid_match_payloads)
  )$$,
  '22023', 'Player win flags must match the game winning side.',
  'player win flags must agree with the game winner'
);
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d207', 'db02-admin',
    (SELECT unsafe_optional FROM db02_invalid_match_payloads)
  )$$,
  '22023', 'Role must be a string of at most 64 characters.',
  'unsafe optional stat fields are rejected'
);
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d208', 'db02-admin',
    (SELECT games FROM db02_match_payload)
  )$$,
  '55000', 'Related match is not in a reviewable state.',
  'a stale completed match cannot be resolved from an open report'
);
SELECT ok(
  (SELECT count(*) = 7 FROM public.match_reports
    WHERE id BETWEEN '00000000-0000-0000-0000-00000000d202'::uuid
      AND '00000000-0000-0000-0000-00000000d208'::uuid
      AND status = 'review')
  AND NOT EXISTS (
    SELECT 1 FROM public.player_match_stats
    WHERE match_report_id BETWEEN '00000000-0000-0000-0000-00000000d202'::uuid
      AND '00000000-0000-0000-0000-00000000d208'::uuid
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE entity_type = 'match_report'
      AND entity_id IN (
        '00000000-0000-0000-0000-00000000d202',
        '00000000-0000-0000-0000-00000000d203',
        '00000000-0000-0000-0000-00000000d204',
        '00000000-0000-0000-0000-00000000d205',
        '00000000-0000-0000-0000-00000000d206',
        '00000000-0000-0000-0000-00000000d207',
        '00000000-0000-0000-0000-00000000d208'
      )
  ),
  'invalid, cross-team, partial, and stale payloads leave every domain and audit row unchanged'
);

CREATE TEMP TABLE db02_unlinked_match_result AS
SELECT public.resolve_match_report_review(
  '00000000-0000-0000-0000-00000000d209',
  'db02-admin',
  (SELECT unlinked FROM db02_invalid_match_payloads)
) AS result;
SELECT ok(
  (SELECT result ->> 'code' = 'applied' FROM db02_unlinked_match_result)
  AND
  (SELECT count(*) = 1 FROM public.player_match_stats
    WHERE match_report_id = '00000000-0000-0000-0000-00000000d209'
      AND player_id IS NULL
      AND player_ign = 'Unlinked Scout'),
  'a validated unlinked IGN is retained as a stat row without claiming a player identity'
);

CREATE FUNCTION pg_temp.db02_reject_stats_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.match_report_id = '00000000-0000-0000-0000-00000000d210'::uuid THEN
    RAISE EXCEPTION 'forced stats insert failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER db02_force_stats_insert_failure
BEFORE INSERT ON public.player_match_stats
FOR EACH ROW EXECUTE FUNCTION pg_temp.db02_reject_stats_insert();
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d210', 'db02-admin',
    (SELECT games FROM db02_match_payload)
  )$$,
  'P0001', 'forced stats insert failure',
  'a stats write failure aborts match-report resolution'
);
SELECT ok(
  (SELECT status = 'scheduled' FROM public.matches WHERE id = 'db02-fail-stats')
  AND (SELECT status = 'review' FROM public.match_reports WHERE id = '00000000-0000-0000-0000-00000000d210')
  AND NOT EXISTS (SELECT 1 FROM public.player_match_stats WHERE match_report_id = '00000000-0000-0000-0000-00000000d210'),
  'a stats write failure leaves the report and match untouched'
);
DROP TRIGGER db02_force_stats_insert_failure ON public.player_match_stats;

CREATE FUNCTION pg_temp.db02_reject_match_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.id = 'db02-fail-match' AND NEW.status = 'completed' THEN
    RAISE EXCEPTION 'forced match update failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER db02_force_match_update_failure
BEFORE UPDATE ON public.matches
FOR EACH ROW EXECUTE FUNCTION pg_temp.db02_reject_match_update();
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d211', 'db02-admin',
    (SELECT games FROM db02_match_payload)
  )$$,
  'P0001', 'forced match update failure',
  'a match write failure aborts match-report resolution'
);
SELECT ok(
  (SELECT status = 'scheduled' FROM public.matches WHERE id = 'db02-fail-match')
  AND (SELECT status = 'review' FROM public.match_reports WHERE id = '00000000-0000-0000-0000-00000000d211')
  AND NOT EXISTS (SELECT 1 FROM public.player_match_stats WHERE match_report_id = '00000000-0000-0000-0000-00000000d211'),
  'a match write failure rolls back the inserted stats'
);
DROP TRIGGER db02_force_match_update_failure ON public.matches;

CREATE FUNCTION pg_temp.db02_reject_report_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.id = '00000000-0000-0000-0000-00000000d212'::uuid AND NEW.status = 'done' THEN
    RAISE EXCEPTION 'forced report update failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER db02_force_report_update_failure
BEFORE UPDATE ON public.match_reports
FOR EACH ROW EXECUTE FUNCTION pg_temp.db02_reject_report_update();
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d212', 'db02-admin',
    (SELECT games FROM db02_match_payload)
  )$$,
  'P0001', 'forced report update failure',
  'a report write failure aborts match-report resolution'
);
SELECT ok(
  (SELECT status = 'scheduled' FROM public.matches WHERE id = 'db02-fail-report')
  AND (SELECT status = 'review' FROM public.match_reports WHERE id = '00000000-0000-0000-0000-00000000d212')
  AND NOT EXISTS (SELECT 1 FROM public.player_match_stats WHERE match_report_id = '00000000-0000-0000-0000-00000000d212'),
  'a report write failure rolls back the stats and match transition'
);
DROP TRIGGER db02_force_report_update_failure ON public.match_reports;

CREATE FUNCTION pg_temp.db02_reject_match_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.entity_type = 'match_report' AND NEW.entity_id = '00000000-0000-0000-0000-00000000d213' THEN
    RAISE EXCEPTION 'forced match audit failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER db02_force_match_audit_failure
BEFORE INSERT ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION pg_temp.db02_reject_match_audit();
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d213', 'db02-admin',
    (SELECT games FROM db02_match_payload)
  )$$,
  'P0001', 'forced match audit failure',
  'a structured audit failure aborts match-report resolution'
);
SELECT ok(
  (SELECT status = 'scheduled' FROM public.matches WHERE id = 'db02-fail-audit')
  AND (SELECT status = 'review' FROM public.match_reports WHERE id = '00000000-0000-0000-0000-00000000d213')
  AND NOT EXISTS (SELECT 1 FROM public.player_match_stats WHERE match_report_id = '00000000-0000-0000-0000-00000000d213'),
  'a structured audit failure rolls back every earlier domain write'
);
DROP TRIGGER db02_force_match_audit_failure ON public.audit_logs;

CREATE FUNCTION pg_temp.db02_reject_match_admin_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.entity_type = 'match_report' AND NEW.entity_id = '00000000-0000-0000-0000-00000000d214' THEN
    RAISE EXCEPTION 'forced match admin audit failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER db02_force_match_admin_audit_failure
BEFORE INSERT ON public.admin_audit_log
FOR EACH ROW EXECUTE FUNCTION pg_temp.db02_reject_match_admin_audit();
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d214', 'db02-admin',
    (SELECT games FROM db02_match_payload)
  )$$,
  'P0001', 'forced match admin audit failure',
  'a site audit failure aborts match-report resolution'
);
SELECT ok(
  (SELECT status = 'scheduled' FROM public.matches WHERE id = 'db02-fail-admin-audit')
  AND (SELECT status = 'review' FROM public.match_reports WHERE id = '00000000-0000-0000-0000-00000000d214')
  AND NOT EXISTS (SELECT 1 FROM public.player_match_stats WHERE match_report_id = '00000000-0000-0000-0000-00000000d214')
  AND NOT EXISTS (SELECT 1 FROM public.audit_logs WHERE entity_id = '00000000-0000-0000-0000-00000000d214'),
  'a site audit failure rolls back the structured audit and every domain write'
);
DROP TRIGGER db02_force_match_admin_audit_failure ON public.admin_audit_log;

CREATE FUNCTION pg_temp.db02_reject_match_outbox() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.aggregate_type = 'match_report' AND NEW.aggregate_id = '00000000-0000-0000-0000-00000000d215' THEN
    RAISE EXCEPTION 'forced match outbox failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER db02_force_match_outbox_failure
BEFORE INSERT ON public.operation_outbox
FOR EACH ROW EXECUTE FUNCTION pg_temp.db02_reject_match_outbox();
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d215', 'db02-admin',
    (SELECT games FROM db02_match_payload)
  )$$,
  'P0001', 'forced match outbox failure',
  'an outbox failure aborts match-report resolution'
);
SELECT ok(
  (SELECT status = 'scheduled' FROM public.matches WHERE id = 'db02-fail-outbox')
  AND (SELECT status = 'review' FROM public.match_reports WHERE id = '00000000-0000-0000-0000-00000000d215')
  AND NOT EXISTS (SELECT 1 FROM public.player_match_stats WHERE match_report_id = '00000000-0000-0000-0000-00000000d215')
  AND NOT EXISTS (SELECT 1 FROM public.audit_logs WHERE entity_id = '00000000-0000-0000-0000-00000000d215')
  AND NOT EXISTS (SELECT 1 FROM public.admin_audit_log WHERE entity_id = '00000000-0000-0000-0000-00000000d215'),
  'an outbox failure rolls back both audit forms and every domain write'
);
DROP TRIGGER db02_force_match_outbox_failure ON public.operation_outbox;

SELECT * FROM finish();
ROLLBACK;
