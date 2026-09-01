BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(26);

-- ── Contract surface ────────────────────────────────────────────────────────

SELECT has_table(
  'public', 'match_report_corrections',
  'published match-report corrections keep durable receipts'
);
SELECT has_function(
  'public', 'correct_match_report_result',
  ARRAY['uuid', 'text', 'integer', 'text', 'text', 'jsonb'],
  'the audited match-report correction RPC exists'
);
SELECT has_function(
  'private', 'validate_match_report_games', ARRAY['text', 'jsonb'],
  'the shared reviewed-game validator exists'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.match_report_corrections'::regclass
      AND conname = 'match_report_corrections_correction_key_key'
      AND contype = 'u'
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.match_report_corrections'::regclass
      AND conname = 'match_report_corrections_revision_check'
      AND contype = 'c'
  )
  AND EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'match_report_corrections_report_created_idx'
  )
  AND (
    SELECT relrowsecurity FROM pg_class
    WHERE oid = 'public.match_report_corrections'::regclass
  ),
  'correction keys, revision arithmetic, lookup index, and row security are database-enforced'
);

SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.correct_match_report_result(uuid,text,integer,text,text,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege(
    'authenticated', 'public.correct_match_report_result(uuid,text,integer,text,text,jsonb)', 'EXECUTE')
  AND has_function_privilege(
    'service_role', 'public.correct_match_report_result(uuid,text,integer,text,text,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege(
    'service_role', 'private.validate_match_report_games(text,jsonb)', 'EXECUTE'),
  'the correction RPC is service-role-only and its validator stays private'
);

-- ── Fixture: one approved, published report ─────────────────────────────────

INSERT INTO public.admin_users (discord_id, role, discord_username, display_name)
VALUES ('mr-fix-admin', 'admin', 'mr-fix-admin', 'Correction Admin');

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES ('mr-fix-season', 'Correction Season', 'active', '2026-08-01', '2026-12-31', false);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
) VALUES
  ('mr-fix-home', 'Correction Home', 'CFH', 'terra', 'CH', 'from-black to-white', '#000000', 'from-black to-white'),
  ('mr-fix-away', 'Correction Away', 'CFA', 'terra', 'CA', 'from-black to-white', '#000000', 'from-black to-white');

INSERT INTO public.season_orgs (season_id, org_id, division_id)
VALUES ('mr-fix-season', 'mr-fix-home', 'terra'), ('mr-fix-season', 'mr-fix-away', 'terra');

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status
)
SELECT 'mr-fix-home-' || n, 'mr-fix-home', 'mr-fix-home-' || n, 'CF Home ' || n,
       'CH', 'from-black to-white', 'Flex', 'terra', 'active'
FROM generate_series(1, 5) AS n
UNION ALL
SELECT 'mr-fix-away-' || n, 'mr-fix-away', 'mr-fix-away-' || n, 'CF Away ' || n,
       'CA', 'from-black to-white', 'Flex', 'terra', 'active'
FROM generate_series(1, 5) AS n;

INSERT INTO public.season_rosters (season_id, player_id, org_id, division_id, roster_status)
SELECT 'mr-fix-season', id, org_id, 'terra', 'active'
FROM public.players WHERE id LIKE 'mr-fix-%-%' AND org_id LIKE 'mr-fix-%';

INSERT INTO public.matches (
  id, division_id, home_org_id, away_org_id, scheduled_date, scheduled_time,
  status, week, season_id
) VALUES
  ('mr-fix-match', 'terra', 'mr-fix-home', 'mr-fix-away', '2026-08-25', '19:00', 'scheduled', 1, 'mr-fix-season'),
  ('mr-fix-other-match', 'terra', 'mr-fix-home', 'mr-fix-away', '2026-08-26', '19:00', 'scheduled', 1, 'mr-fix-season');

INSERT INTO public.match_reports (
  id, match_id, season_id, division_id, status, submitted_by
) VALUES
  ('aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-match', 'mr-fix-season', 'terra', 'review', 'mr-fix-admin'),
  ('aaaaaaaa-0000-4000-8000-000000000002', 'mr-fix-other-match', 'mr-fix-season', 'terra', 'review', 'mr-fix-admin');

