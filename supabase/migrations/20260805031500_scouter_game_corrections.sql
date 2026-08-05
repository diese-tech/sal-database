-- Post-persist scouter corrections replace one complete ten-player game through
-- a single admin-only transaction. Evidence keys and match membership remain
-- immutable; a revision check prevents overwriting a newer correction, while a
-- durable receipt makes an exact retry safe after an uncertain network result.

ALTER TABLE public.scouter_games
  ADD COLUMN revision integer NOT NULL DEFAULT 1,
  ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN updated_by_discord_id text,
  ADD CONSTRAINT scouter_games_revision_check CHECK (revision > 0),
  ADD CONSTRAINT scouter_games_updated_by_check CHECK (
    updated_by_discord_id IS NULL OR btrim(updated_by_discord_id) <> ''
  );

-- A reviewed correction may swap two OCR names. Deferring this existing key
-- until transaction end permits that swap while the RPC's final duplicate-IGN
-- validation still guarantees a unique completed state.
ALTER TABLE public.scouter_game_participants
  DROP CONSTRAINT scouter_game_participants_game_side_ign_key,
  ADD CONSTRAINT scouter_game_participants_game_side_ign_key
    UNIQUE (scouter_game_id, side, raw_ign) DEFERRABLE INITIALLY IMMEDIATE;

CREATE TABLE public.scouter_game_corrections (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  scouter_game_id text NOT NULL REFERENCES public.scouter_games(id),
  correction_key text NOT NULL UNIQUE,
  actor_discord_id text NOT NULL,
  reason text NOT NULL,
  expected_revision integer NOT NULL,
  resulting_revision integer NOT NULL,
  request_json jsonb NOT NULL,
  old_value_json jsonb NOT NULL,
  new_value_json jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT scouter_game_corrections_key_check CHECK (
    btrim(correction_key) <> '' AND length(correction_key) <= 200
  ),
  CONSTRAINT scouter_game_corrections_actor_check CHECK (
    btrim(actor_discord_id) <> ''
  ),
  CONSTRAINT scouter_game_corrections_reason_check CHECK (
    btrim(reason) <> '' AND length(reason) <= 1000
  ),
  CONSTRAINT scouter_game_corrections_revision_check CHECK (
    expected_revision > 0 AND resulting_revision = expected_revision + 1
  )
);

CREATE INDEX scouter_game_corrections_game_created_idx
  ON public.scouter_game_corrections (scouter_game_id, created_at DESC);

ALTER TABLE public.scouter_game_corrections ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.scouter_game_corrections
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.scouter_game_corrections TO service_role;

COMMENT ON TABLE public.scouter_game_corrections IS
  'Private immutable receipts for audited, full-game scouter corrections.';

