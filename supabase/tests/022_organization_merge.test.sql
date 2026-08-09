BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(20);

SELECT ok(
  to_regprocedure('public.preview_organization_merge(text,text)') IS NOT NULL
    AND to_regprocedure('public.merge_organization(text,text,text)') IS NOT NULL,
  'organization merge preview and apply RPCs exist'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.preview_organization_merge(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.preview_organization_merge(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.merge_organization(text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.merge_organization(text,text,text)', 'EXECUTE'),
  'client roles cannot preview or apply organization merges'
);

SELECT ok(
  has_function_privilege('service_role', 'public.preview_organization_merge(text,text)', 'EXECUTE')
    AND has_function_privilege('service_role', 'public.merge_organization(text,text,text)', 'EXECUTE'),
  'service_role can preview and apply organization merges'
);

INSERT INTO public.admin_users (discord_id, role, discord_username, display_name)
VALUES
  ('org-merge-superadmin', 'super_admin', 'org-merge-superadmin', 'Org Merge Superadmin'),
  ('org-merge-admin', 'admin', 'org-merge-admin', 'Org Merge Admin');

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES ('org-merge-season', 'Organization Merge Season', 'active', '2026-08-01', '2026-09-30', false);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
) VALUES
  ('org-merge-source', 'Duplicate Grizzlies', 'DGRR', 'terra', 'DG', 'from-red-500 to-red-900', '#ff0000', 'from-red-500 to-red-900'),
  ('org-merge-target', 'Grizzlies', 'GRR', 'solar', 'GRR', 'from-cyan-500 to-blue-900', '#00ffff', 'from-cyan-500 to-blue-900'),
  ('org-merge-away', 'Merge Opponent', 'AWAY', 'terra', 'AW', 'from-black to-white', '#000000', 'from-black to-white');

SELECT ok(
  NOT (public.preview_organization_merge(
    'org-merge-source', 'org-merge-source'
  ) ->> 'canMerge')::boolean,
  'an organization cannot be merged into itself'
);

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status, is_captain
) VALUES (
  'org-merge-player', 'org-merge-source', 'org-merge-player', 'Merge Player', 'MP',
  'from-black to-white', 'Support', 'terra', 'org-affiliated', true
);

INSERT INTO public.season_orgs (season_id, org_id, division_id, status) VALUES
  ('org-merge-season', 'org-merge-source', 'terra', 'active'),
  ('org-merge-season', 'org-merge-target', 'solar', 'active'),
  ('org-merge-season', 'org-merge-target', 'lunar', 'active'),
  ('org-merge-season', 'org-merge-away', 'terra', 'active');

INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, is_captain, roster_status
) VALUES (
  'org-merge-season', 'org-merge-player', 'org-merge-source', 'terra', true, 'active'
);

INSERT INTO public.matches (
  id, season_id, division_id, home_org_id, away_org_id, scheduled_date,
  scheduled_time, status, week, winner_org_id, home_score, away_score
) VALUES (
  'org-merge-match', 'org-merge-season', 'terra', 'org-merge-source',
  'org-merge-away', '2026-08-15', '20:00', 'completed', 1,
  'org-merge-source', 2, 0
);

INSERT INTO public.match_reports (
  id, match_id, season_id, division_id, status, submitted_by
) VALUES (
  '10000000-0000-0000-0000-000000000001', 'org-merge-match',
  'org-merge-season', 'terra', 'done', 'org-merge-superadmin'
);

INSERT INTO public.player_match_stats (
  match_report_id, match_id, player_id, player_ign, game_number, org_id,
  won, season_id, division_id
) VALUES (
  '10000000-0000-0000-0000-000000000001', 'org-merge-match',
  'org-merge-player', 'Merge Player', 1, 'org-merge-source', true,
  'org-merge-season', 'terra'
);

INSERT INTO public.player_stats (
  id, match_id, player_id, kills, deaths, assists, game_number, won,
  season_id, org_id, division_id
) VALUES (
  'org-merge-player-stat', 'org-merge-match', 'org-merge-player', 1, 0, 2, 1,
  true, 'org-merge-season', 'org-merge-source', 'terra'
);

