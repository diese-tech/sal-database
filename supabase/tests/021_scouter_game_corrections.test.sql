BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(17);

SELECT ok(
  to_regprocedure('public.correct_scouter_game(text,text,integer,text,text,jsonb)') IS NOT NULL,
  'the atomic scouter game correction RPC exists'
);

SELECT ok(
  to_regclass('public.scouter_game_corrections') IS NOT NULL,
  'durable scouter correction receipts exist'
);

SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.scouter_game_corrections'::regclass)
    AND NOT has_table_privilege('anon', 'public.scouter_game_corrections', 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated', 'public.scouter_game_corrections', 'SELECT,INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.scouter_game_corrections', 'SELECT')
    AND NOT has_table_privilege('service_role', 'public.scouter_game_corrections', 'INSERT,UPDATE,DELETE'),
  'receipts are private and cannot be mutated directly by application roles'
);

SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.correct_scouter_game(text,text,integer,text,text,jsonb)', 'EXECUTE'
  )
    AND NOT has_function_privilege(
      'authenticated', 'public.correct_scouter_game(text,text,integer,text,text,jsonb)', 'EXECUTE'
    )
    AND has_function_privilege(
      'service_role', 'public.correct_scouter_game(text,text,integer,text,text,jsonb)', 'EXECUTE'
    ),
  'only the service role can enter the correction transaction'
);

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES (
  'scouter-correction-season', 'Scouter Correction Season', 'pre-season',
  '2026-08-01', '2026-08-31', false
);

INSERT INTO public.admin_users (
  discord_id, role, discord_username, display_name
) VALUES (
  'scouter-correction-admin', 'admin', 'correction-admin', 'Correction Admin'
);

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient, primary_role, status
) VALUES (
  'scouter-correction-player', 'corrected-captain', 'Corrected Captain', 'CC',
  'from-black to-white', 'Solo', 'active'
);

CREATE FUNCTION pg_temp.scouter_correction_ingest_participants()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_array(
    jsonb_build_object('side', 'order', 'rawIgn', 'Order One', 'godName', 'Achilles', 'role', 'solo', 'playerLevel', 20, 'kills', 1, 'deaths', 2, 'assists', 3, 'gpm', 500, 'playerDamage', 10000, 'minionDamage', 20000, 'jungleDamage', 3000, 'structureDamage', 4000, 'damageTaken', 15000, 'damageMitigated', 16000, 'selfHealing', 1000, 'allyHealing', 0, 'wardsPlaced', 8),
    jsonb_build_object('side', 'order', 'rawIgn', 'Order Two', 'role', 'jungle', 'kills', 2, 'deaths', 3, 'assists', 4),
    jsonb_build_object('side', 'order', 'rawIgn', 'Order Three', 'role', 'mid', 'kills', 3, 'deaths', 4, 'assists', 5),
    jsonb_build_object('side', 'order', 'rawIgn', 'Order Four', 'role', 'support', 'kills', 4, 'deaths', 5, 'assists', 6),
    jsonb_build_object('side', 'order', 'rawIgn', 'Order Five', 'role', 'carry', 'kills', 5, 'deaths', 6, 'assists', 7),
    jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos One', 'role', 'solo', 'kills', 6, 'deaths', 5, 'assists', 4),
    jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos Two', 'role', 'jungle', 'kills', 7, 'deaths', 4, 'assists', 3),
    jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos Three', 'role', 'mid', 'kills', 8, 'deaths', 3, 'assists', 2),
    jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos Four', 'role', 'support', 'kills', 9, 'deaths', 2, 'assists', 1),
    jsonb_build_object('side', 'chaos', 'rawIgn', 'Chaos Five', 'role', 'carry', 'kills', 10, 'deaths', 1, 'assists', 0)
  );
$$;

CREATE TEMP TABLE scouter_correction_ingest AS
SELECT public.ingest_scouter_game(
  'scouter-correction-season',
  'scouter-correction-host',
  1,
  'scouters/correction/scoreboard.png',
  'scouters/correction/details.png',
  pg_temp.scouter_correction_ingest_participants(),
  'order',
  NULL,
  'scouter-correction-smite',
  'Conquest',
  1800
) AS result;

CREATE TEMP TABLE scouter_correction_fixture AS
SELECT
  game.id AS game_id,
  participant.id AS target_participant_id
FROM public.scouter_games game
JOIN public.scouter_game_participants participant
  ON participant.scouter_game_id = game.id
WHERE game.smite_match_id = 'scouter-correction-smite'
  AND participant.raw_ign = 'Order One';

