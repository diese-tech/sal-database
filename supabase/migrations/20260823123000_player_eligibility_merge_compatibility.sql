-- Keep the canonical player-identity merge compatible with authoritative
-- post-transaction eligibility. A merge transfers the typed reference while
-- preserving the fail-closed behavior for future, unhandled player references.

CREATE OR REPLACE FUNCTION public.preview_player_merge(
  p_source_player_id text,
  p_target_player_id text
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_source_id text := NULLIF(btrim(COALESCE(p_source_player_id, '')), '');
  v_target_id text := NULLIF(btrim(COALESCE(p_target_player_id, '')), '');
  v_source public.players%ROWTYPE;
  v_target public.players%ROWTYPE;
  v_counts jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_blocker_codes jsonb := '[]'::jsonb;
  v_unknown_references jsonb;
BEGIN
  IF v_source_id IS NULL OR v_target_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Source and target player IDs are required.';
  END IF;

  IF v_source_id = v_target_id THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('SELF_MERGE');
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target players must be different.'
    );
  END IF;

  SELECT * INTO v_source FROM public.players WHERE id = v_source_id;
  SELECT * INTO v_target FROM public.players WHERE id = v_target_id;

  IF v_source.id IS NULL THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('SOURCE_NOT_FOUND');
    v_blockers := v_blockers || jsonb_build_array('Source player does not exist.');
  ELSIF v_source.archived_at IS NOT NULL OR v_source.deletion_scheduled_at IS NOT NULL THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('SOURCE_UNAVAILABLE');
    v_blockers := v_blockers || jsonb_build_array(
      'Source player must be active and not scheduled for deletion.'
    );
  END IF;

  IF v_target.id IS NULL THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('TARGET_NOT_FOUND');
    v_blockers := v_blockers || jsonb_build_array('Target player does not exist.');
  ELSIF v_target.archived_at IS NOT NULL OR v_target.deletion_scheduled_at IS NOT NULL THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('TARGET_UNAVAILABLE');
    v_blockers := v_blockers || jsonb_build_array(
      'Target player must be active and not scheduled for deletion.'
    );
  END IF;

  -- This allow-list makes a later, unhandled FK a hard blocker instead of
  -- allowing a partial merge or relying on an opaque delete failure.
  SELECT COALESCE(jsonb_agg(constraint_name ORDER BY constraint_name), '[]'::jsonb)
  INTO v_unknown_references
  FROM (
    SELECT constraints.conname AS constraint_name
    FROM pg_constraint AS constraints
    WHERE constraints.contype = 'f'
      AND constraints.confrelid = 'public.players'::regclass
      AND constraints.conname <> ALL (ARRAY[
        'draft_picks_player_id_fkey',
        'orgs_captain_id_fkey',
        'pending_stat_records_player_id_fkey',
        'player_match_stats_player_id_fkey',
        'player_stats_player_id_fkey',
        'registrations_player_id_fkey',
        'scouter_game_participants_player_id_fkey',
        'season_rosters_player_id_fkey',
        'roster_transaction_movements_player_id_fkey',
        'season_player_eligibility_player_id_fkey'
      ]::text[])
  ) AS unknown;

  IF jsonb_array_length(v_unknown_references) > 0 THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('UNSUPPORTED_PLAYER_REFERENCE');
    v_blockers := v_blockers || jsonb_build_array(
      'The schema contains an unhandled player reference: ' || v_unknown_references::text
    );
  END IF;

  IF v_source.discord_id IS NOT NULL
    AND v_target.discord_id IS NOT NULL
    AND v_source.discord_id <> v_target.discord_id THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('DISCORD_ID_CONFLICT');
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target are linked to different Discord identities.'
    );
  END IF;

  IF NOT (
    v_source.discord_id IS NOT NULL
    AND v_target.discord_id IS NOT NULL
    AND v_source.discord_id <> v_target.discord_id
  ) AND (
    SELECT count(DISTINCT discord_id) > 1
    FROM (
      SELECT v_source.discord_id AS discord_id
      UNION ALL SELECT v_target.discord_id
      UNION ALL
      SELECT registrations.discord_id
      FROM public.registrations
      WHERE registrations.player_id IN (v_source_id, v_target_id)
    ) AS identity_links
    WHERE discord_id IS NOT NULL
  ) THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('REGISTRATION_DISCORD_CONFLICT');
    v_blockers := v_blockers || jsonb_build_array(
      'Player and registration rows identify more than one Discord account.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.season_rosters AS source_roster
    JOIN public.season_rosters AS target_roster
      ON target_roster.season_id = source_roster.season_id
     AND target_roster.player_id = v_target_id
    WHERE source_roster.player_id = v_source_id
      AND source_roster.roster_status <> 'free_agent'
      AND target_roster.roster_status <> 'free_agent'
      AND (
        source_roster.org_id IS DISTINCT FROM target_roster.org_id
        OR source_roster.division_id IS DISTINCT FROM target_roster.division_id
      )
  ) THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('SEASON_ROSTER_CONFLICT');
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target have competing team assignments in the same season.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.season_player_eligibility AS source_eligibility
    JOIN public.season_player_eligibility AS target_eligibility
      ON target_eligibility.season_id = source_eligibility.season_id
     AND target_eligibility.player_id = v_target_id
    WHERE source_eligibility.player_id = v_source_id
  ) THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('SEASON_ELIGIBILITY_CONFLICT');
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target both have post-transaction eligibility in the same season.'
    );
  END IF;

  IF (
    SELECT count(DISTINCT id) > 1
    FROM public.orgs
    WHERE captain_id IN (v_source_id, v_target_id)
      AND archived_at IS NULL
  ) THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('ORGANIZATION_CAPTAIN_CONFLICT');
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target are captains of different active organizations.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.draft_picks AS source_pick
    JOIN public.draft_picks AS target_pick
      ON target_pick.draft_room_id = source_pick.draft_room_id
     AND target_pick.player_id = v_target_id
    WHERE source_pick.player_id = v_source_id
  ) THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('DRAFT_PICK_CONFLICT');
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target both participate in the same draft room.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.captain_shortlists AS source_item
    JOIN public.captain_shortlists AS target_item
      ON target_item.draft_room_id = source_item.draft_room_id
     AND target_item.org_id = source_item.org_id
     AND target_item.player_id = v_target_id
    WHERE source_item.player_id = v_source_id
      AND source_item.position <> target_item.position
  ) THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('DRAFT_SHORTLIST_CONFLICT');
    v_blockers := v_blockers || jsonb_build_array(
      'A captain ranked source and target differently in the same shortlist.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.player_match_stats AS source_stats
    JOIN public.player_match_stats AS target_stats
      ON target_stats.match_id = source_stats.match_id
     AND target_stats.game_number = source_stats.game_number
     AND target_stats.player_id = v_target_id
    WHERE source_stats.player_id = v_source_id
  ) THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('PLAYER_MATCH_STATS_CONFLICT');
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target both have report stats for the same game.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.player_stats AS source_stats
    JOIN public.player_stats AS target_stats
      ON target_stats.match_id = source_stats.match_id
     AND target_stats.game_number = source_stats.game_number
     AND target_stats.player_id = v_target_id
    WHERE source_stats.player_id = v_source_id
      AND (
        (source_stats.pending_stat_record_id IS NOT NULL AND target_stats.pending_stat_record_id IS NOT NULL AND source_stats.pending_stat_record_id IS DISTINCT FROM target_stats.pending_stat_record_id)
        OR (source_stats.kills IS NOT NULL AND target_stats.kills IS NOT NULL AND source_stats.kills IS DISTINCT FROM target_stats.kills)
        OR (source_stats.deaths IS NOT NULL AND target_stats.deaths IS NOT NULL AND source_stats.deaths IS DISTINCT FROM target_stats.deaths)
        OR (source_stats.assists IS NOT NULL AND target_stats.assists IS NOT NULL AND source_stats.assists IS DISTINCT FROM target_stats.assists)
        OR (source_stats.damage_dealt IS NOT NULL AND target_stats.damage_dealt IS NOT NULL AND source_stats.damage_dealt IS DISTINCT FROM target_stats.damage_dealt)
        OR (source_stats.healing_done IS NOT NULL AND target_stats.healing_done IS NOT NULL AND source_stats.healing_done IS DISTINCT FROM target_stats.healing_done)
        OR (source_stats.damage_mitigated IS NOT NULL AND target_stats.damage_mitigated IS NOT NULL AND source_stats.damage_mitigated IS DISTINCT FROM target_stats.damage_mitigated)
        OR (source_stats.god_played IS NOT NULL AND target_stats.god_played IS NOT NULL AND source_stats.god_played IS DISTINCT FROM target_stats.god_played)
        OR (source_stats.role IS NOT NULL AND target_stats.role IS NOT NULL AND source_stats.role IS DISTINCT FROM target_stats.role)
        OR (source_stats.won IS NOT NULL AND target_stats.won IS NOT NULL AND source_stats.won IS DISTINCT FROM target_stats.won)
        OR (source_stats.season_id IS NOT NULL AND target_stats.season_id IS NOT NULL AND source_stats.season_id IS DISTINCT FROM target_stats.season_id)
        OR (source_stats.org_id IS NOT NULL AND target_stats.org_id IS NOT NULL AND source_stats.org_id IS DISTINCT FROM target_stats.org_id)
        OR (source_stats.division_id IS NOT NULL AND target_stats.division_id IS NOT NULL AND source_stats.division_id IS DISTINCT FROM target_stats.division_id)
      )
  ) THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('PLAYER_STATS_CONFLICT');
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target have conflicting official stats for the same game.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.scouter_game_participants AS source_participant
    JOIN public.scouter_game_participants AS target_participant
      ON target_participant.scouter_game_id = source_participant.scouter_game_id
     AND target_participant.player_id = v_target_id
    WHERE source_participant.player_id = v_source_id
  ) THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('SCOUTER_PARTICIPANT_CONFLICT');
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target both occupy participant slots in the same scouter game.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.roster_transaction_movements AS source_movement
    JOIN public.roster_transaction_movements AS target_movement
      ON target_movement.transaction_id = source_movement.transaction_id
     AND target_movement.revision = source_movement.revision
     AND target_movement.player_id = v_target_id
    WHERE source_movement.player_id = v_source_id
  ) THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('ROSTER_TRANSACTION_MOVEMENT_CONFLICT');
    v_blockers := v_blockers || jsonb_build_array(
      'Source and target both appear in the same roster transaction revision.'
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
        jsonb_path_exists(extracted_json, '$.** ? (@ == $source)', jsonb_build_object('source', v_source_id))
        OR jsonb_path_exists(COALESCE(stats_json, '{}'::jsonb), '$.** ? (@ == $source)', jsonb_build_object('source', v_source_id))
      )
  ) OR EXISTS (
    SELECT 1
    FROM public.match_reports
    WHERE status IN ('pending', 'extracting', 'review')
      AND jsonb_path_exists(COALESCE(extracted_data, '{}'::jsonb), '$.** ? (@ == $source)', jsonb_build_object('source', v_source_id))
  ) OR EXISTS (
    SELECT 1
    FROM public.scouter_game_drafts
    WHERE status = 'pending'
      AND (
        jsonb_path_exists(extracted_game, '$.** ? (@ == $source)', jsonb_build_object('source', v_source_id))
        OR jsonb_path_exists(COALESCE(revised_game, '{}'::jsonb), '$.** ? (@ == $source)', jsonb_build_object('source', v_source_id))
      )
  ) THEN
    v_blocker_codes := v_blocker_codes || jsonb_build_array('UNRESOLVED_JSON_REFERENCE');
    v_blockers := v_blockers || jsonb_build_array(
      'An unresolved review or action contains the source player ID in JSON.'
    );
  END IF;

  SELECT jsonb_build_object(
    'seasonRosters', (SELECT count(*) FROM public.season_rosters WHERE player_id = v_source_id),
    'organizationCaptainLinks', (SELECT count(*) FROM public.orgs WHERE captain_id = v_source_id),
    'pendingStatRecords', (SELECT count(*) FROM public.pending_stat_records WHERE player_id = v_source_id),
    'playerMatchStats', (SELECT count(*) FROM public.player_match_stats WHERE player_id = v_source_id),
    'playerStats', (SELECT count(*) FROM public.player_stats WHERE player_id = v_source_id),
    'registrations', (SELECT count(*) FROM public.registrations WHERE player_id = v_source_id),
    'scouterParticipants', (SELECT count(*) FROM public.scouter_game_participants WHERE player_id = v_source_id),
    'draftPicks', (SELECT count(*) FROM public.draft_picks WHERE player_id = v_source_id),
    'rosterTransactionMovements', (SELECT count(*) FROM public.roster_transaction_movements WHERE player_id = v_source_id),
    'seasonPlayerEligibility', (SELECT count(*) FROM public.season_player_eligibility WHERE player_id = v_source_id),
    'draftShortlists', (SELECT count(*) FROM public.captain_shortlists WHERE player_id = v_source_id),
    'immutableAuditLogs', (
      SELECT count(*) FROM public.audit_logs
      WHERE entity_id = v_source_id
        OR jsonb_path_exists(COALESCE(old_value_json, '{}'::jsonb), '$.** ? (@ == $source)', jsonb_build_object('source', v_source_id))
        OR jsonb_path_exists(COALESCE(new_value_json, '{}'::jsonb), '$.** ? (@ == $source)', jsonb_build_object('source', v_source_id))
    ),
    'immutableAdminAuditLogs', (
      SELECT count(*) FROM public.admin_audit_log
      WHERE entity_id = v_source_id
        OR jsonb_path_exists(COALESCE(payload, '{}'::jsonb), '$.** ? (@ == $source)', jsonb_build_object('source', v_source_id))
    ),
    'immutableOutboxEvents', (
      SELECT count(*) FROM public.operation_outbox
      WHERE aggregate_id = v_source_id
        OR jsonb_path_exists(payload, '$.** ? (@ == $source)', jsonb_build_object('source', v_source_id))
    ),
    'immutableScouterCorrections', (
      SELECT count(*) FROM public.scouter_game_corrections
      WHERE jsonb_path_exists(request_json, '$.** ? (@ == $source)', jsonb_build_object('source', v_source_id))
        OR jsonb_path_exists(old_value_json, '$.** ? (@ == $source)', jsonb_build_object('source', v_source_id))
        OR jsonb_path_exists(new_value_json, '$.** ? (@ == $source)', jsonb_build_object('source', v_source_id))
    )
  ) INTO v_counts;

  RETURN jsonb_build_object(
    'source', CASE WHEN v_source.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_source.id,
      'ign', v_source.ign,
      'discordUsername', v_source.discord_username,
      'orgId', v_source.org_id,
      'divisionId', v_source.division_id,
      'status', v_source.status,
      'isCaptain', v_source.is_captain,
      'isStarter', v_source.is_starter,
      'profileClaimed', v_source.profile_claimed,
      'hasDiscordId', v_source.discord_id IS NOT NULL,
      'archivedAt', v_source.archived_at
    ) END,
    'target', CASE WHEN v_target.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_target.id,
      'ign', v_target.ign,
      'discordUsername', v_target.discord_username,
      'orgId', v_target.org_id,
      'divisionId', v_target.division_id,
      'status', v_target.status,
      'isCaptain', v_target.is_captain,
      'isStarter', v_target.is_starter,
      'profileClaimed', v_target.profile_claimed,
      'hasDiscordId', v_target.discord_id IS NOT NULL,
      'archivedAt', v_target.archived_at
    ) END,
    'counts', v_counts,
    'blockers', v_blockers,
    'blockerCodes', v_blocker_codes,
    'canMerge', jsonb_array_length(v_blockers) = 0
  );
