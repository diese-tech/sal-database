-- Make site registration and match-report review decisions transactional.
-- This release adds service-role entry points only; existing rows are not
-- rewritten, remapped, or deleted by the migration.

-- The production baseline retains historical Gaia reports, while current
-- consumers submit Terra. Accept both identifiers without rewriting history.
ALTER TABLE public.match_reports
  DROP CONSTRAINT match_reports_division_id_check,
  ADD CONSTRAINT match_reports_division_id_check
    CHECK (division_id IN ('gaia', 'solar', 'lunar', 'terra'));

CREATE OR REPLACE FUNCTION public.resolve_registration_review(
  p_registration_id text,
  p_actor_discord_id text,
  p_decision text,
  p_reviewer_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_registration public.registrations%ROWTYPE;
  v_decision text := lower(btrim(COALESCE(p_decision, '')));
  v_note text := NULLIF(btrim(COALESCE(p_reviewer_note, '')), '');
  v_target_status text;
  v_player_id text;
  v_linked_player_id text;
  v_existing_discord_id text;
  v_ign text;
  v_primary_role text := 'Flex';
  v_secondary_role text;
BEGIN
  IF p_registration_id IS NULL OR btrim(p_registration_id) = ''
    OR p_actor_discord_id IS NULL OR btrim(p_actor_discord_id) = '' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Registration ID and actor Discord ID are required.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.admin_users
    WHERE discord_id = p_actor_discord_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Actor is not an authorized administrator.';
  END IF;

  IF v_decision NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Registration decision must be approve or reject.';
  END IF;
  IF v_note IS NOT NULL AND length(v_note) > 500 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Reviewer note cannot exceed 500 characters.';
  END IF;
  IF v_decision = 'reject' AND v_note IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A reviewer note is required for registration rejection.';
  END IF;

  SELECT * INTO v_registration
  FROM public.registrations
  WHERE id = p_registration_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0002',
      MESSAGE = 'Registration not found.';
  END IF;

  v_target_status := CASE WHEN v_decision = 'approve' THEN 'approved' ELSE 'rejected' END;
  IF v_registration.status = v_target_status THEN
    RETURN jsonb_build_object(
      'code', 'already_processed',
      'registrationId', v_registration.id,
      'finalStatus', v_registration.status,
      'applied', false,
      'playerId', v_registration.player_id
    );
  END IF;
  IF v_registration.status <> 'pending' THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'Registration already has a conflicting terminal decision.';
  END IF;

  v_player_id := v_registration.player_id;
  IF v_decision = 'approve' THEN
    v_ign := btrim(COALESCE(v_registration.form_data ->> 'ign', ''));
    IF v_ign = '' OR length(v_ign) > 64 THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = 'Registration IGN must contain between 1 and 64 characters.';
    END IF;

    IF NULLIF(btrim(COALESCE(v_registration.form_data ->> 'primary_role', '')), '') IS NOT NULL THEN
      v_primary_role := CASE lower(btrim(v_registration.form_data ->> 'primary_role'))
        WHEN 'solo' THEN 'Solo'
        WHEN 'jungle' THEN 'Jungle'
        WHEN 'mid' THEN 'Mid'
        WHEN 'carry' THEN 'Carry'
        WHEN 'support' THEN 'Support'
        WHEN 'flex' THEN 'Flex'
        ELSE NULL
      END;
      IF v_primary_role IS NULL THEN
        RAISE EXCEPTION USING
          ERRCODE = '22023',
          MESSAGE = 'Registration primary role is invalid.';
      END IF;
    END IF;

    IF NULLIF(btrim(COALESCE(v_registration.form_data ->> 'secondary_role', '')), '') IS NOT NULL THEN
      v_secondary_role := CASE lower(btrim(v_registration.form_data ->> 'secondary_role'))
        WHEN 'solo' THEN 'Solo'
        WHEN 'jungle' THEN 'Jungle'
        WHEN 'mid' THEN 'Mid'
        WHEN 'carry' THEN 'Carry'
        WHEN 'support' THEN 'Support'
        WHEN 'flex' THEN 'Flex'
        ELSE NULL
      END;
      IF v_secondary_role IS NULL THEN
        RAISE EXCEPTION USING
          ERRCODE = '22023',
          MESSAGE = 'Registration secondary role is invalid.';
      END IF;
      IF v_secondary_role = v_primary_role THEN
        RAISE EXCEPTION USING
          ERRCODE = '22023',
          MESSAGE = 'Registration primary and secondary roles must differ.';
      END IF;
    END IF;

    IF v_player_id IS NOT NULL THEN
      SELECT discord_id INTO v_existing_discord_id
      FROM public.players
      WHERE id = v_player_id
      FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION USING
          ERRCODE = 'P0002',
          MESSAGE = 'Registration-linked player not found.';
      END IF;
      IF v_existing_discord_id IS NOT NULL
        AND v_existing_discord_id <> v_registration.discord_id THEN
        RAISE EXCEPTION USING
          ERRCODE = '23505',
          MESSAGE = 'Registration-linked player belongs to another Discord identity.';
      END IF;
    END IF;

    SELECT id INTO v_linked_player_id
    FROM public.players
    WHERE discord_id = v_registration.discord_id
    FOR UPDATE;

    IF v_player_id IS NOT NULL
      AND v_linked_player_id IS NOT NULL
      AND v_player_id <> v_linked_player_id THEN
      RAISE EXCEPTION USING
        ERRCODE = '23505',
        MESSAGE = 'Discord identity is already linked to a different player.';
    END IF;
    v_player_id := COALESCE(v_player_id, v_linked_player_id);

    IF v_player_id IS NULL THEN
      v_player_id := gen_random_uuid()::text;
      INSERT INTO public.players (
        id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
        primary_role, secondary_roles, is_starter, is_captain, division_id,
        status, discord_id, profile_claimed
      ) VALUES (
        v_player_id, NULL, v_registration.discord_username, v_ign,
        upper(left(v_ign, 2)), '', v_primary_role,
        CASE
          WHEN v_secondary_role IS NULL THEN '[]'::jsonb
          ELSE jsonb_build_array(v_secondary_role)
        END,
        false, false, NULL, 'free-agent', v_registration.discord_id, true
      );
    ELSE
      UPDATE public.players
      SET discord_id = v_registration.discord_id,
          discord_username = v_registration.discord_username,
          profile_claimed = true
      WHERE id = v_player_id;
    END IF;

    IF v_registration.season_id IS NOT NULL THEN
      INSERT INTO public.season_rosters (
        season_id, player_id, org_id, division_id, is_captain, roster_status
      ) VALUES (
        v_registration.season_id, v_player_id, NULL, NULL, false, 'free_agent'
      )
      ON CONFLICT (season_id, player_id) DO NOTHING;
    END IF;
  END IF;

  UPDATE public.registrations
  SET status = v_target_status,
      player_id = CASE WHEN v_decision = 'approve' THEN v_player_id ELSE player_id END,
      reviewer_note = v_note,
      reviewed_at = now()
  WHERE id = v_registration.id;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, actor_discord_id,
    old_value_json, new_value_json, note
  ) VALUES (
    'registration_' || v_target_status,
    'registration', v_registration.id, p_actor_discord_id,
    jsonb_build_object('status', v_registration.status, 'playerId', v_registration.player_id),
    jsonb_build_object('status', v_target_status, 'playerId', v_player_id),
    v_note
  );

  INSERT INTO public.admin_audit_log (
    action, entity_type, entity_id, payload
  ) VALUES (
    CASE WHEN v_decision = 'approve' THEN 'approve_registration' ELSE 'update_registration' END,
    'registration', v_registration.id,
    jsonb_build_object(
      'status', v_target_status,
      'playerId', v_player_id,
      'reviewerNote', v_note,
      'actorDiscordId', p_actor_discord_id
    )
  );

  RETURN jsonb_build_object(
    'code', 'applied',
    'registrationId', v_registration.id,
    'finalStatus', v_target_status,
    'applied', true,
    'playerId', v_player_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_registration_review(text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_registration_review(text, text, text, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.resolve_match_report_review(
  p_match_report_id uuid,
  p_actor_discord_id text,
  p_games jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_report public.match_reports%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_game jsonb;
  v_player jsonb;
  v_game_number integer;
  v_winning_side text;
  v_player_side text;
  v_player_ign text;
  v_player_id text;
  v_supplied_org_id text;
  v_expected_org_id text;
  v_known_player_ign text;
  v_known_player_org_id text;
  v_known_roster_status text;
  v_game_count integer;
  v_home_count integer;
  v_away_count integer;
  v_home_score integer := 0;
  v_away_score integer := 0;
  v_seen_game_numbers integer[] := ARRAY[]::integer[];
  v_seen_igns text[];
  v_seen_player_ids text[];
  v_outbox_id uuid;
BEGIN
  IF p_match_report_id IS NULL
    OR p_actor_discord_id IS NULL OR btrim(p_actor_discord_id) = '' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Match-report ID and actor Discord ID are required.';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.admin_users
    WHERE discord_id = p_actor_discord_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Actor is not an authorized administrator.';
  END IF;

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0002',
      MESSAGE = 'Match report not found.';
  END IF;

  SELECT * INTO v_match
  FROM public.matches
  WHERE id = v_report.match_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0002',
      MESSAGE = 'Related match not found.';
  END IF;

  IF v_report.status = 'done' THEN
    RETURN jsonb_build_object(
      'code', 'already_processed',
      'reportId', v_report.id,
      'matchId', v_report.match_id,
      'finalStatus', v_report.status,
      'applied', false,
      'homeScore', v_report.home_score,
      'awayScore', v_report.away_score,
      'totalGames', v_report.total_games,
      'outboxIds', COALESCE(
        (
          SELECT jsonb_agg(outbox.id ORDER BY outbox.created_at)
          FROM public.operation_outbox outbox
          WHERE outbox.aggregate_type = 'match_report'
            AND outbox.aggregate_id = v_report.id::text
        ),
        '[]'::jsonb
      )
    );
  END IF;
  IF v_report.status <> 'review' THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'Match report is not ready for review.';
  END IF;
  IF v_match.status NOT IN ('scheduled', 'live') THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'Related match is not in a reviewable state.';
  END IF;
  IF v_match.season_id IS NULL
    OR v_report.season_id <> v_match.season_id
    OR v_report.division_id <> v_match.division_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Match report season or division does not match its related match.';
  END IF;

  IF p_games IS NULL OR jsonb_typeof(p_games) <> 'array' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Reviewed games must be a JSON array.';
  END IF;
  v_game_count := jsonb_array_length(p_games);
  IF v_game_count < 1 OR v_game_count > 5 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Reviewed payload must contain between one and five games.';
  END IF;

  FOR v_game IN SELECT value FROM jsonb_array_elements(p_games)
  LOOP
    IF jsonb_typeof(v_game) <> 'object'
      OR jsonb_typeof(v_game -> 'gameNumber') <> 'number'
      OR (v_game ->> 'gameNumber') !~ '^[0-9]+$' THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = 'Every game must have an integer gameNumber.';
    END IF;
    v_game_number := (v_game ->> 'gameNumber')::integer;
    IF v_game_number < 1 OR v_game_number > 5 THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = 'Game numbers must be between one and five.';
    END IF;
    IF v_game_number = ANY(v_seen_game_numbers) THEN
      RAISE EXCEPTION USING
        ERRCODE = '23505',
        MESSAGE = 'Reviewed payload contains a duplicate game number.';
    END IF;
    v_seen_game_numbers := array_append(v_seen_game_numbers, v_game_number);

    v_winning_side := v_game ->> 'winningSide';
    IF v_winning_side NOT IN ('home', 'away') THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = 'Every game must identify home or away as the winning side.';
    END IF;
    IF v_winning_side = 'home' THEN
      v_home_score := v_home_score + 1;
    ELSE
      v_away_score := v_away_score + 1;
    END IF;

    IF jsonb_typeof(v_game -> 'players') <> 'array'
      OR jsonb_array_length(v_game -> 'players') <> 10 THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = 'Every game must contain exactly ten player rows.';
    END IF;

    v_home_count := 0;
    v_away_count := 0;
    v_seen_igns := ARRAY[]::text[];
    v_seen_player_ids := ARRAY[]::text[];

    FOR v_player IN SELECT value FROM jsonb_array_elements(v_game -> 'players')
    LOOP
      IF jsonb_typeof(v_player) <> 'object' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Every player row must be a JSON object.';
      END IF;

      v_player_ign := btrim(COALESCE(v_player ->> 'playerIgn', ''));
      IF jsonb_typeof(v_player -> 'playerIgn') <> 'string'
        OR v_player_ign = '' OR length(v_player_ign) > 64 THEN
        RAISE EXCEPTION USING
          ERRCODE = '22023',
          MESSAGE = 'Every player row must include an IGN between 1 and 64 characters.';
      END IF;
      IF lower(v_player_ign) = ANY(v_seen_igns) THEN
        RAISE EXCEPTION USING
          ERRCODE = '23505',
          MESSAGE = 'A player IGN can appear only once per game.';
      END IF;
      v_seen_igns := array_append(v_seen_igns, lower(v_player_ign));

      v_player_side := v_player ->> 'side';
      IF v_player_side NOT IN ('home', 'away') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Every player row must identify a valid side.';
      END IF;
      IF v_player_side = 'home' THEN
        v_home_count := v_home_count + 1;
        v_expected_org_id := v_match.home_org_id;
      ELSE
        v_away_count := v_away_count + 1;
        v_expected_org_id := v_match.away_org_id;
      END IF;

      IF jsonb_typeof(v_player -> 'won') <> 'boolean'
        OR (v_player ->> 'won')::boolean IS DISTINCT FROM (v_player_side = v_winning_side) THEN
        RAISE EXCEPTION USING
          ERRCODE = '22023',
          MESSAGE = 'Player win flags must match the game winning side.';
      END IF;

      IF jsonb_typeof(v_player -> 'kills') <> 'number'
        OR jsonb_typeof(v_player -> 'deaths') <> 'number'
        OR jsonb_typeof(v_player -> 'assists') <> 'number'
        OR (v_player ->> 'kills') !~ '^[0-9]+$'
        OR (v_player ->> 'deaths') !~ '^[0-9]+$'
        OR (v_player ->> 'assists') !~ '^[0-9]+$'
        OR (v_player ->> 'kills')::numeric > 2147483647
        OR (v_player ->> 'deaths')::numeric > 2147483647
        OR (v_player ->> 'assists')::numeric > 2147483647 THEN
        RAISE EXCEPTION USING
          ERRCODE = '22023',
          MESSAGE = 'Kills, deaths, and assists must be nonnegative integers.';
      END IF;

      IF v_player ? 'damageDealt' AND v_player -> 'damageDealt' <> 'null'::jsonb
        AND (
          jsonb_typeof(v_player -> 'damageDealt') <> 'number'
          OR (v_player ->> 'damageDealt') !~ '^[0-9]+$'
          OR (v_player ->> 'damageDealt')::numeric > 2147483647
        ) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Damage dealt must be a nonnegative integer.';
      END IF;
      IF v_player ? 'damageMitigated' AND v_player -> 'damageMitigated' <> 'null'::jsonb
        AND (
          jsonb_typeof(v_player -> 'damageMitigated') <> 'number'
          OR (v_player ->> 'damageMitigated') !~ '^[0-9]+$'
          OR (v_player ->> 'damageMitigated')::numeric > 2147483647
        ) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Damage mitigated must be a nonnegative integer.';
      END IF;
      IF v_player ? 'godPlayed' AND v_player -> 'godPlayed' <> 'null'::jsonb
        AND (jsonb_typeof(v_player -> 'godPlayed') <> 'string' OR length(v_player ->> 'godPlayed') > 100) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'God played must be a string of at most 100 characters.';
      END IF;
      IF v_player ? 'role' AND v_player -> 'role' <> 'null'::jsonb
        AND (jsonb_typeof(v_player -> 'role') <> 'string' OR length(v_player ->> 'role') > 64) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Role must be a string of at most 64 characters.';
      END IF;

      v_supplied_org_id := NULLIF(btrim(COALESCE(v_player ->> 'orgId', '')), '');
      IF v_player ? 'orgId' AND v_player -> 'orgId' <> 'null'::jsonb
        AND (jsonb_typeof(v_player -> 'orgId') <> 'string' OR v_supplied_org_id IS NULL) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supplied organization ID must be a non-empty string.';
      END IF;
      IF v_supplied_org_id IS NOT NULL AND v_supplied_org_id <> v_expected_org_id THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Player organization does not match the selected side.';
      END IF;

      v_player_id := NULLIF(btrim(COALESCE(v_player ->> 'playerId', '')), '');
      IF v_player ? 'playerId' AND v_player -> 'playerId' <> 'null'::jsonb
        AND (jsonb_typeof(v_player -> 'playerId') <> 'string' OR v_player_id IS NULL OR length(v_player_id) > 128) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supplied player ID must be a non-empty string.';
      END IF;
      IF v_player_id IS NOT NULL THEN
        IF v_player_id = ANY(v_seen_player_ids) THEN
          RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'A player ID can appear only once per game.';
        END IF;
        v_seen_player_ids := array_append(v_seen_player_ids, v_player_id);

        SELECT players.ign, rosters.org_id, rosters.roster_status
        INTO v_known_player_ign, v_known_player_org_id, v_known_roster_status
        FROM public.players players
        JOIN public.season_rosters rosters
          ON rosters.player_id = players.id
         AND rosters.season_id = v_match.season_id
        WHERE players.id = v_player_id;
        IF NOT FOUND THEN
          RAISE EXCEPTION USING ERRCODE = '23503', MESSAGE = 'Supplied player is not rostered for the match season.';
        END IF;
        IF lower(btrim(v_known_player_ign)) <> lower(v_player_ign) THEN
          RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Supplied player ID does not match the player IGN.';
        END IF;
        IF v_known_roster_status <> 'active' OR v_known_player_org_id <> v_expected_org_id THEN
          RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Supplied player is not active on the expected organization.';
        END IF;
      END IF;
    END LOOP;

    IF v_home_count <> 5 OR v_away_count <> 5 THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = 'Every game must contain exactly five home and five away players.';
    END IF;
  END LOOP;

  IF v_home_score = v_away_score THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Reviewed series cannot end in a tie.';
  END IF;

  DELETE FROM public.player_match_stats
  WHERE match_report_id = v_report.id;

  INSERT INTO public.player_match_stats (
    match_report_id, match_id, player_id, player_ign, game_number, org_id,
    won, kills, deaths, assists, god_played, role, damage_dealt,
    damage_mitigated, season_id, division_id
  )
  SELECT
    v_report.id,
    v_match.id,
    NULLIF(btrim(COALESCE(player ->> 'playerId', '')), ''),
    btrim(player ->> 'playerIgn'),
    (game ->> 'gameNumber')::integer,
    CASE WHEN player ->> 'side' = 'home' THEN v_match.home_org_id ELSE v_match.away_org_id END,
    (player ->> 'won')::boolean,
    (player ->> 'kills')::integer,
    (player ->> 'deaths')::integer,
    (player ->> 'assists')::integer,
    NULLIF(btrim(COALESCE(player ->> 'godPlayed', '')), ''),
    NULLIF(btrim(COALESCE(player ->> 'role', '')), ''),
    CASE WHEN player ? 'damageDealt' AND player -> 'damageDealt' <> 'null'::jsonb
      THEN (player ->> 'damageDealt')::integer ELSE NULL END,
    CASE WHEN player ? 'damageMitigated' AND player -> 'damageMitigated' <> 'null'::jsonb
      THEN (player ->> 'damageMitigated')::integer ELSE NULL END,
    v_match.season_id,
    v_match.division_id
  FROM jsonb_array_elements(p_games) AS game
  CROSS JOIN LATERAL jsonb_array_elements(game -> 'players') AS player;

  UPDATE public.matches
  SET status = 'completed',
      home_score = v_home_score,
      away_score = v_away_score,
      winner_org_id = CASE
        WHEN v_home_score > v_away_score THEN home_org_id
        WHEN v_away_score > v_home_score THEN away_org_id
        ELSE NULL
      END,
      score = greatest(v_home_score, v_away_score)::text || '-' || least(v_home_score, v_away_score)::text
  WHERE id = v_match.id;

  UPDATE public.match_reports
  SET status = 'done',
      home_score = v_home_score,
      away_score = v_away_score,
      total_games = v_game_count,
      reviewed_at = now(),
      reviewed_by = p_actor_discord_id
  WHERE id = v_report.id;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, actor_discord_id,
    old_value_json, new_value_json
  ) VALUES (
    'match_report_resolved', 'match_report', v_report.id::text, p_actor_discord_id,
    jsonb_build_object('status', v_report.status, 'matchStatus', v_match.status),
    jsonb_build_object(
      'status', 'done', 'matchStatus', 'completed', 'matchId', v_match.id,
      'homeScore', v_home_score, 'awayScore', v_away_score,
      'totalGames', v_game_count, 'playerRows', v_game_count * 10
    )
  );

  INSERT INTO public.admin_audit_log (
    action, entity_type, entity_id, payload
  ) VALUES (
    'match_report_submitted', 'match_report', v_report.id::text,
    jsonb_build_object(
      'matchId', v_match.id,
      'homeScore', v_home_score,
      'awayScore', v_away_score,
      'totalGames', v_game_count,
      'playerCount', v_game_count * 10,
      'actorDiscordId', p_actor_discord_id
    )
  );

  v_outbox_id := public.enqueue_operation_outbox(
    'standings_recalculation',
    'match_report',
    v_report.id::text,
    'match_report_resolved',
    'match_report:' || v_report.id::text || ':resolved:standings_recalculation',
    jsonb_build_object(
      'reportId', v_report.id,
      'matchId', v_match.id,
      'seasonId', v_match.season_id,
      'outboxIdempotencyKey', 'match_report:' || v_report.id::text || ':standings'
    )
  );

  RETURN jsonb_build_object(
    'code', 'applied',
    'reportId', v_report.id,
    'matchId', v_match.id,
    'finalStatus', 'done',
    'applied', true,
    'homeScore', v_home_score,
    'awayScore', v_away_score,
    'totalGames', v_game_count,
    'outboxIds', jsonb_build_array(v_outbox_id)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_match_report_review(uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_match_report_review(uuid, text, jsonb)
  TO service_role;
