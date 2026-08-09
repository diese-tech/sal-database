BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(29);

SELECT ok(
  to_regprocedure('public.preview_player_merge(text,text)') IS NOT NULL
    AND to_regprocedure('public.merge_player(text,text,text)') IS NOT NULL,
  'player merge preview and apply RPCs exist'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.preview_player_merge(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.preview_player_merge(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.merge_player(text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.merge_player(text,text,text)', 'EXECUTE'),
  'client roles cannot preview or apply player merges'
);

SELECT ok(
  has_function_privilege('service_role', 'public.preview_player_merge(text,text)', 'EXECUTE')
    AND has_function_privilege('service_role', 'public.merge_player(text,text,text)', 'EXECUTE'),
  'service_role can preview and apply player merges'
);

SELECT ok(
  NOT has_function_privilege(
    'service_role',
    'private.resolve_registration_review_unhardened(text,text,text,text)',
    'EXECUTE'
  ),
  'service_role cannot bypass hardened registration approval through the preserved implementation'
);

INSERT INTO public.admin_users (discord_id, role, discord_username, display_name)
VALUES
  ('player-merge-superadmin', 'super_admin', 'player-merge-superadmin', 'Player Merge Superadmin'),
  ('player-merge-admin', 'admin', 'player-merge-admin', 'Player Merge Admin');

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, status
) VALUES (
  'player-merge-imported-registration', ' ImportedHandle ', 'Imported Registration',
  'IR', 'from-black to-white', 'Support', 'free-agent'
);

INSERT INTO public.registrations (
  id, discord_id, discord_username, avatar_url, form_data
) VALUES (
  'player-merge-registration', 'player-merge-registration-discord',
  'importedhandle', 'https://cdn.discordapp.com/avatars/123/imported.png',
  '{"ign":"Duplicate Form IGN","primary_role":"Carry"}'::jsonb
);

CREATE TEMP TABLE player_merge_registration_result AS
SELECT public.resolve_registration_review(
  'player-merge-registration', 'player-merge-admin', 'approve', NULL
) AS result;

SELECT ok(
  (SELECT result ->> 'playerId' = 'player-merge-imported-registration'
     FROM player_merge_registration_result)
  AND (SELECT count(*) = 1 FROM public.players
       WHERE lower(btrim(discord_username)) = 'importedhandle')
  AND EXISTS (
    SELECT 1 FROM public.players
    WHERE id = 'player-merge-imported-registration'
      AND ign = 'Imported Registration'
      AND primary_role = 'Support'
      AND discord_id = 'player-merge-registration-discord'
      AND profile_claimed
      AND avatar_url = 'https://cdn.discordapp.com/avatars/123/imported.png'
  ),
  'registration approval reuses one normalized active unclaimed identity without replacing imported metadata'
);

SELECT ok(
  (public.resolve_registration_review(
    'player-merge-registration', 'player-merge-admin', 'approve', NULL
  ) ->> 'code') = 'already_processed'
  AND (SELECT count(*) = 1 FROM public.players
       WHERE lower(btrim(discord_username)) = 'importedhandle')
  AND (SELECT count(*) = 1 FROM public.audit_logs
       WHERE entity_type = 'registration'
         AND entity_id = 'player-merge-registration'
         AND action_type = 'registration_approved')
  AND (SELECT count(*) = 1 FROM public.admin_audit_log
       WHERE entity_type = 'registration'
         AND entity_id = 'player-merge-registration'
         AND action = 'approve_registration'),
  'replaying a normalized identity-link approval is idempotent and creates no duplicate player or audit'
);

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, status, discord_id, profile_claimed
) VALUES (
  'player-merge-claimed-username', 'ClaimedHandle', 'Claimed Username',
  'CU', 'from-black to-white', 'Flex', 'free-agent',
  'player-merge-claimed-owner', true
);
INSERT INTO public.registrations (id, discord_id, discord_username, form_data)
VALUES (
  'player-merge-claimed-registration', 'player-merge-claimed-contender',
  ' claimedhandle ', '{"ign":"Claimed Contender","primary_role":"Flex"}'::jsonb
);

SELECT throws_ok(
  $$SELECT public.resolve_registration_review(
    'player-merge-claimed-registration', 'player-merge-admin', 'approve', NULL
  )$$,
  '23514',
  'Registration approval blocked [REGISTRATION_USERNAME_CONFLICT]: the normalized Discord username belongs to a claimed player.',
  'registration approval fails closed when the normalized username is already claimed'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.registrations
    WHERE id = 'player-merge-claimed-registration'
      AND status = 'pending'
      AND player_id IS NULL
  )
  AND EXISTS (
    SELECT 1 FROM public.players
    WHERE id = 'player-merge-claimed-username'
      AND discord_id = 'player-merge-claimed-owner'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.players
    WHERE discord_id = 'player-merge-claimed-contender'
  ),
  'a claimed-username conflict leaves registration and player identities unchanged'
);

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, status
) VALUES
  ('player-merge-ambiguous-a', 'AmbiguousHandle', 'Ambiguous A', 'AA', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-ambiguous-b', ' ambiguoushandle ', 'Ambiguous B', 'AB', 'from-black to-white', 'Flex', 'free-agent');
INSERT INTO public.registrations (id, discord_id, discord_username, form_data)
VALUES (
  'player-merge-ambiguous-registration', 'player-merge-ambiguous-discord',
  'AMBIGUOUSHANDLE', '{"ign":"Ambiguous Form","primary_role":"Flex"}'::jsonb
);

SELECT throws_ok(
  $$SELECT public.resolve_registration_review(
    'player-merge-ambiguous-registration', 'player-merge-admin', 'approve', NULL
  )$$,
  '23514',
  'Registration approval blocked [REGISTRATION_USERNAME_AMBIGUOUS]: multiple active players match the normalized Discord username.',
  'registration approval fails closed when normalized username matching is ambiguous'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.registrations
    WHERE id = 'player-merge-ambiguous-registration'
      AND status = 'pending'
      AND player_id IS NULL
  )
  AND (SELECT count(*) = 2 FROM public.players
       WHERE lower(btrim(discord_username)) = 'ambiguoushandle'),
  'a blocked registration approval leaves the registration and player catalog unchanged'
);

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES ('player-merge-season', 'Player Merge Season', 'active', '2026-08-01', '2026-09-30', false);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
) VALUES
  ('player-merge-org', 'Player Merge Org', 'PMO', 'terra', 'PM', 'from-black to-white', '#000000', 'from-black to-white'),
  ('player-merge-away', 'Player Merge Away', 'PMA', 'terra', 'PA', 'from-black to-white', '#000000', 'from-black to-white');

