BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(29);

SELECT has_table(
  'public', 'season_organization_role_mappings',
  'team roles are scoped by season, division, and organization'
);
SELECT has_table(
  'public', 'season_player_eligibility',
  'post-drop eligibility is an authoritative private contract'
);
SELECT has_function(
  'public', 'set_season_organization_role_mappings', ARRAY['text', 'text', 'jsonb'],
  'reviewed mapping artifacts have one audited bulk setter'
);
SELECT has_function(
  'public', 'create_roster_drop', ARRAY['text', 'text', 'text', 'text', 'text', 'text'],
  'drop creation is transport neutral'
);
SELECT has_function(
  'public', 'resolve_roster_drop_pending_action',
  ARRAY['text', 'text', 'text', 'text', 'timestamp with time zone', 'text'],
  'drop execution remains an administrator pending-action decision'
);
SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.create_roster_drop(text,text,text,text,text,text)', 'EXECUTE'
  )
  AND NOT has_function_privilege(
    'authenticated', 'public.create_roster_drop(text,text,text,text,text,text)', 'EXECUTE'
  )
  AND has_function_privilege(
    'service_role', 'public.create_roster_drop(text,text,text,text,text,text)', 'EXECUTE'
  ),
  'drop mutation RPCs are service-role-only'
);

UPDATE public.seasons SET is_current = false WHERE is_current;
INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES ('drop-season', 'Drop Season', 'active', '2026-08-01', '2026-12-31', true);
INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
) VALUES
  ('drop-org-a', 'Drop Organization A', 'DOA', 'solar', 'DA', 'x', '#000000', 'x'),
  ('drop-org-b', 'Drop Organization B', 'DOB', 'solar', 'DB', 'x', '#000000', 'x');
INSERT INTO public.season_orgs (season_id, org_id, division_id)
VALUES
  ('drop-season', 'drop-org-a', 'solar'),
  ('drop-season', 'drop-org-b', 'solar');
INSERT INTO public.admin_users (discord_id, role, discord_username, display_name)
VALUES
  ('drop-admin', 'admin', 'drop-admin', 'Drop Admin'),
  ('merge-admin', 'super_admin', 'merge-admin', 'Merge Admin');
INSERT INTO public.season_transaction_settings (
  season_id, division_id, trades_open, drops_open, max_roster_size, updated_by_discord_id
) VALUES ('drop-season', 'solar', false, true, 5, 'drop-admin');
INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status, discord_id
) VALUES
  ('drop-player-1', 'drop-org-a', 'drop-one', 'Drop One', 'D1', 'x', 'Flex', 'solar', 'active', 'discord-drop-one'),
  ('drop-player-2', 'drop-org-a', 'drop-two', 'Drop Two', 'D2', 'x', 'Flex', 'solar', 'active', 'discord-drop-two'),
  ('drop-player-3', 'drop-org-a', 'drop-three', 'Drop Three', 'D3', 'x', 'Flex', 'solar', 'active', 'discord-drop-three');
INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, is_captain, roster_status
) VALUES
  ('drop-season', 'drop-player-1', 'drop-org-a', 'solar', false, 'active'),
  ('drop-season', 'drop-player-2', 'drop-org-a', 'solar', false, 'active'),
  ('drop-season', 'drop-player-3', 'drop-org-a', 'solar', false, 'active');

CREATE TEMP TABLE mapping_result AS
SELECT public.set_season_organization_role_mappings(
  'drop-admin', 'drop-season',
  '[
    {"division_id":"solar","org_id":"drop-org-a","discord_role_id":"1491162482394529863"},
    {"division_id":"solar","org_id":"drop-org-b","discord_role_id":"1491163450972311602"}
  ]'::jsonb
) AS result;
SELECT ok(
  (SELECT result ->> 'updatedCount' = '2' FROM mapping_result)
  AND (SELECT count(*) = 2 FROM public.season_organization_role_mappings WHERE season_id = 'drop-season'),
  'bulk role mapping writes every reviewed season-team tuple'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE action_type = 'season_team_role_mappings_updated'
      AND entity_id = 'drop-season' AND actor_discord_id = 'drop-admin'
  ),
  'bulk role mapping is audited once with its reviewed input'
);
SELECT lives_ok(
  $$SELECT public.set_season_organization_role_mappings(
    'drop-admin', 'drop-season',
    '[
      {"division_id":"solar","org_id":"drop-org-a","discord_role_id":"1491163450972311602"},
      {"division_id":"solar","org_id":"drop-org-b","discord_role_id":"1491162482394529863"}
    ]'::jsonb
  )$$,
  'bulk mapping can atomically exchange two existing team roles'
);
SELECT ok(
  (SELECT discord_role_id = '1491163450972311602'
   FROM public.season_organization_role_mappings
   WHERE season_id = 'drop-season' AND division_id = 'solar' AND org_id = 'drop-org-a')
  AND
  (SELECT discord_role_id = '1491162482394529863'
   FROM public.season_organization_role_mappings
   WHERE season_id = 'drop-season' AND division_id = 'solar' AND org_id = 'drop-org-b'),
  'role exchange commits the complete reviewed replacement set'
);
SELECT throws_ok(
  $$SELECT public.set_season_organization_role_mappings(
    'drop-admin', 'drop-season',
    '[
      {"division_id":"solar","org_id":"drop-org-a","discord_role_id":"1491162482394529863"},
      {"division_id":"solar","org_id":"drop-org-b","discord_role_id":"1491162482394529863"}
    ]'::jsonb
  )$$,
  '22023', 'A Discord team role cannot be assigned more than once in a season.',
  'bulk mapping rejects duplicate Discord team roles'
);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
) VALUES
  ('drop-org-source', 'Drop Organization Source', 'DOS', 'solar', 'DS', 'x', '#000000', 'x'),
  ('drop-org-target', 'Drop Organization Target', 'DOT', 'solar', 'DT', 'x', '#000000', 'x');