CREATE FUNCTION pg_temp.scouter_correction_payload(
  p_game_id text,
  p_target_participant_id text,
  p_raw_ign text,
  p_player_id text,
  p_kills integer,
  p_winning_side text DEFAULT 'chaos'
) RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object(
    'smiteMatchId', game.smite_match_id,
    'gameMode', game.game_mode,
    'winningSide', p_winning_side,
    'matchLengthSeconds', game.match_length_seconds,
    'participants', jsonb_agg(
      jsonb_build_object(
        'id', participant.id,
        'side', participant.side,
        'rawIgn', CASE WHEN participant.id = p_target_participant_id THEN p_raw_ign ELSE participant.raw_ign END,
        'playerId', CASE WHEN participant.id = p_target_participant_id THEN p_player_id ELSE participant.player_id END,
        'godId', participant.god_id,
        'role', participant.role,
        'playerLevel', participant.player_level,
        'kills', CASE WHEN participant.id = p_target_participant_id THEN p_kills ELSE participant.kills END,
        'deaths', participant.deaths,
        'assists', participant.assists,
        'gpm', participant.gpm,
        'playerDamage', participant.player_damage,
        'minionDamage', participant.minion_damage,
        'jungleDamage', participant.jungle_damage,
        'structureDamage', participant.structure_damage,
        'damageTaken', participant.damage_taken,
        'damageMitigated', participant.damage_mitigated,
        'selfHealing', participant.self_healing,
        'allyHealing', participant.ally_healing,
        'wardsPlaced', participant.wards_placed
      ) ORDER BY participant.side, lower(participant.raw_ign), participant.id
    )
  )
  FROM public.scouter_games game
  JOIN public.scouter_game_participants participant
    ON participant.scouter_game_id = game.id
  WHERE game.id = p_game_id
  GROUP BY game.id;
$$;

CREATE TEMP TABLE scouter_correction_request AS
SELECT pg_temp.scouter_correction_payload(
  fixture.game_id,
  fixture.target_participant_id,
  'Corrected Captain',
  'scouter-correction-player',
  9,
  'chaos'
) AS payload
FROM scouter_correction_fixture fixture;

SELECT throws_ok(
  format(
    'SELECT public.correct_scouter_game(%L, %L, 1, %L, %L, %L::jsonb)',
    (SELECT game_id FROM scouter_correction_fixture),
    'not-an-admin',
    'correction-unauthorized',
    'Unauthorized correction attempt',
    (SELECT payload::text FROM scouter_correction_request)
  ),
  '42501',
  'Actor is not an authorized administrator.',
  'a non-admin cannot correct scouter rows'
);

CREATE TEMP TABLE scouter_correction_result AS
SELECT public.correct_scouter_game(
  (SELECT game_id FROM scouter_correction_fixture),
  'scouter-correction-admin',
  1,
  'correction-success-1',
  'OCR misread the captain name and kills.',
  (SELECT payload FROM scouter_correction_request)
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'corrected'
      AND result ->> 'applied' = 'true'
      AND result ->> 'revision' = '2'
   FROM scouter_correction_result),
  'an admin applies one full-game correction at the expected revision'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.scouter_games game
    JOIN public.scouter_game_participants participant
      ON participant.scouter_game_id = game.id
    WHERE game.id = (SELECT game_id FROM scouter_correction_fixture)
      AND game.revision = 2
      AND game.winning_side = 'chaos'
      AND game.updated_by_discord_id = 'scouter-correction-admin'
      AND participant.id = (SELECT target_participant_id FROM scouter_correction_fixture)
      AND participant.raw_ign = 'Corrected Captain'
      AND participant.player_id = 'scouter-correction-player'
      AND participant.kills = 9
  )
    AND (
      SELECT count(*) = 10
      FROM public.scouter_game_participants participant
      WHERE participant.scouter_game_id = (SELECT game_id FROM scouter_correction_fixture)
        AND participant.updated_by_discord_id = 'scouter-correction-admin'
    ),
  'game metadata and all ten existing participant rows update together'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.audit_logs audit
    WHERE audit.action_type = 'scouter_game_corrected'
      AND audit.entity_id = (SELECT game_id FROM scouter_correction_fixture)
      AND audit.actor_discord_id = 'scouter-correction-admin'
      AND audit.note = 'OCR misread the captain name and kills.'
      AND audit.old_value_json ->> 'revision' = '1'
      AND audit.new_value_json ->> 'revision' = '2'
      AND jsonb_path_exists(
        audit.old_value_json,
        '$.game.participants[*] ? (@.rawIgn == "Order One")'
      )
      AND jsonb_path_exists(
        audit.new_value_json,
        '$.game.participants[*] ? (@.rawIgn == "Corrected Captain" && @.kills == 9)'
      )
  ),
  'the immutable audit contains the complete before and after game snapshots'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.scouter_game_corrections correction
    WHERE correction.correction_key = 'correction-success-1'
      AND correction.expected_revision = 1
      AND correction.resulting_revision = 2
      AND correction.old_value_json ->> 'revision' = '1'
      AND correction.new_value_json ->> 'revision' = '2'
  ),
  'a durable receipt binds the idempotency key to the applied transition'
);

CREATE TEMP TABLE scouter_correction_retry AS
SELECT public.correct_scouter_game(
  (SELECT game_id FROM scouter_correction_fixture),
  'scouter-correction-admin',
  1,
  'correction-success-1',
  'OCR misread the captain name and kills.',
  (SELECT payload FROM scouter_correction_request)
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'already_applied'
      AND result ->> 'applied' = 'false'
      AND result ->> 'revision' = '2'
   FROM scouter_correction_retry),
  'an exact retry returns the original correction receipt'
);

