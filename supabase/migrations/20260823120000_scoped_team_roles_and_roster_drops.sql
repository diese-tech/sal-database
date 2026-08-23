-- Division team roles and roster drops extend the canonical roster transaction
-- ledger. Discord remains a projection: no captain interaction mutates a
-- roster, and completed transactions publish/reconcile only through outbox
-- rows committed with the database change.

CREATE TABLE public.season_organization_role_mappings (
  season_id text NOT NULL,
  division_id text NOT NULL,
  org_id text NOT NULL,
  discord_role_id text NOT NULL,
  updated_by_discord_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, division_id, org_id),
  CONSTRAINT season_organization_role_mappings_team_fkey
    FOREIGN KEY (season_id, org_id, division_id)
    REFERENCES public.season_orgs(season_id, org_id, division_id)
    ON DELETE CASCADE,
  CONSTRAINT season_organization_role_mappings_role_format_check
    CHECK (discord_role_id ~ '^[0-9]{17,20}$'),
  CONSTRAINT season_organization_role_mappings_role_key
    UNIQUE (season_id, discord_role_id)
);

ALTER TABLE public.season_organization_role_mappings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.season_organization_role_mappings FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.season_organization_role_mappings TO service_role;

CREATE OR REPLACE FUNCTION public.set_season_organization_role_mappings(
  p_actor_discord_id text,
  p_season_id text,
  p_mappings jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_old jsonb;
  v_new jsonb;
  v_count integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_users WHERE discord_id = p_actor_discord_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Actor is not an authorized administrator.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.seasons WHERE id = p_season_id) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Season does not exist.';
  END IF;
  IF jsonb_typeof(p_mappings) <> 'array' OR jsonb_array_length(p_mappings) = 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Mappings must be a non-empty JSON array.';
  END IF;

  SELECT count(*) INTO v_count
  FROM jsonb_to_recordset(p_mappings) AS item(
    division_id text, org_id text, discord_role_id text
  );
  IF v_count <> jsonb_array_length(p_mappings)
     OR EXISTS (
       SELECT 1
       FROM jsonb_to_recordset(p_mappings) AS item(
         division_id text, org_id text, discord_role_id text
       )
       WHERE item.division_id IS NULL OR btrim(item.division_id) = ''
          OR item.org_id IS NULL OR btrim(item.org_id) = ''
          OR item.discord_role_id IS NULL
          OR btrim(item.discord_role_id) !~ '^[0-9]{17,20}$'
     ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Each mapping requires valid division, organization, and Discord role IDs.';
  END IF;
  IF v_count <> (
    SELECT count(*) FROM (
      SELECT DISTINCT btrim(item.division_id), btrim(item.org_id)
      FROM jsonb_to_recordset(p_mappings) AS item(
        division_id text, org_id text, discord_role_id text
      )
    ) AS distinct_teams
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Mappings contain a duplicate season team.';
  END IF;
  IF v_count <> (
    SELECT count(DISTINCT btrim(item.discord_role_id))
    FROM jsonb_to_recordset(p_mappings) AS item(
      division_id text, org_id text, discord_role_id text
    )
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A Discord team role cannot be assigned more than once in a season.';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_mappings) AS input(
      division_id text, org_id text, discord_role_id text
    )
    LEFT JOIN public.season_orgs AS team
      ON team.season_id = p_season_id
     AND team.division_id = btrim(input.division_id)
     AND team.org_id = btrim(input.org_id)
    WHERE team.season_id IS NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'A mapping does not belong to the selected season.';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('season-team-role-mappings:' || p_season_id, 0)
  );

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'divisionId', mapping.division_id,
    'orgId', mapping.org_id,
    'discordRoleId', mapping.discord_role_id
  ) ORDER BY mapping.division_id, mapping.org_id), '[]'::jsonb)
  INTO v_old
  FROM public.season_organization_role_mappings AS mapping
  JOIN jsonb_to_recordset(p_mappings) AS input(
    division_id text, org_id text, discord_role_id text
  )
    ON btrim(input.division_id) = mapping.division_id
   AND btrim(input.org_id) = mapping.org_id
  WHERE mapping.season_id = p_season_id;

  -- Remove the reviewed team keys before inserting their complete replacement
  -- set. This keeps role exchanges such as A:r1/B:r2 -> A:r2/B:r1 atomic
  -- without weakening the season-wide Discord-role uniqueness constraint.
  DELETE FROM public.season_organization_role_mappings AS mapping
  USING jsonb_to_recordset(p_mappings) AS input(
    division_id text, org_id text, discord_role_id text
  )
  WHERE mapping.season_id = p_season_id
    AND mapping.division_id = btrim(input.division_id)
    AND mapping.org_id = btrim(input.org_id);

  INSERT INTO public.season_organization_role_mappings (
    season_id, division_id, org_id, discord_role_id, updated_by_discord_id
  )
  SELECT p_season_id, btrim(input.division_id), btrim(input.org_id),
         btrim(input.discord_role_id), p_actor_discord_id
  FROM jsonb_to_recordset(p_mappings) AS input(
    division_id text, org_id text, discord_role_id text
  );

  SELECT jsonb_agg(jsonb_build_object(
    'divisionId', division_id,
    'orgId', org_id,
    'discordRoleId', discord_role_id
  ) ORDER BY division_id, org_id)
  INTO v_new
  FROM (
    SELECT btrim(item.division_id) AS division_id,
           btrim(item.org_id) AS org_id,
           btrim(item.discord_role_id) AS discord_role_id
    FROM jsonb_to_recordset(p_mappings) AS item(
      division_id text, org_id text, discord_role_id text
    )
  ) AS normalized_input;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, actor_discord_id,
    old_value_json, new_value_json, note
  ) VALUES (
    'season_team_role_mappings_updated', 'season_team_role_mappings', p_season_id,
    p_actor_discord_id, v_old, v_new,
    format('Updated %s season-scoped Discord team role mappings.', v_count)
  );

  RETURN jsonb_build_object('code', 'updated', 'seasonId', p_season_id, 'updatedCount', v_count);