INSERT INTO public.season_orgs (season_id, org_id, division_id)
VALUES
  ('drop-season', 'drop-org-source', 'solar'),
  ('drop-season', 'drop-org-target', 'solar');
INSERT INTO public.organization_role_mappings (
  org_id, discord_role_id, updated_by_discord_id
) VALUES ('drop-org-source', '17777777777777777', 'drop-admin');
INSERT INTO public.season_organization_role_mappings (
  season_id, division_id, org_id, discord_role_id, updated_by_discord_id
) VALUES (
  'drop-season', 'solar', 'drop-org-source', '18888888888888888', 'drop-admin'
);
SELECT lives_ok(
  $$SELECT public.merge_organization('drop-org-source', 'drop-org-target', 'merge-admin')$$,
  'organization merge preserves Discord role mapping contracts'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.organization_role_mappings
    WHERE org_id = 'drop-org-target' AND discord_role_id = '17777777777777777'
  )
  AND EXISTS (
    SELECT 1 FROM public.season_organization_role_mappings
    WHERE season_id = 'drop-season' AND division_id = 'solar'
      AND org_id = 'drop-org-target' AND discord_role_id = '18888888888888888'
  )
  AND NOT EXISTS (SELECT 1 FROM public.orgs WHERE id = 'drop-org-source'),
  'owner/advisor and season-team roles remain attached to the canonical organization'
);

CREATE TEMP TABLE drop_created AS
SELECT public.create_roster_drop(
  'discord-captain', 'drop-season', 'solar', 'drop-org-a', 'drop-player-1',
  'discord_workflow'
) AS result;
SELECT ok(
  (SELECT result ->> 'status' = 'awaiting_admin' FROM drop_created)
  AND (SELECT status = 'pending' FROM public.pending_actions
       WHERE id = (SELECT result ->> 'pendingActionId' FROM drop_created)
         AND type = 'roster_drop')
  AND (SELECT org_id = 'drop-org-a' AND roster_status = 'active'
       FROM public.season_rosters
       WHERE season_id = 'drop-season' AND player_id = 'drop-player-1'),
  'authorized submission creates a drop ledger and pending action without roster mutation'
);
SELECT is(
  (SELECT count(*)::integer FROM public.operation_outbox
   WHERE topic = 'discord_roster_drop_admin_review'
     AND aggregate_id = (SELECT result ->> 'transactionId' FROM drop_created)),
  1,
  'drop submission durably queues administrator review'
);
SELECT throws_ok(
  format(
    'SELECT public.resolve_roster_drop_pending_action(%L, %L, %L, NULL, NULL, NULL)',
    (SELECT result ->> 'pendingActionId' FROM drop_created), 'drop-admin', 'approve'
  ),
  '22023', 'Approval requires a valid post-drop eligibility status.',
  'admin approval must explicitly select post-drop eligibility'
);

