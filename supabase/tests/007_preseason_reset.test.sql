BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(7);

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES
  ('test-reset-season', 'Reset Test Preseason', 'pre-season', '2026-07-01', '2026-08-31', false),
  ('test-control-season', 'Control Test Season', 'post-season', '2026-01-01', '2026-06-30', false);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
)
VALUES (
  'test-reset-org', 'Reset Test Organization', 'RTO', 'terra', 'RTO',
  'from-black to-white', '#000000', 'from-black to-white'
);

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status, discord_id
)
VALUES (
  'test-reset-player', 'test-reset-org', 'test-reset-user', 'Reset Test Player', 'RP',
  'from-black to-white', 'Support', 'terra', 'active', 'test-reset-discord-id'
);

INSERT INTO public.season_orgs (season_id, org_id, division_id)
VALUES
  ('test-reset-season', 'test-reset-org', 'terra'),
  ('test-control-season', 'test-reset-org', 'terra');

INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, is_captain, roster_status
)
VALUES
  ('test-reset-season', 'test-reset-player', 'test-reset-org', 'terra', true, 'active'),
  ('test-control-season', 'test-reset-player', 'test-reset-org', 'terra', true, 'active');

SELECT has_function(
  'public',
  'clear_preseason_assignments',
  ARRAY['text'],
  'the service-only preseason reset function exists'
);

SELECT is(
  public.clear_preseason_assignments('test-reset-season')->>'code',
  'cleared',
  'the first reset reports a completed clear'
);

SELECT is(
  (SELECT count(*)::integer FROM public.season_rosters WHERE season_id = 'test-reset-season')
    +
  (SELECT count(*)::integer FROM public.season_orgs WHERE season_id = 'test-reset-season'),
  0,
  'the target preseason has no remaining assignments'
);

SELECT is(
  (SELECT count(*)::integer FROM public.season_rosters WHERE season_id = 'test-control-season')
    +
  (SELECT count(*)::integer FROM public.season_orgs WHERE season_id = 'test-control-season'),
  2,
  'assignments for every other season remain intact'
);

SELECT ok(
  EXISTS (SELECT 1 FROM public.orgs WHERE id = 'test-reset-org')
    AND EXISTS (SELECT 1 FROM public.players WHERE id = 'test-reset-player'),
  'the reset preserves organization and player identities'
);

SELECT is(
  public.clear_preseason_assignments('test-reset-season')->>'code',
  'already_empty',
  'repeating the reset is idempotent'
);

SELECT throws_ok(
  $$SELECT public.clear_preseason_assignments('test-control-season')$$,
  'P0001',
  'Season test-control-season is not a pre-season and cannot be cleared',
  'a non-preseason cannot be cleared'
);

SELECT * FROM finish();
ROLLBACK;