END;
$$;

ALTER TABLE public.season_transaction_settings
  ADD COLUMN drops_open boolean NOT NULL DEFAULT false;

ALTER TABLE public.pending_actions
  DROP CONSTRAINT pending_actions_type_check,
  ADD CONSTRAINT pending_actions_type_check CHECK (
    type IN (
      'match_result', 'reschedule', 'admin_review', 'alias_change',
      'roster_trade', 'roster_drop'
    )
  );

ALTER TABLE public.roster_transactions
  DROP CONSTRAINT roster_transactions_transaction_type_check,
  DROP CONSTRAINT roster_transactions_distinct_orgs,
  ALTER COLUMN receiver_org_id DROP NOT NULL,
  ADD COLUMN drop_eligibility_status text,
  ADD COLUMN drop_suspended_until timestamptz,
  ADD COLUMN drop_private_note text,
  ADD CONSTRAINT roster_transactions_transaction_type_check
    CHECK (transaction_type IN ('trade', 'drop')),
  ADD CONSTRAINT roster_transactions_participants_check CHECK (
    (transaction_type = 'trade' AND receiver_org_id IS NOT NULL AND proposer_org_id <> receiver_org_id)
    OR
    (transaction_type = 'drop' AND receiver_org_id IS NULL)
  ),
  ADD CONSTRAINT roster_transactions_drop_eligibility_check CHECK (
    (transaction_type = 'trade'
      AND drop_eligibility_status IS NULL
      AND drop_suspended_until IS NULL
      AND drop_private_note IS NULL)
    OR
    (transaction_type = 'drop'
      AND (drop_eligibility_status IS NULL OR drop_eligibility_status IN (
        'eligible', 'suspended_until', 'ineligible_for_season'
      ))
      AND (
        (drop_eligibility_status = 'suspended_until' AND drop_suspended_until IS NOT NULL)
        OR
        (drop_eligibility_status IS DISTINCT FROM 'suspended_until' AND drop_suspended_until IS NULL)
      ))
  );

ALTER TABLE public.roster_transaction_revisions
  DROP CONSTRAINT roster_transaction_revisions_distinct_orgs,
  ALTER COLUMN receiver_org_id DROP NOT NULL,
  ADD CONSTRAINT roster_transaction_revisions_participants_check
    CHECK (receiver_org_id IS NULL OR proposer_org_id <> receiver_org_id);

