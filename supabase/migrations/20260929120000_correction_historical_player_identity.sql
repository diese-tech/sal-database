-- Let corrections credit historical players.
--
-- `private.validate_match_report_games` required every supplied player to hold
-- an active season roster row on the expected organization and in the match
-- division. That is right for a live submission, but a correction repairs
-- published results, and historical matches involve players who filled in,
-- subbed, or were traded without that movement ever being recorded before the
-- import. Such a player has no roster row (or one for a different team or
-- division), so the correction was rejected and their stats could not be put
-- on the right player.
--
-- The validator is now identity-based: a supplied player ID must exist and
-- must match the supplied IGN. Roster membership, active status, organization
-- and division are no longer required. The organization on each stat row is
-- still derived from the side (home or away) the player played on, and every
-- other payload rule is unchanged. The validator is called only by
-- `correct_match_report_result`, so the approval path is not affected.
--
-- Forward-only: the previous definition lives in
-- 20260901120000_match_report_result_corrections.sql.

CREATE OR REPLACE FUNCTION private.validate_match_report_games(
  p_match_id text,
  p_games jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
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
  v_game_count integer;
  v_home_count integer;
  v_away_count integer;
  v_home_score integer := 0;
  v_away_score integer := 0;
  v_seen_game_numbers integer[] := ARRAY[]::integer[];
  v_seen_igns text[];
  v_seen_player_ids text[];
BEGIN
  SELECT * INTO v_match FROM public.matches WHERE id = p_match_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Related match not found.';
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

        -- Identity is the whole rule. A player who filled in, subbed, or was
        -- traded may have no season roster row, or one for another team or
        -- division, because those moves were never recorded before the
        -- historical import. Their stats still belong to them, so the player
        -- must exist and the IGN must match; the organization stamped on the
        -- stat row comes from the side they played on.
        SELECT players.ign
        INTO v_known_player_ign
        FROM public.players players
        WHERE players.id = v_player_id;
        IF NOT FOUND THEN
          RAISE EXCEPTION USING ERRCODE = '23503', MESSAGE = 'Supplied player does not exist.';
        END IF;
        IF lower(btrim(v_known_player_ign)) <> lower(v_player_ign) THEN
          RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Supplied player ID does not match the player IGN.';
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

  RETURN jsonb_build_object(
    'homeScore', v_home_score,
    'awayScore', v_away_score,
    'gameCount', v_game_count
  );
END;
$$;

ALTER FUNCTION private.validate_match_report_games(text, jsonb) OWNER TO postgres;

REVOKE ALL ON FUNCTION private.validate_match_report_games(text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION private.validate_match_report_games(text, jsonb) IS
  'Validates a reviewed match-report game payload against its match, returning the derived series score and game count. Supplied players are checked for existence and IGN identity, not current roster membership, so historical players can be credited.';
