BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(12);

SELECT has_column('public', 'player_stats', 'season_id', 'player_stats stores its season snapshot');
SELECT has_column('public', 'player_stats', 'org_id', 'player_stats stores its organization snapshot');
SELECT has_column('public', 'player_stats', 'division_id', 'player_stats stores its division snapshot');
SELECT has_trigger(
  'public', 'player_stats', 'player_stats_game_attribution',
  'official player stats require game-time attribution'
);

INSERT INTO public.admin_users (discord_id, role, discord_username, display_name)
VALUES ('db20-admin', 'admin', 'db20-admin', 'DB20 Admin');

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES ('db20-season', 'DB20 Season', 'active', '2026-01-01', '2026-12-31', false);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient,
  primary_color, accent_gradient
) VALUES
  ('db20-home', 'DB20 Home', 'D20H', 'terra', 'DH', 'from-black to-white', '#000000', 'from-black to-white'),
  ('db20-away', 'DB20 Away', 'D20A', 'terra', 'DA', 'from-black to-white', '#000000', 'from-black to-white'),
  ('db20-trade', 'DB20 Trade', 'D20T', 'terra', 'DT', 'from-black to-white', '#000000', 'from-black to-white');

INSERT INTO public.season_orgs (season_id, org_id, division_id)
VALUES
  ('db20-season', 'db20-home', 'terra'),
  ('db20-season', 'db20-away', 'terra'),
  ('db20-season', 'db20-trade', 'terra');

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status
) VALUES (
  'db20-player', 'db20-home', 'db20-player', 'DB20 Player', 'DP',
  'from-black to-white', 'Support', 'terra', 'active'
);

INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, roster_status
) VALUES (
  'db20-season', 'db20-player', 'db20-home', 'terra', 'active'
);

INSERT INTO public.matches (
  id, division_id, home_org_id, away_org_id, scheduled_date, scheduled_time,
  status, week, winner_org_id, home_score, away_score, season_id
) VALUES (
  'db20-match', 'terra', 'db20-home', 'db20-away', '2026-08-01', '19:00',
  'completed', 1, 'db20-home', 2, 0, 'db20-season'
);

-- The stat is reviewed after the player has moved, but its audited payload says
-- which team the player represented in the already-completed match.
UPDATE public.players
SET org_id = 'db20-trade'
WHERE id = 'db20-player';
UPDATE public.season_rosters
SET org_id = 'db20-trade', updated_at = now()
WHERE season_id = 'db20-season' AND player_id = 'db20-player';

INSERT INTO public.pending_stat_records (
  id, match_id, player_id, screenshot_url, extracted_json, stats_json, confidence
) VALUES (
  'db20-pending', 'db20-match', 'db20-player', 'https://example.invalid/db20.png',
  '{}'::jsonb,
  '{"game_number":1,"org_id":"db20-home","kills":3,"deaths":1,"assists":9}'::jsonb,
  0.990
);

SELECT is(
  public.resolve_pending_stat_record(
    'db20-pending', 'db20-admin', 'approve', 'Verified against the game roster.'
  ) ->> 'code',
  'applied',
  'an explicit game-time organization allows approval after a trade'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.player_stats
    WHERE pending_stat_record_id = 'db20-pending'
      AND player_id = 'db20-player'
      AND season_id = 'db20-season'
      AND org_id = 'db20-home'
      AND division_id = 'terra'
  ),
  'legacy official stats remain player-owned and store the full game-time attribution tuple'
);

SELECT is(
  (SELECT org_id FROM public.players WHERE id = 'db20-player'),
  'db20-trade',
  'publishing historical stats does not move ownership back to the former team'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.audit_logs
    WHERE action_type = 'stat_approved'
      AND entity_type = 'player_stat'
      AND new_value_json @> '{"player_id":"db20-player","season_id":"db20-season","org_id":"db20-home","division_id":"terra"}'::jsonb
  ),
  'the approval audit captures the historical attribution'
);

INSERT INTO public.match_reports (
  id, match_id, season_id, division_id, status, submitted_by,
  home_score, away_score, total_games
) VALUES (
  '00000000-0000-0000-0000-00000000d220', 'db20-match',
  'db20-season', 'terra', 'done', 'db20-admin', 2, 0, 1
);

INSERT INTO public.player_match_stats (
  match_report_id, match_id, player_id, player_ign, game_number, org_id,
  won, kills, deaths, assists, season_id, division_id
) VALUES (
  '00000000-0000-0000-0000-00000000d220', 'db20-match', 'db20-player',
  'DB20 Player', 1, 'db20-home', true, 3, 1, 9, 'db20-season', 'terra'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.player_match_stats
    WHERE match_report_id = '00000000-0000-0000-0000-00000000d220'
      AND player_id = 'db20-player'
      AND org_id = 'db20-home'
      AND season_id = 'db20-season'
      AND division_id = 'terra'
  )
  AND (SELECT org_id = 'db20-trade' FROM public.players WHERE id = 'db20-player'),
  'match-report stats retain their player owner and former game team after a trade'
);

SELECT throws_ok(
  $$
    INSERT INTO public.player_stats (
      match_id, player_id, game_number, won, org_id
    ) VALUES (
      'db20-match', 'db20-player', 2, false, 'db20-trade'
    )
  $$,
  '23514',
  'Official player stat organization must be a team in the match.',
  'an organization outside the match cannot be stored as game-time attribution'
);

SELECT lives_ok(
  $$
    INSERT INTO public.player_stats (
      match_id, player_id, game_number, won
    ) VALUES (
      'db20-match', 'db20-player', 2, true
    )
  $$,
  'the match winner can provide an unambiguous fallback team attribution'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.player_stats
    WHERE match_id = 'db20-match'
      AND player_id = 'db20-player'
      AND game_number = 2
      AND season_id = 'db20-season'
      AND org_id = 'db20-home'
      AND division_id = 'terra'
  ),
  'the fallback still persists the complete attribution tuple'
);

SELECT * FROM finish();
ROLLBACK;
