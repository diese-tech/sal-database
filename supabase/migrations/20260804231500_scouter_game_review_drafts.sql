-- Durable pre-persist review state for scouter OCR. Draft rows are private and
-- host-scoped; canonical scouter rows are still created only by the existing
-- atomic ingest_scouter_game boundary after explicit confirmation.

CREATE TABLE public.scouter_game_drafts (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  season_id text NOT NULL REFERENCES public.seasons(id),
  hosted_by_discord_id text NOT NULL,
  scouter_match_id text REFERENCES public.scouter_matches(id),
  game_ordinal integer NOT NULL,
  scoreboard_image_path text NOT NULL,
  details_image_path text NOT NULL,
  extracted_game jsonb NOT NULL,
  revised_game jsonb,
  revision integer NOT NULL DEFAULT 1,
  status text NOT NULL DEFAULT 'pending',
  confirmed_scouter_game_id text REFERENCES public.scouter_games(id),
  identity_override_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CONSTRAINT scouter_game_drafts_evidence_key
    UNIQUE (scoreboard_image_path, details_image_path),
  CONSTRAINT scouter_game_drafts_host_check
    CHECK (btrim(hosted_by_discord_id) <> ''),
  CONSTRAINT scouter_game_drafts_ordinal_check CHECK (game_ordinal > 0),
  CONSTRAINT scouter_game_drafts_scoreboard_path_check
    CHECK (btrim(scoreboard_image_path) <> ''),
  CONSTRAINT scouter_game_drafts_details_path_check
    CHECK (btrim(details_image_path) <> ''),
  CONSTRAINT scouter_game_drafts_revision_check CHECK (revision > 0),
  CONSTRAINT scouter_game_drafts_status_check
    CHECK (status IN ('pending', 'confirmed', 'cancelled')),
  CONSTRAINT scouter_game_drafts_completion_check CHECK (
    (status = 'pending' AND completed_at IS NULL AND confirmed_scouter_game_id IS NULL)
    OR (status = 'confirmed' AND completed_at IS NOT NULL AND confirmed_scouter_game_id IS NOT NULL)
    OR (status = 'cancelled' AND completed_at IS NOT NULL AND confirmed_scouter_game_id IS NULL)
  ),
  CONSTRAINT scouter_game_drafts_override_reason_check CHECK (
    identity_override_reason IS NULL
    OR (btrim(identity_override_reason) <> '' AND length(identity_override_reason) <= 500)
  )
);

CREATE INDEX scouter_game_drafts_host_status_idx
  ON public.scouter_game_drafts (hosted_by_discord_id, status, updated_at DESC);

ALTER TABLE public.scouter_game_drafts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.scouter_game_drafts FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.scouter_game_drafts TO service_role;

COMMENT ON TABLE public.scouter_game_drafts IS
  'Private, durable OCR drafts reviewed by one Discord host before canonical scouter ingestion.';

