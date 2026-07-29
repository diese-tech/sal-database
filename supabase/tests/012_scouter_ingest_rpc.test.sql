BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(14);

CREATE FUNCTION pg_temp.scouter_test_participants()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_array(
    jsonb_build_object('side', 'order', 'rawIgn', 'KNOWN PLAYER', 'godName', 'Achilles', 'role', 'solo', 'playerLevel', 20, 'kills', 8, 'deaths', 2, 'assists', 7, 'gpm', 610, 'playerDamage', 32000, 'wardsPlaced', 8),
    jsonb_build_object('side', 'order', 'rawIgn', 'Order Two', 'role', 'jungle', 'kills', 3, 'deaths', 4, 'assists', 10),
    jsonb_build_object('side', 'order', 'rawIgn', 'Order Three', 'role', 'mid', 'kills', 7, 'deaths', 3, 'assists', 9),
    jsonb_build_object('side', 'order', 'rawIgn', 'Order Four', 'role', 'support', 'kills', 1, 'deaths', 5, 'assists', 15),
    jsonb_build_object('side', 'order', 'rawIgn', 'Order Five', 'role', 'carry', 'kills', 9, 'deaths', 1, 'assists', 6),
    jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos One', 'role', 'solo', 'kills', 2, 'deaths', 6, 'assists', 5),
    jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos Two', 'role', 'jungle', 'kills', 4, 'deaths', 5, 'assists', 4),
    jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos Three', 'role', 'mid', 'kills', 5, 'deaths', 7, 'assists', 3),
    jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos Four', 'role', 'support', 'kills', 0, 'deaths', 8, 'assists', 11),
    jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos Five', 'role', 'carry', 'kills', 6, 'deaths', 4, 'assists', 2)
  );
$$;

SELECT ok(
  to_regprocedure('public.ingest_scouter_game(text,text,integer,text,text,jsonb,text,text,text,text,integer)') IS NOT NULL,
  'the atomic scouter ingest RPC exists'
);

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.ingest_scouter_game(text,text,integer,text,text,jsonb,text,text,text,text,integer)',
    'EXECUTE'
  )
    AND NOT has_function_privilege(
      'authenticated',
      'public.ingest_scouter_game(text,text,integer,text,text,jsonb,text,text,text,text,integer)',
      'EXECUTE'
    ),
  'client roles cannot execute scouter ingestion'
);

SELECT ok(
  has_function_privilege(
    'service_role',
    'public.ingest_scouter_game(text,text,integer,text,text,jsonb,text,text,text,text,integer)',
    'EXECUTE'
  ),
  'service_role can execute scouter ingestion'
);

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES ('scouter-rpc-season', 'Scouter RPC Season', 'pre-season', '2026-07-01', '2026-08-31', false);

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient, primary_role, status
) VALUES (
  'scouter-rpc-player', 'scouter-rpc-user', 'Known Player', 'KP',
  'from-black to-white', 'Solo', 'active'
);

CREATE TEMP TABLE scouter_rpc_first_result AS
SELECT public.ingest_scouter_game(
  'scouter-rpc-season',
  'scouter-rpc-host',
  1,
  'scouters/rpc/scoreboard-1.png',
  'scouters/rpc/details-1.png',
  pg_temp.scouter_test_participants(),
  NULL,
  'scouter-rpc-smite-1',
  'Conquest',
  'order',
  1800
) AS result;

SELECT is(
  (SELECT result ->> 'code' FROM scouter_rpc_first_result),
  'inserted',
  'a structurally valid game is inserted'
);

SELECT ok(
  (SELECT count(*) = 1 FROM public.scouter_matches WHERE hosted_by_discord_id = 'scouter-rpc-host')
    AND (SELECT count(*) = 1 FROM public.scouter_games WHERE smite_match_id = 'scouter-rpc-smite-1')
    AND (SELECT count(*) = 10 FROM public.scouter_game_participants participant
      JOIN public.scouter_games game ON game.id = participant.scouter_game_id
      WHERE game.smite_match_id = 'scouter-rpc-smite-1'),
  'the match, game, and all ten participants persist together'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.scouter_game_participants participant
    JOIN public.scouter_games game ON game.id = participant.scouter_game_id
    WHERE game.smite_match_id = 'scouter-rpc-smite-1'
      AND participant.raw_ign = 'KNOWN PLAYER'
      AND participant.player_id = 'scouter-rpc-player'
      AND participant.god_id = 'achilles'
  ),
  'case-insensitive exact IGN and god names resolve to canonical IDs'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.scouter_game_participants participant
    JOIN public.scouter_games game ON game.id = participant.scouter_game_id
    WHERE game.smite_match_id = 'scouter-rpc-smite-1'
      AND participant.raw_ign = 'Order Two'
      AND participant.player_id IS NULL
  ),
  'an unrecognized IGN remains stored and unlinked'
);