INSERT INTO public.season_orgs (season_id, org_id, division_id)
VALUES
  ('player-merge-season', 'player-merge-org', 'terra'),
  ('player-merge-season', 'player-merge-away', 'terra');

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, secondary_roles, is_starter, is_captain, division_id,
  status, discord_id, profile_claimed, avatar_url
) VALUES
  (
    'player-merge-source', NULL, 'MergeHandle', 'Duplicate Player', 'DP',
    'from-red-500 to-red-900', 'Carry', '[]'::jsonb, false, false, NULL,
    'free-agent', 'player-merge-discord', true,
    'https://cdn.discordapp.com/avatars/123/source.png'
  ),
  (
    'player-merge-target', 'player-merge-org', 'mergehandle', 'Canonical Player', 'CP',
    'from-cyan-500 to-blue-900', 'Support', '["Solo"]'::jsonb, true, true, 'terra',
    'org-affiliated', NULL, false, NULL
  );

UPDATE public.orgs SET captain_id = 'player-merge-source'
WHERE id = 'player-merge-org';

INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, is_captain, roster_status
) VALUES
  ('player-merge-season', 'player-merge-source', NULL, NULL, false, 'free_agent'),
  ('player-merge-season', 'player-merge-target', 'player-merge-org', 'terra', true, 'active');

INSERT INTO public.matches (
  id, season_id, division_id, home_org_id, away_org_id, scheduled_date,
  scheduled_time, status, week, winner_org_id, home_score, away_score
) VALUES (
  'player-merge-match', 'player-merge-season', 'terra', 'player-merge-org',
  'player-merge-away', '2026-08-15', '20:00', 'completed', 1,
  'player-merge-org', 2, 0
);

INSERT INTO public.match_reports (
  id, match_id, season_id, division_id, status, submitted_by
) VALUES (
  '25000000-0000-0000-0000-000000000001', 'player-merge-match',
  'player-merge-season', 'terra', 'done', 'player-merge-superadmin'
);

INSERT INTO public.pending_stat_records (
  id, match_id, player_id, screenshot_url, extracted_json, confidence, status
) VALUES (
  'player-merge-pending-stat', 'player-merge-match', 'player-merge-source',
  'https://example.test/stat.png', '{"playerId":"player-merge-source"}'::jsonb,
  1, 'approved'
);

INSERT INTO public.player_match_stats (
  match_report_id, match_id, player_id, player_ign, game_number, org_id,
  won, kills, deaths, assists, season_id, division_id
) VALUES (
  '25000000-0000-0000-0000-000000000001', 'player-merge-match',
  'player-merge-source', 'Duplicate Player', 1, 'player-merge-org',
  true, 5, 1, 8, 'player-merge-season', 'terra'
);

