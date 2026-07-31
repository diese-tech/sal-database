BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

-- Boundary contract test: sal-site's scouter-profile.ts and scouter-receipt.ts,
-- and lab-salbot's packages/db/src/queries/scouters.ts, all read scouter data
-- back out through a join shaped like the one below (participant -> game ->
-- match -> season, plus the god lookup). 011/012 prove the ingest RPC persists
-- one game correctly in isolation; neither proves that a real player's data
-- across *multiple* games in the same match round-trips correctly through the
-- read side those three clients actually depend on. This test closes that gap
-- by driving two games through the real ingest RPC for one player, one on the
-- winning side and one on the losing side, and asserting the read join
-- produces the exact aggregate every profile renderer computes from it.

SELECT plan(7);

-- Ten fixed filler seats (five order, five chaos). The real player's row
-- replaces whichever seat matches p_real_player_side, so the result always
-- keeps the RPC's required 5-order/5-chaos split regardless of which side
-- the real player is on for a given game.
CREATE FUNCTION pg_temp.scouter_read_contract_participants(
  p_real_player_ign text,
  p_real_player_god text,
  p_real_player_side text
) RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_set(
    jsonb_build_array(
      jsonb_build_object('side', 'order', 'rawIgn', 'Order One', 'role', 'solo', 'kills', 8, 'deaths', 2, 'assists', 7),
      jsonb_build_object('side', 'order', 'rawIgn', 'Order Two', 'role', 'jungle', 'kills', 3, 'deaths', 4, 'assists', 10),
      jsonb_build_object('side', 'order', 'rawIgn', 'Order Three', 'role', 'mid', 'kills', 7, 'deaths', 3, 'assists', 9),
      jsonb_build_object('side', 'order', 'rawIgn', 'Order Four', 'role', 'support', 'kills', 1, 'deaths', 5, 'assists', 15),
      jsonb_build_object('side', 'order', 'rawIgn', 'Order Five', 'role', 'carry', 'kills', 9, 'deaths', 1, 'assists', 6),
      jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos One', 'role', 'solo', 'kills', 2, 'deaths', 6, 'assists', 5),
      jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos Two', 'role', 'jungle', 'kills', 4, 'deaths', 5, 'assists', 4),
      jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos Three', 'role', 'mid', 'kills', 5, 'deaths', 7, 'assists', 3),
      jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos Four', 'role', 'support', 'kills', 0, 'deaths', 8, 'assists', 11),
      jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos Five', 'role', 'carry', 'kills', 6, 'deaths', 4, 'assists', 2)
    ),
    ARRAY[(CASE WHEN p_real_player_side = 'order' THEN 0 ELSE 5 END)::text],
    jsonb_build_object(
      'side', p_real_player_side, 'rawIgn', p_real_player_ign, 'godName', p_real_player_god,
      'role', 'solo', 'playerLevel', 20, 'kills', 8, 'deaths', 2, 'assists', 7,
      'gpm', 610, 'playerDamage', 32000, 'wardsPlaced', 8
    )
  );
$$;

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES ('scouter-read-contract-season', 'Scouter Read Contract Season', 'pre-season', '2026-07-01', '2026-08-31', false);

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient, primary_role, status
) VALUES (
  'scouter-read-contract-player', 'realleagueplayer', 'RealLeaguePlayer', 'RL',
  'from-black to-white', 'Solo', 'active'
);

-- Game 1: the real player is on the winning (order) side.
CREATE TEMP TABLE scouter_read_contract_game1 AS
SELECT public.ingest_scouter_game(
  'scouter-read-contract-season',
  'scouter-read-contract-host',
  1,
  'scouters/read-contract/scoreboard-1.png',
  'scouters/read-contract/details-1.png',
  pg_temp.scouter_read_contract_participants('RealLeaguePlayer', 'Achilles', 'order'),
  'order',
  NULL,
  'scouter-read-contract-smite-1',
  'Conquest',
  1800
) AS result;

-- Game 2: same match, real player switches to the losing (chaos) side.
CREATE TEMP TABLE scouter_read_contract_game2 AS
SELECT public.ingest_scouter_game(
  'scouter-read-contract-season',
  'scouter-read-contract-host',
  2,
  'scouters/read-contract/scoreboard-2.png',
  'scouters/read-contract/details-2.png',
  pg_temp.scouter_read_contract_participants('RealLeaguePlayer', 'Achilles', 'chaos'),
  'order',
  (SELECT result ->> 'scouterMatchId' FROM scouter_read_contract_game1),
  'scouter-read-contract-smite-2',
  'Conquest',
  1900
) AS result;

-- This mirrors the exact embed shape scouter-profile.ts, scouter-receipt.ts,
-- and lab-salbot's scouters.ts select: participant -> game(!inner) ->
-- match(!inner) -> season(!inner), plus a to-one god lookup.
CREATE TEMP VIEW scouter_read_contract_rows AS
SELECT
  participant.id,
  participant.side,
  participant.kills,
  participant.deaths,
  participant.assists,
  participant.player_damage,
  god.name AS god_name,
  game.id AS game_id,
  game.smite_match_id,
  game.winning_side,
  match.id AS match_id,
  match.season_id,
  season.id AS season_row_id
FROM public.scouter_game_participants participant
JOIN public.scouter_games game ON game.id = participant.scouter_game_id
JOIN public.scouter_matches match ON match.id = game.scouter_match_id
JOIN public.seasons season ON season.id = match.season_id
LEFT JOIN public.gods god ON god.id = participant.god_id
WHERE participant.player_id = 'scouter-read-contract-player';

SELECT is(
  (SELECT count(*)::int FROM scouter_read_contract_rows),
  2,
  'the read join returns exactly the two games the real player appeared in'
);

SELECT is(
  (SELECT count(DISTINCT match_id)::int FROM scouter_read_contract_rows),
  1,
  'both games resolve to the same scouter match through the join, as scouter-profile.ts assumes'
);

SELECT is(
  (SELECT count(DISTINCT season_row_id)::int FROM scouter_read_contract_rows),
  1,
  'both games resolve to the season row scouter-profile.ts uses to scope the summary'
);

SELECT is(
  (SELECT god_name FROM scouter_read_contract_rows WHERE smite_match_id = 'scouter-read-contract-smite-1'),
  'Achilles',
  'the god join resolves for the real player exactly as scouter-profile.ts expects (row.god?.name)'
);

-- Client-side win/loss derivation is `winningSide === row.side`; reproduce it
-- here to prove the columns the join returns are sufficient and correctly
-- oriented for that comparison (not swapped, not off by a side).
SELECT is(
  (SELECT count(*)::int FROM scouter_read_contract_rows WHERE winning_side = side),
  1,
  'exactly one of the two games has the real player on the winning side'
);

SELECT is(
  (SELECT count(*)::int FROM scouter_read_contract_rows WHERE winning_side <> side),
  1,
  'exactly one of the two games has the real player on the losing side'
);

-- averageKda / averageDamage in scouter-profile.ts and scouters.ts sum
-- (kills + assists) / max(deaths, 1) and player_damage across exactly these rows;
-- prove the join doesn't fan out (e.g. via the god left-join) and inflate counts.
SELECT is(
  (SELECT sum(player_damage)::bigint FROM scouter_read_contract_rows),
  64000::bigint,
  'player_damage sums to exactly what both ingests wrote (no join fan-out)'
);

SELECT * FROM finish();
ROLLBACK;