-- Builds a well-formed payload: `home_wins` names the games home takes.
CREATE FUNCTION pg_temp.mr_fix_games(home_wins integer[], kills integer)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT jsonb_agg(game ORDER BY game ->> 'gameNumber')
  FROM (
    SELECT jsonb_build_object(
      'gameNumber', gn,
      'winningSide', CASE WHEN gn = ANY(home_wins) THEN 'home' ELSE 'away' END,
      'players', (
        SELECT jsonb_agg(jsonb_build_object(
          'playerIgn', p.ign,
          'playerId', p.id,
          'side', CASE WHEN p.org_id = 'mr-fix-home' THEN 'home' ELSE 'away' END,
          'won', (p.org_id = 'mr-fix-home') = (gn = ANY(home_wins)),
          'kills', kills, 'deaths', 2, 'assists', 3,
          'damageDealt', 1000, 'damageMitigated', 500,
          'godPlayed', 'Ymir', 'role', 'Solo'
        ))
        FROM public.players p
        WHERE p.org_id IN ('mr-fix-home', 'mr-fix-away')
      )
    ) AS game
    FROM unnest(ARRAY[1, 2, 3]) AS gn
  ) games;
$fn$;

CREATE TEMP TABLE mr_fix_approved AS
SELECT public.resolve_match_report_review(
  'aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-admin',
  pg_temp.mr_fix_games(ARRAY[1, 2], 4)
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'applied' AND result ->> 'applied' = 'true'
   FROM mr_fix_approved)
  AND EXISTS (
    SELECT 1 FROM public.match_reports
    WHERE id = 'aaaaaaaa-0000-4000-8000-000000000001'
      AND status = 'done' AND home_score = 2 AND away_score = 1 AND total_games = 3
  ),
  'the fixture report is approved and published before any correction'
);

-- ── The published result is terminal for approval ───────────────────────────

CREATE TEMP TABLE mr_fix_reapprove AS
SELECT public.resolve_match_report_review(
  'aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-admin',
  pg_temp.mr_fix_games(ARRAY[1, 2, 3], 99)
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'already_processed' AND result ->> 'applied' = 'false'
   FROM mr_fix_reapprove)
  AND NOT EXISTS (
    SELECT 1 FROM public.player_match_stats
    WHERE match_report_id = 'aaaaaaaa-0000-4000-8000-000000000001' AND kills = 99
  ),
  're-approving a published report stays terminal and never overwrites its stats'
);

-- ── Correcting a published result ───────────────────────────────────────────

CREATE TEMP TABLE mr_fix_correction AS
SELECT public.correct_match_report_result(
  'aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-admin', 1,
  'mr-fix-correction-1', 'Scoreboard kills were misread.',
  pg_temp.mr_fix_games(ARRAY[1, 2, 3], 7)
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'applied'
      AND result ->> 'applied' = 'true'
      AND result ->> 'revision' = '2'
      AND result ->> 'homeScore' = '3'
      AND result ->> 'awayScore' = '0'
    FROM mr_fix_correction)
  AND EXISTS (
    SELECT 1 FROM public.match_reports
    WHERE id = 'aaaaaaaa-0000-4000-8000-000000000001'
      AND status = 'done' AND revision = 2
      AND home_score = 3 AND away_score = 0 AND total_games = 3
      AND reviewed_by = 'mr-fix-admin'
  ),
  'a correction republishes the report at the next revision'
);

SELECT ok(
  (SELECT count(*) = 30 FROM public.player_match_stats
   WHERE match_report_id = 'aaaaaaaa-0000-4000-8000-000000000001')
  AND NOT EXISTS (
    SELECT 1 FROM public.player_match_stats
    WHERE match_report_id = 'aaaaaaaa-0000-4000-8000-000000000001' AND kills <> 7
  ),
  'the corrected stat set fully replaces the published rows'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.matches
    WHERE id = 'mr-fix-match'
      AND status = 'completed'
      AND home_score = 3 AND away_score = 0
      AND winner_org_id = 'mr-fix-home'
      AND score = '3-0'
  ),
  'the related match keeps its completed status and records the corrected result'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.match_report_corrections
    WHERE correction_key = 'mr-fix-correction-1'
      AND match_report_id = 'aaaaaaaa-0000-4000-8000-000000000001'
      AND actor_discord_id = 'mr-fix-admin'
      AND expected_revision = 1 AND resulting_revision = 2
      AND old_value_json ->> 'homeScore' = '2'
      AND new_value_json ->> 'homeScore' = '3'
      AND jsonb_array_length(old_value_json -> 'playerMatchStats') = 30
  ),
  'the receipt records the actor, revisions, and the complete before and after snapshot'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE action_type = 'match_report_corrected'
      AND entity_id = 'aaaaaaaa-0000-4000-8000-000000000001'
      AND actor_discord_id = 'mr-fix-admin'
      AND note = 'Scoreboard kills were misread.'
  )
  AND EXISTS (
    SELECT 1 FROM public.admin_audit_log
    WHERE action = 'match_report_corrected'
      AND entity_id = 'aaaaaaaa-0000-4000-8000-000000000001'
  )
  AND EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_type = 'match_report'
      AND aggregate_id = 'aaaaaaaa-0000-4000-8000-000000000001'
      AND event_type = 'match_report_corrected'
  ),
  'a correction is audited twice and enqueues its own standings recalculation'
);

