-- Canonical roster-trade lifecycle for transport-neutral Discord/web clients.
-- Captain UX remains a consumer concern; every revision, consent, admin
-- decision, roster write, audit, and durable projection is owned here.

ALTER TABLE public.pending_actions
  DROP CONSTRAINT pending_actions_type_check,
  ADD CONSTRAINT pending_actions_type_check CHECK (
    type IN ('match_result', 'reschedule', 'admin_review', 'alias_change', 'roster_trade')
  );

ALTER TABLE public.operation_outbox
  DROP CONSTRAINT operation_outbox_state_check,
  ADD CONSTRAINT operation_outbox_state_check CHECK (
    state IN ('pending', 'processing', 'completed', 'dead_letter', 'needs_reconciliation')
  );

CREATE INDEX operation_outbox_reconciliation_idx
  ON public.operation_outbox (updated_at DESC)
  WHERE state = 'needs_reconciliation';

CREATE OR REPLACE FUNCTION public.mark_operation_outbox_needs_reconciliation(
  p_outbox_id uuid,
  p_worker_id text,
  p_error text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_row public.operation_outbox%ROWTYPE;
BEGIN
  IF p_error IS NULL OR btrim(p_error) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Reconciliation error is required.';
  END IF;
  SELECT * INTO v_row FROM public.operation_outbox WHERE id = p_outbox_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Outbox row not found.'; END IF;
  IF v_row.state <> 'processing' OR v_row.lease_owner <> p_worker_id
    OR v_row.lease_expires_at <= now() THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Worker does not own an active lease for this outbox row.';
  END IF;
  UPDATE public.operation_outbox
  SET state = 'needs_reconciliation', lease_owner = NULL, lease_expires_at = NULL,
      last_error = left(p_error, 4000), updated_at = now()
  WHERE id = p_outbox_id;
  RETURN jsonb_build_object('code', 'needs_reconciliation', 'outboxId', p_outbox_id,
    'state', 'needs_reconciliation');
END;
$$;

CREATE OR REPLACE FUNCTION public.reconcile_operation_outbox(
  p_outbox_id uuid,
  p_actor_discord_id text,
  p_external_id text DEFAULT NULL,
  p_retry boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_row public.operation_outbox%ROWTYPE;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_users WHERE discord_id = p_actor_discord_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Actor is not an authorized administrator.';
  END IF;
  IF COALESCE(p_retry, false) = (
    NULLIF(btrim(COALESCE(p_external_id, '')), '') IS NOT NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'Choose exactly one reconciliation outcome: link an existing Discord message or retry delivery.';
  END IF;
  SELECT * INTO v_row FROM public.operation_outbox WHERE id = p_outbox_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Outbox row not found.'; END IF;
  IF v_row.state <> 'needs_reconciliation' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Outbox row is not awaiting reconciliation.';
  END IF;

  IF p_retry THEN
    UPDATE public.operation_outbox
    SET state = 'pending', attempts = 0, available_at = now(), last_error = NULL,
        external_id = NULL, completed_at = NULL, updated_at = now()
    WHERE id = v_row.id;
  ELSE
    UPDATE public.operation_outbox
    SET state = 'completed', external_id = btrim(p_external_id), completed_at = now(),
        last_error = NULL, updated_at = now()
    WHERE id = v_row.id;
  END IF;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, actor_discord_id,
    old_value_json, new_value_json, note
  ) VALUES (
    'operation_outbox_reconciled', 'operation_outbox', v_row.id::text, p_actor_discord_id,
    jsonb_build_object('state', v_row.state, 'lastError', v_row.last_error),
    CASE WHEN p_retry THEN jsonb_build_object('state', 'pending')
      ELSE jsonb_build_object('state', 'completed', 'externalId', btrim(p_external_id)) END,
    CASE WHEN p_retry THEN 'Administrator authorized one explicit retry after checking Discord.'
      ELSE 'Administrator linked the already-delivered Discord message.' END
  );
  RETURN jsonb_build_object(
    'code', CASE WHEN p_retry THEN 'retry_scheduled' ELSE 'linked_existing' END,
    'outboxId', v_row.id,
    'state', CASE WHEN p_retry THEN 'pending' ELSE 'completed' END,
    'externalId', CASE WHEN p_retry THEN NULL ELSE btrim(p_external_id) END
  );
END;
$$;

CREATE TABLE public.captain_role_mappings (
  division_id text PRIMARY KEY REFERENCES public.divisions(id),
  discord_role_id text NOT NULL,
  updated_by_discord_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.organization_role_mappings (
  org_id text PRIMARY KEY REFERENCES public.orgs(id),
  discord_role_id text NOT NULL UNIQUE,
  updated_by_discord_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.season_transaction_settings (
  season_id text NOT NULL REFERENCES public.seasons(id) ON DELETE CASCADE,
  division_id text NOT NULL REFERENCES public.divisions(id),
  trades_open boolean NOT NULL DEFAULT false,
  max_roster_size integer NOT NULL CHECK (max_roster_size > 0),
  updated_by_discord_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (season_id, division_id)
);

CREATE TABLE public.roster_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_type text NOT NULL DEFAULT 'trade' CHECK (transaction_type = 'trade'),
  source text NOT NULL CHECK (
    source IN ('discord_workflow', 'web_workflow', 'manual_reconciliation', 'migration')
  ),
  season_id text NOT NULL REFERENCES public.seasons(id),
  division_id text NOT NULL REFERENCES public.divisions(id),
  proposer_org_id text NOT NULL REFERENCES public.orgs(id),
  receiver_org_id text NOT NULL REFERENCES public.orgs(id),
  status text NOT NULL DEFAULT 'awaiting_acceptance' CHECK (
    status IN (
      'proposed', 'awaiting_acceptance', 'awaiting_admin', 'blocked', 'completed',
      'withdrawn', 'denied', 'conflicted', 'superseded', 'reversed'
    )
  ),
  current_revision integer NOT NULL DEFAULT 1 CHECK (current_revision > 0),
  pending_action_id text NOT NULL UNIQUE REFERENCES public.pending_actions(id),
  initiated_by_discord_id text NOT NULL,
  proposal_channel_id text,
  proposal_message_id text,
  accepted_at timestamptz,
  execution_claimed_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  admin_decided_by_discord_id text,
  admin_decided_at timestamptz,
  admin_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT roster_transactions_distinct_orgs CHECK (proposer_org_id <> receiver_org_id)
);

CREATE TABLE public.roster_transaction_revisions (
  transaction_id uuid NOT NULL REFERENCES public.roster_transactions(id) ON DELETE RESTRICT,
  revision integer NOT NULL CHECK (revision > 0),
  proposer_org_id text NOT NULL REFERENCES public.orgs(id),
  receiver_org_id text NOT NULL REFERENCES public.orgs(id),
  status text NOT NULL DEFAULT 'current' CHECK (
    status IN ('current', 'accepted', 'superseded', 'declined', 'cancelled', 'completed')
  ),
  created_by_discord_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  supersedes_revision integer,
  PRIMARY KEY (transaction_id, revision),
  CONSTRAINT roster_transaction_revisions_distinct_orgs CHECK (proposer_org_id <> receiver_org_id),
  CONSTRAINT roster_transaction_revisions_supersedes_fkey
    FOREIGN KEY (transaction_id, supersedes_revision)
    REFERENCES public.roster_transaction_revisions(transaction_id, revision)
);

CREATE TABLE public.roster_transaction_movements (
  transaction_id uuid NOT NULL,
  revision integer NOT NULL,
  player_id text NOT NULL REFERENCES public.players(id),
  from_org_id text NOT NULL REFERENCES public.orgs(id),
  to_org_id text NOT NULL REFERENCES public.orgs(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (transaction_id, revision, player_id),
  FOREIGN KEY (transaction_id, revision)
    REFERENCES public.roster_transaction_revisions(transaction_id, revision),
  CONSTRAINT roster_transaction_movements_distinct_orgs CHECK (from_org_id <> to_org_id)
);

CREATE TABLE public.roster_transaction_consents (
  transaction_id uuid NOT NULL,
  revision integer NOT NULL,
  org_id text NOT NULL REFERENCES public.orgs(id),
  consented boolean NOT NULL DEFAULT false,
  actor_discord_id text,
  consented_at timestamptz,
  revoked_at timestamptz,
  PRIMARY KEY (transaction_id, revision, org_id),
  FOREIGN KEY (transaction_id, revision)
    REFERENCES public.roster_transaction_revisions(transaction_id, revision)
);

CREATE INDEX roster_transactions_pending_status_idx
  ON public.roster_transactions (status, updated_at DESC);
CREATE INDEX roster_transaction_movements_player_idx
  ON public.roster_transaction_movements (player_id, transaction_id, revision);

ALTER TABLE public.captain_role_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_role_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.season_transaction_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roster_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roster_transaction_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roster_transaction_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roster_transaction_consents ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
  public.captain_role_mappings,
  public.organization_role_mappings,
  public.season_transaction_settings,
  public.roster_transactions,
  public.roster_transaction_revisions,
  public.roster_transaction_movements,
  public.roster_transaction_consents
FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE
  public.captain_role_mappings,
  public.organization_role_mappings,
  public.season_transaction_settings,
  public.roster_transactions,
  public.roster_transaction_revisions,
  public.roster_transaction_movements,
  public.roster_transaction_consents
TO service_role;

CREATE OR REPLACE FUNCTION private.assert_roster_trade_captain(
  p_season_id text,
  p_division_id text,
  p_org_id text,
  p_actor_discord_id text
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.season_rosters AS roster
    JOIN public.players AS player ON player.id = roster.player_id
    WHERE roster.season_id = p_season_id
      AND roster.division_id = p_division_id
      AND roster.org_id = p_org_id
      AND roster.roster_status = 'active'
      AND roster.is_captain
      AND player.discord_id = p_actor_discord_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Actor is not the current captain for this organization and division.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.assert_trade_player_set(
  p_season_id text,
  p_division_id text,
  p_org_id text,
  p_player_ids text[],
  p_label text
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_player_ids IS NULL OR cardinality(p_player_ids) = 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = p_label || ' must include at least one player.';
  END IF;
  IF cardinality(p_player_ids) <> (
       SELECT count(DISTINCT player_id) FROM unnest(p_player_ids) AS ids(player_id)
     )
     OR EXISTS (
       SELECT 1 FROM unnest(p_player_ids) AS ids(player_id)
       WHERE player_id IS NULL OR btrim(player_id) = ''
     ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = p_label || ' contains a duplicate or invalid player.';
  END IF;
  IF (SELECT count(*) FROM public.season_rosters AS roster
      WHERE roster.season_id = p_season_id
        AND roster.division_id = p_division_id
        AND roster.org_id = p_org_id
        AND roster.roster_status = 'active'
        AND roster.player_id = ANY(p_player_ids)) <> cardinality(p_player_ids) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = p_label || ' includes a player who is no longer on that roster.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION private.append_trade_revision(
  p_transaction_id uuid,
  p_revision integer,
  p_proposer_org_id text,
  p_receiver_org_id text,
  p_offered_player_ids text[],
  p_requested_player_ids text[],
  p_actor_discord_id text,
  p_supersedes_revision integer DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_player_id text;
BEGIN
  INSERT INTO public.roster_transaction_revisions (
    transaction_id, revision, proposer_org_id, receiver_org_id,
    created_by_discord_id, supersedes_revision
  ) VALUES (
    p_transaction_id, p_revision, p_proposer_org_id, p_receiver_org_id,
    p_actor_discord_id, p_supersedes_revision
  );

  FOREACH v_player_id IN ARRAY p_offered_player_ids LOOP
    INSERT INTO public.roster_transaction_movements (
      transaction_id, revision, player_id, from_org_id, to_org_id
    ) VALUES (
      p_transaction_id, p_revision, v_player_id, p_proposer_org_id, p_receiver_org_id
    );
  END LOOP;
  FOREACH v_player_id IN ARRAY p_requested_player_ids LOOP
    INSERT INTO public.roster_transaction_movements (
      transaction_id, revision, player_id, from_org_id, to_org_id
    ) VALUES (
      p_transaction_id, p_revision, v_player_id, p_receiver_org_id, p_proposer_org_id
    );
  END LOOP;

  INSERT INTO public.roster_transaction_consents (
    transaction_id, revision, org_id, consented, actor_discord_id, consented_at
  ) VALUES (
    p_transaction_id, p_revision, p_proposer_org_id, true, p_actor_discord_id, now()
  ), (
    p_transaction_id, p_revision, p_receiver_org_id, false, NULL, NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.create_roster_trade(
  p_actor_discord_id text,
  p_season_id text,
  p_division_id text,
  p_proposer_org_id text,
  p_receiver_org_id text,
  p_offered_player_ids text[],
  p_requested_player_ids text[],
  p_proposal_channel_id text DEFAULT NULL,
  p_source text DEFAULT 'discord_workflow'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
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
  IF p_proposer_org_id = p_receiver_org_id THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'A trade requires two different organizations.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.seasons
    WHERE id = p_season_id AND is_current AND status = 'active'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Trades require the active current season.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.season_transaction_settings
    WHERE season_id = p_season_id AND division_id = p_division_id AND trades_open
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Trades are not open for this season and division.';
  END IF;
  IF (SELECT count(*) FROM public.season_orgs
      WHERE season_id = p_season_id AND division_id = p_division_id
        AND status = 'active' AND org_id IN (p_proposer_org_id, p_receiver_org_id)) <> 2 THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Both organizations must be active in the same season division.';
  END IF;

  PERFORM private.assert_roster_trade_captain(
    p_season_id, p_division_id, p_proposer_org_id, p_actor_discord_id
  );
  PERFORM private.assert_trade_player_set(
    p_season_id, p_division_id, p_proposer_org_id, p_offered_player_ids, 'Offered players'
  );
  PERFORM private.assert_trade_player_set(
    p_season_id, p_division_id, p_receiver_org_id, p_requested_player_ids, 'Requested players'
  );
  IF p_offered_player_ids && p_requested_player_ids THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'The same player cannot appear on both sides of a trade.';
  END IF;

  INSERT INTO public.pending_actions (
    id, type, status, requested_by_discord_id, division_id, payload_json
  ) VALUES (
    v_action_id, 'roster_trade', 'pending', p_actor_discord_id, p_division_id,
    jsonb_build_object('transactionId', v_transaction_id, 'revision', 1, 'source', p_source)
  );
  INSERT INTO public.roster_transactions (
    id, source, season_id, division_id, proposer_org_id, receiver_org_id,
    pending_action_id, initiated_by_discord_id, proposal_channel_id
  ) VALUES (
    v_transaction_id, p_source, p_season_id, p_division_id,
    p_proposer_org_id, p_receiver_org_id, v_action_id, p_actor_discord_id,
    NULLIF(btrim(COALESCE(p_proposal_channel_id, '')), '')
  );
  PERFORM private.append_trade_revision(
    v_transaction_id, 1, p_proposer_org_id, p_receiver_org_id,
    p_offered_player_ids, p_requested_player_ids, p_actor_discord_id, NULL
  );

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
    old_value_json, new_value_json, note
  ) VALUES (
    'roster_trade_proposed', 'roster_transaction', v_transaction_id::text,
    v_action_id, p_actor_discord_id, NULL,
    jsonb_build_object('revision', 1, 'source', p_source,
      'proposerOrgId', p_proposer_org_id, 'receiverOrgId', p_receiver_org_id,
      'offeredPlayerIds', to_jsonb(p_offered_player_ids),
      'requestedPlayerIds', to_jsonb(p_requested_player_ids)),
    'Created the first durable trade revision.'
  );

  IF NULLIF(btrim(COALESCE(p_proposal_channel_id, '')), '') IS NOT NULL THEN
    v_outbox_id := public.enqueue_operation_outbox(
      'discord_trade_proposal_projection', 'roster_transaction', v_transaction_id::text,
      'roster_trade_proposed', 'roster_transaction:' || v_transaction_id || ':revision:1:proposal',
      jsonb_build_object('transactionId', v_transaction_id, 'revision', 1,
        'channelId', p_proposal_channel_id)
    );
  END IF;

  RETURN jsonb_build_object(
    'code', 'created', 'transactionId', v_transaction_id,
    'revision', 1, 'pendingActionId', v_action_id,
    'status', 'awaiting_acceptance',
    'outboxIds', CASE WHEN v_outbox_id IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(v_outbox_id) END
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.counter_roster_trade(
  p_transaction_id uuid,
  p_expected_revision integer,
  p_actor_discord_id text,
  p_offered_player_ids text[],
  p_requested_player_ids text[]
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
  v_trade public.roster_transactions%ROWTYPE;
  v_new_revision integer;
BEGIN
  SELECT * INTO v_trade FROM public.roster_transactions
  WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Trade not found.'; END IF;
  IF v_trade.status <> 'awaiting_acceptance' OR v_trade.current_revision <> p_expected_revision THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'This trade revision is stale.';
  END IF;
  PERFORM private.assert_roster_trade_captain(
    v_trade.season_id, v_trade.division_id, v_trade.receiver_org_id, p_actor_discord_id
  );
  PERFORM private.assert_trade_player_set(
    v_trade.season_id, v_trade.division_id, v_trade.receiver_org_id,
    p_offered_player_ids, 'Offered players'
  );
  PERFORM private.assert_trade_player_set(
    v_trade.season_id, v_trade.division_id, v_trade.proposer_org_id,
    p_requested_player_ids, 'Requested players'
  );
  IF p_offered_player_ids && p_requested_player_ids THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'The same player cannot appear on both sides of a trade.';
  END IF;

  UPDATE public.roster_transaction_revisions
  SET status = 'superseded'
  WHERE transaction_id = v_trade.id AND revision = v_trade.current_revision;
  v_new_revision := v_trade.current_revision + 1;
  PERFORM private.append_trade_revision(
    v_trade.id, v_new_revision, v_trade.receiver_org_id, v_trade.proposer_org_id,
    p_offered_player_ids, p_requested_player_ids, p_actor_discord_id,
    v_trade.current_revision
  );
  UPDATE public.roster_transactions
  SET proposer_org_id = v_trade.receiver_org_id,
      receiver_org_id = v_trade.proposer_org_id,
      current_revision = v_new_revision,
      accepted_at = NULL,
      status = 'awaiting_acceptance',
      updated_at = now()
  WHERE id = v_trade.id;
  UPDATE public.pending_actions
  SET payload_json = payload_json || jsonb_build_object('revision', v_new_revision),
      updated_at = now()
  WHERE id = v_trade.pending_action_id;
  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
    old_value_json, new_value_json, note
  ) VALUES (
    'roster_trade_countered', 'roster_transaction', v_trade.id::text,
    v_trade.pending_action_id, p_actor_discord_id,
    jsonb_build_object('revision', v_trade.current_revision),
    jsonb_build_object('revision', v_new_revision,
      'proposerOrgId', v_trade.receiver_org_id, 'receiverOrgId', v_trade.proposer_org_id),
    'Counteroffer superseded the prior revision and invalidated its consent.'
  );
  IF v_trade.proposal_channel_id IS NOT NULL THEN
    PERFORM public.enqueue_operation_outbox(
      'discord_trade_proposal_projection', 'roster_transaction', v_trade.id::text,
      'roster_trade_countered', 'roster_transaction:' || v_trade.id || ':revision:' || v_new_revision || ':proposal',
      jsonb_build_object('transactionId', v_trade.id, 'revision', v_new_revision,
        'channelId', v_trade.proposal_channel_id)
    );
  END IF;
  RETURN jsonb_build_object(
    'code', 'countered', 'transactionId', v_trade.id,
    'revision', v_new_revision, 'pendingActionId', v_trade.pending_action_id,
    'status', 'awaiting_acceptance'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.accept_roster_trade(
  p_transaction_id uuid,
  p_expected_revision integer,
  p_actor_discord_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
  v_trade public.roster_transactions%ROWTYPE;
BEGIN
  SELECT * INTO v_trade FROM public.roster_transactions
  WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Trade not found.'; END IF;
  IF v_trade.status <> 'awaiting_acceptance' OR v_trade.current_revision <> p_expected_revision THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'This trade revision is stale.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.roster_transaction_revisions
    WHERE transaction_id = v_trade.id AND revision = v_trade.current_revision
      AND created_by_discord_id = p_actor_discord_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'A proposer cannot accept their own revision.';
  END IF;
  PERFORM private.assert_roster_trade_captain(
    v_trade.season_id, v_trade.division_id, v_trade.receiver_org_id, p_actor_discord_id
  );

  -- Revalidate the exact durable assets before recording binding consent.
  IF EXISTS (
    SELECT 1 FROM public.roster_transaction_movements AS movement
    LEFT JOIN public.season_rosters AS roster
      ON roster.season_id = v_trade.season_id
     AND roster.player_id = movement.player_id
     AND roster.division_id = v_trade.division_id
     AND roster.org_id = movement.from_org_id
     AND roster.roster_status = 'active'
    WHERE movement.transaction_id = v_trade.id
      AND movement.revision = v_trade.current_revision
      AND roster.player_id IS NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'A selected player is no longer on the proposed roster.';
  END IF;

  UPDATE public.roster_transaction_consents
  SET consented = true, actor_discord_id = p_actor_discord_id,
      consented_at = now(), revoked_at = NULL
  WHERE transaction_id = v_trade.id AND revision = v_trade.current_revision
    AND org_id = v_trade.receiver_org_id;
  UPDATE public.roster_transaction_revisions
  SET status = 'accepted'
  WHERE transaction_id = v_trade.id AND revision = v_trade.current_revision;
  UPDATE public.roster_transactions
  SET status = 'awaiting_admin', accepted_at = now(), updated_at = now()
  WHERE id = v_trade.id;
  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
    old_value_json, new_value_json, note
  ) VALUES (
    'roster_trade_accepted', 'roster_transaction', v_trade.id::text,
    v_trade.pending_action_id, p_actor_discord_id,
    jsonb_build_object('status', v_trade.status, 'revision', v_trade.current_revision),
    jsonb_build_object('status', 'awaiting_admin', 'revision', v_trade.current_revision),
    'Counterpart consent is bound to the exact current revision; no roster row changed.'
  );
  IF v_trade.proposal_channel_id IS NOT NULL THEN
    PERFORM public.enqueue_operation_outbox(
      'discord_trade_proposal_projection', 'roster_transaction', v_trade.id::text,
      'roster_trade_accepted', 'roster_transaction:' || v_trade.id || ':revision:' || v_trade.current_revision || ':accepted:proposal',
      jsonb_build_object('transactionId', v_trade.id, 'revision', v_trade.current_revision,
        'channelId', v_trade.proposal_channel_id)
    );
  END IF;
  -- Admin review is transport-neutral: a future web-created proposal may have
  -- no Discord proposal channel but still uses the same pending-action queue.
  PERFORM public.enqueue_operation_outbox(
    'discord_trade_admin_review', 'roster_transaction', v_trade.id::text,
    'roster_trade_accepted', 'roster_transaction:' || v_trade.id || ':revision:' || v_trade.current_revision || ':admin_review',
    jsonb_build_object('transactionId', v_trade.id, 'revision', v_trade.current_revision,
      'pendingActionId', v_trade.pending_action_id)
  );
  RETURN jsonb_build_object(
    'code', 'accepted', 'transactionId', v_trade.id,
    'revision', v_trade.current_revision, 'pendingActionId', v_trade.pending_action_id,
    'status', 'awaiting_admin'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.decline_roster_trade(
  p_transaction_id uuid,
  p_expected_revision integer,
  p_actor_discord_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
  v_trade public.roster_transactions%ROWTYPE;
BEGIN
  SELECT * INTO v_trade FROM public.roster_transactions WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Trade not found.'; END IF;
  IF v_trade.status <> 'awaiting_acceptance' OR v_trade.current_revision <> p_expected_revision THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'This trade revision is stale.';
  END IF;
  PERFORM private.assert_roster_trade_captain(
    v_trade.season_id, v_trade.division_id, v_trade.receiver_org_id, p_actor_discord_id
  );
  UPDATE public.roster_transaction_revisions SET status = 'declined'
  WHERE transaction_id = v_trade.id AND revision = v_trade.current_revision;
  UPDATE public.roster_transactions
  SET status = 'denied', cancelled_at = now(), updated_at = now()
  WHERE id = v_trade.id;
  UPDATE public.pending_actions
  SET status = 'cancelled', admin_note = 'Declined by the receiving captain.', updated_at = now()
  WHERE id = v_trade.pending_action_id AND status IN ('pending', 'pending_info');
  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
    old_value_json, new_value_json, note
  ) VALUES (
    'roster_trade_declined', 'roster_transaction', v_trade.id::text,
    v_trade.pending_action_id, p_actor_discord_id,
    jsonb_build_object('status', v_trade.status), jsonb_build_object('status', 'denied'),
    'Receiving captain declined the current revision.'
  );
  IF v_trade.proposal_channel_id IS NOT NULL THEN
    PERFORM public.enqueue_operation_outbox(
      'discord_trade_proposal_projection', 'roster_transaction', v_trade.id::text,
      'roster_trade_declined', 'roster_transaction:' || v_trade.id || ':revision:' || v_trade.current_revision || ':declined:proposal',
      jsonb_build_object('transactionId', v_trade.id, 'revision', v_trade.current_revision,
        'channelId', v_trade.proposal_channel_id)
    );
  END IF;
  RETURN jsonb_build_object('code', 'declined', 'transactionId', v_trade.id,
    'revision', v_trade.current_revision, 'status', 'denied');
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_roster_trade(
  p_transaction_id uuid,
  p_expected_revision integer,
  p_actor_discord_id text,
  p_mode text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
  v_trade public.roster_transactions%ROWTYPE;
BEGIN
  SELECT * INTO v_trade FROM public.roster_transactions WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Trade not found.'; END IF;
  IF v_trade.current_revision <> p_expected_revision THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'This trade revision is stale.';
  END IF;
  IF v_trade.execution_claimed_at IS NOT NULL OR v_trade.status NOT IN ('awaiting_acceptance', 'awaiting_admin', 'blocked') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'This trade can no longer be cancelled.';
  END IF;

  IF p_mode = 'withdraw' THEN
    IF v_trade.status <> 'awaiting_acceptance' THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Only the current proposer may withdraw this trade.';
    END IF;
    PERFORM private.assert_roster_trade_captain(
      v_trade.season_id, v_trade.division_id, v_trade.proposer_org_id, p_actor_discord_id
    );
  ELSIF p_mode = 'revoke' THEN
    IF v_trade.status NOT IN ('awaiting_admin', 'blocked') OR NOT EXISTS (
      SELECT 1
      FROM public.season_rosters AS roster
      JOIN public.players AS player ON player.id = roster.player_id
      WHERE roster.season_id = v_trade.season_id
        AND roster.division_id = v_trade.division_id
        AND roster.org_id IN (v_trade.proposer_org_id, v_trade.receiver_org_id)
        AND roster.roster_status = 'active' AND roster.is_captain
        AND player.discord_id = p_actor_discord_id
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Only a participating captain may revoke accepted consent.';
    END IF;
  ELSE
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Cancellation mode must be withdraw or revoke.';
  END IF;

  UPDATE public.roster_transaction_consents
  SET consented = false, revoked_at = now()
  WHERE transaction_id = v_trade.id AND revision = v_trade.current_revision
    AND org_id IN (
      SELECT roster.org_id
      FROM public.season_rosters AS roster
      JOIN public.players AS player ON player.id = roster.player_id
      WHERE roster.season_id = v_trade.season_id
        AND roster.division_id = v_trade.division_id
        AND roster.org_id IN (v_trade.proposer_org_id, v_trade.receiver_org_id)
        AND roster.roster_status = 'active' AND roster.is_captain
        AND player.discord_id = p_actor_discord_id
    );
  UPDATE public.roster_transaction_revisions SET status = 'cancelled'
  WHERE transaction_id = v_trade.id AND revision = v_trade.current_revision;
  UPDATE public.roster_transactions
  SET status = 'withdrawn', cancelled_at = now(), updated_at = now()
  WHERE id = v_trade.id;
  UPDATE public.pending_actions
  SET status = 'cancelled', admin_note = CASE WHEN p_mode = 'revoke'
      THEN 'Captain consent was revoked before execution.' ELSE 'Proposal was withdrawn.' END,
      updated_at = now()
  WHERE id = v_trade.pending_action_id AND status IN ('pending', 'pending_info');
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'The linked admin action was already claimed.';
  END IF;
  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
    old_value_json, new_value_json, note
  ) VALUES (
    CASE WHEN p_mode = 'revoke' THEN 'roster_trade_consent_revoked' ELSE 'roster_trade_withdrawn' END,
    'roster_transaction', v_trade.id::text, v_trade.pending_action_id, p_actor_discord_id,
    jsonb_build_object('status', v_trade.status), jsonb_build_object('status', 'withdrawn'),
    CASE WHEN p_mode = 'revoke' THEN 'Consent revoked before administrator execution.'
      ELSE 'Proposal withdrawn before counterpart acceptance.' END
  );
  IF v_trade.proposal_channel_id IS NOT NULL THEN
    PERFORM public.enqueue_operation_outbox(
      'discord_trade_proposal_projection', 'roster_transaction', v_trade.id::text,
      CASE WHEN p_mode = 'revoke' THEN 'roster_trade_consent_revoked' ELSE 'roster_trade_withdrawn' END,
      'roster_transaction:' || v_trade.id || ':revision:' || v_trade.current_revision || ':' || p_mode || ':proposal',
      jsonb_build_object('transactionId', v_trade.id, 'revision', v_trade.current_revision,
        'channelId', v_trade.proposal_channel_id)
    );
  END IF;
  RETURN jsonb_build_object('code', CASE WHEN p_mode = 'revoke' THEN 'revoked' ELSE 'withdrawn' END,
    'transactionId', v_trade.id,
    'revision', v_trade.current_revision, 'status', 'withdrawn');
END;
$$;

CREATE OR REPLACE FUNCTION private.execute_roster_trade(
  p_transaction_id uuid,
  p_actor_discord_id text
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_trade public.roster_transactions%ROWTYPE;
  v_max_roster_size integer;
  v_trades_open boolean;
  v_outbox_ids uuid[] := ARRAY[]::uuid[];
  v_outbox_id uuid;
  v_movements jsonb;
  v_player_ids text[];
BEGIN
  SELECT * INTO v_trade FROM public.roster_transactions WHERE id = p_transaction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Trade not found.'; END IF;
  IF v_trade.status NOT IN ('awaiting_admin', 'blocked') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Trade is not awaiting administrator execution.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.roster_transaction_consents
    WHERE transaction_id = v_trade.id AND revision = v_trade.current_revision
    GROUP BY transaction_id, revision
    HAVING count(*) = 2 AND bool_and(consented)
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'The current trade revision does not have both consents.';
  END IF;
  UPDATE public.roster_transactions SET execution_claimed_at = now(), updated_at = now()
  WHERE id = v_trade.id RETURNING * INTO v_trade;

  IF NOT EXISTS (
    SELECT 1 FROM public.seasons
    WHERE id = v_trade.season_id AND is_current AND status = 'active'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23514',
      MESSAGE = 'The transaction season is no longer the active current season.';
  END IF;
  IF (
    SELECT count(*) FROM public.season_orgs
    WHERE season_id = v_trade.season_id AND division_id = v_trade.division_id
      AND status = 'active' AND org_id IN (v_trade.proposer_org_id, v_trade.receiver_org_id)
  ) <> 2 THEN
    RAISE EXCEPTION USING ERRCODE = '23514',
      MESSAGE = 'A participating organization is no longer active in this season division.';
  END IF;

  PERFORM season_org.org_id
  FROM public.season_orgs AS season_org
  WHERE season_org.season_id = v_trade.season_id
    AND season_org.division_id = v_trade.division_id
    AND season_org.org_id IN (v_trade.proposer_org_id, v_trade.receiver_org_id)
  ORDER BY season_org.org_id
  FOR UPDATE;

  SELECT max_roster_size, trades_open INTO v_max_roster_size, v_trades_open
  FROM public.season_transaction_settings
  WHERE season_id = v_trade.season_id AND division_id = v_trade.division_id;
  IF v_max_roster_size IS NULL OR NOT COALESCE(v_trades_open, false) THEN
    RAISE EXCEPTION USING ERRCODE = '55000',
      MESSAGE = 'Trades are closed or roster capacity is not configured for this season division.';
  END IF;

  PERFORM roster.player_id
  FROM public.season_rosters AS roster
  JOIN public.roster_transaction_movements AS movement ON movement.player_id = roster.player_id
  WHERE movement.transaction_id = v_trade.id AND movement.revision = v_trade.current_revision
    AND roster.season_id = v_trade.season_id
  ORDER BY roster.player_id
  FOR UPDATE OF roster;

  IF EXISTS (
    SELECT 1 FROM public.roster_transaction_movements AS movement
    LEFT JOIN public.season_rosters AS roster
      ON roster.season_id = v_trade.season_id
     AND roster.player_id = movement.player_id
     AND roster.division_id = v_trade.division_id
     AND roster.org_id = movement.from_org_id
     AND roster.roster_status = 'active'
    WHERE movement.transaction_id = v_trade.id AND movement.revision = v_trade.current_revision
      AND roster.player_id IS NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'A traded player is no longer owned by the expected organization.';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM (VALUES (v_trade.proposer_org_id), (v_trade.receiver_org_id)) AS org(org_id)
    WHERE (
      (SELECT count(*) FROM public.season_rosters AS roster
       WHERE roster.season_id = v_trade.season_id AND roster.org_id = org.org_id
         AND roster.division_id = v_trade.division_id AND roster.roster_status = 'active')
      - (SELECT count(*) FROM public.roster_transaction_movements AS movement
         WHERE movement.transaction_id = v_trade.id AND movement.revision = v_trade.current_revision
           AND movement.from_org_id = org.org_id)
      + (SELECT count(*) FROM public.roster_transaction_movements AS movement
         WHERE movement.transaction_id = v_trade.id AND movement.revision = v_trade.current_revision
           AND movement.to_org_id = org.org_id)
    ) > v_max_roster_size
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Trade would exceed configured roster capacity.';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'playerId', movement.player_id,
    'playerName', COALESCE(player.display_alias, player.ign),
    'discordId', player.discord_id,
    'fromOrgId', movement.from_org_id,
    'toOrgId', movement.to_org_id
  ) ORDER BY movement.from_org_id, movement.player_id), '[]'::jsonb),
  array_agg(movement.player_id ORDER BY movement.player_id)
  INTO v_movements, v_player_ids
  FROM public.roster_transaction_movements AS movement
  JOIN public.players AS player ON player.id = movement.player_id
  WHERE movement.transaction_id = v_trade.id AND movement.revision = v_trade.current_revision;

  UPDATE public.season_rosters AS roster
  SET org_id = movement.to_org_id, division_id = v_trade.division_id,
      roster_status = 'active', is_captain = false, updated_at = now()
  FROM public.roster_transaction_movements AS movement
  WHERE movement.transaction_id = v_trade.id AND movement.revision = v_trade.current_revision
    AND roster.season_id = v_trade.season_id AND roster.player_id = movement.player_id;

  UPDATE public.roster_transaction_revisions SET status = 'completed'
  WHERE transaction_id = v_trade.id AND revision = v_trade.current_revision;
  UPDATE public.roster_transactions
  SET status = 'completed', completed_at = now(), admin_decided_by_discord_id = p_actor_discord_id,
      admin_decided_at = now(), updated_at = now()
  WHERE id = v_trade.id;
  UPDATE public.pending_actions
  SET status = 'approved', approved_by_discord_id = p_actor_discord_id,
      approved_at = now(), updated_at = now()
  WHERE id = v_trade.pending_action_id;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
    old_value_json, new_value_json, note
  ) VALUES (
    'roster_trade_completed', 'roster_transaction', v_trade.id::text,
    v_trade.pending_action_id, p_actor_discord_id,
    jsonb_build_object('status', 'awaiting_admin', 'movements', v_movements),
    jsonb_build_object('status', 'completed', 'movements', v_movements),
    'Executed the accepted roster trade atomically from canonical roster state.'
  );

  v_outbox_id := public.enqueue_operation_outbox(
    'discord_transaction_bulletin', 'roster_transaction', v_trade.id::text,
    'roster_trade_completed', 'roster_transaction:' || v_trade.id || ':completed:bulletin',
    jsonb_build_object(
      'operationId', v_trade.id, 'transactionId', v_trade.id,
      'revision', v_trade.current_revision, 'divisionId', v_trade.division_id,
      'proposerOrgId', v_trade.proposer_org_id, 'receiverOrgId', v_trade.receiver_org_id,
      'movements', v_movements
    )
  );
  v_outbox_ids := array_append(v_outbox_ids, v_outbox_id);
  IF v_trade.proposal_channel_id IS NOT NULL THEN
    v_outbox_id := public.enqueue_operation_outbox(
      'discord_trade_proposal_projection', 'roster_transaction', v_trade.id::text,
      'roster_trade_completed', 'roster_transaction:' || v_trade.id || ':revision:' || v_trade.current_revision || ':completed:proposal',
      jsonb_build_object('transactionId', v_trade.id, 'revision', v_trade.current_revision,
        'channelId', v_trade.proposal_channel_id)
    );
    v_outbox_ids := array_append(v_outbox_ids, v_outbox_id);
  END IF;
  IF EXISTS (SELECT 1 FROM public.pending_actions WHERE id = v_trade.pending_action_id
    AND admin_review_message_id IS NOT NULL) THEN
    v_outbox_id := public.enqueue_operation_outbox(
      'discord_review_projection', 'pending_action', v_trade.pending_action_id,
      'pending_action_approved', 'roster_transaction:' || v_trade.id || ':completed:admin_review',
      jsonb_build_object('actionId', v_trade.pending_action_id, 'finalStatus', 'approved',
        'transactionId', v_trade.id)
    );
    v_outbox_ids := array_append(v_outbox_ids, v_outbox_id);
  END IF;
  v_outbox_id := public.enqueue_operation_outbox(
    'discord_organization_role_reconciliation', 'roster_transaction', v_trade.id::text,
    'roster_trade_completed', 'roster_transaction:' || v_trade.id || ':completed:role_reconciliation',
    jsonb_build_object(
      'operationId', v_trade.id, 'transactionId', v_trade.id,
      'seasonId', v_trade.season_id, 'divisionId', v_trade.division_id,
      'playerIds', to_jsonb(v_player_ids)
    )
  );
  v_outbox_ids := array_append(v_outbox_ids, v_outbox_id);
  RETURN jsonb_build_object('code', 'completed', 'applied', true,
    'actionId', v_trade.pending_action_id, 'actionType', 'roster_trade',
    'finalStatus', 'approved', 'matchId', NULL, 'note', NULL,
    'transactionId', v_trade.id, 'outboxIds', to_jsonb(v_outbox_ids));
END;
$$;

ALTER FUNCTION public.resolve_pending_action(text, text, text, text)
  RENAME TO resolve_pending_action_without_roster_trade;
ALTER FUNCTION public.resolve_pending_action_without_roster_trade(text, text, text, text)
  SET SCHEMA private;
REVOKE ALL ON FUNCTION private.resolve_pending_action_without_roster_trade(text, text, text, text)
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
  v_trade public.roster_transactions%ROWTYPE;
  v_result jsonb;
  v_error text;
  v_decision text := lower(btrim(COALESCE(p_decision, '')));
  v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  SELECT * INTO v_action FROM public.pending_actions WHERE id = p_action_id;
  IF NOT FOUND OR v_action.type <> 'roster_trade' THEN
    RETURN private.resolve_pending_action_without_roster_trade(
      p_action_id, p_actor_discord_id, p_decision, p_note
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.admin_users WHERE discord_id = p_actor_discord_id) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Actor is not an authorized administrator.';
  END IF;
  SELECT * INTO v_action FROM public.pending_actions WHERE id = p_action_id FOR UPDATE;
  SELECT * INTO v_trade FROM public.roster_transactions
  WHERE pending_action_id = p_action_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Linked roster trade is missing.';
  END IF;
  IF v_action.status IN ('approved', 'denied', 'cancelled') THEN
    RETURN jsonb_build_object('code', 'already_processed', 'applied', false,
      'actionId', v_action.id, 'actionType', v_action.type,
      'finalStatus', v_action.status, 'matchId', NULL, 'note', v_action.admin_note,
      'outboxIds', '[]'::jsonb);
  END IF;
  IF v_decision = 'needs_info' AND v_action.status <> 'pending' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Needs Info is allowed only from pending.';
  END IF;
  IF v_decision IN ('deny', 'needs_info') AND v_note IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A note is required for denial and Needs Info.';
  END IF;
  IF v_decision = 'approve' THEN
    BEGIN
      IF v_trade.status = 'blocked' THEN
        UPDATE public.roster_transactions
        SET status = 'awaiting_admin', admin_note = NULL, updated_at = now()
        WHERE id = v_trade.id;
      END IF;
      RETURN private.execute_roster_trade(v_trade.id, p_actor_discord_id);
    EXCEPTION WHEN SQLSTATE '23514' OR SQLSTATE '55000' THEN
      GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
      UPDATE public.roster_transactions
      SET status = 'blocked', execution_claimed_at = NULL, admin_note = v_error, updated_at = now()
      WHERE id = v_trade.id;
      UPDATE public.pending_actions
      SET status = 'pending_info', admin_note = v_error, updated_at = now()
      WHERE id = v_action.id;
      INSERT INTO public.audit_logs (
        action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
        old_value_json, new_value_json, note
      ) VALUES (
        'roster_trade_execution_blocked', 'roster_transaction', v_trade.id::text,
        v_action.id, p_actor_discord_id,
        jsonb_build_object('status', v_trade.status), jsonb_build_object('status', 'blocked'), v_error
      );
      IF v_trade.proposal_channel_id IS NOT NULL THEN
        PERFORM public.enqueue_operation_outbox(
          'discord_trade_proposal_projection', 'roster_transaction', v_trade.id::text,
          'roster_trade_execution_blocked', 'roster_transaction:' || v_trade.id || ':revision:' || v_trade.current_revision || ':blocked:proposal',
          jsonb_build_object('transactionId', v_trade.id, 'revision', v_trade.current_revision,
            'channelId', v_trade.proposal_channel_id)
        );
      END IF;
      IF v_action.admin_review_message_id IS NOT NULL THEN
        PERFORM public.enqueue_operation_outbox(
          'discord_review_projection', 'pending_action', v_action.id,
          'pending_action_pending_info', 'roster_transaction:' || v_trade.id || ':blocked:admin_review',
          jsonb_build_object('actionId', v_action.id, 'finalStatus', 'pending_info',
            'transactionId', v_trade.id)
        );
      END IF;
      RETURN jsonb_build_object('code', 'blocked', 'applied', false,
        'actionId', v_action.id, 'actionType', v_action.type,
        'finalStatus', 'pending_info', 'matchId', NULL, 'note', v_error,
        'transactionId', v_trade.id, 'outboxIds', '[]'::jsonb);
    END;
  ELSIF v_decision = 'deny' THEN
    UPDATE public.roster_transactions
    SET status = 'denied', admin_decided_by_discord_id = p_actor_discord_id,
        admin_decided_at = now(), admin_note = v_note,
        cancelled_at = now(), updated_at = now()
    WHERE id = v_trade.id;
    UPDATE public.roster_transaction_revisions SET status = 'declined'
    WHERE transaction_id = v_trade.id AND revision = v_trade.current_revision;
    UPDATE public.pending_actions
    SET status = 'denied', approved_by_discord_id = p_actor_discord_id,
        approved_at = now(), admin_note = v_note, updated_at = now()
    WHERE id = v_action.id;
    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
      old_value_json, new_value_json, note
    ) VALUES (
      'roster_trade_denied', 'roster_transaction', v_trade.id::text,
      v_action.id, p_actor_discord_id,
      jsonb_build_object('status', v_trade.status), jsonb_build_object('status', 'denied'), v_note
    );
    IF v_trade.proposal_channel_id IS NOT NULL THEN
      PERFORM public.enqueue_operation_outbox(
        'discord_trade_proposal_projection', 'roster_transaction', v_trade.id::text,
        'roster_trade_denied', 'roster_transaction:' || v_trade.id || ':revision:' || v_trade.current_revision || ':denied:proposal',
        jsonb_build_object('transactionId', v_trade.id, 'revision', v_trade.current_revision,
          'channelId', v_trade.proposal_channel_id)
      );
    END IF;
    IF v_action.admin_review_message_id IS NOT NULL THEN
      PERFORM public.enqueue_operation_outbox(
        'discord_review_projection', 'pending_action', v_action.id,
        'pending_action_denied', 'roster_transaction:' || v_trade.id || ':denied:admin_review',
        jsonb_build_object('actionId', v_action.id, 'finalStatus', 'denied',
          'transactionId', v_trade.id)
      );
    END IF;
    RETURN jsonb_build_object('code', 'denied', 'applied', true,
      'actionId', v_action.id, 'actionType', v_action.type,
      'finalStatus', 'denied', 'matchId', NULL, 'note', v_note, 'outboxIds', '[]'::jsonb);
  ELSIF v_decision = 'needs_info' THEN
    UPDATE public.pending_actions SET status = 'pending_info', admin_note = v_note, updated_at = now()
    WHERE id = v_action.id;
    INSERT INTO public.audit_logs (
      action_type, entity_type, entity_id, pending_action_id, actor_discord_id,
      old_value_json, new_value_json, note
    ) VALUES (
      'pending_action_needs_info', 'pending_action', v_action.id,
      v_action.id, p_actor_discord_id,
      jsonb_build_object('status', v_action.status), jsonb_build_object('status', 'pending_info'), v_note
    );
    IF v_action.admin_review_message_id IS NOT NULL THEN
      PERFORM public.enqueue_operation_outbox(
        'discord_review_projection', 'pending_action', v_action.id,
        'pending_action_pending_info', 'roster_transaction:' || v_trade.id || ':needs_info:admin_review',
        jsonb_build_object('actionId', v_action.id, 'finalStatus', 'pending_info',
          'transactionId', v_trade.id)
      );
    END IF;
    RETURN jsonb_build_object('code', 'needs_info', 'applied', true,
      'actionId', v_action.id, 'actionType', v_action.type,
      'finalStatus', 'pending_info', 'matchId', NULL, 'note', v_note, 'outboxIds', '[]'::jsonb);
  END IF;
  RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Decision must be approve, deny, or needs_info.';
END;
$$;

ALTER FUNCTION public.create_roster_trade(text, text, text, text, text, text[], text[], text, text) OWNER TO postgres;
ALTER FUNCTION public.mark_operation_outbox_needs_reconciliation(uuid, text, text) OWNER TO postgres;
ALTER FUNCTION public.reconcile_operation_outbox(uuid, text, text, boolean) OWNER TO postgres;
ALTER FUNCTION public.counter_roster_trade(uuid, integer, text, text[], text[]) OWNER TO postgres;
ALTER FUNCTION public.accept_roster_trade(uuid, integer, text) OWNER TO postgres;
ALTER FUNCTION public.decline_roster_trade(uuid, integer, text) OWNER TO postgres;
ALTER FUNCTION public.cancel_roster_trade(uuid, integer, text, text) OWNER TO postgres;
ALTER FUNCTION public.resolve_pending_action(text, text, text, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.create_roster_trade(text, text, text, text, text, text[], text[], text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mark_operation_outbox_needs_reconciliation(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reconcile_operation_outbox(uuid, text, text, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.counter_roster_trade(uuid, integer, text, text[], text[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.accept_roster_trade(uuid, integer, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.decline_roster_trade(uuid, integer, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cancel_roster_trade(uuid, integer, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.resolve_pending_action(text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_roster_trade(text, text, text, text, text, text[], text[], text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.mark_operation_outbox_needs_reconciliation(uuid, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.reconcile_operation_outbox(uuid, text, text, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.counter_roster_trade(uuid, integer, text, text[], text[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.accept_roster_trade(uuid, integer, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.decline_roster_trade(uuid, integer, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.cancel_roster_trade(uuid, integer, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.resolve_pending_action(text, text, text, text) TO service_role;

COMMENT ON TABLE public.roster_transactions IS
  'Transport-neutral roster transaction ledger; completed rows are immutable business history.';
COMMENT ON TABLE public.roster_transaction_revisions IS
  'Immutable proposal revisions. A counteroffer appends a revision and supersedes the previous one.';
COMMENT ON TABLE public.roster_transaction_consents IS
  'Organization consent bound to one exact roster transaction revision.';
COMMENT ON FUNCTION public.create_roster_trade(text, text, text, text, text, text[], text[], text, text) IS
  'Creates one durable trade revision and its linked pending-action envelope without mutating rosters.';
COMMENT ON FUNCTION public.reconcile_operation_outbox(uuid, text, text, boolean) IS
  'Admin-only manual resolution for ambiguous Discord delivery: link the existing message or authorize an explicit retry.';
