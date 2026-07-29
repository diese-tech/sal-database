BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(15);

SELECT ok(to_regclass('public.scouter_matches') IS NOT NULL, 'scouter_matches exists');
SELECT ok(to_regclass('public.scouter_games') IS NOT NULL, 'scouter_games exists');
SELECT ok(
  to_regclass('public.scouter_game_participants') IS NOT NULL,
  'scouter_game_participants exists'
);

SELECT ok(
  (SELECT count(*) = 3
   FROM pg_class tables
   JOIN pg_namespace schemas ON schemas.oid = tables.relnamespace
   WHERE schemas.nspname = 'public'
     AND tables.relname IN ('scouter_matches', 'scouter_games', 'scouter_game_participants')
     AND tables.relrowsecurity),
  'RLS is enabled on every scouter table'
);

SELECT ok(
  has_table_privilege('anon', 'public.scouter_matches', 'SELECT')
    AND has_table_privilege('anon', 'public.scouter_games', 'SELECT')
    AND has_table_privilege('anon', 'public.scouter_game_participants', 'SELECT')
    AND has_table_privilege('authenticated', 'public.scouter_matches', 'SELECT')
    AND has_table_privilege('authenticated', 'public.scouter_games', 'SELECT')
    AND has_table_privilege('authenticated', 'public.scouter_game_participants', 'SELECT'),
  'scouter reads are available to public profile clients'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.scouter_matches', 'INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('anon', 'public.scouter_games', 'INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('anon', 'public.scouter_game_participants', 'INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated', 'public.scouter_matches', 'INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated', 'public.scouter_games', 'INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated', 'public.scouter_game_participants', 'INSERT,UPDATE,DELETE'),
  'client roles cannot mutate scouter data'
);

SELECT ok(
  has_table_privilege('service_role', 'public.scouter_matches', 'INSERT,SELECT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.scouter_games', 'INSERT,SELECT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.scouter_game_participants', 'INSERT,SELECT,UPDATE,DELETE'),
  'service_role owns the scouter write boundary'
);

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES ('scouter-test-season', 'Scouter Test Season', 'pre-season', '2026-07-01', '2026-08-31', false);

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient, primary_role, status
) VALUES (
  'scouter-test-player', 'scouter-test-user', 'Scouter Test IGN', 'ST',
  'from-black to-white', 'Mid', 'active'
);

INSERT INTO public.scouter_matches (
  id, season_id, hosted_by_discord_id
) VALUES (
  'scouter-test-match', 'scouter-test-season', 'scouter-test-host'
);

INSERT INTO public.scouter_games (
  id, scouter_match_id, game_ordinal, smite_match_id, game_mode, winning_side,
  match_length_seconds, scoreboard_image_path, details_image_path
) VALUES (
  'scouter-test-game', 'scouter-test-match', 1, 'scouter-smite-match-1', 'Conquest',
  'order', 1800, 'scouters/test/scoreboard.png', 'scouters/test/details.png'
);

INSERT INTO public.scouter_game_participants (
  id, scouter_game_id, side, raw_ign, player_id, role, player_level,
  kills, deaths, assists, gpm, player_damage, wards_placed
) VALUES (
  'scouter-test-participant', 'scouter-test-game', 'order', 'Scouter Test IGN',
  'scouter-test-player', 'mid', 20, 10, 2, 8, 650, 42000, 12
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.scouter_game_participants participants
    JOIN public.scouter_games games ON games.id = participants.scouter_game_id
    JOIN public.scouter_matches matches ON matches.id = games.scouter_match_id
    WHERE participants.id = 'scouter-test-participant'
      AND participants.player_id = 'scouter-test-player'
      AND games.smite_match_id = 'scouter-smite-match-1'
      AND matches.season_id = 'scouter-test-season'
  ),
  'a complete season-scoped scouter result can be stored'
);

SELECT throws_ok(
  $$INSERT INTO public.scouter_games (
      scouter_match_id, game_ordinal, smite_match_id,
      scoreboard_image_path, details_image_path
    ) VALUES (
      'scouter-test-match', 2, 'scouter-smite-match-1', 'duplicate.png', 'duplicate-details.png'
    )$$,
  '23505',
  NULL,
  'SMITE match identity is globally idempotent'
);

SELECT throws_ok(
  $$INSERT INTO public.scouter_games (
      scouter_match_id, game_ordinal, scoreboard_image_path, details_image_path
    ) VALUES ('scouter-test-match', 0, 'bad.png', 'bad-details.png')$$,
  '23514',
  NULL,
  'game ordinal must be positive'
);

SELECT throws_ok(
  $$INSERT INTO public.scouter_game_participants (
      scouter_game_id, side, raw_ign, role
    ) VALUES ('scouter-test-game', 'order', 'Bad Role', 'coach')$$,
  '23514',
  NULL,
  'participant role must use the canonical scouter role set'
);

DELETE FROM public.scouter_matches WHERE id = 'scouter-test-match';

SELECT ok(
  NOT EXISTS (SELECT 1 FROM public.scouter_games WHERE id = 'scouter-test-game')
    AND NOT EXISTS (
      SELECT 1 FROM public.scouter_game_participants WHERE id = 'scouter-test-participant'
    ),
  'deleting a scouter match cascades through games and participants'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'scouter_games_match_idx'
      AND indexdef LIKE '%(scouter_match_id, game_ordinal)%'
  ),
  'the match and ordinal lookup index exists'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'scouter_participants_player_idx'
      AND indexdef LIKE '%(player_id)%WHERE (player_id IS NOT NULL)%'
  ),
  'the linked-player partial index exists'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'scouter_game_participants'
      AND column_name = 'updated_at'
      AND is_nullable = 'NO'
  )
    AND EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'scouter_game_participants'
        AND column_name = 'updated_by_discord_id'
        AND is_nullable = 'YES'
    ),
  'v2 correction metadata exists from the first release'
);

SELECT * FROM finish();
ROLLBACK;
