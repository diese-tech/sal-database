BEGIN;

-- Concurrency contract test for public.ingest_scouter_game.
--
-- 012_scouter_ingest_rpc.test.sql proves idempotent retries are safe when
-- called *sequentially* in one session. It cannot prove the advisory-lock
-- serialization (pg_advisory_xact_lock keyed on the SMITE match id) actually
-- holds under real concurrency, because a single session can't run two
-- overlapping transactions. This mirrors 010_site_review_concurrency.test.sql's
-- proven dblink pattern: two genuinely separate PostgreSQL backends racing
-- the real SMITE match id for one real player, simulating a host
-- double-clicking the upload button or a client retrying after a slow
-- response — the exact scenario the advisory lock exists to protect against.
--
-- All committed state (setup and cleanup) goes through a third dblink
-- connection rather than the outer BEGIN/ROLLBACK session, exactly like
-- 010 does — a second backend can't see this session's uncommitted rows,
-- so the season/player seed and final cleanup need their own real commits.

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS dblink WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(7);

DO $connect$
BEGIN
  PERFORM dblink_connect(
    'scouter_conc_setup',
    format(
      'hostaddr=%s port=%s dbname=%s user=%s password=%s',
      host(inet_server_addr()), inet_server_port(),
      current_database(), current_user, current_user
    )
  );
  PERFORM dblink_connect(
    'scouter_conc_a',
    format(
      'hostaddr=%s port=%s dbname=%s user=%s password=%s',
      host(inet_server_addr()), inet_server_port(),
      current_database(), current_user, current_user
    )
  );
  PERFORM dblink_connect(
    'scouter_conc_b',
    format(
      'hostaddr=%s port=%s dbname=%s user=%s password=%s',
      host(inet_server_addr()), inet_server_port(),
      current_database(), current_user, current_user
    )
  );
END;
$connect$;

DO $setup$
BEGIN
  PERFORM dblink_exec('scouter_conc_setup', $sql$
    DELETE FROM public.audit_logs WHERE actor_discord_id = 'scouter-conc-host';
    DELETE FROM public.scouter_matches WHERE hosted_by_discord_id = 'scouter-conc-host';
    DELETE FROM public.players WHERE id = 'scouter-conc-player';
    DELETE FROM public.seasons WHERE id = 'scouter-conc-season';

    INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
    VALUES ('scouter-conc-season', 'Scouter Concurrency Season', 'pre-season', '2026-07-01', '2026-08-31', false);

    INSERT INTO public.players (
      id, discord_username, ign, avatar_initials, avatar_gradient, primary_role, status
    ) VALUES (
      'scouter-conc-player', 'concurrentleagueplayer', 'ConcurrentLeaguePlayer', 'CL',
      'from-black to-white', 'Solo', 'active'
    );
  $sql$);
END;
$setup$;

