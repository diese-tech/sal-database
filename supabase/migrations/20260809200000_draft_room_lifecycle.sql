-- Give league operators a safe recovery path for stale draft rooms. Unused
-- pending rooms may be deleted; opened rooms become terminal, audited voids so
-- their competitive history remains intact and a replacement may be created.

ALTER TABLE public.draft_rooms
  ADD COLUMN voided_at timestamptz,
  ADD COLUMN voided_by_discord_id text,
  ADD COLUMN void_reason text;

ALTER TABLE public.draft_rooms
  DROP CONSTRAINT draft_rooms_status_check,
  ADD CONSTRAINT draft_rooms_status_check
    CHECK (status = ANY (ARRAY['pending', 'active', 'paused', 'complete', 'voided']));

ALTER TABLE public.draft_rooms
  DROP CONSTRAINT draft_rooms_season_id_division_id_key;

CREATE UNIQUE INDEX draft_rooms_live_season_division_key
  ON public.draft_rooms (season_id, division_id)
  WHERE status IN ('pending', 'active', 'paused');

CREATE OR REPLACE FUNCTION public.delete_pending_draft_room(
  p_draft_room_id text,
  p_actor_discord_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_room_id text := NULLIF(btrim(COALESCE(p_draft_room_id, '')), '');
  v_actor_id text := NULLIF(btrim(COALESCE(p_actor_discord_id, '')), '');
  v_room public.draft_rooms%ROWTYPE;
  v_snapshot jsonb;
BEGIN
  IF v_room_id IS NULL OR v_actor_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Draft room and actor IDs are required.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.admin_users
    WHERE discord_id = v_actor_id AND role IN ('admin', 'super_admin')
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Only a SAL admin can manage draft room lifecycle.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('draft-room-lifecycle:' || v_room_id, 0));

  SELECT * INTO v_room
  FROM public.draft_rooms
  WHERE id = v_room_id
  FOR UPDATE;

  IF v_room.id IS NULL THEN
    IF EXISTS (
      SELECT 1 FROM public.audit_logs
      WHERE action_type = 'draft_room_deleted'
        AND entity_type = 'draft_room'
        AND entity_id = v_room_id
    ) THEN
      RETURN jsonb_build_object(
        'code', 'already_deleted',
        'applied', false,
        'draftRoomId', v_room_id
      );
    END IF;

    RAISE EXCEPTION USING
      ERRCODE = 'P0002',
      MESSAGE = 'Draft room does not exist.';
  END IF;

  IF v_room.status <> 'pending' THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Only an unused pending draft room can be deleted.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.draft_picks WHERE draft_room_id = v_room_id) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Pending draft room has draft picks and must be preserved.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.captain_tokens WHERE draft_room_id = v_room_id) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Pending draft room has captain tokens and must be preserved.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.captain_shortlists WHERE draft_room_id = v_room_id) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Pending draft room has captain shortlists and must be preserved.';
  END IF;

  v_snapshot := to_jsonb(v_room);

  INSERT INTO public.audit_logs (
    action_type,
    entity_type,
    entity_id,
    actor_discord_id,
    old_value_json,
    new_value_json,
    note
  ) VALUES (
    'draft_room_deleted',
    'draft_room',
    v_room_id,
    v_actor_id,
    v_snapshot,
    NULL,
    'Deleted an unused pending draft room.'
  );

  INSERT INTO public.admin_audit_log (action, entity_type, entity_id, payload)
  VALUES (
    'delete_pending_draft_room',
    'draft_room',
    v_room_id,
    jsonb_build_object(
      'actorDiscordId', v_actor_id,
      'room', v_snapshot
    )
  );

  DELETE FROM public.draft_rooms WHERE id = v_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Draft room % disappeared during deletion.', v_room_id;
  END IF;

  RETURN jsonb_build_object(
    'code', 'deleted',
    'applied', true,
    'draftRoomId', v_room_id,
    'room', v_snapshot
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.void_draft_room(
  p_draft_room_id text,
  p_actor_discord_id text,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_room_id text := NULLIF(btrim(COALESCE(p_draft_room_id, '')), '');
  v_actor_id text := NULLIF(btrim(COALESCE(p_actor_discord_id, '')), '');
  v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_room public.draft_rooms%ROWTYPE;
  v_old_value jsonb;
  v_new_value jsonb;
BEGIN
  IF v_room_id IS NULL OR v_actor_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Draft room and actor IDs are required.';
  END IF;

  IF v_reason IS NULL OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A void reason between 1 and 500 characters is required.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.admin_users
    WHERE discord_id = v_actor_id AND role IN ('admin', 'super_admin')
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Only a SAL admin can manage draft room lifecycle.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('draft-room-lifecycle:' || v_room_id, 0));

  SELECT * INTO v_room
  FROM public.draft_rooms
  WHERE id = v_room_id
  FOR UPDATE;

  IF v_room.id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0002',
      MESSAGE = 'Draft room does not exist.';
  END IF;

  IF v_room.status = 'voided' THEN
    RETURN jsonb_build_object(
      'code', 'already_voided',
      'applied', false,
      'draftRoomId', v_room_id,
      'room', to_jsonb(v_room)
    );
  END IF;

  IF v_room.status = 'complete' THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Completed draft rooms are immutable and cannot be voided.';
  END IF;

  IF v_room.status = 'pending' THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Pending draft rooms must use the delete-pending workflow.';
  END IF;

  IF v_room.status NOT IN ('active', 'paused') THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Only active or paused draft rooms can be voided.';
  END IF;

  v_old_value := to_jsonb(v_room);

  UPDATE public.draft_rooms
  SET
    status = 'voided',
    voided_at = now(),
    voided_by_discord_id = v_actor_id,
    void_reason = v_reason,
    pick_started_at = NULL
  WHERE id = v_room_id
  RETURNING to_jsonb(draft_rooms.*) INTO v_new_value;

  INSERT INTO public.audit_logs (
    action_type,
    entity_type,
    entity_id,
    actor_discord_id,
    old_value_json,
    new_value_json,
    note
  ) VALUES (
    'draft_room_voided',
    'draft_room',
    v_room_id,
    v_actor_id,
    v_old_value,
    v_new_value || jsonb_build_object('reason', v_reason),
    v_reason
  );

  INSERT INTO public.admin_audit_log (action, entity_type, entity_id, payload)
  VALUES (
    'void_draft_room',
    'draft_room',
    v_room_id,
    jsonb_build_object(
      'actorDiscordId', v_actor_id,
      'reason', v_reason,
      'oldRoom', v_old_value,
      'newRoom', v_new_value
    )
  );

  RETURN jsonb_build_object(
    'code', 'voided',
    'applied', true,
    'draftRoomId', v_room_id,
    'room', v_new_value
  );
END;
$$;

ALTER FUNCTION public.delete_pending_draft_room(text, text) OWNER TO postgres;
ALTER FUNCTION public.void_draft_room(text, text, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.delete_pending_draft_room(text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.void_draft_room(text, text, text)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.delete_pending_draft_room(text, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.void_draft_room(text, text, text)
  TO service_role;

COMMENT ON FUNCTION public.delete_pending_draft_room(text, text) IS
  'Atomically deletes an unused pending draft room, records the acting admin, and treats exact retries as idempotent.';
COMMENT ON FUNCTION public.void_draft_room(text, text, text) IS
  'Atomically voids an active or paused draft room while preserving history and recording actor-attributed audit evidence.';
