-- Concurrency contract test for public.ingest_scouter_game.
--
-- 012_scouter_ingest_rpc.test.sql proves idempotent retries are safe when
-- called *sequentially* in one session. It cannot prove the advisory-lock
-- serialization (pg_advisory_xact_lock keyed on the SMITE match id) actually
-- holds under real concurrency, because a single session can't run two
-- overlapping transactions. This test drives two genuinely separate
-- PostgreSQL backends (via dblink) at the real SMITE match id for one real
-- player at the same time, simulating a host double-clicking the upload
-- button or a client retrying after a slow response — the exact scenario the
-- advisory lock exists to protect against.
--
-- Because dblink opens independent connections, this file cannot rely on the
-- usual BEGIN/ROLLBACK-per-file convention (a second backend cannot see this
-- session's uncommitted rows). Setup is committed for real and torn down
-- explicitly at the end instead.

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS dblink;
SET search_path TO extensions, public, pg_catalog;

SELECT plan(6);

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES ('scouter-conc-season', 'Scouter Concurrency Season', 'pre-season', '2026-07-01', '2026-08-31', false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient, primary_role, status
) VALUES (
  'scouter-conc-player', 'concurrentleagueplayer', 'ConcurrentLeaguePlayer', 'CL',
  'from-black to-white', 'Solo', 'active'
) ON CONFLICT (id) DO NOTHING;

CREATE TEMP TABLE scouter_conc_participants AS
SELECT jsonb_build_array(
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
) AS participants;

-- Both racing callers submit the *same* real SMITE match for the *same*
-- player with no scouter_match_id yet — the worst case, where there is no
-- existing row for either side to FOR UPDATE lock onto and the advisory lock
-- is the only thing standing between this and a duplicated/corrupted game.
CREATE TEMP TABLE scouter_conc_call_sql AS
SELECT format(
  $fmt$select public.ingest_scouter_game(%L, %L, %L, %L, %L, %L::jsonb, %L, %L, %L, %L, %L)$fmt$,
  'scouter-conc-season',
  'scouter-conc-host',
  1,
  'scouters/conc/scoreboard-1.png',
  'scouters/conc/details-1.png',
  (SELECT participants FROM scouter_conc_participants),
  'order',
  NULL,
  'scouter-conc-smite-1',
  'Conquest',
  1800
) AS sql;

SELECT dblink_connect('scouter_conc_a', 'dbname=' || current_database());
SELECT dblink_connect('scouter_conc_b', 'dbname=' || current_database());

-- Fire both requests back-to-back, without waiting on either — this is two
-- real backends racing for the same advisory lock at (as close as a script
-- can get to) the same instant.
SELECT dblink_send_query('scouter_conc_a', (SELECT sql FROM scouter_conc_call_sql));
SELECT dblink_send_query('scouter_conc_b', (SELECT sql FROM scouter_conc_call_sql));

CREATE TEMP TABLE scouter_conc_result_a AS
SELECT result FROM dblink_get_result('scouter_conc_a') AS t(result jsonb);
CREATE TEMP TABLE scouter_conc_result_b AS
SELECT result FROM dblink_get_result('scouter_conc_b') AS t(result jsonb);

SELECT dblink_disconnect('scouter_conc_a');
SELECT dblink_disconnect('scouter_conc_b');

SELECT ok(
  (SELECT result IS NOT NULL FROM scouter_conc_result_a)
    AND (SELECT result IS NOT NULL FROM scouter_conc_result_b),
  'both concurrent callers get a graceful RPC result — neither raises a raw constraint error'
);

SELECT ok(
  (
    (SELECT result ->> 'code' FROM scouter_conc_result_a) = 'inserted'
    AND (SELECT result ->> 'code' FROM scouter_conc_result_b) = 'existing'
  ) OR (
    (SELECT result ->> 'code' FROM scouter_conc_result_a) = 'existing'
    AND (SELECT result ->> 'code' FROM scouter_conc_result_b) = 'inserted'
  ),
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

SELECT * FROM finish();

-- Explicit cleanup: this file commits for real (dblink needs committed rows
-- to see across connections), so there is no enclosing ROLLBACK to rely on.
DELETE FROM public.audit_logs WHERE actor_discord_id = 'scouter-conc-host';
DELETE FROM public.scouter_matches WHERE hosted_by_discord_id = 'scouter-conc-host';
DELETE FROM public.players WHERE id = 'scouter-conc-player';
DELETE FROM public.seasons WHERE id = 'scouter-conc-season';
