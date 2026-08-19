-- Complete the official-match capture boundary: one pending result action owns
-- one recoverable report, one Discord host can exchange short-lived one-time
-- capabilities, and reviewed rows publish to the canonical public stat store.

ALTER TABLE public.match_reports
  ADD COLUMN pending_action_id text,
  ADD COLUMN revision integer NOT NULL DEFAULT 1,
  ADD COLUMN host_discord_id text,
  ADD COLUMN host_submitted_at timestamptz,
  ADD CONSTRAINT match_reports_pending_action_id_fkey
    FOREIGN KEY (pending_action_id) REFERENCES public.pending_actions(id),
  ADD CONSTRAINT match_reports_pending_action_id_key UNIQUE (pending_action_id),
  ADD CONSTRAINT match_reports_revision_check CHECK (revision > 0),
  ADD CONSTRAINT match_reports_host_discord_id_check CHECK (
    host_discord_id IS NULL OR btrim(host_discord_id) <> ''
  ),
  ADD CONSTRAINT match_reports_host_submission_check CHECK (
    (status <> 'host_review' OR (host_discord_id IS NOT NULL AND host_submitted_at IS NOT NULL))
    AND (
      host_submitted_at IS NULL
      OR (host_discord_id IS NOT NULL AND status IN ('review', 'host_review', 'done'))
    )
  );

ALTER TABLE public.match_reports
  DROP CONSTRAINT match_reports_status_check,
  ADD CONSTRAINT match_reports_status_check
    CHECK (status IN ('pending', 'extracting', 'review', 'host_review', 'done', 'cancelled'));

-- The official stat table previously identified only the pending-stat producer.
-- Record match-report ownership explicitly so a report can replace exactly its
-- own set without silently adopting or deleting rows from another producer.
ALTER TABLE public.player_stats
  ADD COLUMN match_report_id uuid,
  ADD CONSTRAINT player_stats_match_report_id_fkey
    FOREIGN KEY (match_report_id) REFERENCES public.match_reports(id),
  ADD CONSTRAINT player_stats_single_provenance_check CHECK (
    NOT (pending_stat_record_id IS NOT NULL AND match_report_id IS NOT NULL)
  );

CREATE INDEX idx_player_stats_match_report
  ON public.player_stats (match_report_id)
  WHERE match_report_id IS NOT NULL;

-- The match row lock serializes canonical RPC callers; this partial key also
-- protects the invariant from legacy service-role clients that still insert
-- pending actions directly.
CREATE UNIQUE INDEX pending_actions_open_match_result_match_key
  ON public.pending_actions (match_id)
  WHERE type = 'match_result' AND status IN ('pending', 'pending_info');

CREATE TABLE public.match_report_host_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  match_report_id uuid NOT NULL REFERENCES public.match_reports(id) ON DELETE CASCADE,
  host_discord_id text NOT NULL CHECK (btrim(host_discord_id) <> ''),
  token_hash text NOT NULL,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT match_report_host_tokens_report_host_key
    UNIQUE (match_report_id, host_discord_id),
  CONSTRAINT match_report_host_tokens_token_hash_key UNIQUE (token_hash),
  CONSTRAINT match_report_host_tokens_hash_check
    CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT match_report_host_tokens_consumed_check
    CHECK (consumed_at IS NULL OR consumed_at >= created_at)
);

-- The token hash uniqueness constraint is a btree lookup index. Keep a named
-- expiry index as well so routine cleanup never scans the private token table.
CREATE INDEX match_report_host_tokens_expiry_idx
  ON public.match_report_host_tokens (expires_at);

ALTER TABLE public.match_report_host_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.match_report_host_tokens FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.match_report_host_tokens TO service_role;

COMMENT ON TABLE public.match_report_host_tokens IS
  'Private one-time capabilities bound to one match report and its verified Discord host; raw tokens are never stored.';
COMMENT ON CONSTRAINT match_report_host_tokens_token_hash_key
  ON public.match_report_host_tokens IS
  'Unique btree lookup for a SHA-256 token hash; also prevents capability collision.';