CREATE TEMP TABLE drop_completed AS
SELECT public.resolve_roster_drop_pending_action(
  (SELECT result ->> 'pendingActionId' FROM drop_created),
  'drop-admin', 'approve', 'eligible', NULL, NULL
) AS result;
SELECT ok(
  (SELECT result ->> 'code' = 'completed' FROM drop_completed)
  AND (SELECT org_id IS NULL AND roster_status = 'free_agent' AND NOT is_captain
       FROM public.season_rosters
       WHERE season_id = 'drop-season' AND player_id = 'drop-player-1'),
  'admin execution atomically removes the player from the organization roster'
);
SELECT is(
  (SELECT status FROM public.season_player_eligibility
   WHERE season_id = 'drop-season' AND player_id = 'drop-player-1'),
  'eligible',
  'eligible drops record same-season eligibility separately from roster membership'
);
SELECT is(
  (SELECT count(*)::integer FROM public.operation_outbox
   WHERE topic = 'discord_transaction_bulletin'
     AND aggregate_id = (SELECT result ->> 'transactionId' FROM drop_created)),
  1,
  'completed drops publish through the durable transaction bulletin outbox'
);
SELECT is(
  (SELECT count(*)::integer FROM public.operation_outbox
   WHERE topic = 'discord_organization_role_reconciliation'
     AND aggregate_id = (SELECT result ->> 'transactionId' FROM drop_created)),
  1,
  'completed drops reconcile Discord roles only after the roster commit'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE action_type = 'roster_drop_completed'
      AND entity_id = (SELECT result ->> 'transactionId' FROM drop_created)
      AND actor_discord_id = 'drop-admin'
  ),
  'completed drops preserve administrator identity in immutable audit history'
);

CREATE TEMP TABLE suspended_drop AS
SELECT public.create_roster_drop(
  'discord-captain', 'drop-season', 'solar', 'drop-org-a', 'drop-player-2',
  'discord_workflow'
) AS result;
SELECT lives_ok(
  format(
    'SELECT public.resolve_roster_drop_pending_action(%L, %L, %L, %L, %L::timestamptz, %L)',
    (SELECT result ->> 'pendingActionId' FROM suspended_drop),
    'drop-admin', 'approve', 'suspended_until', now() + interval '7 days',
    'Private suspension reason.'
  ),
  'an administrator can approve a time-bounded suspension privately'
);
SELECT ok(
  (SELECT status = 'suspended_until' AND suspended_until > now()
   FROM public.season_player_eligibility
   WHERE season_id = 'drop-season' AND player_id = 'drop-player-2')
  AND NOT EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE aggregate_id = (SELECT result ->> 'transactionId' FROM suspended_drop)
      AND payload::text LIKE '%Private suspension reason%'
  ),
  'private sanction details never enter public Discord outbox payloads'
);

CREATE TEMP TABLE denied_drop AS
SELECT public.create_roster_drop(
  'discord-captain', 'drop-season', 'solar', 'drop-org-a', 'drop-player-3',
  'discord_workflow'
) AS result;
SELECT throws_ok(
  format(
    'SELECT public.resolve_roster_drop_pending_action(%L, %L, %L, NULL, NULL, NULL)',
    (SELECT result ->> 'pendingActionId' FROM denied_drop), 'drop-admin', 'deny'
  ),
  '22023', 'A note is required for denial and Needs Info.',
  'drop denial requires a durable administrator note'
);
SELECT lives_ok(
  format(
    'SELECT public.resolve_roster_drop_pending_action(%L, %L, %L, NULL, NULL, %L)',
    (SELECT result ->> 'pendingActionId' FROM denied_drop),
    'drop-admin', 'deny', 'Roster correction required first.'
  ),
  'administrator can deny without mutating the roster'
);
SELECT ok(
  (SELECT org_id = 'drop-org-a' AND roster_status = 'active'
   FROM public.season_rosters
   WHERE season_id = 'drop-season' AND player_id = 'drop-player-3')
  AND (SELECT status = 'denied' FROM public.pending_actions
       WHERE id = (SELECT result ->> 'pendingActionId' FROM denied_drop)),
  'denial leaves canonical roster state unchanged'
);

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status, discord_id
) VALUES (
  'drop-player-canonical', NULL, 'drop-canonical', 'Drop Canonical',
  'DC', 'x', 'Flex', 'solar', 'free_agent', NULL
);
SELECT ok(
  (public.preview_player_merge('drop-player-1', 'drop-player-canonical') ->> 'canMerge')::boolean
    AND public.preview_player_merge('drop-player-1', 'drop-player-canonical')
      #>> '{counts,seasonPlayerEligibility}' = '1',
  'player merge preview recognizes authoritative eligibility references'
);
SELECT lives_ok(
  $$SELECT public.merge_player('drop-player-1', 'drop-player-canonical', 'merge-admin')$$,
  'player merge transfers post-transaction eligibility to the canonical identity'
);
SELECT is(
  (SELECT player_id FROM public.season_player_eligibility
   WHERE season_id = 'drop-season' AND player_id = 'drop-player-canonical'),
  'drop-player-canonical',
  'post-transaction eligibility remains attached after a player merge'
);

SELECT * FROM finish();
ROLLBACK;
