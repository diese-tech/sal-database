-- Safely consolidate an accidentally duplicated league-wide organization into
-- the canonical identity. Preview and apply share the same conflict rules;
-- apply rechecks them while holding locks and performs every mutation in the
-- caller's transaction.

CREATE OR REPLACE FUNCTION public.preview_organization_merge(
  p_source_org_id text,
  p_target_org_id text
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_source_id text := NULLIF(btrim(COALESCE(p_source_org_id, '')), '');
  v_target_id text := NULLIF(btrim(COALESCE(p_target_org_id, '')), '');
  v_source public.orgs%ROWTYPE;
  v_target public.orgs%ROWTYPE;
  v_counts jsonb;
  v_blockers jsonb := '[]'::jsonb;
BEGIN
  IF v_source_id IS NULL OR v_target_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Source and target organization IDs are required.';
  END IF;

  IF v_source_id = v_target_id THEN
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target organizations must be different.'
    );
  END IF;

  SELECT * INTO v_source FROM public.orgs WHERE id = v_source_id;
  SELECT * INTO v_target FROM public.orgs WHERE id = v_target_id;

  IF v_source.id IS NULL THEN
    v_blockers := v_blockers || jsonb_build_array('Source organization does not exist.');
  ELSIF v_source.archived_at IS NOT NULL OR v_source.deletion_scheduled_at IS NOT NULL THEN
    v_blockers := v_blockers || jsonb_build_array(
      'Source organization must be active and not scheduled for deletion.'
    );
  END IF;

  IF v_target.id IS NULL THEN
    v_blockers := v_blockers || jsonb_build_array('Target organization does not exist.');
  ELSIF v_target.archived_at IS NOT NULL OR v_target.deletion_scheduled_at IS NOT NULL THEN
    v_blockers := v_blockers || jsonb_build_array(
      'Target organization must be active and not scheduled for deletion.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.matches
    WHERE (home_org_id = v_source_id AND away_org_id = v_target_id)
       OR (home_org_id = v_target_id AND away_org_id = v_source_id)
  ) THEN
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target oppose each other in a match; merging would create a self-match.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.draft_rooms
    WHERE base_order ? v_source_id
      AND base_order ? v_target_id
  ) THEN
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target both participate in the same draft room.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.season_rosters AS source_roster
    JOIN public.season_rosters AS target_roster
      ON target_roster.season_id = source_roster.season_id
     AND target_roster.division_id = source_roster.division_id
     AND target_roster.org_id = v_target_id
     AND target_roster.is_captain
     AND target_roster.roster_status = 'active'
    WHERE source_roster.org_id = v_source_id
      AND source_roster.is_captain
      AND source_roster.roster_status = 'active'
      AND source_roster.player_id <> target_roster.player_id
  ) THEN
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target have different active captains for the same season and division.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.captain_tokens AS source_token
    JOIN public.captain_tokens AS target_token
      ON target_token.draft_room_id = source_token.draft_room_id
     AND target_token.org_id = v_target_id
    WHERE source_token.org_id = v_source_id
  ) THEN
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target both have captain access tokens for the same draft room.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.captain_shortlists AS source_item
    JOIN public.captain_shortlists AS target_item
      ON target_item.draft_room_id = source_item.draft_room_id
     AND target_item.player_id = source_item.player_id
     AND target_item.org_id = v_target_id
    WHERE source_item.org_id = v_source_id
  ) THEN
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target shortlist the same player in the same draft room.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.pending_actions
    WHERE status IN ('pending', 'pending_info')
      AND jsonb_path_exists(
        payload_json,
        '$.** ? (@ == $source)',
        jsonb_build_object('source', v_source_id)
      )
  ) OR EXISTS (
    SELECT 1
    FROM public.pending_stat_records
    WHERE status = 'pending'
      AND (
        jsonb_path_exists(
          extracted_json,
          '$.** ? (@ == $source)',
          jsonb_build_object('source', v_source_id)
        )
        OR jsonb_path_exists(
          COALESCE(stats_json, '{}'::jsonb),
          '$.** ? (@ == $source)',
          jsonb_build_object('source', v_source_id)
        )
      )
  ) THEN
    v_blockers := v_blockers || jsonb_build_array(
      'An unresolved admin action or stat record still references the source organization.'
    );
  END IF;

  SELECT jsonb_build_object(
    'seasonTeams', (SELECT count(*) FROM public.season_orgs WHERE org_id = v_source_id),
    'seasonRosters', (SELECT count(*) FROM public.season_rosters WHERE org_id = v_source_id),
    'players', (SELECT count(*) FROM public.players WHERE org_id = v_source_id),
    'matches', (
      SELECT count(*) FROM public.matches
      WHERE home_org_id = v_source_id OR away_org_id = v_source_id OR winner_org_id = v_source_id
    ),
    'playerMatchStats', (SELECT count(*) FROM public.player_match_stats WHERE org_id = v_source_id),
    'playerStats', (SELECT count(*) FROM public.player_stats WHERE org_id = v_source_id),
    'draftPicks', (SELECT count(*) FROM public.draft_picks WHERE org_id = v_source_id),
    'draftShortlists', (SELECT count(*) FROM public.captain_shortlists WHERE org_id = v_source_id),
    'captainTokens', (SELECT count(*) FROM public.captain_tokens WHERE org_id = v_source_id),
    'draftRooms', (SELECT count(*) FROM public.draft_rooms WHERE base_order ? v_source_id),
    'godPicks', (SELECT count(*) FROM public.god_picks WHERE org_id = v_source_id),
    'godBans', (SELECT count(*) FROM public.god_bans WHERE org_id = v_source_id),
    'standings', (SELECT count(*) FROM public.standings WHERE org_id = v_source_id)
  ) INTO v_counts;

  RETURN jsonb_build_object(
    'source', CASE WHEN v_source.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_source.id,
      'name', v_source.name,
      'tag', v_source.tag,
      'divisionId', v_source.division_id
    ) END,
    'target', CASE WHEN v_target.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_target.id,
      'name', v_target.name,
      'tag', v_target.tag,
      'divisionId', v_target.division_id
    ) END,
    'counts', v_counts,
    'blockers', v_blockers,
    'canMerge', jsonb_array_length(v_blockers) = 0
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.merge_organization(
  p_source_org_id text,
  p_target_org_id text,
  p_actor_discord_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_source_id text := NULLIF(btrim(COALESCE(p_source_org_id, '')), '');
  v_target_id text := NULLIF(btrim(COALESCE(p_target_org_id, '')), '');
  v_actor_id text := NULLIF(btrim(COALESCE(p_actor_discord_id, '')), '');
  v_preview jsonb;
  v_source jsonb;
  v_target jsonb;
  v_remaining bigint;
BEGIN
  IF v_source_id IS NULL OR v_target_id IS NULL OR v_actor_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Source, target, and actor IDs are required.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.admin_users
    WHERE discord_id = v_actor_id AND role = 'super_admin'
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Only a SAL superadmin can merge organizations.';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'organization-merge:' || LEAST(v_source_id, v_target_id)
        || ':' || GREATEST(v_source_id, v_target_id),
      0
    )
  );

  -- A missing source after a successful commit is an idempotent retry, not an
  -- ambiguous failure caused by a lost HTTP response.
  IF NOT EXISTS (SELECT 1 FROM public.orgs WHERE id = v_source_id) THEN
    IF EXISTS (
      SELECT 1
      FROM public.audit_logs
      WHERE action_type = 'organization_merged'
        AND entity_type = 'organization'
        AND entity_id = v_source_id
        AND new_value_json ->> 'targetOrganizationId' = v_target_id
    ) THEN
      RETURN jsonb_build_object(
        'code', 'already_merged',
        'applied', false,
        'sourceOrganizationId', v_source_id,
        'targetOrganizationId', v_target_id
      );
    END IF;
  END IF;

  -- Lock both identities in a stable order before the final preview so two
  -- overlapping merges cannot pass validation concurrently.
  PERFORM id
  FROM public.orgs
  WHERE id IN (v_source_id, v_target_id)
  ORDER BY id
  FOR UPDATE;

  v_preview := public.preview_organization_merge(v_source_id, v_target_id);
  IF COALESCE((v_preview ->> 'canMerge')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Organization merge blocked: ' || COALESCE(
        (
          SELECT string_agg(value, ' ')
          FROM jsonb_array_elements_text(v_preview -> 'blockers') AS blockers(value)
        ),
        'Preview validation failed.'
      );
  END IF;

  v_source := v_preview -> 'source';
  v_target := v_preview -> 'target';

  -- Materialize every source season-team identity under the canonical org
  -- before moving composite-FK children. Existing canonical rows win.
  INSERT INTO public.season_orgs (
    season_id, org_id, division_id, status, created_at, updated_at
  )
  SELECT season_id, v_target_id, division_id, status, created_at, now()
  FROM public.season_orgs
  WHERE org_id = v_source_id
  ON CONFLICT (season_id, org_id, division_id) DO NOTHING;

  UPDATE public.season_rosters SET org_id = v_target_id, updated_at = now()
  WHERE org_id = v_source_id;

  -- Match sides must move before official player_stats: that table's
  -- attribution trigger verifies the new org remains one of the match teams.
  UPDATE public.matches SET home_org_id = v_target_id WHERE home_org_id = v_source_id;
  UPDATE public.matches SET away_org_id = v_target_id WHERE away_org_id = v_source_id;
  UPDATE public.matches SET winner_org_id = v_target_id WHERE winner_org_id = v_source_id;

  UPDATE public.player_stats SET org_id = v_target_id WHERE org_id = v_source_id;
  UPDATE public.player_match_stats SET org_id = v_target_id WHERE org_id = v_source_id;
  UPDATE public.players SET org_id = v_target_id WHERE org_id = v_source_id;

  UPDATE public.draft_picks SET org_id = v_target_id WHERE org_id = v_source_id;
  UPDATE public.captain_shortlists SET org_id = v_target_id WHERE org_id = v_source_id;
  UPDATE public.captain_tokens SET org_id = v_target_id WHERE org_id = v_source_id;
  UPDATE public.god_picks SET org_id = v_target_id WHERE org_id = v_source_id;
  UPDATE public.god_bans SET org_id = v_target_id WHERE org_id = v_source_id;

  UPDATE public.draft_rooms AS rooms
  SET base_order = (
    SELECT jsonb_agg(
      CASE WHEN item.value = to_jsonb(v_source_id) THEN to_jsonb(v_target_id) ELSE item.value END
      ORDER BY item.ordinality
    )
    FROM jsonb_array_elements(rooms.base_order) WITH ORDINALITY AS item(value, ordinality)
  )
  WHERE rooms.base_order ? v_source_id;

  -- Standings are derived. Preserve the canonical cache row when both exist;
  -- otherwise re-key the source row. The site performs a full recalculation
  -- after the merge response.
  DELETE FROM public.standings AS source_standing
  WHERE source_standing.org_id = v_source_id
    AND EXISTS (SELECT 1 FROM public.standings WHERE org_id = v_target_id);
  UPDATE public.standings SET org_id = v_target_id WHERE org_id = v_source_id;

  DELETE FROM public.season_orgs WHERE org_id = v_source_id;

  SELECT
    (SELECT count(*) FROM public.season_orgs WHERE org_id = v_source_id)
    + (SELECT count(*) FROM public.season_rosters WHERE org_id = v_source_id)
    + (SELECT count(*) FROM public.players WHERE org_id = v_source_id)
    + (SELECT count(*) FROM public.matches WHERE home_org_id = v_source_id OR away_org_id = v_source_id OR winner_org_id = v_source_id)
    + (SELECT count(*) FROM public.player_match_stats WHERE org_id = v_source_id)
    + (SELECT count(*) FROM public.player_stats WHERE org_id = v_source_id)
    + (SELECT count(*) FROM public.draft_picks WHERE org_id = v_source_id)
    + (SELECT count(*) FROM public.captain_shortlists WHERE org_id = v_source_id)
    + (SELECT count(*) FROM public.captain_tokens WHERE org_id = v_source_id)
    + (SELECT count(*) FROM public.draft_rooms WHERE base_order ? v_source_id)
    + (SELECT count(*) FROM public.god_picks WHERE org_id = v_source_id)
    + (SELECT count(*) FROM public.god_bans WHERE org_id = v_source_id)
    + (SELECT count(*) FROM public.standings WHERE org_id = v_source_id)
  INTO v_remaining;

  IF v_remaining <> 0 THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = format(
        'Organization merge left %s typed references to source %s.',
        v_remaining,
        v_source_id
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
    'organization_merged',
    'organization',
    v_source_id,
    v_actor_id,
    v_source,
    jsonb_build_object(
      'targetOrganizationId', v_target_id,
      'target', v_target,
      'counts', v_preview -> 'counts'
    ),
    'Consolidated a duplicate organization identity into the canonical organization.'
  );

  INSERT INTO public.admin_audit_log (action, entity_type, entity_id, payload)
  VALUES (
    'merge_organization',
    'org',
    v_source_id,
    jsonb_build_object(
      'actorDiscordId', v_actor_id,
      'source', v_source,
      'target', v_target,
      'counts', v_preview -> 'counts'
    )
  );

  DELETE FROM public.orgs WHERE id = v_source_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source organization % disappeared during merge', v_source_id;
  END IF;

  RETURN jsonb_build_object(
    'code', 'merged',
    'applied', true,
    'sourceOrganizationId', v_source_id,
    'targetOrganizationId', v_target_id,
    'source', v_source,
    'target', v_target,
    'counts', v_preview -> 'counts'
  );
END;
$$;

ALTER FUNCTION public.preview_organization_merge(text, text) OWNER TO postgres;
ALTER FUNCTION public.merge_organization(text, text, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.preview_organization_merge(text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.merge_organization(text, text, text)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.preview_organization_merge(text, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.merge_organization(text, text, text)
  TO service_role;

COMMENT ON FUNCTION public.preview_organization_merge(text, text) IS
  'Returns affected-row counts and fail-closed blockers for consolidating one organization identity into another.';
COMMENT ON FUNCTION public.merge_organization(text, text, text) IS
  'Atomically transfers every typed live organization reference to a canonical identity, preserves immutable evidence, audits the actor, and deletes the duplicate.';