INSERT INTO public.player_stats (
  id, match_id, player_id, pending_stat_record_id, game_number,
  kills, deaths, assists, won, season_id, org_id, division_id
) VALUES (
  'player-merge-official-stat', 'player-merge-match', 'player-merge-source',
  'player-merge-pending-stat', 1, 5, 1, 8, true,
  'player-merge-season', 'player-merge-org', 'terra'
);
INSERT INTO public.player_stats (
  id, match_id, player_id, game_number, kills, deaths, assists, won,
  season_id, org_id, division_id
) VALUES (
  'player-merge-target-official-stat', 'player-merge-match', 'player-merge-target',
  1, 5, 1, 8, true, 'player-merge-season', 'player-merge-org', 'terra'
);

INSERT INTO public.draft_rooms (
  id, season_id, division_id, status, base_order
) VALUES (
  'player-merge-draft-room', 'player-merge-season', 'terra', 'complete',
  '["player-merge-org"]'::jsonb
);
INSERT INTO public.draft_picks (draft_room_id, pick_number, org_id, player_id)
VALUES ('player-merge-draft-room', 1, 'player-merge-org', 'player-merge-source');
INSERT INTO public.captain_shortlists (draft_room_id, org_id, player_id, position)
VALUES ('player-merge-draft-room', 'player-merge-org', 'player-merge-source', 1);
INSERT INTO public.captain_shortlists (draft_room_id, org_id, player_id, position)
VALUES ('player-merge-draft-room', 'player-merge-org', 'player-merge-target', 1);

INSERT INTO public.registrations (
  id, discord_id, discord_username, player_id, form_data, status
) VALUES (
  'player-merge-source-registration', 'player-merge-discord', 'MergeHandle',
  'player-merge-source', '{"ign":"Duplicate Player"}'::jsonb, 'approved'
);

INSERT INTO public.scouter_matches (id, season_id, hosted_by_discord_id)
VALUES ('player-merge-scouter-match', 'player-merge-season', 'player-merge-superadmin');
INSERT INTO public.scouter_games (
  id, scouter_match_id, game_ordinal, winning_side,
  scoreboard_image_path, details_image_path
) VALUES (
  'player-merge-scouter-game', 'player-merge-scouter-match', 1, 'order',
  'player-merge-score.png', 'player-merge-details.png'
);
INSERT INTO public.scouter_game_participants (
  id, scouter_game_id, side, raw_ign, player_id
) VALUES (
  'player-merge-participant', 'player-merge-scouter-game', 'order',
  'Duplicate Player', 'player-merge-source'
);

INSERT INTO public.audit_logs (
  action_type, entity_type, entity_id, actor_discord_id, new_value_json
) VALUES (
  'historical_player_event', 'player', 'player-merge-source',
  'player-merge-superadmin', '{"playerId":"player-merge-source"}'::jsonb
);
INSERT INTO public.admin_audit_log (action, entity_type, entity_id, payload)
VALUES (
  'historical_player_event', 'player', 'player-merge-source',
  '{"playerId":"player-merge-source"}'::jsonb
);
INSERT INTO public.operation_outbox (
  topic, aggregate_type, aggregate_id, event_type, deduplication_key, payload
) VALUES (
  'historical', 'player', 'player-merge-source', 'historical_player_event',
  'player-merge-source-evidence', '{"playerId":"player-merge-source"}'::jsonb
);
INSERT INTO public.scouter_game_corrections (
  id, scouter_game_id, correction_key, actor_discord_id, reason,
  expected_revision, resulting_revision, request_json, old_value_json, new_value_json
) VALUES (
  'player-merge-correction', 'player-merge-scouter-game', 'player-merge-correction-key',
  'player-merge-superadmin', 'Historical fixture', 1, 2,
  '{"playerId":"player-merge-source"}'::jsonb,
  '{"playerId":"player-merge-source"}'::jsonb,
  '{"playerId":"player-merge-source"}'::jsonb
);

CREATE TEMP TABLE player_merge_preview AS
SELECT public.preview_player_merge('player-merge-source', 'player-merge-target') AS result;

