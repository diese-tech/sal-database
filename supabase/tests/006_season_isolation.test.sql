BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(4);

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES
  ('test-source-season', 'Source Test Season', 'active', '2026-01-01', '2026-06-30', false),
  ('test-new-season', 'New Test Season', 'pre-season', '2026-07-01', '2026-12-31', false);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
)
VALUES (
  'test-org', 'Test Organization', 'TEST', 'terra', 'TO', 'from-black to-white', '#000000',
  'from-black to-white'
);

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status, discord_id
)
VALUES (
  'test-player', 'test-org', 'test-user', 'Test Player', 'TP', 'from-black to-white',
  'Support', 'terra', 'active', 'test-discord-id'
);

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status, discord_id
)
VALUES (
  'test-unassigned-player', NULL, 'test-unassigned', 'Unassigned Player', 'UP',
  'from-black to-white', 'Support', NULL, 'active', 'test-unassigned-discord-id'
);

INSERT INTO public.season_orgs (season_id, org_id, division_id)
VALUES ('test-source-season', 'test-org', 'terra');

INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, is_captain, roster_status
)
VALUES (
  'test-source-season', 'test-player', 'test-org', 'terra', true, 'active'
);

INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, is_captain, roster_status
)
VALUES (
  'test-source-season', 'test-unassigned-player', NULL, NULL, false, 'free_agent'
);

SELECT is(
  (SELECT count(*)::integer FROM public.season_orgs WHERE season_id = 'test-new-season')
    +
  (SELECT count(*)::integer FROM public.season_rosters WHERE season_id = 'test-new-season'),
  0,
  'a newly created season starts with no organizations or roster assignments'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.season_rosters
    WHERE season_id = 'test-source-season'
      AND player_id = 'test-unassigned-player'
      AND org_id IS NULL
      AND division_id IS NULL
      AND roster_status = 'free_agent'
  ),
  'an unassigned player remains in the season roster without inventing a division'
);

SELECT lives_ok(
  $$SELECT public.set_current_season('test-new-season')$$,
  'service code can atomically select the new current season'
);

SELECT ok(
  (SELECT count(*) = 1 FROM public.seasons WHERE is_current)
    AND
  (SELECT is_current FROM public.seasons WHERE id = 'test-new-season'),
  'exactly the requested season is current after the switch'
);

SELECT * FROM finish();
ROLLBACK;
