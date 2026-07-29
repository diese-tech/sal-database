-- Keep scouter ingestion inside one PostgreSQL transaction. The service-role
-- caller supplies structurally validated OCR output; this boundary resolves
-- canonical identities, enforces idempotency, persists the whole game, and
-- records one audit event for the business mutation.

CREATE OR REPLACE FUNCTION public.ingest_scouter_game(
  p_season_id text,
  p_hosted_by_discord_id text,
  p_game_ordinal integer,
  p_scoreboard_image_path text,
  p_details_image_path text,
  p_participants jsonb,
  p_scouter_match_id text DEFAULT NULL,
  p_smite_match_id text DEFAULT NULL,
  p_game_mode text DEFAULT NULL,
  p_winning_side text DEFAULT NULL,
  p_match_length_seconds integer DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_scouter_match public.scouter_matches%ROWTYPE;
  v_existing_game public.scouter_games%ROWTYPE;
  v_scouter_game_id text;
  v_smite_match_id text := NULLIF(btrim(COALESCE(p_smite_match_id, '')), '');
  v_game_mode text := NULLIF(btrim(COALESCE(p_game_mode, '')), '');
  v_winning_side text := lower(NULLIF(btrim(COALESCE(p_winning_side, '')), ''));
  v_participants_summary jsonb;
  v_order_count integer;
  v_chaos_count integer;
BEGIN
  IF p_season_id IS NULL OR btrim(p_season_id) = ''
    OR p_hosted_by_discord_id IS NULL OR btrim(p_hosted_by_discord_id) = ''
    OR p_game_ordinal IS NULL OR p_game_ordinal < 1
    OR p_scoreboard_image_path IS NULL OR btrim(p_scoreboard_image_path) = ''
    OR p_details_image_path IS NULL OR btrim(p_details_image_path) = '' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Season, host, positive game ordinal, and both image paths are required.';
  END IF;

  IF v_winning_side IS NULL OR v_winning_side NOT IN ('order', 'chaos') THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Winning side must be order or chaos.';
  END IF;
  IF p_match_length_seconds IS NOT NULL AND p_match_length_seconds < 0 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Match length cannot be negative.';
  END IF;
  IF p_participants IS NULL
    OR jsonb_typeof(p_participants) <> 'array'
    OR jsonb_array_length(p_participants) <> 10 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A scouter game must contain exactly ten participant rows.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_participants) AS participant(
      side text,
      "rawIgn" text,
      "godName" text,
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
    WHERE participant."rawIgn" IS NULL OR btrim(participant."rawIgn") = ''
      OR participant.side IS NULL OR lower(btrim(participant.side)) NOT IN ('order', 'chaos')
      OR participant.kills IS NULL OR participant.kills < 0
      OR participant.deaths IS NULL OR participant.deaths < 0
      OR participant.assists IS NULL OR participant.assists < 0
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Every participant needs an IGN, valid side, and nonnegative K/D/A.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_participants) AS participant("rawIgn" text)
    GROUP BY lower(btrim(participant."rawIgn"))
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23505',
      MESSAGE = 'A participant IGN can appear only once per game.';
  END IF;

  SELECT
    count(*) FILTER (WHERE lower(btrim(participant.side)) = 'order'),
    count(*) FILTER (WHERE lower(btrim(participant.side)) = 'chaos')
  INTO v_order_count, v_chaos_count
  FROM jsonb_to_recordset(p_participants) AS participant(side text);
  IF v_order_count <> 5 OR v_chaos_count <> 5 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A scouter game must contain five order and five chaos participants.';
  END IF;

  -- Serialize retries for the same external SMITE identity before checking it.
  IF v_smite_match_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('scouter-game:' || v_smite_match_id, 0));

    SELECT * INTO v_existing_game
    FROM public.scouter_games
    WHERE smite_match_id = v_smite_match_id;

    IF FOUND THEN
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'id', participant.id,
            'side', participant.side,
            'rawIgn', participant.raw_ign,
            'playerId', participant.player_id,
            'godId', participant.god_id,
            'role', participant.role,
            'kills', participant.kills,
            'deaths', participant.deaths,
            'assists', participant.assists,
            'playerDamage', participant.player_damage,
            'wardsPlaced', participant.wards_placed
          ) ORDER BY participant.side, lower(participant.raw_ign)
        ),
        '[]'::jsonb
      ) INTO v_participants_summary
      FROM public.scouter_game_participants participant
      WHERE participant.scouter_game_id = v_existing_game.id;

      RETURN jsonb_build_object(
        'code', 'existing',
        'applied', false,
        'scouterMatchId', v_existing_game.scouter_match_id,
        'scouterGameId', v_existing_game.id,
        'participantsSummary', v_participants_summary
      );
    END IF;
  END IF;

  IF NULLIF(btrim(COALESCE(p_scouter_match_id, '')), '') IS NULL THEN
    INSERT INTO public.scouter_matches (
      season_id, hosted_by_discord_id
    ) VALUES (
      btrim(p_season_id), btrim(p_hosted_by_discord_id)
    )
    RETURNING * INTO v_scouter_match;
  ELSE
    SELECT * INTO v_scouter_match
    FROM public.scouter_matches
    WHERE id = btrim(p_scouter_match_id)
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0002',
        MESSAGE = 'Scouter match not found.';
    END IF;
    IF v_scouter_match.season_id <> btrim(p_season_id)
      OR v_scouter_match.hosted_by_discord_id <> btrim(p_hosted_by_discord_id) THEN
      RAISE EXCEPTION USING
        ERRCODE = '23514',
        MESSAGE = 'Scouter match season and host must match the original game.';
    END IF;
  END IF;

  INSERT INTO public.scouter_games (
    scouter_match_id,
    game_ordinal,
    smite_match_id,
    game_mode,
    winning_side,
    match_length_seconds,
    scoreboard_image_path,
    details_image_path
  ) VALUES (
    v_scouter_match.id,
    p_game_ordinal,
    v_smite_match_id,
    v_game_mode,
    v_winning_side,
    p_match_length_seconds,
    btrim(p_scoreboard_image_path),
    btrim(p_details_image_path)
  )
  RETURNING id INTO v_scouter_game_id;

  WITH participant_input AS (
    SELECT participant.*
    FROM jsonb_to_recordset(p_participants) AS participant(
      side text,
      "rawIgn" text,
      "godName" text,
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
  ), inserted AS (
    INSERT INTO public.scouter_game_participants (
      scouter_game_id,
      side,
      raw_ign,
      player_id,
      god_id,
      role,
      player_level,
      kills,
      deaths,
      assists,
      gpm,
      player_damage,
      minion_damage,
      jungle_damage,
      structure_damage,
      damage_taken,
      damage_mitigated,
      self_healing,
      ally_healing,
      wards_placed
    )
    SELECT
      v_scouter_game_id,
      lower(btrim(participant.side)),
      btrim(participant."rawIgn"),
      known_player.player_id,
      known_god.god_id,
      lower(NULLIF(btrim(COALESCE(participant.role, '')), '')),
      participant."playerLevel",
      participant.kills,
      participant.deaths,
      participant.assists,
      participant.gpm,
      participant."playerDamage",
      participant."minionDamage",
      participant."jungleDamage",
      participant."structureDamage",
      participant."damageTaken",
      participant."damageMitigated",
      participant."selfHealing",
      participant."allyHealing",
      participant."wardsPlaced"
    FROM participant_input participant
    LEFT JOIN LATERAL (
      SELECT CASE WHEN count(*) = 1 THEN min(player.id) END AS player_id
      FROM public.players player
      WHERE lower(btrim(player.ign)) = lower(btrim(participant."rawIgn"))
    ) known_player ON true
    LEFT JOIN LATERAL (
      SELECT CASE WHEN count(*) = 1 THEN min(god.id) END AS god_id
      FROM public.gods god
      WHERE NULLIF(btrim(COALESCE(participant."godName", '')), '') IS NOT NULL
        AND lower(btrim(god.name)) = lower(btrim(participant."godName"))
    ) known_god ON true
    RETURNING *
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', inserted.id,
        'side', inserted.side,
        'rawIgn', inserted.raw_ign,
        'playerId', inserted.player_id,
        'godId', inserted.god_id,
        'role', inserted.role,
        'kills', inserted.kills,
        'deaths', inserted.deaths,
        'assists', inserted.assists,
        'playerDamage', inserted.player_damage,
        'wardsPlaced', inserted.wards_placed
      ) ORDER BY inserted.side, lower(inserted.raw_ign)
    ),
    '[]'::jsonb
  ) INTO v_participants_summary
  FROM inserted;

  INSERT INTO public.audit_logs (
    action_type,
    entity_type,
    entity_id,
    actor_discord_id,
    new_value_json
  ) VALUES (
    'scouter_game_ingested',
    'scouter_game',
    v_scouter_game_id,
    btrim(p_hosted_by_discord_id),
    jsonb_build_object(
      'scouterMatchId', v_scouter_match.id,
      'seasonId', v_scouter_match.season_id,
      'gameOrdinal', p_game_ordinal,
      'smiteMatchId', v_smite_match_id,
      'winningSide', v_winning_side,
      'participantCount', jsonb_array_length(v_participants_summary)
    )
  );

  RETURN jsonb_build_object(
    'code', 'inserted',
    'applied', true,
    'scouterMatchId', v_scouter_match.id,
    'scouterGameId', v_scouter_game_id,
    'participantsSummary', v_participants_summary
  );
END;
$$;

REVOKE ALL ON FUNCTION public.ingest_scouter_game(
  text, text, integer, text, text, jsonb, text, text, text, text, integer
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_scouter_game(
  text, text, integer, text, text, jsonb, text, text, text, text, integer
) TO service_role;

COMMENT ON FUNCTION public.ingest_scouter_game(
  text, text, integer, text, text, jsonb, text, text, text, text, integer
) IS 'Atomically persists one OCR-extracted scouter game, resolves identities, and appends its audit event.';