INSERT INTO public.draft_rooms (
  id, season_id, division_id, status, base_order
) VALUES (
  'org-merge-draft', 'org-merge-season', 'terra', 'complete',
  '["org-merge-source", "org-merge-away"]'::jsonb
);

INSERT INTO public.draft_picks (draft_room_id, pick_number, org_id, player_id)
VALUES ('org-merge-draft', 1, 'org-merge-source', 'org-merge-player');

INSERT INTO public.captain_shortlists (draft_room_id, org_id, player_id, position)
VALUES ('org-merge-draft', 'org-merge-source', 'org-merge-player', 1);

INSERT INTO public.captain_tokens (id, draft_room_id, org_id, token_hash, expires_at)
VALUES ('org-merge-token', 'org-merge-draft', 'org-merge-source', 'hash', now() + interval '1 hour');

INSERT INTO public.god_draft_sessions (id, match_id, game_number, status)
VALUES ('org-merge-god-session', 'org-merge-match', 1, 'complete');

INSERT INTO public.god_picks (session_id, match_id, game_number, org_id, god_id, god_name, slot)
VALUES ('org-merge-god-session', 'org-merge-match', 1, 'org-merge-source', 'achilles', 'Achilles', 1);

INSERT INTO public.god_bans (session_id, match_id, game_number, org_id, god_id, god_name, slot)
VALUES ('org-merge-god-session', 'org-merge-match', 1, 'org-merge-source', 'agni', 'Agni', 1);

INSERT INTO public.standings (org_id, division_id, wins, matches_played)
VALUES ('org-merge-source', 'terra', 1, 1);

CREATE TEMP TABLE org_merge_preview AS
SELECT public.preview_organization_merge('org-merge-source', 'org-merge-target') AS result;

SELECT ok(
  (SELECT (result ->> 'canMerge')::boolean AND jsonb_array_length(result -> 'blockers') = 0
   FROM org_merge_preview),
  'preview permits an unambiguous all-history merge'
);

SELECT is(
  (SELECT (result -> 'counts' ->> 'seasonTeams')::integer FROM org_merge_preview),
  1,
  'preview reports source season-team references'
);

SELECT is(
  (SELECT (result -> 'counts' ->> 'matches')::integer FROM org_merge_preview),
  1,
  'preview reports source match references'
);

SELECT throws_ok(
  $$SELECT public.merge_organization('org-merge-source', 'org-merge-target', 'org-merge-admin')$$,
  '42501',
  'Only a SAL superadmin can merge organizations.',
  'ordinary admins cannot apply a merge'
);

CREATE TEMP TABLE org_merge_result AS
SELECT public.merge_organization(
  'org-merge-source', 'org-merge-target', 'org-merge-superadmin'
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'merged' AND (result ->> 'applied')::boolean FROM org_merge_result),
  'superadmin applies the merge atomically'
);

SELECT ok(
  NOT EXISTS (SELECT 1 FROM public.orgs WHERE id = 'org-merge-source')
    AND EXISTS (
      SELECT 1 FROM public.orgs
      WHERE id = 'org-merge-target' AND name = 'Grizzlies' AND tag = 'GRR'
    ),
  'duplicate identity is deleted while canonical metadata wins'
);

SELECT is(
  (SELECT count(*)::integer FROM public.season_orgs
   WHERE season_id = 'org-merge-season' AND org_id = 'org-merge-target'),
  3,
  'canonical organization owns all three divisional season teams'
);

SELECT ok(
  (SELECT org_id = 'org-merge-target' FROM public.season_rosters
   WHERE season_id = 'org-merge-season' AND player_id = 'org-merge-player')
    AND (SELECT org_id = 'org-merge-target' FROM public.players WHERE id = 'org-merge-player'),
  'season roster and legacy player mirror move to the canonical organization'
);

