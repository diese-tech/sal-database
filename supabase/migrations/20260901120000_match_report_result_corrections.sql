-- Post-publication corrections for completed match reports.
--
-- `resolve_match_report_review` is deliberately terminal: once a report is
-- `done` it returns `already_processed` with `applied = false` and writes
-- nothing, so a retried or duplicated approval can never silently overwrite a
-- published league result. That property must not be weakened -- the bot and
-- outbox flows depend on it -- so repairing a published result gets its own
-- explicit, admin-only entry point instead, mirroring the post-persist scouter
-- correction path added in 20260805031500.
--
-- A correction names the revision it expects, carries a reason, and is keyed so
-- an exact retry after an uncertain network result returns the recorded outcome
-- rather than applying a second mutation.

CREATE TABLE public.match_report_corrections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  match_report_id uuid NOT NULL REFERENCES public.match_reports(id),
  correction_key text NOT NULL UNIQUE,
  actor_discord_id text NOT NULL,
  reason text NOT NULL,
  expected_revision integer NOT NULL,
  resulting_revision integer NOT NULL,
  request_json jsonb NOT NULL,
  old_value_json jsonb NOT NULL,
  new_value_json jsonb NOT NULL,
  result_json jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT match_report_corrections_key_check CHECK (
    btrim(correction_key) <> '' AND length(correction_key) <= 200
  ),
  CONSTRAINT match_report_corrections_actor_check CHECK (
    btrim(actor_discord_id) <> ''
  ),
  CONSTRAINT match_report_corrections_reason_check CHECK (
    btrim(reason) <> '' AND length(reason) <= 1000
  ),
  CONSTRAINT match_report_corrections_revision_check CHECK (
    expected_revision > 0 AND resulting_revision = expected_revision + 1
  )
);

CREATE INDEX match_report_corrections_report_created_idx
  ON public.match_report_corrections (match_report_id, created_at DESC);

ALTER TABLE public.match_report_corrections ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.match_report_corrections
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.match_report_corrections TO service_role;

COMMENT ON TABLE public.match_report_corrections IS
  'Private immutable receipts for audited corrections to published match-report results.';