-- ── Retry safety and optimistic concurrency ─────────────────────────────────

-- Byte-for-byte the first correction, as an uncertain client would resend it.
CREATE TEMP TABLE mr_fix_retry AS
SELECT public.correct_match_report_result(
  'aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-admin', 1,
  'mr-fix-correction-1', 'Scoreboard kills were misread.',
  pg_temp.mr_fix_games(ARRAY[1, 2, 3], 7)
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'already_corrected' AND result ->> 'applied' = 'false'
   FROM mr_fix_retry)
  AND (SELECT count(*) = 1 FROM public.match_report_corrections
       WHERE correction_key = 'mr-fix-correction-1')
  -- A second correction would have advanced the revision to 3.
  AND (SELECT revision = 2 FROM public.match_reports
       WHERE id = 'aaaaaaaa-0000-4000-8000-000000000001')
  AND (SELECT result ->> 'revision' = '2' FROM mr_fix_retry),
  'an exact correction retry returns the recorded receipt without mutating again'
);

SELECT throws_ok(
  $$SELECT public.correct_match_report_result(
      'aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-admin', 1,
      'mr-fix-stale', 'Stale write.',
      pg_temp.mr_fix_games(ARRAY[1], 5))$$,
  '55000',
  'Match report changed since it was loaded; reload and reapply the correction.',
  'a correction naming a superseded revision is rejected'
);

SELECT throws_ok(
  $$SELECT public.correct_match_report_result(
      'aaaaaaaa-0000-4000-8000-000000000002', 'mr-fix-admin', 1,
      'mr-fix-correction-1', 'Reused key.',
      pg_temp.mr_fix_games(ARRAY[1, 2], 5))$$,
  '23505',
  'Correction key already recorded for a different match report.',
  'a correction key cannot be replayed against a different report'
);

-- ── Authorization and lifecycle boundaries ─────────────────────────────────

SELECT throws_ok(
  $$SELECT public.correct_match_report_result(
      'aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-not-admin', 2,
      'mr-fix-unauthorized', 'Not an admin.',
      pg_temp.mr_fix_games(ARRAY[1, 2], 5))$$,
  '42501',
  'Actor is not an authorized administrator.',
  'only an authorized administrator can correct a published result'
);

SELECT throws_ok(
  $$SELECT public.correct_match_report_result(
      'aaaaaaaa-0000-4000-8000-000000000002', 'mr-fix-admin', 1,
      'mr-fix-not-done', 'Still in review.',
      pg_temp.mr_fix_games(ARRAY[1, 2], 5))$$,
  '55000',
  'Only a completed match report can be corrected.',
  'a report still in review is approved, not corrected'
);

SELECT throws_ok(
  $$SELECT public.correct_match_report_result(
      'aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-admin', 2,
      'mr-fix-blank-reason', '   ',
      pg_temp.mr_fix_games(ARRAY[1, 2], 5))$$,
  '22023',
  'A correction reason between 1 and 1000 characters is required.',
  'a correction must carry a reason'
);

-- ── Payload validation matches the approval path ───────────────────────────

SELECT throws_ok(
  $$SELECT public.correct_match_report_result(
      'aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-admin', 2,
      'mr-fix-unlinked', 'Unlinked identity.',
      (SELECT jsonb_agg(jsonb_set(game, '{players,0,playerId}', 'null'::jsonb))
       FROM jsonb_array_elements(pg_temp.mr_fix_games(ARRAY[1, 2], 5)) AS game))$$,
  '23514',
  'Every official player stat must be linked before approval.',
  'a correction cannot publish an unlinked identity'
);