SELECT ok(
  (SELECT home_org_id = 'org-merge-target' AND winner_org_id = 'org-merge-target'
   FROM public.matches WHERE id = 'org-merge-match')
    AND (SELECT org_id = 'org-merge-target' FROM public.player_match_stats
         WHERE match_report_id = '10000000-0000-0000-0000-000000000001')
    AND (SELECT org_id = 'org-merge-target' FROM public.player_stats
         WHERE id = 'org-merge-player-stat'),
  'match and official-stat history move to the canonical organization'
);

SELECT ok(
  (SELECT org_id = 'org-merge-target' FROM public.draft_picks
   WHERE draft_room_id = 'org-merge-draft' AND pick_number = 1)
    AND (SELECT org_id = 'org-merge-target' FROM public.captain_shortlists
         WHERE draft_room_id = 'org-merge-draft')
    AND (SELECT org_id = 'org-merge-target' FROM public.captain_tokens
         WHERE id = 'org-merge-token')
    AND (SELECT base_order = '["org-merge-target", "org-merge-away"]'::jsonb
         FROM public.draft_rooms WHERE id = 'org-merge-draft'),
  'draft picks, access state, shortlists, and base order are rewritten'
);

SELECT ok(
  (SELECT org_id = 'org-merge-target' FROM public.god_picks
   WHERE session_id = 'org-merge-god-session')
    AND (SELECT org_id = 'org-merge-target' FROM public.god_bans
         WHERE session_id = 'org-merge-god-session'),
  'god-draft history moves to the canonical organization'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE action_type = 'organization_merged'
      AND entity_id = 'org-merge-source'
      AND actor_discord_id = 'org-merge-superadmin'
      AND old_value_json ->> 'name' = 'Duplicate Grizzlies'
      AND new_value_json ->> 'targetOrganizationId' = 'org-merge-target'
  )
    AND EXISTS (
      SELECT 1 FROM public.admin_audit_log
      WHERE action = 'merge_organization' AND entity_id = 'org-merge-source'
    ),
  'merge appends immutable and admin audit evidence'
);

SELECT is(
  public.merge_organization(
    'org-merge-source', 'org-merge-target', 'org-merge-superadmin'
  ) ->> 'code',
  'already_merged',
  'an exact retry is idempotent after the source was deleted'
);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
) VALUES
  ('org-merge-blocked-source', 'Blocked Source', 'BLS', 'terra', 'BS', 'from-black to-white', '#000000', 'from-black to-white'),
  ('org-merge-blocked-target', 'Blocked Target', 'BLT', 'terra', 'BT', 'from-black to-white', '#000000', 'from-black to-white');

INSERT INTO public.season_orgs (season_id, org_id, division_id) VALUES
  ('org-merge-season', 'org-merge-blocked-source', 'terra'),
  ('org-merge-season', 'org-merge-blocked-target', 'terra');

INSERT INTO public.matches (
  id, season_id, division_id, home_org_id, away_org_id, scheduled_date,
  scheduled_time, status, week
) VALUES (
  'org-merge-self-match', 'org-merge-season', 'terra', 'org-merge-blocked-source',
  'org-merge-blocked-target', '2026-08-22', '20:00', 'scheduled', 2
);

SELECT ok(
  NOT (public.preview_organization_merge(
    'org-merge-blocked-source', 'org-merge-blocked-target'
  ) ->> 'canMerge')::boolean,
  'preview blocks a merge that would create a self-match'
);

SELECT throws_ok(
  $$SELECT public.merge_organization('org-merge-blocked-source', 'org-merge-blocked-target', 'org-merge-superadmin')$$,
  '23514',
  'Organization merge blocked: Source and target oppose each other in a match; merging would create a self-match.',
  'blocked merge raises a constraint error'
);

SELECT ok(
  EXISTS (SELECT 1 FROM public.orgs WHERE id = 'org-merge-blocked-source')
    AND EXISTS (
      SELECT 1 FROM public.matches
      WHERE id = 'org-merge-self-match'
        AND home_org_id = 'org-merge-blocked-source'
        AND away_org_id = 'org-merge-blocked-target'
    ),
  'a blocked merge leaves every source record unchanged'
);

SELECT * FROM finish();
ROLLBACK;