CREATE OR REPLACE FUNCTION public.correct_scouter_game(
  p_scouter_game_id text,
  p_actor_discord_id text,
  p_expected_revision integer,
  p_correction_key text,
  p_reason text,
  p_game jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_game public.scouter_games%ROWTYPE;
  v_existing_correction public.scouter_game_corrections%ROWTYPE;
  v_correction_id text;
  v_game_id text := btrim(COALESCE(p_scouter_game_id, ''));
  v_actor_discord_id text := btrim(COALESCE(p_actor_discord_id, ''));
  v_correction_key text := btrim(COALESCE(p_correction_key, ''));
  v_reason text := btrim(COALESCE(p_reason, ''));
  v_smite_match_id text;
  v_game_mode text;
  v_winning_side text;
  v_match_length_seconds integer;
  v_order_count integer;
  v_chaos_count integer;
  v_before_content jsonb;
  v_after_content jsonb;
  v_old_value jsonb;
  v_new_value jsonb;
BEGIN
  IF v_game_id = '' OR v_actor_discord_id = '' OR v_correction_key = ''
    OR p_expected_revision IS NULL OR p_expected_revision < 1 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Game, admin actor, positive expected revision, and correction key are required.';
  END IF;
  IF length(v_correction_key) > 200 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Correction key must be 200 characters or fewer.';
  END IF;
  IF v_reason = '' OR length(v_reason) > 1000 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A correction reason between 1 and 1000 characters is required.';
  END IF;
  IF p_game IS NULL OR jsonb_typeof(p_game) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Corrected game must be a JSON object.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_users WHERE discord_id = v_actor_discord_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Actor is not an authorized administrator.';
  END IF;

  -- A global key lock closes the gap between an uncertain first response and an
  -- immediate retry before the unique receipt becomes visible to another call.
  PERFORM pg_advisory_xact_lock(hashtextextended('scouter-correction:' || v_correction_key, 0));

  SELECT * INTO v_existing_correction
  FROM public.scouter_game_corrections
  WHERE correction_key = v_correction_key;
  IF FOUND THEN
    IF v_existing_correction.scouter_game_id <> v_game_id
      OR v_existing_correction.actor_discord_id <> v_actor_discord_id
      OR v_existing_correction.reason <> v_reason
      OR v_existing_correction.request_json <> p_game THEN
      RAISE EXCEPTION USING
        ERRCODE = '23505',
        MESSAGE = 'Correction key was already used for a different request.';
    END IF;

    RETURN jsonb_build_object(
      'code', 'already_applied',
      'applied', false,
      'correctionId', v_existing_correction.id,
      'scouterGameId', v_existing_correction.scouter_game_id,
      'revision', v_existing_correction.resulting_revision
    );
  END IF;

  SELECT * INTO v_game
  FROM public.scouter_games
  WHERE id = v_game_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Scouter game not found.';
  END IF;
  IF v_game.revision <> p_expected_revision THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'Scouter game revision is stale.';
  END IF;

  v_smite_match_id := NULLIF(btrim(COALESCE(p_game ->> 'smiteMatchId', '')), '');
  v_game_mode := NULLIF(btrim(COALESCE(p_game ->> 'gameMode', '')), '');
  v_winning_side := lower(NULLIF(btrim(COALESCE(p_game ->> 'winningSide', '')), ''));
  IF v_winning_side IS NULL OR v_winning_side NOT IN ('order', 'chaos') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Winning side must be order or chaos.';
  END IF;
  IF p_game -> 'matchLengthSeconds' IS NULL
    OR p_game -> 'matchLengthSeconds' = 'null'::jsonb THEN
    v_match_length_seconds := NULL;
  ELSE
    v_match_length_seconds := (p_game ->> 'matchLengthSeconds')::integer;
  END IF;
  IF v_match_length_seconds IS NOT NULL AND v_match_length_seconds < 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Match length cannot be negative.';
  END IF;
  IF v_smite_match_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.scouter_games other_game
    WHERE other_game.smite_match_id = v_smite_match_id
      AND other_game.id <> v_game.id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'SMITE match ID belongs to another scouter game.';
  END IF;

  IF jsonb_typeof(p_game -> 'participants') <> 'array'
    OR jsonb_array_length(p_game -> 'participants') <> 10 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A corrected scouter game must contain exactly ten participant rows.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_game -> 'participants') AS participant(
      id text,
      side text,
      "rawIgn" text,
      "playerId" text,
      "godId" text,
      role text,
      "playerLevel" integer,
      kills integer,
      deaths integer,
      assists integer,
      gpm integer,
      "playerDamage" bigint,
      "minionDamage" bigint,
      "jungleDamage" bigint,
      "structureDamage" bigint,
      "damageTaken" bigint,
      "damageMitigated" bigint,
      "selfHealing" bigint,
      "allyHealing" bigint,
      "wardsPlaced" integer
    )
    WHERE participant.id IS NULL OR btrim(participant.id) = ''
      OR participant.side IS NULL OR lower(btrim(participant.side)) NOT IN ('order', 'chaos')
      OR participant."rawIgn" IS NULL OR btrim(participant."rawIgn") = ''
      OR length(btrim(participant."rawIgn")) > 64
      OR participant.kills IS NULL OR participant.kills < 0
      OR participant.deaths IS NULL OR participant.deaths < 0
      OR participant.assists IS NULL OR participant.assists < 0
      OR (participant.role IS NOT NULL AND lower(btrim(participant.role)) NOT IN ('solo', 'jungle', 'mid', 'support', 'carry'))
      OR (participant."playerLevel" IS NOT NULL AND participant."playerLevel" NOT BETWEEN 1 AND 20)
      OR (participant.gpm IS NOT NULL AND participant.gpm < 0)
      OR (participant."playerDamage" IS NOT NULL AND participant."playerDamage" < 0)
      OR (participant."minionDamage" IS NOT NULL AND participant."minionDamage" < 0)
      OR (participant."jungleDamage" IS NOT NULL AND participant."jungleDamage" < 0)
      OR (participant."structureDamage" IS NOT NULL AND participant."structureDamage" < 0)
      OR (participant."damageTaken" IS NOT NULL AND participant."damageTaken" < 0)
      OR (participant."damageMitigated" IS NOT NULL AND participant."damageMitigated" < 0)
      OR (participant."selfHealing" IS NOT NULL AND participant."selfHealing" < 0)
      OR (participant."allyHealing" IS NOT NULL AND participant."allyHealing" < 0)
      OR (participant."wardsPlaced" IS NOT NULL AND participant."wardsPlaced" < 0)
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Every correction participant needs valid identity, side, role, level, and nonnegative stats.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_game -> 'participants') AS participant(id text)
    GROUP BY btrim(participant.id)
    HAVING count(*) > 1
  ) OR EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_game -> 'participants') AS participant("rawIgn" text)
    GROUP BY lower(btrim(participant."rawIgn"))
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23505',
      MESSAGE = 'Participant IDs and IGNs must each appear only once per game.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_game -> 'participants') AS participant(id text)
    LEFT JOIN public.scouter_game_participants existing
      ON existing.id = btrim(participant.id)
     AND existing.scouter_game_id = v_game.id
    WHERE existing.id IS NULL
  ) OR EXISTS (
    SELECT 1
    FROM public.scouter_game_participants existing
    WHERE existing.scouter_game_id = v_game.id
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_to_recordset(p_game -> 'participants') AS participant(id text)
        WHERE btrim(participant.id) = existing.id
      )
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Correction must replace the existing ten participant IDs exactly.';
  END IF;

  SELECT
    count(*) FILTER (WHERE lower(btrim(participant.side)) = 'order'),
    count(*) FILTER (WHERE lower(btrim(participant.side)) = 'chaos')
  INTO v_order_count, v_chaos_count
  FROM jsonb_to_recordset(p_game -> 'participants') AS participant(side text);
  IF v_order_count <> 5 OR v_chaos_count <> 5 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A corrected scouter game must contain five order and five chaos participants.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_game -> 'participants') AS participant("playerId" text)
    LEFT JOIN public.players player ON player.id = participant."playerId"
    WHERE participant."playerId" IS NOT NULL AND player.id IS NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23503', MESSAGE = 'Corrected player ID does not exist.';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_game -> 'participants') AS participant("godId" text)
    LEFT JOIN public.gods god ON god.id = participant."godId"
    WHERE participant."godId" IS NOT NULL AND god.id IS NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23503', MESSAGE = 'Corrected god ID does not exist.';
  END IF;

  SELECT jsonb_build_object(
    'smiteMatchId', v_game.smite_match_id,
    'gameMode', v_game.game_mode,
    'winningSide', v_game.winning_side,
    'matchLengthSeconds', v_game.match_length_seconds,
    'participants', COALESCE(jsonb_agg(
      jsonb_build_object(
        'id', participant.id,
        'side', participant.side,
        'rawIgn', participant.raw_ign,
        'playerId', participant.player_id,
        'godId', participant.god_id,
        'role', participant.role,
        'playerLevel', participant.player_level,
        'kills', participant.kills,
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
    ), '[]'::jsonb)
  ) INTO v_before_content
  FROM public.scouter_game_participants participant
  WHERE participant.scouter_game_id = v_game.id;

  WITH normalized AS (
    SELECT
      btrim(participant.id) AS id,
      lower(btrim(participant.side)) AS side,
      btrim(participant."rawIgn") AS raw_ign,
      participant."playerId" AS player_id,
      participant."godId" AS god_id,
      lower(NULLIF(btrim(COALESCE(participant.role, '')), '')) AS role,
      participant."playerLevel" AS player_level,
      participant.kills,
      participant.deaths,
      participant.assists,
      participant.gpm,
      participant."playerDamage" AS player_damage,
      participant."minionDamage" AS minion_damage,
      participant."jungleDamage" AS jungle_damage,
      participant."structureDamage" AS structure_damage,
      participant."damageTaken" AS damage_taken,
      participant."damageMitigated" AS damage_mitigated,
      participant."selfHealing" AS self_healing,
      participant."allyHealing" AS ally_healing,
      participant."wardsPlaced" AS wards_placed
    FROM jsonb_to_recordset(p_game -> 'participants') AS participant(
      id text, side text, "rawIgn" text, "playerId" text, "godId" text, role text,
      "playerLevel" integer, kills integer, deaths integer, assists integer, gpm integer,
      "playerDamage" bigint, "minionDamage" bigint, "jungleDamage" bigint,
      "structureDamage" bigint, "damageTaken" bigint, "damageMitigated" bigint,
      "selfHealing" bigint, "allyHealing" bigint, "wardsPlaced" integer
    )
  )
  SELECT jsonb_build_object(
    'smiteMatchId', v_smite_match_id,
    'gameMode', v_game_mode,
    'winningSide', v_winning_side,
    'matchLengthSeconds', v_match_length_seconds,
    'participants', jsonb_agg(
      jsonb_build_object(
        'id', normalized.id,
        'side', normalized.side,
        'rawIgn', normalized.raw_ign,
        'playerId', normalized.player_id,
        'godId', normalized.god_id,
        'role', normalized.role,
        'playerLevel', normalized.player_level,
        'kills', normalized.kills,
        'deaths', normalized.deaths,
        'assists', normalized.assists,
        'gpm', normalized.gpm,
        'playerDamage', normalized.player_damage,
        'minionDamage', normalized.minion_damage,
        'jungleDamage', normalized.jungle_damage,
        'structureDamage', normalized.structure_damage,
        'damageTaken', normalized.damage_taken,
        'damageMitigated', normalized.damage_mitigated,
        'selfHealing', normalized.self_healing,
        'allyHealing', normalized.ally_healing,
        'wardsPlaced', normalized.wards_placed
      ) ORDER BY normalized.side, lower(normalized.raw_ign), normalized.id
    )
  ) INTO v_after_content
  FROM normalized;

  IF v_before_content = v_after_content THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Correction does not change the scouter game.';
  END IF;

  UPDATE public.scouter_games
  SET smite_match_id = v_smite_match_id,
      game_mode = v_game_mode,
      winning_side = v_winning_side,
      match_length_seconds = v_match_length_seconds,
      revision = revision + 1,
      updated_at = now(),
      updated_by_discord_id = v_actor_discord_id
  WHERE id = v_game.id;

  SET CONSTRAINTS scouter_game_participants_game_side_ign_key DEFERRED;

  WITH participant_input AS (
    SELECT participant.*
    FROM jsonb_to_recordset(p_game -> 'participants') AS participant(
      id text, side text, "rawIgn" text, "playerId" text, "godId" text, role text,
      "playerLevel" integer, kills integer, deaths integer, assists integer, gpm integer,
      "playerDamage" bigint, "minionDamage" bigint, "jungleDamage" bigint,
      "structureDamage" bigint, "damageTaken" bigint, "damageMitigated" bigint,
      "selfHealing" bigint, "allyHealing" bigint, "wardsPlaced" integer
    )
  )
  UPDATE public.scouter_game_participants participant
  SET side = lower(btrim(input.side)),
      raw_ign = btrim(input."rawIgn"),
      player_id = input."playerId",
      god_id = input."godId",
      role = lower(NULLIF(btrim(COALESCE(input.role, '')), '')),
      player_level = input."playerLevel",
      kills = input.kills,
      deaths = input.deaths,
      assists = input.assists,
      gpm = input.gpm,
      player_damage = input."playerDamage",
      minion_damage = input."minionDamage",
      jungle_damage = input."jungleDamage",
      structure_damage = input."structureDamage",
      damage_taken = input."damageTaken",
      damage_mitigated = input."damageMitigated",
      self_healing = input."selfHealing",
      ally_healing = input."allyHealing",
      wards_placed = input."wardsPlaced",
      updated_at = now(),
      updated_by_discord_id = v_actor_discord_id
  FROM participant_input input
  WHERE participant.id = btrim(input.id)
    AND participant.scouter_game_id = v_game.id;

  v_old_value := jsonb_build_object(
    'revision', v_game.revision,
    'game', v_before_content
  );
  v_new_value := jsonb_build_object(
    'revision', v_game.revision + 1,
    'game', v_after_content
  );

  INSERT INTO public.scouter_game_corrections (
    scouter_game_id,
    correction_key,
    actor_discord_id,
    reason,
    expected_revision,
    resulting_revision,
    request_json,
    old_value_json,
    new_value_json
  ) VALUES (
    v_game.id,
    v_correction_key,
    v_actor_discord_id,
    v_reason,
    v_game.revision,
    v_game.revision + 1,
    p_game,
    v_old_value,
    v_new_value
  ) RETURNING id INTO v_correction_id;

  INSERT INTO public.audit_logs (
    action_type,
    entity_type,
    entity_id,
    actor_discord_id,
    old_value_json,
    new_value_json,
    note
  ) VALUES (
    'scouter_game_corrected',
    'scouter_game',
    v_game.id,
    v_actor_discord_id,
    v_old_value,
    v_new_value || jsonb_build_object('correctionId', v_correction_id),
    v_reason
  );

  RETURN jsonb_build_object(
    'code', 'corrected',
    'applied', true,
    'correctionId', v_correction_id,
    'scouterGameId', v_game.id,
    'revision', v_game.revision + 1
  );
END;
$$;

REVOKE ALL ON FUNCTION public.correct_scouter_game(
  text, text, integer, text, text, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.correct_scouter_game(
  text, text, integer, text, text, jsonb
) TO service_role;

COMMENT ON FUNCTION public.correct_scouter_game(
  text, text, integer, text, text, jsonb
) IS 'Admin-only optimistic full-game scouter correction with durable idempotency and immutable before/after audit.';