SELECT ok(
  (SELECT revision = 2 FROM public.scouter_games
   WHERE id = (SELECT game_id FROM scouter_correction_fixture))
    AND (SELECT count(*) = 1 FROM public.scouter_game_corrections
         WHERE correction_key = 'correction-success-1')
    AND (SELECT count(*) = 1 FROM public.audit_logs
         WHERE action_type = 'scouter_game_corrected'
           AND entity_id = (SELECT game_id FROM scouter_correction_fixture)),
  'an exact retry writes no duplicate rows or audits'
);

SELECT throws_ok(
  format(
    'SELECT public.correct_scouter_game(%L, %L, 1, %L, %L, %L::jsonb)',
    (SELECT game_id FROM scouter_correction_fixture),
    'scouter-correction-admin',
    'correction-success-1',
    'A different reason',
    (SELECT payload::text FROM scouter_correction_request)
  ),
  '23505',
  'Correction key was already used for a different request.',
  'an idempotency key cannot be rebound to a different request'
);

SELECT throws_ok(
  format(
    'SELECT public.correct_scouter_game(%L, %L, 1, %L, %L, %L::jsonb)',
    (SELECT game_id FROM scouter_correction_fixture),
    'scouter-correction-admin',
    'correction-stale',
    'Stale browser state',
    (SELECT payload::text FROM scouter_correction_request)
  ),
  '40001',
  'Scouter game revision is stale.',
  'a stale editor cannot overwrite a newer correction'
);

SELECT throws_ok(
  format(
    'SELECT public.correct_scouter_game(%L, %L, 2, %L, %L, %L::jsonb)',
    (SELECT game_id FROM scouter_correction_fixture),
    'scouter-correction-admin',
    'correction-missing-player',
    'Incomplete correction payload',
    jsonb_set(
      pg_temp.scouter_correction_payload(
        (SELECT game_id FROM scouter_correction_fixture),
        (SELECT target_participant_id FROM scouter_correction_fixture),
        'Corrected Captain', 'scouter-correction-player', 10, 'chaos'
      ),
      '{participants}',
      (
        SELECT jsonb_agg(value)
        FROM (
          SELECT value
          FROM jsonb_array_elements(
            pg_temp.scouter_correction_payload(
              (SELECT game_id FROM scouter_correction_fixture),
              (SELECT target_participant_id FROM scouter_correction_fixture),
              'Corrected Captain', 'scouter-correction-player', 10, 'chaos'
            ) -> 'participants'
          ) WITH ORDINALITY rows(value, ordinal)
          WHERE ordinal < 10
        ) kept
      )
    )::text
  ),
  '22023',
  'A corrected scouter game must contain exactly ten participant rows.',
  'a correction cannot omit a participant'
);

SELECT throws_ok(
  format(
    'SELECT public.correct_scouter_game(%L, %L, 2, %L, %L, %L::jsonb)',
    (SELECT game_id FROM scouter_correction_fixture),
    'scouter-correction-admin',
    'correction-unknown-player',
    'Bad explicit mapping',
    pg_temp.scouter_correction_payload(
      (SELECT game_id FROM scouter_correction_fixture),
      (SELECT target_participant_id FROM scouter_correction_fixture),
      'Another Correction', 'player-does-not-exist', 10, 'chaos'
    )::text
  ),
  '23503',
  'Corrected player ID does not exist.',
  'an explicit player mapping must reference a canonical player'
);

CREATE FUNCTION pg_temp.force_scouter_correction_audit_failure()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.action_type = 'scouter_game_corrected'
    AND NEW.note = 'Force correction audit rollback' THEN
    RAISE EXCEPTION 'forced scouter correction audit failure';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER force_scouter_correction_audit_failure
BEFORE INSERT ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION pg_temp.force_scouter_correction_audit_failure();

SELECT throws_ok(
  format(
    'SELECT public.correct_scouter_game(%L, %L, 2, %L, %L, %L::jsonb)',
    (SELECT game_id FROM scouter_correction_fixture),
    'scouter-correction-admin',
    'correction-audit-rollback',
    'Force correction audit rollback',
    pg_temp.scouter_correction_payload(
      (SELECT game_id FROM scouter_correction_fixture),
      (SELECT target_participant_id FROM scouter_correction_fixture),
      'Corrected Captain', 'scouter-correction-player', 10, 'chaos'
    )::text
  ),
  'P0001',
  'forced scouter correction audit failure',
  'an audit failure aborts the correction transaction'
);

DROP TRIGGER force_scouter_correction_audit_failure ON public.audit_logs;

SELECT ok(
  (SELECT revision = 2 FROM public.scouter_games
   WHERE id = (SELECT game_id FROM scouter_correction_fixture))
    AND (SELECT kills = 9 FROM public.scouter_game_participants
         WHERE id = (SELECT target_participant_id FROM scouter_correction_fixture))
    AND NOT EXISTS (
      SELECT 1 FROM public.scouter_game_corrections
      WHERE correction_key = 'correction-audit-rollback'
    ),
  'audit failure rolls back game, participant, and correction receipt mutations'
);

SELECT * FROM finish();
ROLLBACK;