END;
$$;
CREATE OR REPLACE FUNCTION public.merge_player(
  p_source_player_id text,
  p_target_player_id text,
  p_actor_discord_id text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_source_id text := NULLIF(btrim(COALESCE(p_source_player_id, '')), '');
  v_target_id text := NULLIF(btrim(COALESCE(p_target_player_id, '')), '');
  v_actor_id text := NULLIF(btrim(COALESCE(p_actor_discord_id, '')), '');
  v_preview jsonb;
  v_source public.players%ROWTYPE;
  v_target public.players%ROWTYPE;
  v_source_identity jsonb;
  v_target_identity jsonb;
  v_source_roster public.season_rosters%ROWTYPE;
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
      MESSAGE = 'Only a SAL superadmin can merge players.';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'player-merge:' || LEAST(v_source_id, v_target_id)
        || ':' || GREATEST(v_source_id, v_target_id),
      0
    )
  );

  IF NOT EXISTS (SELECT 1 FROM public.players WHERE id = v_source_id) THEN
    IF EXISTS (
      SELECT 1
      FROM public.audit_logs
      WHERE action_type = 'player_merged'
        AND entity_type = 'player'
        AND entity_id = v_source_id
        AND new_value_json ->> 'targetPlayerId' = v_target_id
    ) THEN
      RETURN jsonb_build_object(
        'code', 'already_merged',
        'applied', false,
        'sourcePlayerId', v_source_id,
        'targetPlayerId', v_target_id
      );
    END IF;
  END IF;

  PERFORM id
  FROM public.players
  WHERE id IN (v_source_id, v_target_id)
  ORDER BY id
  FOR UPDATE;

  -- Prevent a reference/action write from racing the final preview and the
  -- transfer. These locks are short-lived because the merge is one transaction.
  LOCK TABLE
    public.captain_shortlists,
    public.draft_picks,
    public.match_reports,
    public.orgs,
    public.pending_actions,
    public.pending_stat_records,
    public.player_match_stats,
    public.player_stats,
    public.registrations,
    public.roster_transaction_movements,
    public.season_player_eligibility,
    public.scouter_game_drafts,
    public.scouter_game_participants,
    public.season_rosters
  IN SHARE ROW EXCLUSIVE MODE;

  v_preview := public.preview_player_merge(v_source_id, v_target_id);
  IF COALESCE((v_preview ->> 'canMerge')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Player merge blocked [' || COALESCE(
        (
          SELECT string_agg(value, ',')
          FROM jsonb_array_elements_text(v_preview -> 'blockerCodes') AS codes(value)
        ),
        'PREVIEW_FAILED'
      ) || ']: ' || COALESCE(
        (
          SELECT string_agg(value, ' ')
          FROM jsonb_array_elements_text(v_preview -> 'blockers') AS blockers(value)
        ),
        'Preview validation failed.'
      );
  END IF;

  SELECT * INTO STRICT v_source FROM public.players WHERE id = v_source_id;
  SELECT * INTO STRICT v_target FROM public.players WHERE id = v_target_id;
  v_source_identity := v_preview -> 'source';
  v_target_identity := v_preview -> 'target';

  -- Coalesce same-season assignments. An assigned roster beats a free-agent
  -- row; otherwise the target assignment wins and compatible captain/status
  -- evidence is combined.
  FOR v_source_roster IN
    SELECT source_roster.*
    FROM public.season_rosters AS source_roster
    JOIN public.season_rosters AS target_roster
      ON target_roster.season_id = source_roster.season_id
     AND target_roster.player_id = v_target_id
    WHERE source_roster.player_id = v_source_id
    ORDER BY source_roster.season_id
  LOOP
    IF v_source_roster.is_captain THEN
      UPDATE public.season_rosters
      SET is_captain = false, updated_at = now()
      WHERE season_id = v_source_roster.season_id
        AND player_id = v_source_id;
    END IF;

    UPDATE public.season_rosters AS target_roster
    SET org_id = CASE
          WHEN target_roster.roster_status = 'free_agent'
            AND v_source_roster.roster_status <> 'free_agent'
            THEN v_source_roster.org_id
          ELSE target_roster.org_id
        END,
        division_id = CASE
          WHEN target_roster.roster_status = 'free_agent'
            AND v_source_roster.roster_status <> 'free_agent'
            THEN v_source_roster.division_id
          ELSE target_roster.division_id
        END,
        is_captain = CASE
          WHEN target_roster.roster_status = 'free_agent'
            AND v_source_roster.roster_status <> 'free_agent'
            THEN v_source_roster.is_captain
          WHEN v_source_roster.roster_status = 'free_agent'
            THEN target_roster.is_captain
          ELSE target_roster.is_captain OR v_source_roster.is_captain
        END,
        roster_status = CASE
          WHEN target_roster.roster_status = 'free_agent'
            AND v_source_roster.roster_status <> 'free_agent'
            THEN v_source_roster.roster_status
          WHEN target_roster.roster_status <> 'free_agent'
            AND v_source_roster.roster_status = 'free_agent'
            THEN target_roster.roster_status
          WHEN target_roster.roster_status = 'active'
            OR v_source_roster.roster_status = 'active'
            THEN 'active'
          ELSE target_roster.roster_status
        END,
        updated_at = now()
    WHERE target_roster.season_id = v_source_roster.season_id
      AND target_roster.player_id = v_target_id;

    DELETE FROM public.season_rosters
    WHERE season_id = v_source_roster.season_id
      AND player_id = v_source_id;
  END LOOP;

  UPDATE public.season_rosters SET player_id = v_target_id, updated_at = now()
  WHERE player_id = v_source_id;
  UPDATE public.season_player_eligibility
  SET player_id = v_target_id, updated_at = now()
  WHERE player_id = v_source_id;

  -- Compatible duplicate official rows become one row under the canonical ID.
  UPDATE public.player_stats AS target_stats
  SET pending_stat_record_id = COALESCE(target_stats.pending_stat_record_id, source_stats.pending_stat_record_id),
      kills = COALESCE(target_stats.kills, source_stats.kills),
      deaths = COALESCE(target_stats.deaths, source_stats.deaths),
      assists = COALESCE(target_stats.assists, source_stats.assists),
      damage_dealt = COALESCE(target_stats.damage_dealt, source_stats.damage_dealt),
      healing_done = COALESCE(target_stats.healing_done, source_stats.healing_done),
      damage_mitigated = COALESCE(target_stats.damage_mitigated, source_stats.damage_mitigated),
      god_played = COALESCE(target_stats.god_played, source_stats.god_played),
      role = COALESCE(target_stats.role, source_stats.role),
      won = COALESCE(target_stats.won, source_stats.won),
      season_id = COALESCE(target_stats.season_id, source_stats.season_id),
      org_id = COALESCE(target_stats.org_id, source_stats.org_id),
      division_id = COALESCE(target_stats.division_id, source_stats.division_id)
  FROM public.player_stats AS source_stats
  WHERE source_stats.player_id = v_source_id
    AND target_stats.player_id = v_target_id
    AND target_stats.match_id = source_stats.match_id
    AND target_stats.game_number = source_stats.game_number;

  DELETE FROM public.player_stats AS source_stats
  WHERE source_stats.player_id = v_source_id
    AND EXISTS (
      SELECT 1 FROM public.player_stats AS target_stats
      WHERE target_stats.player_id = v_target_id
        AND target_stats.match_id = source_stats.match_id
        AND target_stats.game_number = source_stats.game_number
    );
  UPDATE public.player_stats SET player_id = v_target_id WHERE player_id = v_source_id;
  UPDATE public.roster_transaction_movements SET player_id = v_target_id
  WHERE player_id = v_source_id;

  DELETE FROM public.captain_shortlists AS source_item
  WHERE source_item.player_id = v_source_id
    AND EXISTS (
      SELECT 1 FROM public.captain_shortlists AS target_item
      WHERE target_item.player_id = v_target_id
        AND target_item.draft_room_id = source_item.draft_room_id
        AND target_item.org_id = source_item.org_id
        AND target_item.position = source_item.position
    );

  UPDATE public.orgs SET captain_id = v_target_id WHERE captain_id = v_source_id;
  UPDATE public.pending_stat_records SET player_id = v_target_id WHERE player_id = v_source_id;
  UPDATE public.player_match_stats SET player_id = v_target_id WHERE player_id = v_source_id;
  UPDATE public.registrations SET player_id = v_target_id WHERE player_id = v_source_id;
  UPDATE public.scouter_game_participants SET player_id = v_target_id WHERE player_id = v_source_id;
  UPDATE public.draft_picks SET player_id = v_target_id WHERE player_id = v_source_id;
  UPDATE public.captain_shortlists SET player_id = v_target_id WHERE player_id = v_source_id;

  -- Free the unique Discord ID before moving it to the target row.
  IF v_target.discord_id IS NULL AND v_source.discord_id IS NOT NULL THEN
    UPDATE public.players SET discord_id = NULL WHERE id = v_source_id;
  END IF;

  UPDATE public.players
  SET discord_id = CASE
        WHEN v_target.discord_id IS NULL THEN v_source.discord_id
        ELSE v_target.discord_id
      END,
      discord_username = CASE
        WHEN v_target.discord_id IS NULL AND v_source.discord_id IS NOT NULL
          THEN v_source.discord_username
        ELSE v_target.discord_username
      END,
      profile_claimed = COALESCE(v_target.discord_id, v_source.discord_id) IS NOT NULL
        OR v_target.profile_claimed,
      avatar_url = COALESCE(v_target.avatar_url, v_source.avatar_url)
  WHERE id = v_target_id;

  SELECT
    (SELECT count(*) FROM public.season_rosters WHERE player_id = v_source_id)
    + (SELECT count(*) FROM public.orgs WHERE captain_id = v_source_id)
    + (SELECT count(*) FROM public.pending_stat_records WHERE player_id = v_source_id)
    + (SELECT count(*) FROM public.player_match_stats WHERE player_id = v_source_id)
    + (SELECT count(*) FROM public.player_stats WHERE player_id = v_source_id)
    + (SELECT count(*) FROM public.registrations WHERE player_id = v_source_id)
    + (SELECT count(*) FROM public.scouter_game_participants WHERE player_id = v_source_id)
    + (SELECT count(*) FROM public.draft_picks WHERE player_id = v_source_id)
    + (SELECT count(*) FROM public.roster_transaction_movements WHERE player_id = v_source_id)
    + (SELECT count(*) FROM public.season_player_eligibility WHERE player_id = v_source_id)
    + (SELECT count(*) FROM public.captain_shortlists WHERE player_id = v_source_id)
  INTO v_remaining;

  IF v_remaining <> 0 THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = format(
        'Player merge left %s typed references to source %s.',
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
    'player_merged',
    'player',
    v_source_id,
    v_actor_id,
    v_source_identity,
    jsonb_build_object(
      'targetPlayerId', v_target_id,
      'target', v_target_identity,
      'counts', v_preview -> 'counts'
    ),
    'Consolidated a duplicate player identity into the canonical player.'
  );

  INSERT INTO public.admin_audit_log (action, entity_type, entity_id, payload)
  VALUES (
    'merge_player',
    'player',
    v_source_id,
    jsonb_build_object(
      'actorDiscordId', v_actor_id,
      'source', v_source_identity,
      'target', v_target_identity,
      'counts', v_preview -> 'counts'
    )
  );

  DELETE FROM public.players WHERE id = v_source_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source player % disappeared during merge', v_source_id;
  END IF;

  RETURN jsonb_build_object(
    'code', 'merged',
    'applied', true,
    'sourcePlayerId', v_source_id,
    'targetPlayerId', v_target_id,
    'source', v_source_identity,
    'target', v_target_identity,
    'counts', v_preview -> 'counts'
  );
END;
$$;