-- Shared payload validation.
--
-- This is the same rule set the approval path enforces before publishing stats.
-- It is factored out here so the correction path cannot accept a payload that
-- approval would reject; `030_match_report_result_corrections.test.sql` asserts
-- both entry points reject an identical battery of invalid payloads with the
-- same SQLSTATE and message, which is what keeps the two in step.
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

  RETURN jsonb_build_object(
    'homeScore', v_home_score,
    'awayScore', v_away_score,
    'gameCount', v_game_count
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.correct_match_report_result(
  p_match_report_id uuid,
  p_actor_discord_id text,
  p_expected_revision integer,
  p_correction_key text,
  p_reason text,
  p_games jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
  v_actor_discord_id text := btrim(COALESCE(p_actor_discord_id, ''));
  v_correction_key text := btrim(COALESCE(p_correction_key, ''));
  v_reason text := btrim(COALESCE(p_reason, ''));
  v_existing public.match_report_corrections%ROWTYPE;
  v_report public.match_reports%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_totals jsonb;
  v_home_score integer;
  v_away_score integer;
  v_game_count integer;
  v_new_revision integer;
  v_old_rows jsonb;
  v_new_rows jsonb;
  v_old_value jsonb;
  v_new_value jsonb;
  v_publication jsonb;
  v_outbox_id uuid;
  v_correction_id uuid;
  v_result jsonb;
BEGIN
  IF p_match_report_id IS NULL OR v_actor_discord_id = '' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Match-report ID and actor Discord ID are required.';
  END IF;
  IF v_correction_key = '' OR length(v_correction_key) > 200 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A correction key between 1 and 200 characters is required.';
  END IF;
  IF v_reason = '' OR length(v_reason) > 1000 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A correction reason between 1 and 1000 characters is required.';
  END IF;
  IF p_expected_revision IS NULL OR p_expected_revision < 1 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A positive expected revision is required.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_users WHERE discord_id = v_actor_discord_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Actor is not an authorized administrator.';
  END IF;

  -- An exact retry after an uncertain network result returns the recorded
  -- outcome instead of correcting a second time.
  SELECT * INTO v_existing
  FROM public.match_report_corrections
  WHERE correction_key = v_correction_key;
  IF FOUND THEN
    IF v_existing.match_report_id <> p_match_report_id THEN
      RAISE EXCEPTION USING
        ERRCODE = '23505',
        MESSAGE = 'Correction key already recorded for a different match report.';
    END IF;
    RETURN v_existing.result_json || jsonb_build_object('code', 'already_corrected', 'applied', false);
  END IF;

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Match report not found.';
  END IF;

  PERFORM matches.id FROM public.matches AS matches
  WHERE matches.id = v_report.match_id
  FOR UPDATE;

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id
  FOR UPDATE;

  SELECT * INTO v_match
  FROM public.matches
  WHERE id = v_report.match_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Related match not found.';
  END IF;

  -- Only a published result is correctable here. A report still in review is
  -- approved through resolve_match_report_review, which owns that transition.
  IF v_report.status <> 'done' THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'Only a completed match report can be corrected.';
  END IF;
  IF v_report.season_id <> v_match.season_id
    OR v_report.division_id <> v_match.division_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Match report season or division does not match its related match.';
  END IF;
  IF v_report.revision <> p_expected_revision THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'Match report changed since it was loaded; reload and reapply the correction.';
  END IF;

  -- A correction republishes official stats, so every row must resolve to a
  -- canonical player exactly as approval requires.
  IF p_games IS NULL OR jsonb_typeof(p_games) <> 'array' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Reviewed games must be a JSON array.';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_games) AS game
    CROSS JOIN LATERAL jsonb_array_elements(game -> 'players') AS player
    WHERE NULLIF(btrim(COALESCE(player ->> 'playerId', '')), '') IS NULL
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Every official player stat must be linked before approval.';
  END IF;

  v_totals := private.validate_match_report_games(v_report.match_id, p_games);
  v_home_score := (v_totals ->> 'homeScore')::integer;
  v_away_score := (v_totals ->> 'awayScore')::integer;
  v_game_count := (v_totals ->> 'gameCount')::integer;
  v_new_revision := v_report.revision + 1;

  SELECT COALESCE(jsonb_agg(to_jsonb(stats) ORDER BY stats.game_number, stats.player_ign), '[]'::jsonb)
  INTO v_old_rows
  FROM public.player_match_stats stats
  WHERE stats.match_report_id = v_report.id;

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

  SELECT COALESCE(jsonb_agg(to_jsonb(stats) ORDER BY stats.game_number, stats.player_ign), '[]'::jsonb)
  INTO v_new_rows
  FROM public.player_match_stats stats
  WHERE stats.match_report_id = v_report.id;

  -- The match stays completed; only its recorded result changes.
  UPDATE public.matches
  SET home_score = v_home_score,
      away_score = v_away_score,
      winner_org_id = CASE
        WHEN v_home_score > v_away_score THEN home_org_id
        WHEN v_away_score > v_home_score THEN away_org_id
        ELSE NULL
      END,
      score = greatest(v_home_score, v_away_score)::text || '-' || least(v_home_score, v_away_score)::text
  WHERE id = v_match.id;

  UPDATE public.match_reports
  SET home_score = v_home_score,
      away_score = v_away_score,
      total_games = v_game_count,
      revision = v_new_revision,
      reviewed_at = now(),
      reviewed_by = v_actor_discord_id
  WHERE id = v_report.id;

  v_old_value := jsonb_build_object(
    'revision', v_report.revision,
    'homeScore', v_report.home_score,
    'awayScore', v_report.away_score,
    'totalGames', v_report.total_games,
    'matchStatus', v_match.status,
    'matchHomeScore', v_match.home_score,
    'matchAwayScore', v_match.away_score,
    'winnerOrgId', v_match.winner_org_id,
    'playerMatchStats', v_old_rows
  );
  v_new_value := jsonb_build_object(
    'revision', v_new_revision,
    'homeScore', v_home_score,
    'awayScore', v_away_score,
    'totalGames', v_game_count,
    'matchStatus', v_match.status,
    'matchHomeScore', v_home_score,
    'matchAwayScore', v_away_score,
    'winnerOrgId', CASE
      WHEN v_home_score > v_away_score THEN v_match.home_org_id
      WHEN v_away_score > v_home_score THEN v_match.away_org_id
      ELSE NULL
    END,
    'playerMatchStats', v_new_rows
  );

  -- Republish official player_stats and refresh every affected aggregate from
  -- the corrected rows.
  v_publication := private.publish_match_report_stats(
    v_report.id,
    v_actor_discord_id,
    'Republished during audited match-report correction.'
  );

  v_outbox_id := public.enqueue_operation_outbox(
    'standings_recalculation',
    'match_report',
    v_report.id::text,
    'match_report_corrected',
    'match_report:' || v_report.id::text || ':corrected:' || v_new_revision::text
      || ':standings_recalculation',
    jsonb_build_object(
      'reportId', v_report.id,
      'matchId', v_match.id,
      'seasonId', v_match.season_id,
      'revision', v_new_revision,
      'outboxIdempotencyKey',
        'match_report:' || v_report.id::text || ':corrected:' || v_new_revision::text || ':standings'
    )
  );

  v_result := jsonb_build_object(
    'code', 'applied',
    'reportId', v_report.id,
    'matchId', v_match.id,
    'finalStatus', 'done',
    'applied', true,
    'homeScore', v_home_score,
    'awayScore', v_away_score,
    'totalGames', v_game_count,
    'revision', v_new_revision,
    'publication', v_publication,
    'outboxIds', jsonb_build_array(v_outbox_id)
  );

  INSERT INTO public.match_report_corrections (
    match_report_id, correction_key, actor_discord_id, reason,
    expected_revision, resulting_revision, request_json,
    old_value_json, new_value_json, result_json
  ) VALUES (
    v_report.id, v_correction_key, v_actor_discord_id, v_reason,
    p_expected_revision, v_new_revision,
    jsonb_build_object('games', p_games),
    v_old_value, v_new_value, v_result
  )
  RETURNING id INTO v_correction_id;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, actor_discord_id,
    old_value_json, new_value_json, note
  ) VALUES (
    'match_report_corrected', 'match_report', v_report.id::text, v_actor_discord_id,
    v_old_value, v_new_value || jsonb_build_object('correctionId', v_correction_id), v_reason
  );

  INSERT INTO public.admin_audit_log (
    action, entity_type, entity_id, payload
  ) VALUES (
    'match_report_corrected', 'match_report', v_report.id::text,
    jsonb_build_object(
      'matchId', v_match.id,
      'correctionId', v_correction_id,
      'homeScore', v_home_score,
      'awayScore', v_away_score,
      'totalGames', v_game_count,
      'playerCount', v_game_count * 10,
      'revision', v_new_revision,
      'actorDiscordId', v_actor_discord_id
    )
  );

  RETURN v_result || jsonb_build_object('correctionId', v_correction_id);
END;
$$;

ALTER FUNCTION private.validate_match_report_games(text, jsonb) OWNER TO postgres;
ALTER FUNCTION public.correct_match_report_result(uuid, text, integer, text, text, jsonb)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION private.validate_match_report_games(text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.correct_match_report_result(uuid, text, integer, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.correct_match_report_result(uuid, text, integer, text, text, jsonb)
  TO service_role;

COMMENT ON FUNCTION private.validate_match_report_games(text, jsonb) IS
  'Validates a reviewed match-report game payload against its match and season roster, returning the derived series score and game count.';
COMMENT ON FUNCTION public.correct_match_report_result(uuid, text, integer, text, text, jsonb) IS
  'Applies one audited, revision-checked correction to a published match report, republishing official stats and enqueueing standings recalculation; an exact retry returns the recorded receipt without mutating again.';
