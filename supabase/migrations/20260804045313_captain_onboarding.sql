-- Onboard one season-scoped captain only after Discord identity linking has
-- completed (normally through SALBot /division-sync). The caller must provide
-- every mapping explicitly; this function never infers assignments from the
-- legacy global player/org captain fields and never grants admin access.
--
-- season_orgs identity is the full (season_id, org_id, division_id) triple
-- (see 20260804022500_allow_multidivision_preseason_teams.sql) because a
-- league-wide organization may field an independent team in more than one
-- division for the same season. Every season_orgs lookup here is therefore
-- scoped by division_id as well as org_id, so onboarding a captain for one
-- of an organization's divisions never collides with its other divisions.

CREATE OR REPLACE FUNCTION public.onboard_season_captain(
  p_season_id text,
  p_player_id text,
  p_discord_id text,
  p_org_id text,
  p_division_id text,
  p_actor_discord_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_season_id text := NULLIF(btrim(COALESCE(p_season_id, '')), '');
  v_player_id text := NULLIF(btrim(COALESCE(p_player_id, '')), '');
  v_discord_id text := NULLIF(btrim(COALESCE(p_discord_id, '')), '');
  v_org_id text := NULLIF(btrim(COALESCE(p_org_id, '')), '');
  v_division_id text := NULLIF(btrim(COALESCE(p_division_id, '')), '');
  v_actor_discord_id text := NULLIF(btrim(COALESCE(p_actor_discord_id, '')), '');
  v_season_status text;
  v_player_discord_id text;
  v_player_archived_at timestamptz;
  v_org_archived_at timestamptz;
  v_season_org public.season_orgs%ROWTYPE;
  v_roster public.season_rosters%ROWTYPE;
  v_old_roster jsonb;
  v_season_org_created boolean := false;
  v_audit_rows integer := 0;
BEGIN
  IF v_season_id IS NULL
    OR v_player_id IS NULL
    OR v_discord_id IS NULL
    OR v_org_id IS NULL
    OR v_division_id IS NULL
    OR v_actor_discord_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Season, player, Discord, organization, division, and actor mappings are required.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.admin_users
    WHERE discord_id = v_actor_discord_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Only a SAL admin can onboard a season captain.';
  END IF;

  SELECT status
  INTO v_season_status
  FROM public.seasons
  WHERE id = v_season_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Season % does not exist', v_season_id;
  END IF;
  IF v_season_status NOT IN ('pre-season', 'active') THEN
    RAISE EXCEPTION 'Season % is not open for captain onboarding', v_season_id;
  END IF;

  SELECT discord_id, archived_at
  INTO v_player_discord_id, v_player_archived_at
  FROM public.players
  WHERE id = v_player_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player % does not exist', v_player_id;
  END IF;
  IF v_player_archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'Player % is archived', v_player_id;
  END IF;
  IF v_player_discord_id IS DISTINCT FROM v_discord_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = format(
        'Player %s is not linked to the supplied Discord id; run /division-sync first',
        v_player_id
      );
  END IF;

  SELECT archived_at
  INTO v_org_archived_at
  FROM public.orgs
  WHERE id = v_org_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Organization % does not exist', v_org_id;
  END IF;
  IF v_org_archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'Organization % is archived', v_org_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.divisions WHERE id = v_division_id) THEN
    RAISE EXCEPTION 'Division % does not exist', v_division_id;
  END IF;

  -- season_orgs identity is (season_id, org_id, division_id): an organization
  -- can field an independent team in each division, so this lookup must not
  -- match a sibling division's season_orgs row for the same organization.
  SELECT *
  INTO v_season_org
  FROM public.season_orgs
  WHERE season_id = v_season_id
    AND org_id = v_org_id
    AND division_id = v_division_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_season_org.status <> 'active' THEN
      RAISE EXCEPTION USING
        ERRCODE = '23514',
        MESSAGE = format(
          'Organization %s division %s is not an active season team in season %s',
          v_org_id,
          v_division_id,
          v_season_id
        );
    END IF;
  ELSE
    INSERT INTO public.season_orgs (
      season_id, org_id, division_id, status
    ) VALUES (
      v_season_id, v_org_id, v_division_id, 'active'
    );
    v_season_org_created := true;

    INSERT INTO public.audit_logs (
      action_type,
      entity_type,
      entity_id,
      actor_discord_id,
      old_value_json,
      new_value_json,
      note
    ) VALUES (
      'season_organization_onboarded',
      'season_org',
      v_season_id || ':' || v_org_id || ':' || v_division_id,
      v_actor_discord_id,
      NULL,
      jsonb_build_object(
        'seasonId', v_season_id,
        'organizationId', v_org_id,
        'divisionId', v_division_id,
        'status', 'active'
      ),
      'Created the explicit organization-division mapping required for captain onboarding.'
    );
    v_audit_rows := v_audit_rows + 1;
  END IF;

  -- season_rosters holds at most one row per (season_id, player_id): a player
  -- can only be on one organization's one division-team per season. This is
  -- unrelated to season_orgs allowing multiple divisions per organization.
  SELECT *
  INTO v_roster
  FROM public.season_rosters
  WHERE season_id = v_season_id
    AND player_id = v_player_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_roster.org_id IS DISTINCT FROM v_org_id
      OR v_roster.division_id IS DISTINCT FROM v_division_id
      OR v_roster.roster_status <> 'active' THEN
      RAISE EXCEPTION USING
        ERRCODE = '23514',
        MESSAGE = format(
          'Player %s already has a conflicting roster assignment in season %s',
          v_player_id,
          v_season_id
        );
    END IF;

    IF v_roster.is_captain THEN
      RETURN jsonb_build_object(
        'code', 'already_onboarded',
        'applied', false,
        'seasonId', v_season_id,
        'playerId', v_player_id,
        'discordId', v_discord_id,
        'organizationId', v_org_id,
        'divisionId', v_division_id,
        'seasonOrganizationCreated', false,
        'auditRows', 0
      );
    END IF;

    v_old_roster := jsonb_build_object(
      'seasonId', v_roster.season_id,
      'playerId', v_roster.player_id,
      'organizationId', v_roster.org_id,
      'divisionId', v_roster.division_id,
      'isCaptain', v_roster.is_captain,
      'rosterStatus', v_roster.roster_status
    );

    UPDATE public.season_rosters
    SET is_captain = true,
        updated_at = now()
    WHERE season_id = v_season_id
      AND player_id = v_player_id;
  ELSE
    v_old_roster := NULL;
    INSERT INTO public.season_rosters (
      season_id,
      player_id,
      org_id,
      division_id,
      is_captain,
      roster_status
    ) VALUES (
      v_season_id,
      v_player_id,
      v_org_id,
      v_division_id,
      true,
      'active'
    );
  END IF;

  INSERT INTO public.audit_logs (
    action_type,
    entity_type,
    entity_id,
    actor_discord_id,
    old_value_json,
    new_value_json,
    note
  ) VALUES (
    'season_captain_onboarded',
    'season_roster',
    v_season_id || ':' || v_player_id,
    v_actor_discord_id,
    v_old_roster,
    jsonb_build_object(
      'seasonId', v_season_id,
      'playerId', v_player_id,
      'discordId', v_discord_id,
      'organizationId', v_org_id,
      'divisionId', v_division_id,
      'isCaptain', true,
      'rosterStatus', 'active'
    ),
    'Onboarded an explicitly mapped season captain after Discord identity linking.'
  );
  v_audit_rows := v_audit_rows + 1;

  RETURN jsonb_build_object(
    'code', 'onboarded',
    'applied', true,
    'seasonId', v_season_id,
    'playerId', v_player_id,
    'discordId', v_discord_id,
    'organizationId', v_org_id,
    'divisionId', v_division_id,
    'seasonOrganizationCreated', v_season_org_created,
    'auditRows', v_audit_rows
  );
END;
$$;

ALTER FUNCTION public.onboard_season_captain(text, text, text, text, text, text)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION public.onboard_season_captain(text, text, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.onboard_season_captain(text, text, text, text, text, text)
  TO service_role;

COMMENT ON FUNCTION public.onboard_season_captain(text, text, text, text, text, text)
  IS 'Idempotently creates one explicit season captain mapping after Discord identity linking and appends immutable audits. season_orgs lookups are scoped by division so an organization fielding independent teams in multiple divisions can onboard a captain for each one.';