ALTER TABLE public.roster_transaction_movements
  DROP CONSTRAINT roster_transaction_movements_distinct_orgs,
  ALTER COLUMN to_org_id DROP NOT NULL,
  ADD CONSTRAINT roster_transaction_movements_distinct_orgs
    CHECK (to_org_id IS NULL OR from_org_id <> to_org_id);

CREATE TABLE public.season_player_eligibility (
  season_id text NOT NULL REFERENCES public.seasons(id) ON DELETE CASCADE,
  division_id text NOT NULL REFERENCES public.divisions(id),
  player_id text NOT NULL REFERENCES public.players(id),
  status text NOT NULL CHECK (status IN ('eligible', 'suspended_until', 'ineligible_for_season')),
  suspended_until timestamptz,
  source_transaction_id uuid REFERENCES public.roster_transactions(id) ON DELETE RESTRICT,
  private_note text,
  updated_by_discord_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, player_id),
  CONSTRAINT season_player_eligibility_suspension_check CHECK (
    (status = 'suspended_until' AND suspended_until IS NOT NULL)
    OR (status <> 'suspended_until' AND suspended_until IS NULL)
  )
);

ALTER TABLE public.season_player_eligibility ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.season_player_eligibility FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.season_player_eligibility TO service_role;

CREATE OR REPLACE FUNCTION public.create_roster_drop(
  p_actor_discord_id text,
  p_season_id text,
  p_division_id text,
  p_org_id text,
  p_player_id text,
  p_source text DEFAULT 'discord_workflow'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_transaction_id uuid := gen_random_uuid();
  v_action_id text := gen_random_uuid()::text;
  v_outbox_id uuid;
BEGIN
  IF p_actor_discord_id IS NULL OR btrim(p_actor_discord_id) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Actor Discord ID is required.';
  END IF;
  IF p_source NOT IN ('discord_workflow', 'web_workflow', 'manual_reconciliation', 'migration') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Unsupported roster transaction source.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.seasons
    WHERE id = p_season_id AND is_current AND status = 'active'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Drops require the active current season.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.season_transaction_settings
    WHERE season_id = p_season_id AND division_id = p_division_id AND drops_open
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Drops are not open for this season and division.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.season_orgs
    WHERE season_id = p_season_id AND division_id = p_division_id
      AND org_id = p_org_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Organization is not active in this season division.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.season_rosters
    WHERE season_id = p_season_id AND division_id = p_division_id
      AND org_id = p_org_id AND player_id = p_player_id AND roster_status = 'active'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Player is no longer on that active roster.';
  END IF;

  INSERT INTO public.pending_actions (
    id, type, status, requested_by_discord_id, division_id, payload_json
  ) VALUES (
    v_action_id, 'roster_drop', 'pending', p_actor_discord_id, p_division_id,
    jsonb_build_object(
      'transactionId', v_transaction_id, 'revision', 1, 'source', p_source,
      'orgId', p_org_id, 'playerId', p_player_id
    )
  );
  INSERT INTO public.roster_transactions (
    id, transaction_type, source, season_id, division_id,
    proposer_org_id, receiver_org_id, status, pending_action_id,
    initiated_by_discord_id
  ) VALUES (
    v_transaction_id, 'drop', p_source, p_season_id, p_division_id,
    p_org_id, NULL, 'awaiting_admin', v_action_id, p_actor_discord_id
  );
  INSERT INTO public.roster_transaction_revisions (
    transaction_id, revision, proposer_org_id, receiver_org_id,
    status, created_by_discord_id
  ) VALUES (
    v_transaction_id, 1, p_org_id, NULL, 'accepted', p_actor_discord_id
  );
  INSERT INTO public.roster_transaction_movements (
    transaction_id, revision, player_id, from_org_id, to_org_id
  ) VALUES (v_transaction_id, 1, p_player_id, p_org_id, NULL);
  INSERT INTO public.roster_transaction_consents (
    transaction_id, revision, org_id, consented, actor_discord_id, consented_at
  ) VALUES (v_transaction_id, 1, p_org_id, true, p_actor_discord_id, now());

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
    old_value_json, new_value_json, note
  ) VALUES (
    'roster_drop_requested', 'roster_transaction', v_transaction_id::text,
    v_action_id, p_actor_discord_id,
    jsonb_build_object('orgId', p_org_id, 'playerId', p_player_id, 'rosterStatus', 'active'),
    jsonb_build_object('status', 'awaiting_admin', 'source', p_source),
    'Created a durable roster-drop request; no roster row changed.'
  );

  v_outbox_id := public.enqueue_operation_outbox(
    'discord_roster_drop_admin_review', 'roster_transaction', v_transaction_id::text,
    'roster_drop_requested', 'roster_transaction:' || v_transaction_id || ':drop:admin_review',
    jsonb_build_object(
      'transactionId', v_transaction_id, 'pendingActionId', v_action_id, 'revision', 1
    )
  );

  RETURN jsonb_build_object(
    'code', 'created', 'transactionId', v_transaction_id, 'revision', 1,
    'pendingActionId', v_action_id, 'status', 'awaiting_admin',
    'outboxIds', jsonb_build_array(v_outbox_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION private.execute_roster_drop(
  p_transaction_id uuid,
  p_actor_discord_id text,
  p_eligibility_status text,
  p_suspended_until timestamptz,
  p_note text
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_drop public.roster_transactions%ROWTYPE;
  v_player_id text;
  v_player_name text;
  v_player_discord_id text;
  v_outbox_ids uuid[] := ARRAY[]::uuid[];
  v_outbox_id uuid;
BEGIN
  SELECT * INTO v_drop FROM public.roster_transactions
  WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND OR v_drop.transaction_type <> 'drop' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Roster drop not found.';
  END IF;
  IF v_drop.status NOT IN ('awaiting_admin', 'blocked') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Drop is not awaiting administrator execution.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.roster_transaction_consents
    WHERE transaction_id = v_drop.id AND revision = v_drop.current_revision
      AND org_id = v_drop.proposer_org_id AND consented
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'The roster drop does not have organization consent.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.seasons
    WHERE id = v_drop.season_id AND is_current AND status = 'active'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'The transaction season is no longer the active current season.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.season_transaction_settings
    WHERE season_id = v_drop.season_id AND division_id = v_drop.division_id AND drops_open
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Drops are closed for this season division.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.season_orgs
    WHERE season_id = v_drop.season_id AND division_id = v_drop.division_id
      AND org_id = v_drop.proposer_org_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'The organization is no longer active in this season division.';
  END IF;

  SELECT movement.player_id, COALESCE(player.display_alias, player.ign), player.discord_id
  INTO v_player_id, v_player_name, v_player_discord_id
  FROM public.roster_transaction_movements AS movement
  JOIN public.players AS player ON player.id = movement.player_id
  WHERE movement.transaction_id = v_drop.id AND movement.revision = v_drop.current_revision
  FOR UPDATE OF movement;
  IF v_player_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'The roster drop movement is missing.';
  END IF;

  PERFORM roster.player_id
  FROM public.season_rosters AS roster
  WHERE roster.season_id = v_drop.season_id AND roster.player_id = v_player_id
  FOR UPDATE;
  IF NOT EXISTS (
    SELECT 1 FROM public.season_rosters
    WHERE season_id = v_drop.season_id AND player_id = v_player_id
      AND division_id = v_drop.division_id AND org_id = v_drop.proposer_org_id
      AND roster_status = 'active'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'The player is no longer owned by the expected organization.';
  END IF;

  UPDATE public.roster_transactions
  SET execution_claimed_at = now(), drop_eligibility_status = p_eligibility_status,
      drop_suspended_until = p_suspended_until, drop_private_note = p_note,
      updated_at = now()
  WHERE id = v_drop.id;

  UPDATE public.season_rosters
  SET org_id = NULL, roster_status = 'free_agent', is_captain = false, updated_at = now()
  WHERE season_id = v_drop.season_id AND player_id = v_player_id;

  INSERT INTO public.season_player_eligibility (
    season_id, division_id, player_id, status, suspended_until,
    source_transaction_id, private_note, updated_by_discord_id
  ) VALUES (
    v_drop.season_id, v_drop.division_id, v_player_id, p_eligibility_status,
    p_suspended_until, v_drop.id, p_note, p_actor_discord_id
  )
  ON CONFLICT (season_id, player_id) DO UPDATE
  SET division_id = EXCLUDED.division_id,
      status = EXCLUDED.status,
      suspended_until = EXCLUDED.suspended_until,
      source_transaction_id = EXCLUDED.source_transaction_id,
      private_note = EXCLUDED.private_note,
      updated_by_discord_id = EXCLUDED.updated_by_discord_id,
      updated_at = now();

  UPDATE public.roster_transaction_revisions SET status = 'completed'
  WHERE transaction_id = v_drop.id AND revision = v_drop.current_revision;
  UPDATE public.roster_transactions
  SET status = 'completed', completed_at = now(),
      admin_decided_by_discord_id = p_actor_discord_id,
      admin_decided_at = now(), admin_note = p_note, updated_at = now()
  WHERE id = v_drop.id;
  UPDATE public.pending_actions
  SET status = 'approved', approved_by_discord_id = p_actor_discord_id,
      approved_at = now(), admin_note = p_note, updated_at = now()
  WHERE id = v_drop.pending_action_id;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
    old_value_json, new_value_json, note
  ) VALUES (
    'roster_drop_completed', 'roster_transaction', v_drop.id::text,
    v_drop.pending_action_id, p_actor_discord_id,
    jsonb_build_object(
      'status', 'awaiting_admin', 'playerId', v_player_id,
      'orgId', v_drop.proposer_org_id, 'rosterStatus', 'active'
    ),
    jsonb_build_object(
      'status', 'completed', 'playerId', v_player_id,
      'orgId', NULL, 'rosterStatus', 'free_agent',
      'eligibilityStatus', p_eligibility_status,
      'suspendedUntil', p_suspended_until
    ),
    COALESCE(p_note, 'Administrator completed the roster drop from canonical roster state.')
  );

  v_outbox_id := public.enqueue_operation_outbox(
    'discord_transaction_bulletin', 'roster_transaction', v_drop.id::text,
    'roster_drop_completed', 'roster_transaction:' || v_drop.id || ':completed:bulletin',
    jsonb_build_object(
      'operationId', v_drop.id, 'transactionId', v_drop.id,
      'transactionType', 'drop', 'revision', v_drop.current_revision,
      'divisionId', v_drop.division_id, 'proposerOrgId', v_drop.proposer_org_id,
      'movements', jsonb_build_array(jsonb_build_object(
        'playerId', v_player_id, 'playerName', v_player_name,
        'discordId', v_player_discord_id, 'fromOrgId', v_drop.proposer_org_id,
        'toOrgId', NULL
      ))
    )
  );
  v_outbox_ids := array_append(v_outbox_ids, v_outbox_id);
  IF EXISTS (
    SELECT 1 FROM public.pending_actions
    WHERE id = v_drop.pending_action_id AND admin_review_message_id IS NOT NULL
  ) THEN
    v_outbox_id := public.enqueue_operation_outbox(
      'discord_review_projection', 'pending_action', v_drop.pending_action_id,
      'pending_action_approved', 'roster_transaction:' || v_drop.id || ':completed:admin_review',
      jsonb_build_object(
        'actionId', v_drop.pending_action_id, 'finalStatus', 'approved',
        'transactionId', v_drop.id
      )
    );
    v_outbox_ids := array_append(v_outbox_ids, v_outbox_id);
  END IF;
  v_outbox_id := public.enqueue_operation_outbox(
    'discord_organization_role_reconciliation', 'roster_transaction', v_drop.id::text,
    'roster_drop_completed', 'roster_transaction:' || v_drop.id || ':completed:role_reconciliation',
    jsonb_build_object(
      'operationId', v_drop.id, 'transactionId', v_drop.id,
      'seasonId', v_drop.season_id, 'divisionId', v_drop.division_id,
      'playerIds', jsonb_build_array(v_player_id)
    )
  );
  v_outbox_ids := array_append(v_outbox_ids, v_outbox_id);

  RETURN jsonb_build_object(
    'code', 'completed', 'applied', true,
    'actionId', v_drop.pending_action_id, 'actionType', 'roster_drop',
    'finalStatus', 'approved', 'matchId', NULL, 'note', p_note,
    'transactionId', v_drop.id, 'outboxIds', to_jsonb(v_outbox_ids)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_roster_drop_pending_action(
  p_action_id text,
  p_actor_discord_id text,
  p_decision text,
  p_eligibility_status text DEFAULT NULL,
  p_suspended_until timestamptz DEFAULT NULL,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
  v_action public.pending_actions%ROWTYPE;
  v_drop public.roster_transactions%ROWTYPE;
  v_decision text := lower(btrim(COALESCE(p_decision, '')));
  v_eligibility text := lower(btrim(COALESCE(p_eligibility_status, '')));
  v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_error text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users WHERE discord_id = p_actor_discord_id) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Actor is not an authorized administrator.';
  END IF;
  SELECT * INTO v_action FROM public.pending_actions
  WHERE id = p_action_id AND type = 'roster_drop' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Roster drop pending action not found.';
  END IF;
  SELECT * INTO v_drop FROM public.roster_transactions
  WHERE pending_action_id = p_action_id AND transaction_type = 'drop' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Linked roster drop is missing.';
  END IF;
  IF v_action.status IN ('approved', 'denied', 'cancelled') THEN
    RETURN jsonb_build_object(
      'code', 'already_processed', 'applied', false,
      'actionId', v_action.id, 'actionType', v_action.type,
      'finalStatus', v_action.status, 'matchId', NULL,
      'note', v_action.admin_note, 'outboxIds', '[]'::jsonb
    );
  END IF;
  IF v_decision = 'needs_info' AND v_action.status <> 'pending' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Needs Info is allowed only from pending.';
  END IF;
  IF v_decision IN ('deny', 'needs_info') AND v_note IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A note is required for denial and Needs Info.';
  END IF;

  IF v_decision = 'approve' THEN
    IF v_eligibility NOT IN ('eligible', 'suspended_until', 'ineligible_for_season') THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Approval requires a valid post-drop eligibility status.';
    END IF;
    IF v_eligibility = 'suspended_until' THEN
      IF p_suspended_until IS NULL OR p_suspended_until <= now() THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Suspension approval requires a future expiration time.';
      END IF;
    ELSIF p_suspended_until IS NOT NULL THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Only suspended drops may include a suspension expiration.';
    END IF;
    BEGIN
      IF v_drop.status = 'blocked' THEN
        UPDATE public.roster_transactions
        SET status = 'awaiting_admin', admin_note = NULL, execution_claimed_at = NULL, updated_at = now()
        WHERE id = v_drop.id;
      END IF;
      RETURN private.execute_roster_drop(
        v_drop.id, p_actor_discord_id, v_eligibility, p_suspended_until, v_note
      );
    EXCEPTION WHEN SQLSTATE '23514' OR SQLSTATE '55000' THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      UPDATE public.roster_transactions
      SET status = 'blocked', execution_claimed_at = NULL, admin_note = v_error, updated_at = now()
      WHERE id = v_drop.id;
      UPDATE public.pending_actions
      SET status = 'pending_info', admin_note = v_error, updated_at = now()
      WHERE id = v_action.id;
      INSERT INTO public.audit_logs (
        action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
        old_value_json, new_value_json, note
      ) VALUES (
        'roster_drop_execution_blocked', 'roster_transaction', v_drop.id::text,
        v_action.id, p_actor_discord_id,
        jsonb_build_object('status', v_drop.status),
        jsonb_build_object('status', 'blocked'), v_error
      );
      IF v_action.admin_review_message_id IS NOT NULL THEN
        PERFORM public.enqueue_operation_outbox(
          'discord_review_projection', 'pending_action', v_action.id,
          'pending_action_pending_info', 'roster_transaction:' || v_drop.id || ':blocked:admin_review',
          jsonb_build_object(
            'actionId', v_action.id, 'finalStatus', 'pending_info',
            'transactionId', v_drop.id
          )
        );
      END IF;
      RETURN jsonb_build_object(
        'code', 'blocked', 'applied', false,
        'actionId', v_action.id, 'actionType', v_action.type,
        'finalStatus', 'pending_info', 'matchId', NULL,
        'note', v_error, 'transactionId', v_drop.id,
        'outboxIds', '[]'::jsonb
      );
    END;
  ELSIF v_decision = 'deny' THEN
    UPDATE public.roster_transactions
    SET status = 'denied', admin_decided_by_discord_id = p_actor_discord_id,
        admin_decided_at = now(), admin_note = v_note,
        cancelled_at = now(), updated_at = now()
    WHERE id = v_drop.id;
    UPDATE public.roster_transaction_revisions SET status = 'declined'
    WHERE transaction_id = v_drop.id AND revision = v_drop.current_revision;
    UPDATE public.pending_actions
    SET status = 'denied', approved_by_discord_id = p_actor_discord_id,
        approved_at = now(), admin_note = v_note, updated_at = now()
    WHERE id = v_action.id;
    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
      old_value_json, new_value_json, note
    ) VALUES (
      'roster_drop_denied', 'roster_transaction', v_drop.id::text,
      v_action.id, p_actor_discord_id,
      jsonb_build_object('status', v_drop.status), jsonb_build_object('status', 'denied'), v_note
    );
    IF v_action.admin_review_message_id IS NOT NULL THEN
      PERFORM public.enqueue_operation_outbox(
        'discord_review_projection', 'pending_action', v_action.id,
        'pending_action_denied', 'roster_transaction:' || v_drop.id || ':denied:admin_review',
        jsonb_build_object(
          'actionId', v_action.id, 'finalStatus', 'denied', 'transactionId', v_drop.id
        )
      );
    END IF;
    RETURN jsonb_build_object(
      'code', 'denied', 'applied', true,
      'actionId', v_action.id, 'actionType', v_action.type,
      'finalStatus', 'denied', 'matchId', NULL,
      'note', v_note, 'outboxIds', '[]'::jsonb
    );
  ELSIF v_decision = 'needs_info' THEN
    UPDATE public.pending_actions SET status = 'pending_info', admin_note = v_note, updated_at = now()
    WHERE id = v_action.id;
    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
      old_value_json, new_value_json, note
    ) VALUES (
      'pending_action_needs_info', 'pending_action', v_action.id,
      v_action.id, p_actor_discord_id,
      jsonb_build_object('status', v_action.status),
      jsonb_build_object('status', 'pending_info'), v_note
    );
    IF v_action.admin_review_message_id IS NOT NULL THEN
      PERFORM public.enqueue_operation_outbox(
        'discord_review_projection', 'pending_action', v_action.id,
        'pending_action_pending_info', 'roster_transaction:' || v_drop.id || ':needs_info:admin_review',
        jsonb_build_object(
          'actionId', v_action.id, 'finalStatus', 'pending_info', 'transactionId', v_drop.id
        )
      );
    END IF;
    RETURN jsonb_build_object(
      'code', 'needs_info', 'applied', true,
      'actionId', v_action.id, 'actionType', v_action.type,
      'finalStatus', 'pending_info', 'matchId', NULL,
      'note', v_note, 'outboxIds', '[]'::jsonb
    );
  END IF;
  RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Decision must be approve, deny, or needs_info.';
END;
$$;

ALTER FUNCTION public.set_season_organization_role_mappings(text, text, jsonb) OWNER TO postgres;
ALTER FUNCTION public.create_roster_drop(text, text, text, text, text, text) OWNER TO postgres;
ALTER FUNCTION public.resolve_roster_drop_pending_action(text, text, text, text, timestamptz, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.set_season_organization_role_mappings(text, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_roster_drop(text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.resolve_roster_drop_pending_action(text, text, text, text, timestamptz, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_season_organization_role_mappings(text, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.create_roster_drop(text, text, text, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.resolve_roster_drop_pending_action(text, text, text, text, timestamptz, text) TO service_role;

COMMENT ON TABLE public.organization_role_mappings IS
  'Legacy organization-owner/advisor role mapping. Roster projections use season_organization_role_mappings instead.';
COMMENT ON TABLE public.season_organization_role_mappings IS
  'Canonical Discord team role per season, division, and organization; used only as a projection of season_rosters.';
COMMENT ON TABLE public.season_player_eligibility IS
  'Private authoritative post-transaction eligibility state used by future claim and roster-entry workflows.';
