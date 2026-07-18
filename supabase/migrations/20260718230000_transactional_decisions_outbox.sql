-- Release A: transactional approval decisions and a durable operation outbox.
--
-- All public entry points in this migration are service-role-only. Domain
-- mutations, lifecycle/domain audits, and projection enqueueing share one
-- PostgreSQL transaction so callers cannot leave partially applied decisions.

CREATE TABLE public.operation_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  topic text NOT NULL CHECK (length(btrim(topic)) > 0),
  aggregate_type text NOT NULL CHECK (length(btrim(aggregate_type)) > 0),
  aggregate_id text NOT NULL CHECK (length(btrim(aggregate_id)) > 0),
  event_type text NOT NULL CHECK (length(btrim(event_type)) > 0),
  deduplication_key text NOT NULL UNIQUE CHECK (length(btrim(deduplication_key)) > 0),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
  state text NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending', 'processing', 'completed', 'dead_letter')),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0 AND attempts <= 10),
  available_at timestamptz NOT NULL DEFAULT now(),
  lease_owner text,
  lease_expires_at timestamptz,
  last_error text,
  external_id text,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT operation_outbox_lease_shape CHECK (
    (state = 'processing' AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)
    OR
    (state <> 'processing' AND lease_owner IS NULL AND lease_expires_at IS NULL)
  ),
  CONSTRAINT operation_outbox_completion_shape CHECK (
    (state = 'completed' AND completed_at IS NOT NULL)
    OR
    (state <> 'completed' AND completed_at IS NULL)
  )
);

CREATE INDEX operation_outbox_claim_idx
  ON public.operation_outbox (available_at, created_at)
  WHERE state IN ('pending', 'processing');

CREATE INDEX operation_outbox_dead_letter_idx
  ON public.operation_outbox (updated_at DESC)
  WHERE state = 'dead_letter';