CREATE OR REPLACE FUNCTION public.scouter_game_draft_diagnostics(
  p_game jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_participant_count integer;
  v_order_count integer;
  v_chaos_count integer;
  v_duplicate_igns jsonb;
  v_unlinked_igns jsonb;
  v_ambiguous_igns jsonb;
  v_participants jsonb;
BEGIN
  IF p_game IS NULL
    OR jsonb_typeof(p_game) <> 'object'
    OR jsonb_typeof(p_game -> 'participants') <> 'array' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A scouter draft must contain a participants array.';
  END IF;

  v_participant_count := jsonb_array_length(p_game -> 'participants');
  IF v_participant_count <> 10 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A scouter draft must contain exactly ten participant rows.';
  END IF;

  IF p_game ->> 'winningSide' NOT IN ('order', 'chaos') THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A scouter draft must identify order or chaos as the winning side.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_game -> 'participants') participant
    WHERE jsonb_typeof(participant) <> 'object'
      OR btrim(COALESCE(participant ->> 'rawIgn', '')) = ''
      OR participant ->> 'side' NOT IN ('order', 'chaos')
      OR jsonb_typeof(participant -> 'kills') <> 'number'
      OR jsonb_typeof(participant -> 'deaths') <> 'number'
      OR jsonb_typeof(participant -> 'assists') <> 'number'
      OR (participant ->> 'kills') !~ '^[0-9]+$'
      OR (participant ->> 'deaths') !~ '^[0-9]+$'
      OR (participant ->> 'assists') !~ '^[0-9]+$'
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Every draft participant needs an IGN, valid side, and nonnegative integer K/D/A.';
  END IF;

  SELECT
    count(*) FILTER (WHERE participant ->> 'side' = 'order'),
    count(*) FILTER (WHERE participant ->> 'side' = 'chaos')
  INTO v_order_count, v_chaos_count
  FROM jsonb_array_elements(p_game -> 'participants') participant;
  IF v_order_count <> 5 OR v_chaos_count <> 5 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A scouter draft must contain five order and five chaos participants.';
  END IF;

  WITH participant_input AS (
    SELECT
      participant,
      ordinality::integer - 1 AS participant_index,
      btrim(participant ->> 'rawIgn') AS raw_ign,
      lower(btrim(participant ->> 'rawIgn')) AS normalized_ign
    FROM jsonb_array_elements(p_game -> 'participants') WITH ORDINALITY
      AS input(participant, ordinality)
  ), identity_matches AS (
    SELECT
      input.*,
      count(player.id)::integer AS player_match_count,
      CASE WHEN count(player.id) = 1 THEN min(player.id) END AS player_id,
      count(*) OVER (PARTITION BY input.normalized_ign)::integer AS draft_ign_count
    FROM participant_input input
    LEFT JOIN public.players player
      ON lower(btrim(player.ign)) = input.normalized_ign
     AND player.archived_at IS NULL
    GROUP BY
      input.participant,
      input.participant_index,
      input.raw_ign,
      input.normalized_ign
  )
  SELECT
    COALESCE(
      jsonb_agg(DISTINCT raw_ign) FILTER (WHERE draft_ign_count > 1),
      '[]'::jsonb
    ),
    COALESCE(
      jsonb_agg(DISTINCT raw_ign) FILTER (
        WHERE draft_ign_count = 1 AND player_match_count = 0
      ),
      '[]'::jsonb
    ),
    COALESCE(
      jsonb_agg(DISTINCT raw_ign) FILTER (
        WHERE draft_ign_count = 1 AND player_match_count > 1
      ),
      '[]'::jsonb
    ),
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'index', participant_index,
          'side', participant ->> 'side',
          'rawIgn', raw_ign,
          'playerId', player_id,
          'identityStatus', CASE
            WHEN draft_ign_count > 1 THEN 'duplicate'
            WHEN player_match_count = 0 THEN 'unlinked'
            WHEN player_match_count > 1 THEN 'ambiguous'
            ELSE 'linked'
          END
        ) ORDER BY participant_index
      ),
      '[]'::jsonb
    )
  INTO v_duplicate_igns, v_unlinked_igns, v_ambiguous_igns, v_participants
  FROM identity_matches;

  RETURN jsonb_build_object(
    'participantCount', v_participant_count,
    'duplicateIgns', v_duplicate_igns,
    'unlinkedIgns', v_unlinked_igns,
    'ambiguousIgns', v_ambiguous_igns,
    'participants', v_participants
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.create_scouter_game_draft(
  p_season_id text,
  p_hosted_by_discord_id text,
  p_game_ordinal integer,
  p_scoreboard_image_path text,
  p_details_image_path text,
  p_extracted_game jsonb,
  p_scouter_match_id text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_draft public.scouter_game_drafts%ROWTYPE;
  v_diagnostics jsonb;
  v_scouter_match_id text := NULLIF(btrim(COALESCE(p_scouter_match_id, '')), '');
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

  v_diagnostics := public.scouter_game_draft_diagnostics(p_extracted_game);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'scouter-draft:' || btrim(p_scoreboard_image_path) || ':' || btrim(p_details_image_path),
    0
  ));

  SELECT * INTO v_draft
  FROM public.scouter_game_drafts
  WHERE scoreboard_image_path = btrim(p_scoreboard_image_path)
    AND details_image_path = btrim(p_details_image_path)
  FOR UPDATE;

  IF FOUND THEN
    IF v_draft.season_id <> btrim(p_season_id)
      OR v_draft.hosted_by_discord_id <> btrim(p_hosted_by_discord_id)
      OR v_draft.game_ordinal <> p_game_ordinal
      OR v_draft.scouter_match_id IS DISTINCT FROM v_scouter_match_id THEN
      RAISE EXCEPTION USING
        ERRCODE = '23514',
        MESSAGE = 'Existing scouter draft evidence belongs to a different host or game scope.';
    END IF;

    RETURN jsonb_build_object(
      'code', 'existing',
      'applied', false,
      'draftId', v_draft.id,
      'revision', v_draft.revision,
      'status', v_draft.status,
      'game', COALESCE(v_draft.revised_game, v_draft.extracted_game),
      'diagnostics', public.scouter_game_draft_diagnostics(
        COALESCE(v_draft.revised_game, v_draft.extracted_game)
      )
    );
  END IF;

  IF v_scouter_match_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.scouter_matches match
    WHERE match.id = v_scouter_match_id
      AND match.season_id = btrim(p_season_id)
      AND match.hosted_by_discord_id = btrim(p_hosted_by_discord_id)
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Scouter match season and host must match the draft.';
  END IF;

  INSERT INTO public.scouter_game_drafts (
    season_id,
    hosted_by_discord_id,
    scouter_match_id,
    game_ordinal,
    scoreboard_image_path,
    details_image_path,
    extracted_game
  ) VALUES (
    btrim(p_season_id),
    btrim(p_hosted_by_discord_id),
    v_scouter_match_id,
    p_game_ordinal,
    btrim(p_scoreboard_image_path),
    btrim(p_details_image_path),
    p_extracted_game
  ) RETURNING * INTO v_draft;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, actor_discord_id, new_value_json
  ) VALUES (
    'scouter_game_draft_created',
    'scouter_game_draft',
    v_draft.id,
    v_draft.hosted_by_discord_id,
    jsonb_build_object(
      'seasonId', v_draft.season_id,
      'scouterMatchId', v_draft.scouter_match_id,
      'gameOrdinal', v_draft.game_ordinal,
      'revision', v_draft.revision,
      'duplicateCount', jsonb_array_length(v_diagnostics -> 'duplicateIgns'),
      'unlinkedCount', jsonb_array_length(v_diagnostics -> 'unlinkedIgns'),
      'ambiguousCount', jsonb_array_length(v_diagnostics -> 'ambiguousIgns')
    )
  );

  RETURN jsonb_build_object(
    'code', 'created',
    'applied', true,
    'draftId', v_draft.id,
    'revision', v_draft.revision,
    'status', v_draft.status,
    'game', v_draft.extracted_game,
    'diagnostics', v_diagnostics
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.revise_scouter_game_draft(
  p_draft_id text,
  p_hosted_by_discord_id text,
  p_expected_revision integer,
  p_revised_game jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_draft public.scouter_game_drafts%ROWTYPE;
  v_diagnostics jsonb;
BEGIN
  v_diagnostics := public.scouter_game_draft_diagnostics(p_revised_game);

  SELECT * INTO v_draft
  FROM public.scouter_game_drafts
  WHERE id = btrim(p_draft_id)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Scouter draft not found.';
  END IF;
  IF v_draft.hosted_by_discord_id <> btrim(COALESCE(p_hosted_by_discord_id, '')) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Only the draft host can revise it.';
  END IF;
  IF v_draft.status <> 'pending' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Only a pending scouter draft can be revised.';
  END IF;
  IF p_expected_revision IS NULL OR v_draft.revision <> p_expected_revision THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'Scouter draft revision is stale.';
  END IF;

  UPDATE public.scouter_game_drafts
  SET revised_game = p_revised_game,
      revision = revision + 1,
      updated_at = now()
  WHERE id = v_draft.id
  RETURNING * INTO v_draft;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, actor_discord_id,
    old_value_json, new_value_json
  ) VALUES (
    'scouter_game_draft_revised',
    'scouter_game_draft',
    v_draft.id,
    v_draft.hosted_by_discord_id,
    jsonb_build_object('revision', p_expected_revision),
    jsonb_build_object(
      'revision', v_draft.revision,
      'duplicateCount', jsonb_array_length(v_diagnostics -> 'duplicateIgns'),
      'unlinkedCount', jsonb_array_length(v_diagnostics -> 'unlinkedIgns'),
      'ambiguousCount', jsonb_array_length(v_diagnostics -> 'ambiguousIgns')
    )
  );

  RETURN jsonb_build_object(
    'code', 'revised',
    'applied', true,
    'draftId', v_draft.id,
    'revision', v_draft.revision,
    'status', v_draft.status,
    'game', v_draft.revised_game,
    'diagnostics', v_diagnostics
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_scouter_game_draft(
  p_draft_id text,
  p_hosted_by_discord_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_draft public.scouter_game_drafts%ROWTYPE;
BEGIN
  SELECT * INTO v_draft
  FROM public.scouter_game_drafts
  WHERE id = btrim(p_draft_id)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Scouter draft not found.';
  END IF;
  IF v_draft.hosted_by_discord_id <> btrim(COALESCE(p_hosted_by_discord_id, '')) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Only the draft host can cancel it.';
  END IF;
  IF v_draft.status = 'confirmed' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'A confirmed scouter draft cannot be cancelled.';
  END IF;
  IF v_draft.status = 'cancelled' THEN
    RETURN jsonb_build_object(
      'code', 'already_cancelled',
      'applied', false,
      'draftId', v_draft.id,
      'revision', v_draft.revision,
      'status', v_draft.status
    );
  END IF;

  UPDATE public.scouter_game_drafts
  SET status = 'cancelled', completed_at = now(), updated_at = now()
  WHERE id = v_draft.id
  RETURNING * INTO v_draft;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, actor_discord_id,
    old_value_json, new_value_json
  ) VALUES (
    'scouter_game_draft_cancelled',
    'scouter_game_draft',
    v_draft.id,
    v_draft.hosted_by_discord_id,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object('status', 'cancelled', 'revision', v_draft.revision)
  );

  RETURN jsonb_build_object(
    'code', 'cancelled',
    'applied', true,
    'draftId', v_draft.id,
    'revision', v_draft.revision,
    'status', v_draft.status
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_scouter_game_draft(
  p_draft_id text,
  p_hosted_by_discord_id text,
  p_expected_revision integer,
  p_identity_override_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_draft public.scouter_game_drafts%ROWTYPE;
  v_game jsonb;
  v_diagnostics jsonb;
  v_override_reason text := NULLIF(btrim(COALESCE(p_identity_override_reason, '')), '');
  v_ingest_result jsonb;
BEGIN
  SELECT * INTO v_draft
  FROM public.scouter_game_drafts
  WHERE id = btrim(p_draft_id)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Scouter draft not found.';
  END IF;
  IF v_draft.hosted_by_discord_id <> btrim(COALESCE(p_hosted_by_discord_id, '')) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Only the draft host can confirm it.';
  END IF;
  IF v_draft.status = 'cancelled' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'A cancelled scouter draft cannot be confirmed.';
  END IF;
  IF v_draft.status = 'confirmed' THEN
    RETURN jsonb_build_object(
      'code', 'already_confirmed',
      'applied', false,
      'draftId', v_draft.id,
      'revision', v_draft.revision,
      'status', v_draft.status,
      'scouterMatchId', v_draft.scouter_match_id,
      'scouterGameId', v_draft.confirmed_scouter_game_id
    );
  END IF;
  IF p_expected_revision IS NULL OR v_draft.revision <> p_expected_revision THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'Scouter draft revision is stale.';
  END IF;
  IF v_override_reason IS NOT NULL AND length(v_override_reason) > 500 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Identity override reason must be 500 characters or fewer.';
  END IF;

  v_game := COALESCE(v_draft.revised_game, v_draft.extracted_game);
  v_diagnostics := public.scouter_game_draft_diagnostics(v_game);
  IF jsonb_array_length(v_diagnostics -> 'duplicateIgns') > 0 THEN
    RAISE EXCEPTION USING
      ERRCODE = '23505',
      MESSAGE = 'Duplicate IGNs must be corrected before confirmation.';
  END IF;
  IF (
    jsonb_array_length(v_diagnostics -> 'unlinkedIgns') > 0
    OR jsonb_array_length(v_diagnostics -> 'ambiguousIgns') > 0
  ) AND v_override_reason IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Unlinked or ambiguous IGNs require correction or an explicit override reason.';
  END IF;

  v_ingest_result := public.ingest_scouter_game(
    v_draft.season_id,
    v_draft.hosted_by_discord_id,
    v_draft.game_ordinal,
    v_draft.scoreboard_image_path,
    v_draft.details_image_path,
    v_game -> 'participants',
    v_game ->> 'winningSide',
    v_draft.scouter_match_id,
    NULLIF(btrim(COALESCE(v_game ->> 'smiteMatchId', '')), ''),
    NULLIF(btrim(COALESCE(v_game ->> 'gameMode', '')), ''),
    CASE
      WHEN v_game -> 'matchLengthSeconds' IS NULL
        OR v_game -> 'matchLengthSeconds' = 'null'::jsonb THEN NULL
      ELSE (v_game ->> 'matchLengthSeconds')::integer
    END
  );

  UPDATE public.scouter_game_drafts
  SET status = 'confirmed',
      scouter_match_id = v_ingest_result ->> 'scouterMatchId',
      confirmed_scouter_game_id = v_ingest_result ->> 'scouterGameId',
      identity_override_reason = v_override_reason,
      completed_at = now(),
      updated_at = now()
  WHERE id = v_draft.id
  RETURNING * INTO v_draft;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, actor_discord_id,
    old_value_json, new_value_json, note
  ) VALUES (
    'scouter_game_draft_confirmed',
    'scouter_game_draft',
    v_draft.id,
    v_draft.hosted_by_discord_id,
    jsonb_build_object('status', 'pending', 'revision', v_draft.revision),
    jsonb_build_object(
      'status', 'confirmed',
      'revision', v_draft.revision,
      'scouterMatchId', v_draft.scouter_match_id,
      'scouterGameId', v_draft.confirmed_scouter_game_id,
      'ingestCode', v_ingest_result ->> 'code',
      'identityOverride', v_override_reason IS NOT NULL
    ),
    v_override_reason
  );

  RETURN v_ingest_result || jsonb_build_object(
    'draftId', v_draft.id,
    'revision', v_draft.revision,
    'status', v_draft.status,
    'identityOverrideApplied', v_override_reason IS NOT NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION public.scouter_game_draft_diagnostics(jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_scouter_game_draft(
  text, text, integer, text, text, jsonb, text
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.revise_scouter_game_draft(
  text, text, integer, jsonb
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cancel_scouter_game_draft(text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.confirm_scouter_game_draft(
  text, text, integer, text
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.scouter_game_draft_diagnostics(jsonb)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.create_scouter_game_draft(
  text, text, integer, text, text, jsonb, text
) TO service_role;
GRANT EXECUTE ON FUNCTION public.revise_scouter_game_draft(
  text, text, integer, jsonb
) TO service_role;
GRANT EXECUTE ON FUNCTION public.cancel_scouter_game_draft(text, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.confirm_scouter_game_draft(
  text, text, integer, text
) TO service_role;

COMMENT ON FUNCTION public.create_scouter_game_draft(
  text, text, integer, text, text, jsonb, text
) IS 'Idempotently stores a private OCR draft and returns identity diagnostics without writing canonical scouter rows.';
COMMENT ON FUNCTION public.revise_scouter_game_draft(
  text, text, integer, jsonb
) IS 'Host-scoped optimistic update for a pending scouter OCR draft.';
COMMENT ON FUNCTION public.cancel_scouter_game_draft(text, text)
  IS 'Idempotently cancels a pending scouter OCR draft without canonical ingestion.';
COMMENT ON FUNCTION public.confirm_scouter_game_draft(
  text, text, integer, text
) IS 'Atomically confirms a reviewed draft through ingest_scouter_game and records the terminal audit transition.';