SELECT ok(
  (SELECT (result ->> 'canMerge')::boolean FROM player_merge_preview)
  AND (SELECT result -> 'blockers' = '[]'::jsonb FROM player_merge_preview)
  AND (SELECT result -> 'blockerCodes' = '[]'::jsonb FROM player_merge_preview)
  AND (SELECT result #>> '{source,ign}' = 'Duplicate Player' FROM player_merge_preview)
  AND (SELECT result #>> '{target,ign}' = 'Canonical Player' FROM player_merge_preview)
  AND (SELECT (result #>> '{counts,seasonRosters}')::integer = 1 FROM player_merge_preview)
  AND (SELECT (result #>> '{counts,scouterParticipants}')::integer = 1 FROM player_merge_preview)
  AND (SELECT (result #>> '{counts,immutableOutboxEvents}')::integer = 1 FROM player_merge_preview),
  'preview returns safe identities, affected counts, immutable evidence counts, and no blockers'
);

SELECT throws_ok(
  $$SELECT public.merge_player(
    'player-merge-source', 'player-merge-target', 'player-merge-admin'
  )$$,
  '42501',
  'Only a SAL superadmin can merge players.',
  'only a superadmin can apply a player merge'
);

CREATE TEMP TABLE player_merge_result AS
SELECT public.merge_player(
  'player-merge-source', 'player-merge-target', 'player-merge-superadmin'
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'merged'
      AND (result ->> 'applied')::boolean
      AND result ->> 'sourcePlayerId' = 'player-merge-source'
      AND result ->> 'targetPlayerId' = 'player-merge-target'
    FROM player_merge_result),
  'a valid merge applies once and returns the stable result contract'
);

SELECT ok(
  NOT EXISTS (SELECT 1 FROM public.players WHERE id = 'player-merge-source')
  AND EXISTS (
    SELECT 1 FROM public.players
    WHERE id = 'player-merge-target'
      AND ign = 'Canonical Player'
      AND org_id = 'player-merge-org'
      AND division_id = 'terra'
      AND primary_role = 'Support'
      AND secondary_roles = '["Solo"]'::jsonb
      AND is_starter
      AND is_captain
      AND status = 'org-affiliated'
      AND discord_id = 'player-merge-discord'
      AND discord_username = 'MergeHandle'
      AND profile_claimed
      AND avatar_url = 'https://cdn.discordapp.com/avatars/123/source.png'
  ),
  'the target keeps competitive metadata and receives missing Discord linkage and avatar data'
);

SELECT ok(
  (SELECT count(*) = 1 FROM public.season_rosters
    WHERE season_id = 'player-merge-season'
      AND player_id = 'player-merge-target'
      AND org_id = 'player-merge-org'
      AND division_id = 'terra'
      AND is_captain
      AND roster_status = 'active')
  AND (SELECT captain_id = 'player-merge-target' FROM public.orgs WHERE id = 'player-merge-org')
  AND (SELECT player_id = 'player-merge-target' FROM public.pending_stat_records WHERE id = 'player-merge-pending-stat')
  AND (SELECT player_id = 'player-merge-target' FROM public.player_match_stats WHERE player_ign = 'Duplicate Player')
  AND NOT EXISTS (SELECT 1 FROM public.player_stats WHERE id = 'player-merge-official-stat')
  AND EXISTS (SELECT 1 FROM public.player_stats
    WHERE id = 'player-merge-target-official-stat'
      AND player_id = 'player-merge-target'
      AND pending_stat_record_id = 'player-merge-pending-stat'
      AND kills = 5 AND deaths = 1 AND assists = 8)
  AND (SELECT player_id = 'player-merge-target' FROM public.registrations WHERE id = 'player-merge-source-registration')
  AND (SELECT player_id = 'player-merge-target' FROM public.scouter_game_participants WHERE id = 'player-merge-participant')
  AND (SELECT player_id = 'player-merge-target' FROM public.draft_picks WHERE draft_room_id = 'player-merge-draft-room')
  AND (SELECT player_id = 'player-merge-target' FROM public.captain_shortlists WHERE draft_room_id = 'player-merge-draft-room'),
  'every typed player reference transfers and compatible season rows coalesce under the target'
);

SELECT ok(
  EXISTS (SELECT 1 FROM public.audit_logs
    WHERE action_type = 'historical_player_event' AND entity_id = 'player-merge-source')
  AND EXISTS (SELECT 1 FROM public.admin_audit_log
    WHERE action = 'historical_player_event' AND entity_id = 'player-merge-source')
  AND EXISTS (SELECT 1 FROM public.operation_outbox
    WHERE deduplication_key = 'player-merge-source-evidence'
      AND aggregate_id = 'player-merge-source')
  AND EXISTS (SELECT 1 FROM public.scouter_game_corrections
    WHERE id = 'player-merge-correction'
      AND request_json ->> 'playerId' = 'player-merge-source')
  AND EXISTS (SELECT 1 FROM public.audit_logs
    WHERE action_type = 'player_merged'
      AND entity_id = 'player-merge-source'
      AND actor_discord_id = 'player-merge-superadmin'
      AND new_value_json ->> 'targetPlayerId' = 'player-merge-target')
  AND EXISTS (SELECT 1 FROM public.admin_audit_log
    WHERE action = 'merge_player'
      AND entity_id = 'player-merge-source'
      AND payload ->> 'actorDiscordId' = 'player-merge-superadmin'),
  'immutable evidence remains unchanged and both audit systems record the acting superadmin'
);

SELECT ok(
  (public.merge_player(
    'player-merge-source', 'player-merge-target', 'player-merge-superadmin'
  ) ->> 'code') = 'already_merged'
  AND (SELECT count(*) = 1 FROM public.audit_logs
       WHERE action_type = 'player_merged' AND entity_id = 'player-merge-source')
  AND (SELECT count(*) = 1 FROM public.admin_audit_log
       WHERE action = 'merge_player' AND entity_id = 'player-merge-source'),
  'a retry after a committed merge returns already_merged without duplicating evidence'
);

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, is_starter, division_id, status, discord_id, profile_claimed
) VALUES
  (
    'player-merge-reverse-source', NULL, 'ReverseHandle', 'Imported Reverse',
    'IR', 'from-black to-white', 'Solo', false, NULL, 'free-agent', NULL, false
  ),
  (
    'player-merge-reverse-target', 'player-merge-org', 'reversehandle', 'Signed Competitive',
    'SC', 'from-black to-white', 'Jungle', true, 'terra', 'org-affiliated',
    'player-merge-reverse-discord', true
  );

CREATE TEMP TABLE player_merge_reverse_result AS
SELECT public.merge_player(
  'player-merge-reverse-source', 'player-merge-reverse-target', 'player-merge-superadmin'
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'merged' FROM player_merge_reverse_result)
  AND NOT EXISTS (SELECT 1 FROM public.players WHERE id = 'player-merge-reverse-source')
  AND EXISTS (
    SELECT 1 FROM public.players
    WHERE id = 'player-merge-reverse-target'
      AND ign = 'Signed Competitive'
      AND primary_role = 'Jungle'
      AND is_starter
      AND org_id = 'player-merge-org'
      AND discord_id = 'player-merge-reverse-discord'
      AND discord_username = 'reversehandle'
  ),
  'merge supports the reverse direction when the signed-in competitive player is canonical'
);

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, status, discord_id, profile_claimed
) VALUES
  ('player-merge-block-source', 'block-source', 'Block Source', 'BS', 'from-black to-white', 'Flex', 'free-agent', 'block-source-discord', true),
  ('player-merge-block-target', 'block-target', 'Block Target', 'BT', 'from-black to-white', 'Flex', 'free-agent', 'block-target-discord', true);

SELECT ok(
  NOT (public.preview_player_merge(
    'player-merge-block-source', 'player-merge-block-target'
  ) ->> 'canMerge')::boolean
  AND public.preview_player_merge(
    'player-merge-block-source', 'player-merge-block-target'
  ) -> 'blockerCodes' ? 'DISCORD_ID_CONFLICT',
  'preview exposes a stable blocker code when the players belong to different Discord identities'
);

SELECT throws_ok(
  $$SELECT public.merge_player(
    'player-merge-block-source', 'player-merge-block-target', 'player-merge-superadmin'
  )$$,
  '23514',
  'Player merge blocked [DISCORD_ID_CONFLICT]: Source and target are linked to different Discord identities.',
  'apply rechecks blockers and rejects an ambiguous identity merge'
);

SELECT ok(
  EXISTS (SELECT 1 FROM public.players WHERE id = 'player-merge-block-source' AND discord_id = 'block-source-discord')
  AND EXISTS (SELECT 1 FROM public.players WHERE id = 'player-merge-block-target' AND discord_id = 'block-target-discord')
  AND NOT EXISTS (SELECT 1 FROM public.audit_logs
    WHERE action_type = 'player_merged' AND entity_id = 'player-merge-block-source'),
  'a blocked merge rolls back completely'
);

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient, primary_role, status
) VALUES
  ('player-merge-json-source', 'json-source', 'JSON Source', 'JS', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-json-target', 'json-target', 'JSON Target', 'JT', 'from-black to-white', 'Flex', 'free-agent');
INSERT INTO public.pending_actions (
  id, type, status, requested_by_discord_id, payload_json
) VALUES (
  'player-merge-json-action', 'admin_review', 'pending', 'player-merge-superadmin',
  '{"playerId":"player-merge-json-source"}'::jsonb
);

SELECT ok(
  public.preview_player_merge(
    'player-merge-json-source', 'player-merge-json-target'
  ) -> 'blockerCodes' ? 'UNRESOLVED_JSON_REFERENCE',
  'unresolved JSON-backed workflows fail closed instead of retaining a live source reference'
);

-- Isolated fixtures exercise every practical blocker without allowing one
-- conflict category to mask another.
INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient, primary_role, status
) VALUES
  ('player-merge-unavailable-source', 'unavailable-source', 'Unavailable Source', 'US', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-unavailable-source-target', 'unavailable-source-target', 'Unavailable Source Target', 'UT', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-unavailable-target-source', 'unavailable-target-source', 'Unavailable Target Source', 'TS', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-unavailable-target', 'unavailable-target', 'Unavailable Target', 'UT', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-registration-source', 'registration-source', 'Registration Source', 'RS', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-registration-target', 'registration-target', 'Registration Target', 'RT', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-roster-source', 'roster-source', 'Roster Source', 'RS', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-roster-target', 'roster-target', 'Roster Target', 'RT', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-captain-source', 'captain-source', 'Captain Source', 'CS', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-captain-target', 'captain-target', 'Captain Target', 'CT', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-draft-source', 'draft-source', 'Draft Source', 'DS', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-draft-target', 'draft-target', 'Draft Target', 'DT', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-shortlist-source', 'shortlist-source', 'Shortlist Source', 'SS', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-shortlist-target', 'shortlist-target', 'Shortlist Target', 'ST', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-pms-source', 'pms-source', 'PMS Source', 'PS', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-pms-target', 'pms-target', 'PMS Target', 'PT', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-ps-source', 'ps-source', 'PS Source', 'PS', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-ps-target', 'ps-target', 'PS Target', 'PT', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-scouter-source', 'scouter-source', 'Scouter Source', 'SS', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-scouter-target', 'scouter-target', 'Scouter Target', 'ST', 'from-black to-white', 'Flex', 'free-agent');

UPDATE public.players SET archived_at = now()
WHERE id = 'player-merge-unavailable-source';
UPDATE public.players SET deletion_scheduled_at = now()
WHERE id = 'player-merge-unavailable-target';

INSERT INTO public.registrations (
  id, discord_id, discord_username, player_id, form_data, status
) VALUES
  ('player-merge-registration-source-link', 'registration-source-discord', 'registration-source', 'player-merge-registration-source', '{}'::jsonb, 'approved'),
  ('player-merge-registration-target-link', 'registration-target-discord', 'registration-target', 'player-merge-registration-target', '{}'::jsonb, 'approved');

INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, is_captain, roster_status
) VALUES
  ('player-merge-season', 'player-merge-roster-source', 'player-merge-away', 'terra', false, 'active'),
  ('player-merge-season', 'player-merge-roster-target', 'player-merge-org', 'terra', false, 'active');

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient,
  primary_color, accent_gradient, captain_id
) VALUES
  ('player-merge-captain-source-org', 'Captain Source Org', 'CSO', 'terra', 'CS', 'from-black to-white', '#000000', 'from-black to-white', 'player-merge-captain-source'),
  ('player-merge-captain-target-org', 'Captain Target Org', 'CTO', 'terra', 'CT', 'from-black to-white', '#000000', 'from-black to-white', 'player-merge-captain-target');

INSERT INTO public.draft_rooms (id, season_id, division_id, status, base_order)
VALUES
  ('player-merge-block-draft-room', 'player-merge-season', 'terra', 'complete', '["player-merge-org"]'::jsonb),
  ('player-merge-block-shortlist-room', 'player-merge-season', 'terra', 'complete', '["player-merge-org"]'::jsonb);
INSERT INTO public.draft_picks (draft_room_id, pick_number, org_id, player_id)
VALUES
  ('player-merge-block-draft-room', 1, 'player-merge-org', 'player-merge-draft-source'),
  ('player-merge-block-draft-room', 2, 'player-merge-org', 'player-merge-draft-target');
INSERT INTO public.captain_shortlists (draft_room_id, org_id, player_id, position)
VALUES
  ('player-merge-block-shortlist-room', 'player-merge-org', 'player-merge-shortlist-source', 1),
  ('player-merge-block-shortlist-room', 'player-merge-org', 'player-merge-shortlist-target', 2);

INSERT INTO public.player_match_stats (
  match_report_id, match_id, player_id, player_ign, game_number, org_id,
  won, season_id, division_id
) VALUES
  ('25000000-0000-0000-0000-000000000001', 'player-merge-match', 'player-merge-pms-source', 'PMS Source', 2, 'player-merge-org', true, 'player-merge-season', 'terra'),
  ('25000000-0000-0000-0000-000000000001', 'player-merge-match', 'player-merge-pms-target', 'PMS Target', 2, 'player-merge-org', true, 'player-merge-season', 'terra');

INSERT INTO public.player_stats (
  id, match_id, player_id, game_number, kills, deaths, assists, won,
  season_id, org_id, division_id
) VALUES
  ('player-merge-block-ps-source', 'player-merge-match', 'player-merge-ps-source', 3, 5, 1, 8, true, 'player-merge-season', 'player-merge-org', 'terra'),
  ('player-merge-block-ps-target', 'player-merge-match', 'player-merge-ps-target', 3, 4, 1, 8, true, 'player-merge-season', 'player-merge-org', 'terra');

INSERT INTO public.scouter_game_participants (
  id, scouter_game_id, side, raw_ign, player_id
) VALUES
  ('player-merge-block-scouter-source', 'player-merge-scouter-game', 'order', 'Scouter Source', 'player-merge-scouter-source'),
  ('player-merge-block-scouter-target', 'player-merge-scouter-game', 'chaos', 'Scouter Target', 'player-merge-scouter-target');

CREATE TEMP TABLE player_merge_blocker_cases (
  source_player_id text NOT NULL,
  target_player_id text NOT NULL,
  blocker_code text PRIMARY KEY
);
INSERT INTO player_merge_blocker_cases VALUES
  ('player-merge-block-source', 'player-merge-block-source', 'SELF_MERGE'),
  ('player-merge-does-not-exist', 'player-merge-block-target', 'SOURCE_NOT_FOUND'),
  ('player-merge-block-source', 'player-merge-target-does-not-exist', 'TARGET_NOT_FOUND'),
  ('player-merge-unavailable-source', 'player-merge-unavailable-source-target', 'SOURCE_UNAVAILABLE'),
  ('player-merge-unavailable-target-source', 'player-merge-unavailable-target', 'TARGET_UNAVAILABLE'),
  ('player-merge-block-source', 'player-merge-block-target', 'DISCORD_ID_CONFLICT'),
  ('player-merge-registration-source', 'player-merge-registration-target', 'REGISTRATION_DISCORD_CONFLICT'),
  ('player-merge-roster-source', 'player-merge-roster-target', 'SEASON_ROSTER_CONFLICT'),
  ('player-merge-captain-source', 'player-merge-captain-target', 'ORGANIZATION_CAPTAIN_CONFLICT'),
  ('player-merge-draft-source', 'player-merge-draft-target', 'DRAFT_PICK_CONFLICT'),
  ('player-merge-shortlist-source', 'player-merge-shortlist-target', 'DRAFT_SHORTLIST_CONFLICT'),
  ('player-merge-pms-source', 'player-merge-pms-target', 'PLAYER_MATCH_STATS_CONFLICT'),
  ('player-merge-ps-source', 'player-merge-ps-target', 'PLAYER_STATS_CONFLICT'),
  ('player-merge-scouter-source', 'player-merge-scouter-target', 'SCOUTER_PARTICIPANT_CONFLICT'),
  ('player-merge-json-source', 'player-merge-json-target', 'UNRESOLVED_JSON_REFERENCE');

SELECT ok(
  (SELECT count(*) = 15 FROM player_merge_blocker_cases)
  AND NOT EXISTS (
    SELECT 1
    FROM player_merge_blocker_cases AS cases
    CROSS JOIN LATERAL public.preview_player_merge(
      cases.source_player_id, cases.target_player_id
    ) AS preview(result)
    WHERE (preview.result ->> 'canMerge')::boolean
      OR NOT (preview.result -> 'blockerCodes' ? cases.blocker_code)
  ),
  'every practical blocker fixture previews with its stable blocker code'
);

CREATE TEMP TABLE player_merge_blocker_identity_snapshot AS
SELECT players.id, to_jsonb(players) AS row_json
FROM public.players
WHERE players.id IN (
  SELECT source_player_id FROM player_merge_blocker_cases
  UNION
  SELECT target_player_id FROM player_merge_blocker_cases
);

CREATE TEMP TABLE player_merge_blocker_apply_results (
  blocker_code text PRIMARY KEY,
  returned_sqlstate text NOT NULL,
  returned_message text NOT NULL
);

DO $blocker_apply$
DECLARE
  v_case record;
  v_sqlstate text;
  v_message text;
BEGIN
  FOR v_case IN
    SELECT * FROM player_merge_blocker_cases ORDER BY blocker_code
  LOOP
    BEGIN
      PERFORM public.merge_player(
        v_case.source_player_id,
        v_case.target_player_id,
        'player-merge-superadmin'
      );
      INSERT INTO player_merge_blocker_apply_results
      VALUES (v_case.blocker_code, '00000', 'merge unexpectedly succeeded');
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS
        v_sqlstate = RETURNED_SQLSTATE,
        v_message = MESSAGE_TEXT;
      INSERT INTO player_merge_blocker_apply_results
      VALUES (v_case.blocker_code, v_sqlstate, v_message);
    END;
  END LOOP;
END
$blocker_apply$;

SELECT ok(
  (SELECT count(*) = 15 FROM player_merge_blocker_apply_results)
  AND NOT EXISTS (
    SELECT 1 FROM player_merge_blocker_apply_results
    WHERE returned_sqlstate <> '23514'
      OR returned_message NOT LIKE '%[' || blocker_code || '%'
  ),
  'apply rechecks every practical blocker and returns SQLSTATE 23514 with the stable code'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM player_merge_blocker_identity_snapshot AS snapshot
    LEFT JOIN public.players AS players ON players.id = snapshot.id
    WHERE players.id IS NULL OR to_jsonb(players) IS DISTINCT FROM snapshot.row_json
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.audit_logs AS audits
    JOIN player_merge_blocker_cases AS cases
      ON cases.source_player_id = audits.entity_id
    WHERE audits.action_type = 'player_merged'
  ),
  'all blocker failures preserve every existing player row and create no merge audit'
);

SELECT ok(
  EXISTS (SELECT 1 FROM public.registrations WHERE id = 'player-merge-registration-source-link' AND player_id = 'player-merge-registration-source')
  AND EXISTS (SELECT 1 FROM public.registrations WHERE id = 'player-merge-registration-target-link' AND player_id = 'player-merge-registration-target')
  AND EXISTS (SELECT 1 FROM public.season_rosters WHERE player_id = 'player-merge-roster-source' AND org_id = 'player-merge-away')
  AND EXISTS (SELECT 1 FROM public.season_rosters WHERE player_id = 'player-merge-roster-target' AND org_id = 'player-merge-org')
  AND EXISTS (SELECT 1 FROM public.orgs WHERE id = 'player-merge-captain-source-org' AND captain_id = 'player-merge-captain-source')
  AND EXISTS (SELECT 1 FROM public.orgs WHERE id = 'player-merge-captain-target-org' AND captain_id = 'player-merge-captain-target')
  AND (SELECT count(*) = 2 FROM public.draft_picks WHERE draft_room_id = 'player-merge-block-draft-room')
  AND (SELECT count(*) = 2 FROM public.captain_shortlists WHERE draft_room_id = 'player-merge-block-shortlist-room')
  AND (SELECT count(*) = 2 FROM public.player_match_stats WHERE player_id IN ('player-merge-pms-source', 'player-merge-pms-target'))
  AND (SELECT count(*) = 2 FROM public.player_stats WHERE player_id IN ('player-merge-ps-source', 'player-merge-ps-target'))
  AND (SELECT count(*) = 2 FROM public.scouter_game_participants WHERE player_id IN ('player-merge-scouter-source', 'player-merge-scouter-target'))
  AND EXISTS (SELECT 1 FROM public.pending_actions WHERE id = 'player-merge-json-action' AND payload_json ->> 'playerId' = 'player-merge-json-source'),
  'all blocker failures roll back registrations, rosters, competitive history, scouter links, and pending JSON'
);

-- Install a temporary future FK only after every known-reference case. The
-- preview's schema allow-list must reject it without depending on DELETE failure.
INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient, primary_role, status
) VALUES
  ('player-merge-future-source', 'future-source', 'Future Source', 'FS', 'from-black to-white', 'Flex', 'free-agent'),
  ('player-merge-future-target', 'future-target', 'Future Target', 'FT', 'from-black to-white', 'Flex', 'free-agent');