SELECT throws_ok(
  $$SELECT public.correct_match_report_result(
      'aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-admin', 2,
      'mr-fix-tie', 'Tied series.',
      (SELECT jsonb_agg(game)
       FROM jsonb_array_elements(pg_temp.mr_fix_games(ARRAY[1], 5)) AS game
       WHERE (game ->> 'gameNumber')::integer <= 2))$$,
  '22023',
  'Reviewed series cannot end in a tie.',
  'a correction cannot record a tied series'
);

-- The approval path rejects the same payload the same way. This is what keeps
-- the correction validator from drifting away from the rules approval applies.
SELECT throws_ok(
  $$SELECT public.resolve_match_report_review(
      'aaaaaaaa-0000-4000-8000-000000000002', 'mr-fix-admin',
      (SELECT jsonb_agg(game)
       FROM jsonb_array_elements(pg_temp.mr_fix_games(ARRAY[1], 5)) AS game
       WHERE (game ->> 'gameNumber')::integer <= 2))$$,
  '22023',
  'Reviewed series cannot end in a tie.',
  'the approval path rejects the tied series identically'
);

SELECT throws_ok(
  $$SELECT public.correct_match_report_result(
      'aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-admin', 2,
      'mr-fix-duplicate-game', 'Duplicate game number.',
      (SELECT jsonb_agg(jsonb_set(game, '{gameNumber}', '1'::jsonb))
       FROM jsonb_array_elements(pg_temp.mr_fix_games(ARRAY[1, 2], 5)) AS game))$$,
  '23505',
  'Reviewed payload contains a duplicate game number.',
  'a correction cannot repeat a game number'
);

-- A reused key must be bound to the whole request, not just the report, or a
-- client that accidentally retains its previous key has its next correction
-- silently discarded as a retry.
SELECT throws_ok(
  $$SELECT public.correct_match_report_result(
      'aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-admin', 2,
      'mr-fix-correction-1', 'A different reason entirely.',
      pg_temp.mr_fix_games(ARRAY[1, 2, 3], 7))$$,
  '23505',
  'Correction key already recorded for a different correction.',
  'a reused correction key with a different request is rejected, not replayed'
);

SELECT throws_ok(
  $$SELECT public.correct_match_report_result(
      'aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-admin', 2,
      'mr-fix-correction-1', 'Scoreboard kills were misread.',
      pg_temp.mr_fix_games(ARRAY[1, 2], 7))$$,
  '23505',
  'Correction key already recorded for a different correction.',
  'a reused correction key with a different payload is rejected, not replayed'
);

-- An organization can hold a season roster in more than one division; a player
-- rostered elsewhere must not earn canonical stats in this match's division.
INSERT INTO public.season_orgs (season_id, org_id, division_id)
VALUES ('mr-fix-season', 'mr-fix-home', 'solar');
UPDATE public.season_rosters
SET division_id = 'solar'
WHERE season_id = 'mr-fix-season' AND player_id = 'mr-fix-home-1';

SELECT throws_ok(
  $$SELECT public.correct_match_report_result(
      'aaaaaaaa-0000-4000-8000-000000000001', 'mr-fix-admin', 2,
      'mr-fix-cross-division', 'Cross-division roster member.',
      pg_temp.mr_fix_games(ARRAY[1, 2], 6))$$,
  '23514',
  'Supplied player is not rostered in the match division.',
  'a correction cannot credit a player rostered in another division'
);

UPDATE public.season_rosters
SET division_id = 'terra'
WHERE season_id = 'mr-fix-season' AND player_id = 'mr-fix-home-1';

SELECT ok(
  (SELECT revision = 2 AND home_score = 3 AND away_score = 0
   FROM public.match_reports WHERE id = 'aaaaaaaa-0000-4000-8000-000000000001')
  AND (SELECT count(*) = 1 FROM public.match_report_corrections)
  AND (SELECT count(*) = 30 FROM public.player_match_stats
       WHERE match_report_id = 'aaaaaaaa-0000-4000-8000-000000000001'),
  'every rejected correction leaves the published result untouched'
);

SELECT * FROM finish();
ROLLBACK;