ALTER TABLE public.operation_outbox ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.operation_outbox FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.operation_outbox TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_operation_outbox(
  p_topic text,
  p_aggregate_type text,
  p_aggregate_id text,
  p_event_type text,
  p_deduplication_key text,
  p_payload jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_topic IS NULL OR btrim(p_topic) = ''
    OR p_aggregate_type IS NULL OR btrim(p_aggregate_type) = ''
    OR p_aggregate_id IS NULL OR btrim(p_aggregate_id) = ''
    OR p_event_type IS NULL OR btrim(p_event_type) = ''
    OR p_deduplication_key IS NULL OR btrim(p_deduplication_key) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Outbox routing values must be non-empty.';
  END IF;

  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Outbox payload must be a JSON object.';
  END IF;

  INSERT INTO public.operation_outbox (
    topic, aggregate_type, aggregate_id, event_type, deduplication_key, payload
  ) VALUES (
    p_topic, p_aggregate_type, p_aggregate_id, p_event_type, p_deduplication_key, p_payload
  )
  ON CONFLICT (deduplication_key) DO UPDATE
    SET deduplication_key = EXCLUDED.deduplication_key
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_pending_action(
  p_type text,
  p_requested_by_discord_id text,
  p_match_id text,
  p_division_id text,
  p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_match public.matches%ROWTYPE;
  v_existing public.pending_actions%ROWTYPE;
  v_action public.pending_actions%ROWTYPE;
  v_outbox_ids uuid[] := ARRAY[]::uuid[];
BEGIN
  IF p_type IS NULL OR p_type NOT IN ('match_result', 'reschedule', 'admin_review', 'alias_change') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Unsupported pending action type.';
  END IF;

  IF p_requested_by_discord_id IS NULL OR btrim(p_requested_by_discord_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Requester Discord ID is required.';
  END IF;

  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Pending action payload must be a JSON object.';
  END IF;

  IF p_type IN ('match_result', 'reschedule') AND p_match_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'This action type requires a match.';
  END IF;

  IF p_match_id IS NOT NULL THEN
    SELECT * INTO v_match
    FROM public.matches
    WHERE id = p_match_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Match not found.';
    END IF;

    IF p_division_id IS NOT NULL AND p_division_id <> v_match.division_id THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Action division does not match the match division.';
    END IF;

    IF p_type IN ('match_result', 'reschedule') AND v_match.status <> 'scheduled' THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Match is not in a reportable state.';
    END IF;

    IF p_type IN ('match_result', 'reschedule') THEN
      SELECT * INTO v_existing
      FROM public.pending_actions
      WHERE match_id = p_match_id
        AND type = p_type
        AND status IN ('pending', 'pending_info')
      ORDER BY created_at
      LIMIT 1;

      IF FOUND THEN
        RETURN jsonb_build_object(
          'actionId', v_existing.id,
          'actionType', v_existing.type,
          'status', v_existing.status,
          'created', false,
          'outboxIds', '[]'::jsonb
        );
      END IF;
    END IF;
  END IF;

  INSERT INTO public.pending_actions (
    type, requested_by_discord_id, match_id, division_id, payload_json
  ) VALUES (
    p_type,
    p_requested_by_discord_id,
    p_match_id,
    COALESCE(p_division_id, v_match.division_id),
    p_payload
  )
  RETURNING * INTO v_action;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, pending_action_id,
    actor_discord_id, old_value_json, new_value_json
  ) VALUES (
    'pending_action_created', 'pending_action', v_action.id, v_action.id,
    p_requested_by_discord_id, NULL,
    jsonb_build_object('status', 'pending', 'type', v_action.type)
  );

  v_outbox_ids := array_append(v_outbox_ids, public.enqueue_operation_outbox(
    'discord_review_projection', 'pending_action', v_action.id,
    'pending_action_created',
    'pending_action:' || v_action.id || ':created:admin_review',
    jsonb_build_object('actionId', v_action.id, 'actionType', v_action.type)
  ));
  v_outbox_ids := array_append(v_outbox_ids, public.enqueue_operation_outbox(
    'discord_receipt_projection', 'pending_action', v_action.id,
    'pending_action_created',
    'pending_action:' || v_action.id || ':created:public_receipt',
    jsonb_build_object('actionId', v_action.id, 'actionType', v_action.type)
  ));

  RETURN jsonb_build_object(
    'actionId', v_action.id,
    'actionType', v_action.type,
    'status', v_action.status,
    'created', true,
    'outboxIds', to_jsonb(v_outbox_ids)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_pending_action(
  p_action_id text,
  p_actor_discord_id text,
  p_decision text,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_action public.pending_actions%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_decision text := lower(btrim(COALESCE(p_decision, '')));
  v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_final_status text;
  v_code text := 'applied';
  v_applied boolean := false;
  v_outbox_ids uuid[] := ARRAY[]::uuid[];
  v_winner_org_id text;
  v_score text;
  v_winner_games integer;
  v_loser_games integer;
  v_new_date date;
  v_new_time time;
  v_old_match jsonb;
  v_new_match jsonb;
  v_stale_note text := 'Match is no longer scheduled; the action was cancelled without applying its payload.';
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

  IF v_decision NOT IN ('approve', 'deny', 'needs_info') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Decision must be approve, deny, or needs_info.';
  END IF;

  SELECT * INTO v_action
  FROM public.pending_actions
  WHERE id = p_action_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Pending action not found.';
  END IF;

  IF v_action.status IN ('approved', 'denied', 'cancelled') THEN
    RETURN jsonb_build_object(
      'code', 'already_processed',
      'actionId', v_action.id,
      'actionType', v_action.type,
      'finalStatus', v_action.status,
      'applied', false,
      'matchId', v_action.match_id,
      'note', v_action.admin_note,
      'outboxIds', '[]'::jsonb
    );
  END IF;

  IF v_decision = 'needs_info' AND v_action.status <> 'pending' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Needs Info is allowed only from pending.';
  END IF;

  IF v_decision IN ('deny', 'needs_info') AND v_note IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A note is required for denial and Needs Info.';
  END IF;

  IF v_decision = 'approve' AND v_action.type = 'alias_change' THEN
    RAISE EXCEPTION USING ERRCODE = '0A000', MESSAGE = 'Alias change approval is not implemented.';
  END IF;

  IF v_action.match_id IS NOT NULL THEN
    SELECT * INTO v_match
    FROM public.matches
    WHERE id = v_action.match_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Related match not found.';
    END IF;
  END IF;

  IF v_decision = 'approve'
    AND v_action.type IN ('match_result', 'reschedule')
    AND v_match.status <> 'scheduled' THEN
    UPDATE public.pending_actions
    SET status = 'cancelled',
        admin_note = v_stale_note,
        approved_by_discord_id = p_actor_discord_id,
        approved_at = now(),
        updated_at = now()
    WHERE id = v_action.id;

    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, pending_action_id,
      actor_discord_id, old_value_json, new_value_json, note
    ) VALUES (
      'pending_action_cancelled', 'pending_action', v_action.id, v_action.id,
      p_actor_discord_id,
      jsonb_build_object('status', v_action.status),
      jsonb_build_object('status', 'cancelled'),
      v_stale_note
    );

    v_final_status := 'cancelled';
    v_code := 'stale_cancelled';
    v_note := v_stale_note;
  ELSIF v_decision = 'needs_info' THEN
    UPDATE public.pending_actions
    SET status = 'pending_info', admin_note = v_note, updated_at = now()
    WHERE id = v_action.id;

    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, pending_action_id,
      actor_discord_id, old_value_json, new_value_json, note
    ) VALUES (
      'pending_action_needs_info', 'pending_action', v_action.id, v_action.id,
      p_actor_discord_id,
      jsonb_build_object('status', v_action.status),
      jsonb_build_object('status', 'pending_info'),
      v_note
    );
    v_final_status := 'pending_info';
  ELSIF v_decision = 'deny' THEN
    UPDATE public.pending_actions
    SET status = 'denied',
        admin_note = v_note,
        approved_by_discord_id = p_actor_discord_id,
        approved_at = now(),
        updated_at = now()
    WHERE id = v_action.id;

    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, pending_action_id,
      actor_discord_id, old_value_json, new_value_json, note
    ) VALUES (
      'pending_action_denied', 'pending_action', v_action.id, v_action.id,
      p_actor_discord_id,
      jsonb_build_object('status', v_action.status),
      jsonb_build_object('status', 'denied'),
      v_note
    );
    v_final_status := 'denied';
  ELSE
    IF v_action.type = 'match_result' THEN
      v_winner_org_id := v_action.payload_json ->> 'winnerOrgId';
      v_score := v_action.payload_json ->> 'score';

      IF v_winner_org_id IS NULL OR v_winner_org_id NOT IN (v_match.home_org_id, v_match.away_org_id) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Result winner must be one of the match organizations.';
      END IF;
      IF v_score IS NULL OR v_score !~ '^[0-9]+-[0-9]+$' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Result score must use winner-loser format.';
      END IF;

      v_winner_games := split_part(v_score, '-', 1)::integer;
      v_loser_games := split_part(v_score, '-', 2)::integer;
      IF v_winner_games <= v_loser_games THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Result winner must have more games than the loser.';
      END IF;
      IF jsonb_typeof(v_action.payload_json -> 'parsed') IS DISTINCT FROM 'object'
        OR (v_action.payload_json #>> '{parsed,winnerGames}') IS NULL
        OR (v_action.payload_json #>> '{parsed,loserGames}') IS NULL
        OR (v_action.payload_json #>> '{parsed,gamesPlayed}') IS NULL
        OR (v_action.payload_json #>> '{parsed,expectedScreenshots}') IS NULL
        OR (v_action.payload_json #>> '{parsed,winnerGames}')::integer <> v_winner_games
        OR (v_action.payload_json #>> '{parsed,loserGames}')::integer <> v_loser_games
        OR (v_action.payload_json #>> '{parsed,gamesPlayed}')::integer <> v_winner_games + v_loser_games
        OR (v_action.payload_json #>> '{parsed,expectedScreenshots}')::integer <> (v_winner_games + v_loser_games) * 2 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Parsed result totals do not match the score.';
      END IF;

      v_old_match := jsonb_build_object(
        'status', v_match.status,
        'winner_org_id', v_match.winner_org_id,
        'home_score', v_match.home_score,
        'away_score', v_match.away_score,
        'score', v_match.score
      );

      UPDATE public.matches
      SET status = 'completed',
          winner_org_id = v_winner_org_id,
          home_score = CASE WHEN v_winner_org_id = v_match.home_org_id THEN v_winner_games ELSE v_loser_games END,
          away_score = CASE WHEN v_winner_org_id = v_match.away_org_id THEN v_winner_games ELSE v_loser_games END,
          score = v_score
      WHERE id = v_match.id;

      v_new_match := jsonb_build_object(
        'status', 'completed',
        'winner_org_id', v_winner_org_id,
        'home_score', CASE WHEN v_winner_org_id = v_match.home_org_id THEN v_winner_games ELSE v_loser_games END,
        'away_score', CASE WHEN v_winner_org_id = v_match.away_org_id THEN v_winner_games ELSE v_loser_games END,
        'score', v_score
      );

      INSERT INTO public.audit_logs (
        action_type, entity_type, entity_id, pending_action_id,
        actor_discord_id, old_value_json, new_value_json, note
      ) VALUES (
        'match_result_recorded', 'match', v_match.id, v_action.id,
        p_actor_discord_id, v_old_match, v_new_match, v_note
      );
      v_applied := true;
    ELSIF v_action.type = 'reschedule' THEN
      IF (v_action.payload_json ->> 'newDate') IS NULL
        OR (v_action.payload_json ->> 'newDate') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        OR (v_action.payload_json ->> 'newTime') IS NULL
        OR (v_action.payload_json ->> 'newTime') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Reschedule date or time has an invalid format.';
      END IF;
      v_new_date := (v_action.payload_json ->> 'newDate')::date;
      v_new_time := (v_action.payload_json ->> 'newTime')::time;

      v_old_match := jsonb_build_object(
        'scheduled_date', v_match.scheduled_date,
        'scheduled_time', v_match.scheduled_time
      );
      UPDATE public.matches
      SET scheduled_date = v_new_date, scheduled_time = v_new_time
      WHERE id = v_match.id;
      v_new_match := jsonb_build_object(
        'scheduled_date', v_new_date,
        'scheduled_time', v_new_time
      );

      INSERT INTO public.audit_logs (
        action_type, entity_type, entity_id, pending_action_id,
        actor_discord_id, old_value_json, new_value_json, note
      ) VALUES (
        'match_rescheduled', 'match', v_match.id, v_action.id,
        p_actor_discord_id, v_old_match, v_new_match, v_note
      );
      v_applied := true;
    ELSIF v_action.type = 'admin_review' THEN
      v_applied := true;
    END IF;

    UPDATE public.pending_actions
    SET status = 'approved',
        admin_note = v_note,
        approved_by_discord_id = p_actor_discord_id,
        approved_at = now(),
        updated_at = now()
    WHERE id = v_action.id;

    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, pending_action_id,
      actor_discord_id, old_value_json, new_value_json, note
    ) VALUES (
      'pending_action_approved', 'pending_action', v_action.id, v_action.id,
      p_actor_discord_id,
      jsonb_build_object('status', v_action.status),
      jsonb_build_object('status', 'approved'),
      v_note
    );
    v_final_status := 'approved';
  END IF;

  v_outbox_ids := array_append(v_outbox_ids, public.enqueue_operation_outbox(
    'discord_review_projection', 'pending_action', v_action.id,
    'pending_action_' || v_final_status,
    'pending_action:' || v_action.id || ':' || v_final_status || ':admin_review',
    jsonb_build_object('actionId', v_action.id, 'finalStatus', v_final_status)
  ));
  v_outbox_ids := array_append(v_outbox_ids, public.enqueue_operation_outbox(
    'discord_receipt_projection', 'pending_action', v_action.id,
    'pending_action_' || v_final_status,
    'pending_action:' || v_action.id || ':' || v_final_status || ':public_receipt',
    jsonb_build_object('actionId', v_action.id, 'finalStatus', v_final_status)
  ));
  v_outbox_ids := array_append(v_outbox_ids, public.enqueue_operation_outbox(
    'discord_captain_notification', 'pending_action', v_action.id,
    'pending_action_' || v_final_status,
    'pending_action:' || v_action.id || ':' || v_final_status || ':requester_notification',
    jsonb_build_object(
      'actionId', v_action.id,
      'recipientDiscordId', v_action.requested_by_discord_id,
      'finalStatus', v_final_status,
      'note', v_note
    )
  ));

  IF v_applied AND v_action.type = 'match_result' THEN
    IF v_match.proof_thread_id IS NOT NULL THEN
      v_outbox_ids := array_append(v_outbox_ids, public.enqueue_operation_outbox(
        'proof_thread_closure', 'match', v_match.id, 'match_result_recorded',
        'pending_action:' || v_action.id || ':approved:proof_thread_closure',
        jsonb_build_object(
          'actionId', v_action.id,
          'matchId', v_match.id,
          'proofThreadId', v_match.proof_thread_id
        )
      ));
    END IF;
    v_outbox_ids := array_append(v_outbox_ids, public.enqueue_operation_outbox(
      'standings_recalculation', 'match', v_match.id, 'match_result_recorded',
      'pending_action:' || v_action.id || ':approved:standings_recalculation',
      jsonb_build_object(
        'actionId', v_action.id,
        'matchId', v_match.id,
        'seasonId', v_match.season_id,
        'outboxIdempotencyKey', 'pending_action:' || v_action.id || ':standings'
      )
    ));
  END IF;

  RETURN jsonb_build_object(
    'code', v_code,
    'actionId', v_action.id,
    'actionType', v_action.type,
    'finalStatus', v_final_status,
    'applied', v_applied,
    'matchId', v_action.match_id,
    'note', v_note,
    'outboxIds', to_jsonb(v_outbox_ids)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_pending_stat_record(
  p_record_id text,
  p_actor_discord_id text,
  p_decision text,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_record public.pending_stat_records%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_stats jsonb;
  v_decision text := lower(btrim(COALESCE(p_decision, '')));
  v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_game_number integer;
  v_player_org_id text;
  v_won boolean;
  v_stat_id text;
  v_old_stat jsonb;
  v_new_stat jsonb;
  v_key text;
  v_outbox_ids uuid[] := ARRAY[]::uuid[];
BEGIN
  IF p_record_id IS NULL OR btrim(p_record_id) = ''
    OR p_actor_discord_id IS NULL OR btrim(p_actor_discord_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Record ID and actor Discord ID are required.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_users WHERE discord_id = p_actor_discord_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Actor is not an authorized administrator.';
  END IF;
  IF v_decision NOT IN ('approve', 'deny') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Stat decision must be approve or deny.';
  END IF;
  IF v_decision = 'deny' AND v_note IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A note is required for stat denial.';
  END IF;

  SELECT * INTO v_record
  FROM public.pending_stat_records
  WHERE id = p_record_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Pending stat record not found.';
  END IF;

  IF v_record.status <> 'pending' THEN
    RETURN jsonb_build_object(
      'code', 'already_processed',
      'recordId', v_record.id,
      'finalStatus', v_record.status,
      'applied', false,
      'matchId', v_record.match_id,
      'playerId', v_record.player_id,
      'note', v_record.correction_note,
      'outboxIds', '[]'::jsonb
    );
  END IF;

  SELECT * INTO v_match
  FROM public.matches
  WHERE id = v_record.match_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Related match not found.';
  END IF;

  IF v_decision = 'deny' THEN
    UPDATE public.pending_stat_records
    SET status = 'rejected',
        reviewed_by_discord_id = p_actor_discord_id,
        reviewed_at = now(),
        correction_note = v_note,
        updated_at = now()
    WHERE id = v_record.id;

    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, actor_discord_id,
      old_value_json, new_value_json, note
    ) VALUES (
      'stat_rejected', 'pending_stat_record', v_record.id, p_actor_discord_id,
      jsonb_build_object('status', 'pending'),
      jsonb_build_object('status', 'rejected'),
      v_note
    );
  ELSE
    IF v_record.player_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.players WHERE id = v_record.player_id
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Stat approval requires a known player.';
    END IF;
    IF v_match.status <> 'completed' OR v_match.winner_org_id IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Stats cannot be approved before the match result is completed.';
    END IF;

    v_stats := COALESCE(v_record.stats_json, v_record.extracted_json);
    IF v_stats IS NULL OR jsonb_typeof(v_stats) <> 'object' THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Stat payload must be a JSON object.';
    END IF;
    IF jsonb_typeof(v_stats -> 'game_number') IS DISTINCT FROM 'number'
      OR (v_stats ->> 'game_number')::numeric <> trunc((v_stats ->> 'game_number')::numeric)
      OR (v_stats ->> 'game_number')::integer < 1 THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Stat payload requires a positive integer game_number.';
    END IF;
    v_game_number := (v_stats ->> 'game_number')::integer;

    FOREACH v_key IN ARRAY ARRAY[
      'kills', 'deaths', 'assists', 'damage_dealt',
      'damage_mitigated', 'healing_done'
    ] LOOP
      IF v_stats ? v_key AND (
        jsonb_typeof(v_stats -> v_key) <> 'number'
        OR (v_stats ->> v_key)::numeric <> trunc((v_stats ->> v_key)::numeric)
        OR (v_stats ->> v_key)::numeric < 0
      ) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Stat counters must be non-negative integers.';
      END IF;
    END LOOP;

    IF v_stats ? 'org_id' AND jsonb_typeof(v_stats -> 'org_id') <> 'string' THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Stat org_id must be a string.';
    END IF;
    IF v_stats ? 'god_played' AND jsonb_typeof(v_stats -> 'god_played') <> 'string' THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Stat god_played must be a string.';
    END IF;
    IF v_stats ? 'godPlayed' AND jsonb_typeof(v_stats -> 'godPlayed') <> 'string' THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Stat godPlayed must be a string.';
    END IF;
    IF v_stats ? 'role' AND jsonb_typeof(v_stats -> 'role') <> 'string' THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Stat role must be a string.';
    END IF;

    v_player_org_id := NULLIF(v_stats ->> 'org_id', '');
    IF v_player_org_id IS NULL THEN
      SELECT org_id INTO v_player_org_id FROM public.players WHERE id = v_record.player_id;
    END IF;
    IF v_player_org_id IS NULL
      OR v_player_org_id NOT IN (v_match.home_org_id, v_match.away_org_id) THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Player organization is not part of the match.';
    END IF;
    v_won := v_player_org_id = v_match.winner_org_id;

    SELECT to_jsonb(ps), ps.id INTO v_old_stat, v_stat_id
    FROM public.player_stats ps
    WHERE ps.match_id = v_record.match_id
      AND ps.player_id = v_record.player_id
      AND ps.game_number = v_game_number
    FOR UPDATE;

    INSERT INTO public.player_stats (
      match_id, player_id, pending_stat_record_id, game_number, won,
      kills, deaths, assists, damage_dealt, damage_mitigated,
      healing_done, god_played, role
    ) VALUES (
      v_record.match_id,
      v_record.player_id,
      v_record.id,
      v_game_number,
      v_won,
      CASE WHEN v_stats ? 'kills' THEN (v_stats ->> 'kills')::integer END,
      CASE WHEN v_stats ? 'deaths' THEN (v_stats ->> 'deaths')::integer END,
      CASE WHEN v_stats ? 'assists' THEN (v_stats ->> 'assists')::integer END,
      CASE WHEN v_stats ? 'damage_dealt' THEN (v_stats ->> 'damage_dealt')::integer END,
      CASE WHEN v_stats ? 'damage_mitigated' THEN (v_stats ->> 'damage_mitigated')::integer END,
      CASE WHEN v_stats ? 'healing_done' THEN (v_stats ->> 'healing_done')::integer END,
      COALESCE(v_stats ->> 'god_played', v_stats ->> 'godPlayed'),
      v_stats ->> 'role'
    )
    ON CONFLICT (match_id, player_id, game_number) DO UPDATE SET
      pending_stat_record_id = EXCLUDED.pending_stat_record_id,
      won = EXCLUDED.won,
      kills = EXCLUDED.kills,
      deaths = EXCLUDED.deaths,
      assists = EXCLUDED.assists,
      damage_dealt = EXCLUDED.damage_dealt,
      damage_mitigated = EXCLUDED.damage_mitigated,
      healing_done = EXCLUDED.healing_done,
      god_played = EXCLUDED.god_played,
      role = EXCLUDED.role
    RETURNING id INTO v_stat_id;

    SELECT to_jsonb(ps) INTO v_new_stat FROM public.player_stats ps WHERE ps.id = v_stat_id;

    UPDATE public.players
    SET stats = (
      SELECT jsonb_build_object(
        'kills', COALESCE(sum(COALESCE(ps.kills, 0)), 0),
        'deaths', COALESCE(sum(COALESCE(ps.deaths, 0)), 0),
        'assists', COALESCE(sum(COALESCE(ps.assists, 0)), 0),
        'gamesPlayed', count(*),
        'wins', count(*) FILTER (WHERE ps.won IS TRUE)
      )
      FROM public.player_stats ps
      WHERE ps.player_id = v_record.player_id
    )
    WHERE id = v_record.player_id;

    UPDATE public.pending_stat_records
    SET status = 'approved',
        reviewed_by_discord_id = p_actor_discord_id,
        reviewed_at = now(),
        correction_note = v_note,
        updated_at = now()
    WHERE id = v_record.id;

    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, actor_discord_id,
      old_value_json, new_value_json, note
    ) VALUES (
      'stat_approved', 'player_stat', v_stat_id, p_actor_discord_id,
      v_old_stat, v_new_stat, v_note
    );
    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, actor_discord_id,
      old_value_json, new_value_json, note
    ) VALUES (
      'stat_approved', 'pending_stat_record', v_record.id, p_actor_discord_id,
      jsonb_build_object('status', 'pending'),
      jsonb_build_object('status', 'approved', 'playerStatId', v_stat_id),
      v_note
    );
  END IF;

  v_outbox_ids := array_append(v_outbox_ids, public.enqueue_operation_outbox(
    'discord_review_projection', 'pending_stat_record', v_record.id,
    'pending_stat_record_' || CASE WHEN v_decision = 'approve' THEN 'approved' ELSE 'rejected' END,
    'pending_stat_record:' || v_record.id || ':' || v_decision || ':admin_review',
    jsonb_build_object(
      'recordId', v_record.id,
      'matchId', v_record.match_id,
      'playerId', v_record.player_id,
      'finalStatus', CASE WHEN v_decision = 'approve' THEN 'approved' ELSE 'rejected' END
    )
  ));
  IF v_decision = 'approve' THEN
    v_outbox_ids := array_append(v_outbox_ids, public.enqueue_operation_outbox(
      'standings_recalculation', 'match', v_record.match_id,
      'stat_record_approved',
      'pending_stat_record:' || v_record.id || ':approved:standings_recalculation',
      jsonb_build_object(
        'recordId', v_record.id,
        'matchId', v_record.match_id,
        'seasonId', v_match.season_id,
        'outboxIdempotencyKey', 'pending_stat_record:' || v_record.id || ':standings'
      )
    ));
  END IF;

  RETURN jsonb_build_object(
    'code', 'applied',
    'recordId', v_record.id,
    'finalStatus', CASE WHEN v_decision = 'approve' THEN 'approved' ELSE 'rejected' END,
    'applied', v_decision = 'approve',
    'matchId', v_record.match_id,
    'playerId', v_record.player_id,
    'note', v_note,
    'outboxIds', to_jsonb(v_outbox_ids)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_operation_outbox(
  p_worker_id text,
  p_limit integer DEFAULT 25
) RETURNS SETOF public.operation_outbox
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_worker_id IS NULL OR btrim(p_worker_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Worker ID is required.';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Claim limit must be between 1 and 100.';
  END IF;

  UPDATE public.operation_outbox
  SET state = 'dead_letter',
      lease_owner = NULL,
      lease_expires_at = NULL,
      last_error = COALESCE(last_error, 'Lease expired after the tenth attempt.'),
      updated_at = now()
  WHERE state = 'processing'
    AND lease_expires_at <= now()
    AND attempts >= 10;

  RETURN QUERY
  WITH candidates AS (
    SELECT o.id
    FROM public.operation_outbox o
    WHERE o.attempts < 10
      AND (
        (o.state = 'pending' AND o.available_at <= now())
        OR
        (o.state = 'processing' AND o.lease_expires_at <= now())
      )
    ORDER BY o.available_at, o.created_at
    FOR UPDATE SKIP LOCKED
    LIMIT p_limit
  )
  UPDATE public.operation_outbox o
  SET state = 'processing',
      attempts = o.attempts + 1,
      lease_owner = p_worker_id,
      lease_expires_at = now() + interval '60 seconds',
      updated_at = now()
  FROM candidates c
  WHERE o.id = c.id
  RETURNING o.*;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_operation_outbox(
  p_outbox_id uuid,
  p_worker_id text,
  p_external_id text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_row public.operation_outbox%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM public.operation_outbox
  WHERE id = p_outbox_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Outbox row not found.';
  END IF;

  IF v_row.state = 'completed' THEN
    RETURN jsonb_build_object(
      'code', 'already_completed', 'outboxId', v_row.id,
      'state', v_row.state, 'externalId', v_row.external_id
    );
  END IF;
  IF v_row.state <> 'processing'
    OR v_row.lease_owner <> p_worker_id
    OR v_row.lease_expires_at <= now() THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Worker does not own an active lease for this outbox row.';
  END IF;

  UPDATE public.operation_outbox
  SET state = 'completed',
      external_id = COALESCE(p_external_id, external_id),
      completed_at = now(),
      lease_owner = NULL,
      lease_expires_at = NULL,
      last_error = NULL,
      updated_at = now()
  WHERE id = p_outbox_id;

  RETURN jsonb_build_object(
    'code', 'completed', 'outboxId', p_outbox_id,
    'state', 'completed', 'externalId', p_external_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.fail_operation_outbox(
  p_outbox_id uuid,
  p_worker_id text,
  p_error text,
  p_retry_after_seconds integer DEFAULT 5
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_row public.operation_outbox%ROWTYPE;
  v_next_state text;
  v_retry_after integer;
BEGIN
  IF p_error IS NULL OR btrim(p_error) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Failure error is required.';
  END IF;
  v_retry_after := LEAST(GREATEST(COALESCE(p_retry_after_seconds, 5), 0), 900);

  SELECT * INTO v_row
  FROM public.operation_outbox
  WHERE id = p_outbox_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Outbox row not found.';
  END IF;
  IF v_row.state <> 'processing'
    OR v_row.lease_owner <> p_worker_id
    OR v_row.lease_expires_at <= now() THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Worker does not own an active lease for this outbox row.';
  END IF;

  v_next_state := CASE WHEN v_row.attempts >= 10 THEN 'dead_letter' ELSE 'pending' END;
  UPDATE public.operation_outbox
  SET state = v_next_state,
      available_at = CASE
        WHEN v_next_state = 'pending' THEN now() + make_interval(secs => v_retry_after)
        ELSE available_at
      END,
      lease_owner = NULL,
      lease_expires_at = NULL,
      last_error = left(p_error, 4000),
      updated_at = now()
  WHERE id = p_outbox_id;

  RETURN jsonb_build_object(
    'code', CASE WHEN v_next_state = 'dead_letter' THEN 'dead_lettered' ELSE 'retry_scheduled' END,
    'outboxId', p_outbox_id,
    'state', v_next_state,
    'attempts', v_row.attempts,
    'availableAt', CASE
      WHEN v_next_state = 'pending' THEN now() + make_interval(secs => v_retry_after)
      ELSE NULL
    END
  );
END;
$$;

COMMENT ON TABLE public.operation_outbox IS
  'Service-role-only durable projections committed with domain and audit mutations.';
COMMENT ON FUNCTION public.claim_operation_outbox(text, integer) IS
  'Claims available rows with FOR UPDATE SKIP LOCKED and a fixed 60-second lease.';

REVOKE ALL ON FUNCTION public.enqueue_operation_outbox(text, text, text, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_pending_action(text, text, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.resolve_pending_action(text, text, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.resolve_pending_stat_record(text, text, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_operation_outbox(text, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_operation_outbox(uuid, text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fail_operation_outbox(uuid, text, text, integer)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.enqueue_operation_outbox(text, text, text, text, text, jsonb)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.create_pending_action(text, text, text, text, jsonb)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.resolve_pending_action(text, text, text, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.resolve_pending_stat_record(text, text, text, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_operation_outbox(text, integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_operation_outbox(uuid, text, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.fail_operation_outbox(uuid, text, text, integer)
  TO service_role;