-- Both racing callers submit the *same* real SMITE match for the *same*
-- player with no scouter_match_id yet — the worst case, where there is no
-- existing row for either side to FOR UPDATE lock onto and the advisory lock
-- is the only thing standing between this and a duplicated/corrupted game.
CREATE TEMP TABLE scouter_conc_call_sql AS
SELECT format(
  $fmt$select public.ingest_scouter_game(%L, %L, %L, %L, %L, %L::jsonb, %L, %L, %L, %L, %L)::text$fmt$,
  'scouter-conc-season',
  'scouter-conc-host',
  1,
  'scouters/conc/scoreboard-1.png',
  'scouters/conc/details-1.png',
  jsonb_build_array(
    jsonb_build_object('side', 'order', 'rawIgn', 'ConcurrentLeaguePlayer', 'godName', 'Achilles', 'role', 'solo', 'playerLevel', 20, 'kills', 8, 'deaths', 2, 'assists', 7, 'gpm', 610, 'playerDamage', 32000, 'wardsPlaced', 8),
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
  'order',
  NULL,
  'scouter-conc-smite-1',
  'Conquest',
  1800
) AS sql;

CREATE TEMP TABLE scouter_conc_results (worker text, result jsonb);

-- Caller A: open an explicit transaction and run the ingest call inside it
-- synchronously. It's the first to reach the advisory lock, so this
-- completes immediately — but the lock isn't released until A commits,
-- which is deliberately withheld until caller B is confirmed blocked.
DO $race$
BEGIN
  PERFORM dblink_exec('scouter_conc_a', 'BEGIN');
END;
$race$;

INSERT INTO scouter_conc_results
SELECT 'worker-a', result::jsonb
FROM dblink('scouter_conc_a', (SELECT sql FROM scouter_conc_call_sql)) AS response(result text);

DO $race$
BEGIN
  PERFORM dblink_send_query('scouter_conc_b', (SELECT sql FROM scouter_conc_call_sql));
  PERFORM pg_sleep(0.1);
END;
$race$;

SELECT is(
  dblink_is_busy('scouter_conc_b'),
  1,
  'caller B is genuinely blocked waiting on the advisory lock caller A holds, not just running after A finished'
);

DO $$ BEGIN PERFORM dblink_exec('scouter_conc_a', 'COMMIT'); END $$;

INSERT INTO scouter_conc_results
SELECT 'worker-b', result::jsonb
FROM dblink_get_result('scouter_conc_b') AS response(result text);
DO $$
BEGIN
  PERFORM result FROM dblink_get_result('scouter_conc_b') AS response(result text);
END;
$$;

SELECT ok(
  (SELECT count(*) = 2 FROM scouter_conc_results WHERE result IS NOT NULL),
  'both concurrent callers get a graceful RPC result — neither raises a raw constraint error'
);

SELECT ok(
  (SELECT count(*) = 1 FROM scouter_conc_results WHERE result ->> 'code' = 'inserted')
    AND (SELECT count(*) = 1 FROM scouter_conc_results WHERE result ->> 'code' = 'existing'),
  'exactly one concurrent caller inserts and the other observes it as existing'
);

SELECT is(
  (SELECT count(*)::int FROM public.scouter_games WHERE smite_match_id = 'scouter-conc-smite-1'),
  1,
  'the race produces exactly one game row, not two'
);

SELECT is(
  (SELECT count(*)::int
   FROM public.scouter_game_participants participant
   JOIN public.scouter_games game ON game.id = participant.scouter_game_id
   WHERE game.smite_match_id = 'scouter-conc-smite-1'),
  10,
  'the race produces exactly ten participant rows, not twenty and not fewer'
);

SELECT is(
  (SELECT count(*)::int
   FROM public.audit_logs
   WHERE action_type = 'scouter_game_ingested' AND actor_discord_id = 'scouter-conc-host'),
  1,
  'the race appends exactly one audit event, not one per racing caller'
);

SELECT is(
  (SELECT count(*)::int
   FROM public.scouter_game_participants participant
   JOIN public.scouter_games game ON game.id = participant.scouter_game_id
   WHERE game.smite_match_id = 'scouter-conc-smite-1'
     AND participant.player_id = 'scouter-conc-player'),
  1,
  'the real player appears exactly once in the settled game — no duplicated or lost row'
);

DO $cleanup$
BEGIN
  PERFORM dblink_exec('scouter_conc_setup', $sql$
    DELETE FROM public.audit_logs WHERE actor_discord_id = 'scouter-conc-host';
    DELETE FROM public.scouter_matches WHERE hosted_by_discord_id = 'scouter-conc-host';
    DELETE FROM public.players WHERE id = 'scouter-conc-player';
    DELETE FROM public.seasons WHERE id = 'scouter-conc-season';
  $sql$);
  PERFORM dblink_disconnect('scouter_conc_a');
  PERFORM dblink_disconnect('scouter_conc_b');
  PERFORM dblink_disconnect('scouter_conc_setup');
END;
$cleanup$;

SELECT * FROM finish();
ROLLBACK;