CREATE TABLE public.player_merge_future_reference (
  id text PRIMARY KEY,
  player_id text NOT NULL,
  CONSTRAINT future_player_reference_player_id_fkey
    FOREIGN KEY (player_id) REFERENCES public.players(id)
);
INSERT INTO player_merge_future_reference VALUES
  ('future-reference', 'player-merge-future-source');

SELECT ok(
  NOT (public.preview_player_merge(
    'player-merge-future-source', 'player-merge-future-target'
  ) ->> 'canMerge')::boolean
  AND public.preview_player_merge(
    'player-merge-future-source', 'player-merge-future-target'
  ) -> 'blockerCodes' ? 'UNSUPPORTED_PLAYER_REFERENCE',
  'an unknown future player foreign key fails closed during preview'
);

CREATE TEMP TABLE player_merge_future_apply_result (
  returned_sqlstate text,
  returned_message text
);
DO $future_apply$
DECLARE
  v_sqlstate text;
  v_message text;
BEGIN
  BEGIN
    PERFORM public.merge_player(
      'player-merge-future-source',
      'player-merge-future-target',
      'player-merge-superadmin'
    );
    INSERT INTO player_merge_future_apply_result
    VALUES ('00000', 'merge unexpectedly succeeded');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS
      v_sqlstate = RETURNED_SQLSTATE,
      v_message = MESSAGE_TEXT;
    INSERT INTO player_merge_future_apply_result
    VALUES (v_sqlstate, v_message);
  END;
END
$future_apply$;

SELECT ok(
  EXISTS (
    SELECT 1 FROM player_merge_future_apply_result
    WHERE returned_sqlstate = '23514'
      AND returned_message LIKE '%[UNSUPPORTED_PLAYER_REFERENCE%'
  ),
  'apply rejects an unknown future player foreign key with its stable blocker code'
);

SELECT ok(
  EXISTS (SELECT 1 FROM public.players WHERE id = 'player-merge-future-source')
  AND EXISTS (SELECT 1 FROM public.players WHERE id = 'player-merge-future-target')
  AND EXISTS (SELECT 1 FROM player_merge_future_reference
              WHERE player_id = 'player-merge-future-source')
  AND NOT EXISTS (SELECT 1 FROM public.audit_logs
    WHERE action_type = 'player_merged' AND entity_id = 'player-merge-future-source'),
  'unsupported-reference failure preserves both identities and the future typed reference'
);

SELECT * FROM finish();
ROLLBACK;