SELECT ok(
  (SELECT count(*) = 1
   FROM public.audit_logs
   WHERE action_type = 'scouter_game_ingested'
     AND actor_discord_id = 'scouter-rpc-host'),
  'a successful ingest appends one audit event'
);

CREATE TEMP TABLE scouter_rpc_retry_result AS
SELECT public.ingest_scouter_game(
  'scouter-rpc-season',
  'scouter-rpc-host',
  1,
  'scouters/rpc/retry-scoreboard.png',
  'scouters/rpc/retry-details.png',
  pg_temp.scouter_test_participants(),
  NULL,
  'scouter-rpc-smite-1',
  'Conquest',
  'order',
  1800
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'existing' AND result ->> 'applied' = 'false'
   FROM scouter_rpc_retry_result),
  'a repeated SMITE match returns the existing game'
);

SELECT ok(
  (SELECT count(*) = 1 FROM public.scouter_games WHERE smite_match_id = 'scouter-rpc-smite-1')
    AND (SELECT count(*) = 1 FROM public.audit_logs
      WHERE action_type = 'scouter_game_ingested' AND actor_discord_id = 'scouter-rpc-host'),
  'an idempotent retry performs no mutation and writes no duplicate audit event'
);

CREATE TEMP TABLE scouter_rpc_second_result AS
SELECT public.ingest_scouter_game(
  'scouter-rpc-season',
  'scouter-rpc-host',
  2,
  'scouters/rpc/scoreboard-2.png',
  'scouters/rpc/details-2.png',
  pg_temp.scouter_test_participants(),
  (SELECT result ->> 'scouterMatchId' FROM scouter_rpc_first_result),
  'scouter-rpc-smite-2',
  'Conquest',
  'chaos',
  1900
) AS result;

SELECT ok(
  (SELECT result ->> 'scouterMatchId' FROM scouter_rpc_second_result)
    = (SELECT result ->> 'scouterMatchId' FROM scouter_rpc_first_result)
    AND (SELECT count(*) = 2 FROM public.scouter_games game
      WHERE game.scouter_match_id = (SELECT result ->> 'scouterMatchId' FROM scouter_rpc_first_result)),
  'later games join the same match-scoped transaction boundary'
);

SELECT throws_ok(
  format(
    $$SELECT public.ingest_scouter_game(
      'scouter-rpc-season', 'different-host', 3,
      'scouters/rpc/scoreboard-3.png', 'scouters/rpc/details-3.png',
      pg_temp.scouter_test_participants(), %L, 'scouter-rpc-smite-3',
      'Conquest', 'order', 1700
    )$$,
    (SELECT result ->> 'scouterMatchId' FROM scouter_rpc_first_result)
  ),
  '23514',
  'Scouter match season and host must match the original game.',
  'a caller cannot append a game under a different host'
);

CREATE FUNCTION pg_temp.force_scouter_audit_failure()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.actor_discord_id = 'scouter-rollback-host' THEN
    RAISE EXCEPTION 'forced scouter audit failure';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER scouter_rpc_force_audit_failure
BEFORE INSERT ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION pg_temp.force_scouter_audit_failure();

SELECT throws_ok(
  $$SELECT public.ingest_scouter_game(
    'scouter-rpc-season', 'scouter-rollback-host', 1,
    'scouters/rpc/rollback-scoreboard.png', 'scouters/rpc/rollback-details.png',
    pg_temp.scouter_test_participants(), NULL, 'scouter-rpc-rollback',
    'Conquest', 'order', 1600
  )$$,
  'P0001',
  'forced scouter audit failure',
  'an audit failure aborts the ingest transaction'
);

DROP TRIGGER scouter_rpc_force_audit_failure ON public.audit_logs;

SELECT ok(
  NOT EXISTS (SELECT 1 FROM public.scouter_matches WHERE hosted_by_discord_id = 'scouter-rollback-host')
    AND NOT EXISTS (SELECT 1 FROM public.scouter_games WHERE smite_match_id = 'scouter-rpc-rollback')
    AND NOT EXISTS (SELECT 1 FROM public.audit_logs WHERE actor_discord_id = 'scouter-rollback-host'),
  'forced audit failure rolls back the match, game, participants, and audit event'
);

SELECT * FROM finish();
ROLLBACK;