CREATE OR REPLACE FUNCTION public.ensure_match_report_for_pending_action(
  p_pending_action_id text,
  p_host_discord_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_action public.pending_actions%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_report public.match_reports%ROWTYPE;
  v_host_discord_id text := NULLIF(btrim(COALESCE(p_host_discord_id, '')), '');
  v_created boolean := false;
  v_repaired boolean := false;
  v_rebound boolean := false;
  v_old_pending_action_id text;
  v_old_host_discord_id text;
  v_old_status text;
  v_old_revision integer;
  v_old_report_snapshot jsonb;
BEGIN
  IF p_pending_action_id IS NULL OR btrim(p_pending_action_id) = ''
    OR v_host_discord_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Pending-action ID and host Discord ID are required.';
  END IF;

  SELECT * INTO v_action
  FROM public.pending_actions
  WHERE id = btrim(p_pending_action_id);
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Pending action not found.';
  END IF;
  IF v_action.type <> 'match_result' OR v_action.match_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Only a match-result pending action can own a match report.';
  END IF;
  IF v_action.requested_by_discord_id <> v_host_discord_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Only the pending-action requester can host its match report.';
  END IF;
  IF v_action.status NOT IN ('pending', 'pending_info') THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'The pending action is no longer open for match capture.';
  END IF;

  SELECT * INTO v_match
  FROM public.matches
  WHERE id = v_action.match_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Related match not found.';
  END IF;

  SELECT * INTO v_action
  FROM public.pending_actions
  WHERE id = btrim(p_pending_action_id)
  FOR UPDATE;
  IF NOT FOUND OR v_action.type <> 'match_result'
    OR v_action.match_id IS DISTINCT FROM v_match.id THEN
    RAISE EXCEPTION USING
      ERRCODE = '40001',
      MESSAGE = 'Pending action changed while its match report was being linked.';
  END IF;
  IF v_action.requested_by_discord_id <> v_host_discord_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Only the pending-action requester can host its match report.';
  END IF;
  IF v_action.status NOT IN ('pending', 'pending_info') THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'The pending action is no longer open for match capture.';
  END IF;
  IF v_match.status NOT IN ('scheduled', 'live') OR v_match.season_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'Related match is not open and season-scoped for capture.';
  END IF;
  IF v_action.division_id IS DISTINCT FROM v_match.division_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Pending-action division does not match its related match.';
  END IF;

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE match_id = v_match.id
  FOR UPDATE;

  IF FOUND THEN
    IF v_report.pending_action_id IS NOT NULL
      AND v_report.pending_action_id <> v_action.id
      AND v_report.status <> 'cancelled' THEN
      RAISE EXCEPTION USING
        ERRCODE = '23514',
        MESSAGE = 'The match report is already linked to a different pending action.';
    END IF;
    IF v_report.season_id <> v_match.season_id
      OR v_report.division_id <> v_match.division_id THEN
      RAISE EXCEPTION USING
        ERRCODE = '23514',
        MESSAGE = 'Existing match-report scope conflicts with its related match.';
    END IF;
    IF v_report.status <> 'cancelled'
      AND v_report.submitted_by <> v_host_discord_id THEN
      RAISE EXCEPTION USING
        ERRCODE = '42501',
        MESSAGE = 'Existing match report belongs to a different submitter.';
    END IF;
    IF v_report.status <> 'cancelled'
      AND v_report.host_discord_id IS NOT NULL
      AND v_report.host_discord_id <> v_host_discord_id THEN
      RAISE EXCEPTION USING
        ERRCODE = '42501',
        MESSAGE = 'The match report is already bound to another host.';
    END IF;

    IF v_report.status = 'cancelled' THEN
      v_old_pending_action_id := v_report.pending_action_id;
      v_old_host_discord_id := v_report.host_discord_id;
      v_old_status := v_report.status;
      v_old_revision := v_report.revision;
      SELECT to_jsonb(v_report) || jsonb_build_object(
        'playerMatchStats', COALESCE(
          jsonb_agg(to_jsonb(stats) ORDER BY stats.game_number, stats.player_ign),
          '[]'::jsonb
        )
      )
      INTO v_old_report_snapshot
      FROM public.player_match_stats AS stats
      WHERE stats.match_report_id = v_report.id;

      IF EXISTS (
        SELECT 1
        FROM public.player_stats
        WHERE match_report_id = v_report.id
      ) THEN
        RAISE EXCEPTION USING
          ERRCODE = '23514',
          MESSAGE = 'A cancelled report with published official stats cannot be rebound.';
      END IF;

      DELETE FROM public.match_report_host_tokens
      WHERE match_report_id = v_report.id;
      DELETE FROM public.player_match_stats
      WHERE match_report_id = v_report.id;

      UPDATE public.match_reports
      SET pending_action_id = v_action.id,
          host_discord_id = v_host_discord_id,
          submitted_by = v_host_discord_id,
          status = 'pending',
          revision = revision + 1,
          host_submitted_at = NULL,
          home_score = NULL,
          away_score = NULL,
          total_games = NULL,
          screenshot_urls = '{}'::text[],
          extracted_data = NULL,
          reviewed_at = NULL,
          reviewed_by = NULL
      WHERE id = v_report.id
      RETURNING * INTO v_report;
      v_rebound := true;
    ELSIF v_report.pending_action_id IS NULL OR v_report.host_discord_id IS NULL THEN
      v_old_pending_action_id := v_report.pending_action_id;
      v_old_host_discord_id := v_report.host_discord_id;
      UPDATE public.match_reports
      SET pending_action_id = COALESCE(pending_action_id, v_action.id),
          host_discord_id = COALESCE(host_discord_id, v_host_discord_id)
      WHERE id = v_report.id
      RETURNING * INTO v_report;
      v_repaired := true;
    END IF;
  ELSE
    INSERT INTO public.match_reports (
      match_id, season_id, division_id, status, submitted_by,
      pending_action_id, host_discord_id
    ) VALUES (
      v_match.id, v_match.season_id, v_match.division_id, 'pending',
      v_host_discord_id, v_action.id, v_host_discord_id
    )
    RETURNING * INTO v_report;
    v_created := true;
  END IF;

  IF v_created OR v_repaired OR v_rebound THEN
    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, pending_action_id,
      actor_discord_id, old_value_json, new_value_json
    ) VALUES (
      CASE
        WHEN v_created THEN 'match_report_created'
        WHEN v_rebound THEN 'match_report_rebound'
        ELSE 'match_report_link_repaired'
      END,
      'match_report', v_report.id::text, v_action.id, v_host_discord_id,
      CASE
        WHEN v_created THEN NULL
        WHEN v_rebound THEN v_old_report_snapshot
        ELSE jsonb_build_object(
          'pendingActionId', v_old_pending_action_id,
          'hostDiscordId', v_old_host_discord_id,
          'status', COALESCE(v_old_status, v_report.status),
          'revision', COALESCE(v_old_revision, v_report.revision)
        )
      END,
      jsonb_build_object(
        'pendingActionId', v_action.id,
        'matchId', v_match.id,
        'seasonId', v_match.season_id,
        'divisionId', v_match.division_id,
        'hostDiscordId', v_host_discord_id,
        'status', v_report.status,
        'revision', v_report.revision
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'code', CASE WHEN v_created THEN 'created' ELSE 'existing' END,
    'created', v_created,
    'reportId', v_report.id,
    'pendingActionId', v_action.id,
    'matchId', v_match.id,
    'hostDiscordId', v_report.host_discord_id,
    'status', v_report.status,
    'revision', v_report.revision
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.create_match_result_action_with_report(
  p_match_id text,
  p_host_discord_id text,
  p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_match public.matches%ROWTYPE;
  v_action public.pending_actions%ROWTYPE;
  v_report_result jsonb;
  v_host_discord_id text := NULLIF(btrim(COALESCE(p_host_discord_id, '')), '');
  v_action_created boolean := false;
  v_winner_org_id text;
  v_score text;
  v_winner_games integer;
  v_loser_games integer;
BEGIN
  IF p_match_id IS NULL OR btrim(p_match_id) = '' OR v_host_discord_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Match ID and host Discord ID are required.';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Match-result payload must be a JSON object.';
  END IF;

  SELECT * INTO v_match
  FROM public.matches
  WHERE id = btrim(p_match_id)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Match not found.';
  END IF;
  IF v_match.status NOT IN ('scheduled', 'live') OR v_match.season_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'Match is not open and season-scoped for result capture.';
  END IF;

  v_winner_org_id := p_payload ->> 'winnerOrgId';
  v_score := p_payload ->> 'score';
  IF v_winner_org_id IS NULL
    OR v_winner_org_id NOT IN (v_match.home_org_id, v_match.away_org_id) THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Result winner must be one of the match organizations.';
  END IF;
  IF v_score IS NULL OR v_score !~ '^[0-9]+-[0-9]+$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Result score must use winner-loser format.';
  END IF;
  v_winner_games := split_part(v_score, '-', 1)::integer;
  v_loser_games := split_part(v_score, '-', 2)::integer;
  IF v_winner_games <= v_loser_games
    OR jsonb_typeof(p_payload -> 'parsed') IS DISTINCT FROM 'object'
    OR (p_payload #>> '{parsed,winnerGames}')::integer IS DISTINCT FROM v_winner_games
    OR (p_payload #>> '{parsed,loserGames}')::integer IS DISTINCT FROM v_loser_games
    OR (p_payload #>> '{parsed,gamesPlayed}')::integer IS DISTINCT FROM v_winner_games + v_loser_games
    OR (p_payload #>> '{parsed,expectedScreenshots}')::integer IS DISTINCT FROM
      v_winner_games + v_loser_games THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Parsed result totals do not match the score.';
  END IF;

  SELECT * INTO v_action
  FROM public.pending_actions
  WHERE match_id = v_match.id
    AND type = 'match_result'
    AND status IN ('pending', 'pending_info')
  ORDER BY created_at, id
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    BEGIN
      INSERT INTO public.pending_actions (
        type, requested_by_discord_id, match_id, division_id, payload_json
      ) VALUES (
        'match_result', v_host_discord_id, v_match.id, v_match.division_id, p_payload
      )
      RETURNING * INTO v_action;
      v_action_created := true;
    EXCEPTION WHEN unique_violation THEN
      -- A rolling-deploy legacy client may still insert directly without the
      -- match lock. Recover the row protected by the partial unique index.
      SELECT * INTO v_action
      FROM public.pending_actions
      WHERE match_id = v_match.id
        AND type = 'match_result'
        AND status IN ('pending', 'pending_info')
      ORDER BY created_at, id
      LIMIT 1
      FOR UPDATE;
      IF NOT FOUND THEN
        RAISE;
      END IF;
    END;

    IF v_action_created THEN
      INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, pending_action_id,
      actor_discord_id, old_value_json, new_value_json
      ) VALUES (
        'pending_action_created', 'pending_action', v_action.id, v_action.id,
        v_host_discord_id, NULL,
        jsonb_build_object(
          'status', v_action.status,
          'type', v_action.type,
          'projectionOwner', 'synchronous_bot'
        )
      );
    END IF;
  END IF;

  v_report_result := public.ensure_match_report_for_pending_action(
    v_action.id,
    v_action.requested_by_discord_id
  );

  RETURN jsonb_build_object(
    'code', CASE WHEN v_action_created THEN 'created' ELSE 'existing' END,
    'created', v_action_created,
    'actionId', v_action.id,
    'pendingActionId', v_action.id,
    'reportId', v_report_result ->> 'reportId',
    'matchId', v_match.id,
    'hostDiscordId', v_action.requested_by_discord_id,
    'status', v_report_result ->> 'status',
    'revision', (v_report_result ->> 'revision')::integer
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.issue_match_report_host_token(
  p_match_report_id uuid,
  p_host_discord_id text,
  p_token_hash text,
  p_expires_at timestamptz
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_report public.match_reports%ROWTYPE;
  v_token public.match_report_host_tokens%ROWTYPE;
  v_host_discord_id text := NULLIF(btrim(COALESCE(p_host_discord_id, '')), '');
  v_token_hash text := lower(btrim(COALESCE(p_token_hash, '')));
BEGIN
  IF p_match_report_id IS NULL OR v_host_discord_id IS NULL
    OR v_token_hash !~ '^[0-9a-f]{64}$' OR p_expires_at IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Report, host, SHA-256 token hash, and expiry are required.';
  END IF;
  IF p_expires_at <= now() OR p_expires_at > now() + interval '24 hours' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Host-token expiry must be in the next 24 hours.';
  END IF;

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Match report not found.';
  END IF;

  PERFORM matches.id
  FROM public.matches AS matches
  WHERE matches.id = v_report.match_id
  FOR UPDATE;

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id
  FOR UPDATE;
  IF v_report.status IN ('done', 'cancelled') THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'A terminal match report cannot issue a host token.';
  END IF;
  IF v_report.host_discord_id IS NULL THEN
    UPDATE public.match_reports
    SET host_discord_id = v_host_discord_id
    WHERE id = v_report.id
    RETURNING * INTO v_report;
  ELSIF v_report.host_discord_id <> v_host_discord_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Only the bound match-report host can receive a token.';
  END IF;

  INSERT INTO public.match_report_host_tokens (
    match_report_id, host_discord_id, token_hash, expires_at
  ) VALUES (
    v_report.id, v_host_discord_id, v_token_hash, p_expires_at
  )
  ON CONFLICT (match_report_id, host_discord_id) DO UPDATE
  SET token_hash = EXCLUDED.token_hash,
      expires_at = EXCLUDED.expires_at,
      consumed_at = NULL,
      created_at = now()
  RETURNING * INTO v_token;

  RETURN jsonb_build_object(
    'matchReportId', v_token.match_report_id,
    'hostDiscordId', v_token.host_discord_id,
    'expiresAt', v_token.expires_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.consume_match_report_host_token(
  p_token_hash text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_token public.match_report_host_tokens%ROWTYPE;
  v_token_hash text := lower(btrim(COALESCE(p_token_hash, '')));
BEGIN
  -- Invalid shapes deliberately follow the same NULL response path as unknown,
  -- expired, and already-consumed capabilities.
  IF v_token_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN NULL;
  END IF;

  SELECT tokens.* INTO v_token
  FROM public.match_report_host_tokens AS tokens
  JOIN public.match_reports AS reports ON reports.id = tokens.match_report_id
  WHERE tokens.token_hash = v_token_hash
    AND reports.status NOT IN ('done', 'cancelled')
  FOR UPDATE;

  IF NOT FOUND OR v_token.consumed_at IS NOT NULL OR v_token.expires_at <= now() THEN
    RETURN NULL;
  END IF;

  UPDATE public.match_report_host_tokens
  SET consumed_at = now()
  WHERE id = v_token.id;

  RETURN jsonb_build_object(
    'matchReportId', v_token.match_report_id,
    'hostDiscordId', v_token.host_discord_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.match_report_extraction_diagnostics(
  p_match_report_id uuid,
  p_games jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_report public.match_reports%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_game_count integer;
  v_result jsonb;
BEGIN
  IF p_match_report_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Match-report ID is required.';
  END IF;

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Match report not found.';
  END IF;

  SELECT * INTO v_match
  FROM public.matches
  WHERE id = v_report.match_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Related match not found.';
  END IF;
  IF v_match.season_id IS NULL
    OR v_report.season_id <> v_match.season_id
    OR v_report.division_id <> v_match.division_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Match-report season or division conflicts with its related match.';
  END IF;

  IF p_games IS NULL OR jsonb_typeof(p_games) <> 'array' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Match-report extraction must be a JSON array.';
  END IF;
  v_game_count := jsonb_array_length(p_games);
  IF v_game_count < 1 OR v_game_count > 5 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Match-report extraction must contain between one and five games.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_games) AS game
    WHERE jsonb_typeof(game) <> 'object'
      OR jsonb_typeof(game -> 'gameNumber') <> 'number'
      OR (game ->> 'gameNumber') !~ '^[0-9]+$'
      OR (game ->> 'gameNumber')::numeric > 2147483647
      OR (game ->> 'gameNumber')::integer < 1
      OR (game ->> 'gameNumber')::integer > 5
      OR game ->> 'winningSide' NOT IN ('home', 'away')
      OR jsonb_typeof(game -> 'players') IS DISTINCT FROM 'array'
      OR jsonb_array_length(game -> 'players') <> 10
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Every extracted game needs a unique 1-5 game number, winner, and ten player rows.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_games) AS game
    GROUP BY (game ->> 'gameNumber')::integer
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23505',
      MESSAGE = 'Match-report extraction contains a duplicate game number.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_games) AS game
    CROSS JOIN LATERAL jsonb_array_elements(game -> 'players') AS player
    WHERE jsonb_typeof(player) <> 'object'
      OR NULLIF(btrim(COALESCE(player ->> 'playerIgn', player ->> 'ign', '')), '') IS NULL
      OR length(btrim(COALESCE(player ->> 'playerIgn', player ->> 'ign', ''))) > 100
      OR player ->> 'side' NOT IN ('home', 'away')
      OR jsonb_typeof(player -> 'kills') <> 'number'
      OR jsonb_typeof(player -> 'deaths') <> 'number'
      OR jsonb_typeof(player -> 'assists') <> 'number'
      OR (player ->> 'kills') !~ '^[0-9]+$'
      OR (player ->> 'deaths') !~ '^[0-9]+$'
      OR (player ->> 'assists') !~ '^[0-9]+$'
      OR (player ->> 'kills')::numeric > 2147483647
      OR (player ->> 'deaths')::numeric > 2147483647
      OR (player ->> 'assists')::numeric > 2147483647
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Every extracted player needs an IGN, valid side, and nonnegative integer K/D/A.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_games) AS game
    CROSS JOIN LATERAL jsonb_array_elements(game -> 'players') AS player
    GROUP BY (game ->> 'gameNumber')::integer
    HAVING count(*) FILTER (WHERE player ->> 'side' = 'home') <> 5
      OR count(*) FILTER (WHERE player ->> 'side' = 'away') <> 5
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Every extracted game must contain five home and five away players.';
  END IF;

  WITH player_input AS (
    SELECT
      (game ->> 'gameNumber')::integer AS game_number,
      game_ordinality::integer - 1 AS game_index,
      player_ordinality::integer - 1 AS player_index,
      player ->> 'side' AS side,
      btrim(COALESCE(player ->> 'playerIgn', player ->> 'ign')) AS raw_ign,
      lower(btrim(COALESCE(player ->> 'playerIgn', player ->> 'ign'))) AS normalized_ign,
      NULLIF(btrim(COALESCE(player ->> 'playerId', '')), '') AS supplied_player_id,
      CASE
        WHEN player ->> 'side' = 'home' THEN v_match.home_org_id
        ELSE v_match.away_org_id
      END AS expected_org_id
    FROM jsonb_array_elements(p_games) WITH ORDINALITY
      AS games(game, game_ordinality)
    CROSS JOIN LATERAL jsonb_array_elements(game -> 'players') WITH ORDINALITY
      AS players(player, player_ordinality)
  ), identity_matches AS (
    SELECT
      input.*,
      count(players.id)::integer AS player_match_count,
      CASE WHEN count(players.id) = 1 THEN min(players.id) END AS player_id,
      count(*) OVER (
        PARTITION BY input.game_number, input.normalized_ign
      )::integer AS game_ign_count,
      count(*) FILTER (WHERE input.supplied_player_id IS NOT NULL) OVER (
        PARTITION BY input.game_number, input.supplied_player_id
      )::integer AS supplied_player_count
    FROM player_input AS input
    LEFT JOIN public.season_rosters AS rosters
      ON rosters.season_id = v_match.season_id
     AND rosters.org_id = input.expected_org_id
     AND rosters.division_id = v_match.division_id
     AND rosters.roster_status = 'active'
    LEFT JOIN public.players AS players
      ON players.id = rosters.player_id
     AND players.archived_at IS NULL
     AND players.deletion_scheduled_at IS NULL
     AND lower(btrim(players.ign)) = input.normalized_ign
     AND (
       input.supplied_player_id IS NULL
       OR players.id = input.supplied_player_id
     )
    GROUP BY
      input.game_number, input.game_index, input.player_index, input.side,
      input.raw_ign, input.normalized_ign, input.supplied_player_id,
      input.expected_org_id
  ), player_results AS (
    SELECT
      matches.*,
      CASE
        WHEN matches.game_ign_count > 1 OR matches.supplied_player_count > 1
          THEN 'duplicate'
        WHEN matches.player_match_count = 0 THEN 'unlinked'
        WHEN matches.player_match_count > 1 THEN 'ambiguous'
        ELSE 'linked'
      END AS identity_status
    FROM identity_matches AS matches
  ), game_results AS (
    SELECT
      game_number,
      min(game_index) AS game_index,
      jsonb_agg(
        jsonb_build_object(
          'index', player_index,
          'side', side,
          'rawIgn', raw_ign,
          'playerId', player_id,
          'identityStatus', identity_status
        ) ORDER BY player_index
      ) AS players
    FROM player_results
    GROUP BY game_number
  )
  SELECT jsonb_build_object(
    'gameCount', v_game_count,
    'duplicateIgns', COALESCE((
      SELECT jsonb_agg(DISTINCT raw_ign)
      FROM player_results WHERE identity_status = 'duplicate'
    ), '[]'::jsonb),
    'unlinkedIgns', COALESCE((
      SELECT jsonb_agg(DISTINCT raw_ign)
      FROM player_results WHERE identity_status = 'unlinked'
    ), '[]'::jsonb),
    'ambiguousIgns', COALESCE((
      SELECT jsonb_agg(DISTINCT raw_ign)
      FROM player_results WHERE identity_status = 'ambiguous'
    ), '[]'::jsonb),
    'games', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('gameNumber', game_number, 'players', players)
        ORDER BY game_index
      )
      FROM game_results
    ), '[]'::jsonb)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.revise_match_report_extraction(
  p_match_report_id uuid,
  p_host_discord_id text,
  p_expected_revision integer,
  p_games jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_report public.match_reports%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_diagnostics jsonb;
  v_host_discord_id text := NULLIF(btrim(COALESCE(p_host_discord_id, '')), '');
BEGIN
  IF p_match_report_id IS NULL OR v_host_discord_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Match-report ID and host Discord ID are required.';
  END IF;

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Match report not found.';
  END IF;

  SELECT * INTO v_match
  FROM public.matches
  WHERE id = v_report.match_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Related match not found.';
  END IF;

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id
  FOR UPDATE;
  IF v_report.host_discord_id <> v_host_discord_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Only the match-report host can revise it.';
  END IF;
  IF v_report.status <> 'review' THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'Only a report in host review can be revised.';
  END IF;
  IF p_expected_revision IS NULL OR v_report.revision <> p_expected_revision THEN
    RAISE EXCEPTION USING
      ERRCODE = '40001',
      MESSAGE = 'Match report revision is stale.';
  END IF;

  v_diagnostics := public.match_report_extraction_diagnostics(v_report.id, p_games);

  UPDATE public.match_reports
  SET extracted_data = p_games,
      revision = revision + 1
  WHERE id = v_report.id
  RETURNING * INTO v_report;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, pending_action_id,
    actor_discord_id, old_value_json, new_value_json
  ) VALUES (
    'match_report_host_revised', 'match_report', v_report.id::text,
    v_report.pending_action_id, v_host_discord_id,
    jsonb_build_object('revision', p_expected_revision),
    jsonb_build_object(
      'revision', v_report.revision,
      'duplicateCount', jsonb_array_length(v_diagnostics -> 'duplicateIgns'),
      'unlinkedCount', jsonb_array_length(v_diagnostics -> 'unlinkedIgns'),
      'ambiguousCount', jsonb_array_length(v_diagnostics -> 'ambiguousIgns')
    )
  );

  RETURN jsonb_build_object(
    'code', 'revised',
    'applied', true,
    'reportId', v_report.id,
    'revision', v_report.revision,
    'status', v_report.status,
    'games', v_report.extracted_data,
    'diagnostics', v_diagnostics
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_match_report_host_review(
  p_match_report_id uuid,
  p_host_discord_id text,
  p_expected_revision integer
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_report public.match_reports%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_diagnostics jsonb;
  v_host_discord_id text := NULLIF(btrim(COALESCE(p_host_discord_id, '')), '');
  v_outbox_id uuid;
  v_existing_outbox_ids jsonb;
BEGIN
  IF p_match_report_id IS NULL OR v_host_discord_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Match-report ID and host Discord ID are required.';
  END IF;

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Match report not found.';
  END IF;

  SELECT * INTO v_match
  FROM public.matches
  WHERE id = v_report.match_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Related match not found.';
  END IF;

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id
  FOR UPDATE;
  IF v_report.host_discord_id <> v_host_discord_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Only the match-report host can submit it.';
  END IF;
  IF p_expected_revision IS NULL OR v_report.revision <> p_expected_revision THEN
    RAISE EXCEPTION USING
      ERRCODE = '40001',
      MESSAGE = 'Match report revision is stale.';
  END IF;

  IF v_report.status = 'host_review' THEN
    SELECT COALESCE(jsonb_agg(outbox.id ORDER BY outbox.created_at), '[]'::jsonb)
    INTO v_existing_outbox_ids
    FROM public.operation_outbox AS outbox
    WHERE outbox.aggregate_type = 'match_report'
      AND outbox.aggregate_id = v_report.id::text
      AND outbox.event_type = 'match_report_host_submitted'
      AND outbox.deduplication_key =
        'match_report:' || v_report.id::text || ':host-submitted:r' || v_report.revision::text;

    RETURN jsonb_build_object(
      'code', 'already_submitted',
      'applied', false,
      'reportId', v_report.id,
      'pendingActionId', v_report.pending_action_id,
      'matchId', v_report.match_id,
      'revision', v_report.revision,
      'status', v_report.status,
      'hostSubmittedAt', v_report.host_submitted_at,
      'outboxIds', v_existing_outbox_ids
    );
  END IF;
  IF v_report.status <> 'review' THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'Only a reviewed extraction can be submitted by its host.';
  END IF;
  IF v_report.pending_action_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Host submission requires a linked pending action.';
  END IF;

  v_diagnostics := public.match_report_extraction_diagnostics(
    v_report.id,
    v_report.extracted_data
  );
  IF jsonb_array_length(v_diagnostics -> 'duplicateIgns') > 0 THEN
    RAISE EXCEPTION USING
      ERRCODE = '23505',
      MESSAGE = 'Duplicate player identities must be corrected before host submission.';
  END IF;
  IF jsonb_array_length(v_diagnostics -> 'unlinkedIgns') > 0
    OR jsonb_array_length(v_diagnostics -> 'ambiguousIgns') > 0 THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Every player must be linked before host submission.';
  END IF;

  SELECT * INTO v_match
  FROM public.matches
  WHERE id = v_report.match_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Related match not found.';
  END IF;

  UPDATE public.match_reports
  SET status = 'host_review',
      host_submitted_at = now()
  WHERE id = v_report.id
  RETURNING * INTO v_report;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, pending_action_id,
    actor_discord_id, old_value_json, new_value_json
  ) VALUES (
    'match_report_host_submitted', 'match_report', v_report.id::text,
    v_report.pending_action_id, v_host_discord_id,
    jsonb_build_object('status', 'review', 'revision', v_report.revision),
    jsonb_build_object('status', 'host_review', 'revision', v_report.revision)
  );

  v_outbox_id := public.enqueue_operation_outbox(
    'discord_review_projection',
    'match_report',
    v_report.id::text,
    'match_report_host_submitted',
    'match_report:' || v_report.id::text || ':host-submitted:r' || v_report.revision::text,
    jsonb_strip_nulls(jsonb_build_object(
      'reportId', v_report.id,
      'pendingActionId', v_report.pending_action_id,
      'matchId', v_report.match_id,
      'hostDiscordId', v_report.host_discord_id,
      'revision', v_report.revision,
      'screenshotUrls', to_jsonb(v_report.screenshot_urls),
      'proofThreadId', v_match.proof_thread_id
    ))
  );

  RETURN jsonb_build_object(
    'code', 'submitted',
    'applied', true,
    'reportId', v_report.id,
    'pendingActionId', v_report.pending_action_id,
    'matchId', v_report.match_id,
    'revision', v_report.revision,
    'status', v_report.status,
    'hostSubmittedAt', v_report.host_submitted_at,
    'outboxIds', jsonb_build_array(v_outbox_id)
  );
END;
$$;

-- Preserve established decision validation behind private boundaries while the
-- public wrappers coordinate the linked report as one final approval flow.
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;

ALTER FUNCTION public.resolve_pending_action(text, text, text, text)
  RENAME TO resolve_pending_action_unlinked;
ALTER FUNCTION public.resolve_pending_action_unlinked(text, text, text, text)
  SET SCHEMA private;
REVOKE ALL ON FUNCTION private.resolve_pending_action_unlinked(text, text, text, text)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.resolve_pending_action(
  p_action_id text,
  p_actor_discord_id text,
  p_decision text,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
  v_action public.pending_actions%ROWTYPE;
  v_report public.match_reports%ROWTYPE;
  v_result jsonb;
BEGIN
  IF p_action_id IS NULL OR btrim(p_action_id) = ''
    OR p_actor_discord_id IS NULL OR btrim(p_actor_discord_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Action ID and actor Discord ID are required.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_users WHERE discord_id = p_actor_discord_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Actor is not an authorized administrator.';
  END IF;

  SELECT * INTO v_action
  FROM public.pending_actions
  WHERE id = p_action_id;

  IF FOUND AND v_action.match_id IS NOT NULL THEN
    PERFORM matches.id
    FROM public.matches AS matches
    WHERE matches.id = v_action.match_id
    FOR UPDATE;
  END IF;

  SELECT * INTO v_action
  FROM public.pending_actions
  WHERE id = p_action_id
  FOR UPDATE;

  IF FOUND AND v_action.type = 'match_result' THEN
    SELECT * INTO v_report
    FROM public.match_reports
    WHERE pending_action_id = v_action.id
    FOR UPDATE;

    IF FOUND AND lower(btrim(COALESCE(p_decision, ''))) = 'approve'
      AND v_action.status IN ('pending', 'pending_info') THEN
      RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = 'Linked match-result approval must be completed through match-report review.';
    END IF;
  END IF;

  v_result := private.resolve_pending_action_unlinked(
    p_action_id, p_actor_discord_id, p_decision, p_note
  );

  IF v_report.id IS NOT NULL
    AND v_result ->> 'finalStatus' IN ('denied', 'cancelled')
    AND v_report.status <> 'done' THEN
    DELETE FROM public.match_report_host_tokens
    WHERE match_report_id = v_report.id;

    UPDATE public.match_reports
    SET status = 'cancelled',
        host_submitted_at = NULL
    WHERE id = v_report.id;

    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, pending_action_id,
      actor_discord_id, old_value_json, new_value_json, note
    ) VALUES (
      'match_report_cancelled', 'match_report', v_report.id::text, v_action.id,
      p_actor_discord_id,
      jsonb_build_object('status', v_report.status, 'revision', v_report.revision),
      jsonb_build_object(
        'status', 'cancelled',
        'revision', v_report.revision,
        'pendingActionStatus', v_result ->> 'finalStatus'
      ),
      NULLIF(btrim(COALESCE(p_note, '')), '')
    );
  END IF;

  RETURN v_result;
END;
$$;

ALTER FUNCTION public.resolve_match_report_review(uuid, text, jsonb)
  RENAME TO resolve_match_report_review_unpublished;
ALTER FUNCTION public.resolve_match_report_review_unpublished(uuid, text, jsonb)
  SET SCHEMA private;
REVOKE ALL ON FUNCTION private.resolve_match_report_review_unpublished(uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION private.publish_match_report_stats(
  p_match_report_id uuid,
  p_actor_discord_id text,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
  v_report public.match_reports%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_expected_rows integer;
  v_source_rows integer;
  v_old_rows jsonb;
  v_new_rows jsonb;
  v_affected_player_ids text[];
BEGIN
  IF p_match_report_id IS NULL
    OR p_actor_discord_id IS NULL OR btrim(p_actor_discord_id) = '' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Match-report ID and actor Discord ID are required.';
  END IF;
  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Match report not found.';
  END IF;
  IF v_report.status <> 'done' OR v_report.total_games IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'Only a completed match report can publish official stats.';
  END IF;

  SELECT * INTO v_match
  FROM public.matches
  WHERE id = v_report.match_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Related match not found.';
  END IF;

  v_expected_rows := v_report.total_games * 10;
  SELECT count(*) INTO v_source_rows
  FROM public.player_match_stats
  WHERE match_report_id = v_report.id;

  IF v_expected_rows < 10 OR v_source_rows <> v_expected_rows
    OR EXISTS (
      SELECT 1
      FROM public.player_match_stats
      WHERE match_report_id = v_report.id
        AND player_id IS NULL
    )
    OR EXISTS (
      SELECT 1
      FROM public.player_match_stats
      WHERE match_report_id = v_report.id
        AND (
          match_id IS DISTINCT FROM v_report.match_id
          OR season_id IS DISTINCT FROM v_report.season_id
          OR division_id IS DISTINCT FROM v_report.division_id
        )
    )
    OR (
      SELECT count(DISTINCT game_number)
      FROM public.player_match_stats
      WHERE match_report_id = v_report.id
    ) <> v_report.total_games
    OR EXISTS (
      SELECT 1
      FROM public.player_match_stats
      WHERE match_report_id = v_report.id
      GROUP BY game_number
      HAVING game_number < 1
        OR game_number > v_report.total_games
        OR count(*) <> 10
        OR count(*) FILTER (WHERE org_id = v_match.home_org_id) <> 5
        OR count(*) FILTER (WHERE org_id = v_match.away_org_id) <> 5
    ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Completed match report does not have one fully linked 5v5 stat set per game.';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.player_match_stats
    WHERE match_report_id = v_report.id
    GROUP BY match_id, player_id, game_number
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23505',
      MESSAGE = 'Completed match report contains duplicate official player identities.';
  END IF;

  -- All reports that can affect the same aggregate take player locks in the
  -- same order before touching official rows, preventing lost refreshes.
  PERFORM players.id
  FROM public.players AS players
  JOIN (
    SELECT stats.player_id
    FROM public.player_match_stats AS stats
    WHERE stats.match_report_id = v_report.id
    UNION
    SELECT stats.player_id
    FROM public.player_stats AS stats
    WHERE stats.match_report_id = v_report.id
  ) AS affected ON affected.player_id = players.id
  ORDER BY players.id
  FOR UPDATE OF players;

  PERFORM stats.id
  FROM public.player_stats AS stats
  WHERE stats.match_id = v_report.match_id
  ORDER BY stats.player_id, stats.game_number, stats.id
  FOR UPDATE;

  IF EXISTS (
    SELECT 1
    FROM public.player_stats AS stats
    WHERE stats.match_id = v_report.match_id
      AND stats.match_report_id IS DISTINCT FROM v_report.id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23505',
      MESSAGE = 'Official player stats already exist for this match from another or ambiguous producer.';
  END IF;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(stats) - 'created_at' ORDER BY stats.player_id, stats.game_number, stats.id),
    '[]'::jsonb
  ) INTO v_old_rows
  FROM public.player_stats AS stats
  WHERE stats.match_report_id = v_report.id;

  SELECT array_agg(player_id ORDER BY player_id)
  INTO v_affected_player_ids
  FROM (
    SELECT stats.player_id
    FROM public.player_match_stats AS stats
    WHERE stats.match_report_id = v_report.id
    UNION
    SELECT stats.player_id
    FROM public.player_stats AS stats
    WHERE stats.match_report_id = v_report.id
  ) AS affected;

  DELETE FROM public.player_stats AS official
  WHERE official.match_report_id = v_report.id
    AND NOT EXISTS (
      SELECT 1
      FROM public.player_match_stats AS source
      WHERE source.match_report_id = v_report.id
        AND source.match_id = official.match_id
        AND source.player_id = official.player_id
        AND source.game_number = official.game_number
    );

  INSERT INTO public.player_stats (
    match_id, player_id, pending_stat_record_id, match_report_id,
    game_number, won, kills, deaths, assists, damage_dealt,
    damage_mitigated, healing_done, god_played, role,
    season_id, org_id, division_id
  )
  SELECT
    stats.match_id,
    stats.player_id,
    NULL,
    v_report.id,
    stats.game_number,
    stats.won,
    stats.kills,
    stats.deaths,
    stats.assists,
    stats.damage_dealt,
    stats.damage_mitigated,
    NULL,
    stats.god_played,
    stats.role,
    stats.season_id,
    stats.org_id,
    stats.division_id
  FROM public.player_match_stats AS stats
  WHERE stats.match_report_id = v_report.id
  ON CONFLICT (match_id, player_id, game_number) DO UPDATE
  SET pending_stat_record_id = NULL,
      match_report_id = EXCLUDED.match_report_id,
      won = EXCLUDED.won,
      kills = EXCLUDED.kills,
      deaths = EXCLUDED.deaths,
      assists = EXCLUDED.assists,
      damage_dealt = EXCLUDED.damage_dealt,
      damage_mitigated = EXCLUDED.damage_mitigated,
      healing_done = EXCLUDED.healing_done,
      god_played = EXCLUDED.god_played,
      role = EXCLUDED.role,
      season_id = EXCLUDED.season_id,
      org_id = EXCLUDED.org_id,
      division_id = EXCLUDED.division_id;

  UPDATE public.players AS players
  SET stats = (
    SELECT jsonb_build_object(
      'kills', COALESCE(sum(COALESCE(stats.kills, 0)), 0),
      'deaths', COALESCE(sum(COALESCE(stats.deaths, 0)), 0),
      'assists', COALESCE(sum(COALESCE(stats.assists, 0)), 0),
      'gamesPlayed', count(*),
      'wins', count(*) FILTER (WHERE stats.won IS TRUE)
    )
    FROM public.player_stats AS stats
    WHERE stats.player_id = players.id
  )
  WHERE players.id = ANY(v_affected_player_ids);

  SELECT COALESCE(
    jsonb_agg(to_jsonb(stats) - 'created_at' ORDER BY stats.player_id, stats.game_number, stats.id),
    '[]'::jsonb
  ) INTO v_new_rows
  FROM public.player_stats AS stats
  WHERE stats.match_report_id = v_report.id;

  IF v_old_rows IS DISTINCT FROM v_new_rows THEN
    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, pending_action_id,
      actor_discord_id, old_value_json, new_value_json, note
    ) VALUES (
      'match_report_stats_published', 'match_report', v_report.id::text,
      v_report.pending_action_id, p_actor_discord_id,
      jsonb_build_object(
        'producer', 'match_report',
        'matchReportId', v_report.id,
        'rows', v_old_rows
      ),
      jsonb_build_object(
        'producer', 'match_report',
        'matchReportId', v_report.id,
        'rows', v_new_rows
      ),
      p_reason
    );
  END IF;

  RETURN jsonb_build_object(
    'code', CASE WHEN v_old_rows IS DISTINCT FROM v_new_rows THEN 'published' ELSE 'already_published' END,
    'applied', v_old_rows IS DISTINCT FROM v_new_rows,
    'playerRows', jsonb_array_length(v_new_rows)
  );
END;
$$;
REVOKE ALL ON FUNCTION private.publish_match_report_stats(uuid, text, text)
  FROM PUBLIC, anon, authenticated, service_role;

-- Repair legacy completed reports only when the whole official set is linked
-- and the match has no canonical rows of unknown or different provenance.
DO $$
DECLARE
  v_report_id uuid;
BEGIN
  FOR v_report_id IN
    SELECT reports.id
    FROM public.match_reports AS reports
    WHERE reports.status = 'done'
      AND reports.total_games BETWEEN 1 AND 5
      AND (
        SELECT count(*)
        FROM public.player_match_stats AS stats
        WHERE stats.match_report_id = reports.id
      ) = reports.total_games * 10
      AND NOT EXISTS (
        SELECT 1
        FROM public.player_match_stats AS stats
        WHERE stats.match_report_id = reports.id
          AND stats.player_id IS NULL
      )
      AND (
        SELECT count(DISTINCT stats.game_number)
        FROM public.player_match_stats AS stats
        WHERE stats.match_report_id = reports.id
      ) = reports.total_games
      AND NOT EXISTS (
        SELECT 1
        FROM public.player_match_stats AS stats
        JOIN public.matches AS matches ON matches.id = reports.match_id
        WHERE stats.match_report_id = reports.id
        GROUP BY stats.game_number, matches.home_org_id, matches.away_org_id
        HAVING stats.game_number < 1
          OR stats.game_number > reports.total_games
          OR count(*) <> 10
          OR count(*) FILTER (WHERE stats.org_id = matches.home_org_id) <> 5
          OR count(*) FILTER (WHERE stats.org_id = matches.away_org_id) <> 5
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.player_match_stats AS stats
        WHERE stats.match_report_id = reports.id
          AND (
            stats.match_id IS DISTINCT FROM reports.match_id
            OR stats.season_id IS DISTINCT FROM reports.season_id
            OR stats.division_id IS DISTINCT FROM reports.division_id
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.player_match_stats AS stats
        WHERE stats.match_report_id = reports.id
        GROUP BY stats.match_id, stats.player_id, stats.game_number
        HAVING count(*) > 1
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.player_stats AS official
        WHERE official.match_id = reports.match_id
      )
    ORDER BY reports.id
  LOOP
    PERFORM private.publish_match_report_stats(
      v_report_id,
      'system:db-v1.18.0-backfill',
      'Idempotent db-v1.18.0 legacy match-report publication backfill.'
    );
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_match_report_review(
  p_match_report_id uuid,
  p_actor_discord_id text,
  p_games jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
  v_report public.match_reports%ROWTYPE;
  v_action public.pending_actions%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_result jsonb;
  v_publication jsonb;
  v_old_action jsonb;
  v_new_action jsonb;
  v_new_payload jsonb;
  v_outbox_ids jsonb;
  v_outbox_id uuid;
BEGIN
  IF p_match_report_id IS NULL
    OR p_actor_discord_id IS NULL OR btrim(p_actor_discord_id) = '' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Match-report ID and actor Discord ID are required.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_users WHERE discord_id = p_actor_discord_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Actor is not an authorized administrator.';
  END IF;

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Match report not found.';
  END IF;

  PERFORM matches.id
  FROM public.matches AS matches
  WHERE matches.id = v_report.match_id
  FOR UPDATE;

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id
  FOR UPDATE;

  IF v_report.status = 'cancelled' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Cancelled match report cannot be approved.';
  END IF;

  IF v_report.pending_action_id IS NOT NULL THEN
    SELECT * INTO v_action
    FROM public.pending_actions
    WHERE id = v_report.pending_action_id
    FOR UPDATE;
    IF NOT FOUND OR v_action.type <> 'match_result' OR v_action.match_id <> v_report.match_id THEN
      RAISE EXCEPTION USING
        ERRCODE = '23514',
        MESSAGE = 'Linked match-result action is missing or conflicts with the report.';
    END IF;
    IF v_action.status IN ('denied', 'cancelled') THEN
      RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = 'A denied or cancelled match-result action cannot publish stats.';
    END IF;
  END IF;

  -- Exact terminal retries retain the original idempotent response even when
  -- the caller no longer has its prior payload available.
  IF v_report.status <> 'done' THEN
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

    -- The preserved implementation recognizes the legacy admin review state.
    -- This temporary transition is protected by the same row lock and rolls
    -- back with every downstream validation or publication failure.
    IF v_report.status = 'host_review' THEN
      UPDATE public.match_reports
      SET status = 'review'
      WHERE id = v_report.id;
    END IF;
  END IF;

  v_result := private.resolve_match_report_review_unpublished(
    p_match_report_id,
    p_actor_discord_id,
    p_games
  );

  v_publication := private.publish_match_report_stats(
    p_match_report_id,
    p_actor_discord_id,
    CASE
      WHEN COALESCE((v_result ->> 'applied')::boolean, false)
        THEN 'Published during canonical match-report approval.'
      ELSE 'Repaired or verified during completed match-report retry.'
    END
  );

  SELECT * INTO v_report
  FROM public.match_reports
  WHERE id = p_match_report_id;
  SELECT * INTO v_match
  FROM public.matches
  WHERE id = v_report.match_id;

  v_outbox_ids := COALESCE(v_result -> 'outboxIds', '[]'::jsonb);
  IF v_action.id IS NOT NULL AND v_action.status IN ('pending', 'pending_info') THEN
    v_old_action := jsonb_build_object(
      'status', v_action.status,
      'payload', v_action.payload_json
    );
    v_new_payload := v_action.payload_json || jsonb_build_object(
      'winnerOrgId', v_match.winner_org_id,
      'score', greatest(v_match.home_score, v_match.away_score)::text || '-' ||
        least(v_match.home_score, v_match.away_score)::text,
      'parsed', CASE
        WHEN jsonb_typeof(v_action.payload_json -> 'parsed') = 'object'
          THEN v_action.payload_json -> 'parsed'
        ELSE '{}'::jsonb
      END || jsonb_build_object(
        'winnerGames', greatest(v_match.home_score, v_match.away_score),
        'loserGames', least(v_match.home_score, v_match.away_score),
        'gamesPlayed', v_report.total_games,
        'expectedScreenshots', v_report.total_games
      )
    );

    UPDATE public.pending_actions
    SET status = 'approved',
        payload_json = v_new_payload,
        approved_by_discord_id = p_actor_discord_id,
        approved_at = now(),
        updated_at = now()
    WHERE id = v_action.id
    RETURNING * INTO v_action;

    v_new_action := jsonb_build_object(
      'status', v_action.status,
      'payload', v_action.payload_json,
      'authoritativeSource', 'match_report',
      'matchReportId', v_report.id
    );
    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, pending_action_id,
      actor_discord_id, old_value_json, new_value_json, note
    ) VALUES (
      'pending_action_approved_via_match_report', 'pending_action', v_action.id,
      v_action.id, p_actor_discord_id, v_old_action, v_new_action,
      'Admin-reviewed match-report games replaced the typed result payload.'
    );

    v_outbox_id := public.enqueue_operation_outbox(
      'discord_review_projection', 'pending_action', v_action.id,
      'pending_action_approved',
      'pending_action:' || v_action.id || ':approved:admin_review',
      jsonb_build_object('actionId', v_action.id, 'finalStatus', 'approved', 'matchReportId', v_report.id)
    );
    v_outbox_ids := v_outbox_ids || jsonb_build_array(v_outbox_id);
    v_outbox_id := public.enqueue_operation_outbox(
      'discord_receipt_projection', 'pending_action', v_action.id,
      'pending_action_approved',
      'pending_action:' || v_action.id || ':approved:public_receipt',
      jsonb_build_object('actionId', v_action.id, 'finalStatus', 'approved', 'matchReportId', v_report.id)
    );
    v_outbox_ids := v_outbox_ids || jsonb_build_array(v_outbox_id);
    v_outbox_id := public.enqueue_operation_outbox(
      'discord_captain_notification', 'pending_action', v_action.id,
      'pending_action_approved',
      'pending_action:' || v_action.id || ':approved:captain_notification',
      jsonb_build_object(
        'actionId', v_action.id,
        'recipientDiscordId', v_action.requested_by_discord_id,
        'finalStatus', 'approved',
        'matchReportId', v_report.id
      )
    );
    v_outbox_ids := v_outbox_ids || jsonb_build_array(v_outbox_id);
    IF v_match.proof_thread_id IS NOT NULL THEN
      v_outbox_id := public.enqueue_operation_outbox(
        'proof_thread_closure', 'match', v_match.id,
        'pending_action_approved',
        'pending_action:' || v_action.id || ':approved:proof_thread_closure',
        jsonb_build_object(
          'actionId', v_action.id,
          'matchId', v_match.id,
          'proofThreadId', v_match.proof_thread_id,
          'finalStatus', 'approved',
          'matchReportId', v_report.id
        )
      );
      v_outbox_ids := v_outbox_ids || jsonb_build_array(v_outbox_id);
    END IF;
  END IF;

  RETURN v_result || jsonb_build_object(
    'pendingActionId', v_report.pending_action_id,
    'publication', v_publication,
    'outboxIds', v_outbox_ids
  );
END;
$$;

ALTER FUNCTION public.ensure_match_report_for_pending_action(text, text) OWNER TO postgres;
ALTER FUNCTION public.create_match_result_action_with_report(text, text, jsonb) OWNER TO postgres;
ALTER FUNCTION public.issue_match_report_host_token(uuid, text, text, timestamptz) OWNER TO postgres;
ALTER FUNCTION public.consume_match_report_host_token(text) OWNER TO postgres;
ALTER FUNCTION public.match_report_extraction_diagnostics(uuid, jsonb) OWNER TO postgres;
ALTER FUNCTION public.revise_match_report_extraction(uuid, text, integer, jsonb) OWNER TO postgres;
ALTER FUNCTION public.submit_match_report_host_review(uuid, text, integer) OWNER TO postgres;
ALTER FUNCTION public.resolve_pending_action(text, text, text, text) OWNER TO postgres;
ALTER FUNCTION public.resolve_match_report_review(uuid, text, jsonb) OWNER TO postgres;
ALTER FUNCTION private.resolve_pending_action_unlinked(text, text, text, text) OWNER TO postgres;
ALTER FUNCTION private.resolve_match_report_review_unpublished(uuid, text, jsonb) OWNER TO postgres;
ALTER FUNCTION private.publish_match_report_stats(uuid, text, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.ensure_match_report_for_pending_action(text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_match_result_action_with_report(text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.issue_match_report_host_token(uuid, text, text, timestamptz)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.consume_match_report_host_token(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.match_report_extraction_diagnostics(uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.revise_match_report_extraction(uuid, text, integer, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.submit_match_report_host_review(uuid, text, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.resolve_pending_action(text, text, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.resolve_match_report_review(uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.ensure_match_report_for_pending_action(text, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.create_match_result_action_with_report(text, text, jsonb)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.issue_match_report_host_token(uuid, text, text, timestamptz)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.consume_match_report_host_token(text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.match_report_extraction_diagnostics(uuid, jsonb)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.revise_match_report_extraction(uuid, text, integer, jsonb)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.submit_match_report_host_review(uuid, text, integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.resolve_pending_action(text, text, text, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.resolve_match_report_review(uuid, text, jsonb)
  TO service_role;

COMMENT ON FUNCTION public.ensure_match_report_for_pending_action(text, text) IS
  'Idempotently creates or safely repairs the one report linked to an open match-result action, deriving every league scope from the action and related match.';
COMMENT ON FUNCTION public.create_match_result_action_with_report(text, text, jsonb) IS
  'Atomically creates or recovers the one open match-result action and its host-bound match report without creating Discord outbox projections owned synchronously by the bot.';
COMMENT ON FUNCTION public.issue_match_report_host_token(uuid, text, text, timestamptz) IS
  'Rotates a short-lived one-time host capability while persisting only its SHA-256 hash.';
COMMENT ON FUNCTION public.consume_match_report_host_token(text) IS
  'Atomically consumes one valid host capability; miss, expiry, and replay all return NULL.';
COMMENT ON FUNCTION public.match_report_extraction_diagnostics(uuid, jsonb) IS
  'Validates an official-match extraction and classifies every identity against the expected active season roster and match side.';
COMMENT ON FUNCTION public.revise_match_report_extraction(uuid, text, integer, jsonb) IS
  'Applies one host-scoped optimistic edit to reviewed official-match extraction data.';
COMMENT ON FUNCTION public.submit_match_report_host_review(uuid, text, integer) IS
  'Submits a completely linked host review and atomically enqueues its Discord proof and admin-review projection.';
COMMENT ON FUNCTION public.resolve_match_report_review(uuid, text, jsonb) IS
  'Atomically approves linked match-report stats, publishes canonical official player_stats and player aggregates, audits completion, and enqueues standings recalculation.';
