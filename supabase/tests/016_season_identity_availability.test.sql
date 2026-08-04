BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(18);

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES ('issue237-season', 'Issue 237 Season', 'pre-season', '2026-08-01', '2026-08-31', false);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient,
  archived_at
)
VALUES
  (
    'issue237-active-org', 'Issue 237 Active Org', 'I2A', 'terra', 'I2A',
    'from-black to-white', '#000000', 'from-black to-white', NULL
  ),
  (
    'issue237-archived-org', 'Issue 237 Archived Org', 'I2R', 'terra', 'I2R',
    'from-black to-white', '#000000', 'from-black to-white', now()
  ),
  (
    'issue237-empty-org', 'Issue 237 Empty Org', 'I2E', 'terra', 'I2E',
    'from-black to-white', '#000000', 'from-black to-white', NULL
  );

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status, discord_id, archived_at
)
VALUES
  (
    'issue237-active-player', NULL, 'issue237-active', 'Issue 237 Active', 'IA',
    'from-black to-white', 'Support', 'terra', 'active', 'issue237-active-discord', NULL
  ),
  (
    'issue237-archived-player', NULL, 'issue237-archived', 'Issue 237 Archived', 'IR',
    'from-black to-white', 'Support', 'terra', 'active', 'issue237-archived-discord', now()
  ),
  (
    'issue237-empty-player', NULL, 'issue237-empty', 'Issue 237 Empty', 'IE',
    'from-black to-white', 'Support', 'terra', 'active', 'issue237-empty-discord', NULL
  ),
  (
    'issue237-second-player', NULL, 'issue237-second', 'Issue 237 Second', 'IS',
    'from-black to-white', 'Support', 'terra', 'active', 'issue237-second-discord', NULL
  ),
  (
    'issue237-unassigned-captain', NULL, 'issue237-unassigned-captain',
    'Issue 237 Unassigned Captain', 'IC', 'from-black to-white', 'Support',
    'lunar', 'active', 'issue237-unassigned-captain-discord', NULL
  );

SELECT ok(
  to_regprocedure('private.assert_season_identity_availability()') IS NOT NULL
    AND to_regprocedure('private.enforce_season_identity_availability()') IS NOT NULL,
  'the private identity-availability validation and trigger functions exist'
);

SELECT is(
  (
    SELECT count(*)::integer
    FROM pg_trigger
    WHERE tgname IN (
      'season_orgs_identity_availability_guard',
      'season_rosters_identity_availability_guard',
      'players_active_participation_archive_guard',
      'orgs_active_participation_archive_guard'
    )
      AND NOT tgisinternal
  ),
  4,
  'all four identity-availability triggers exist'
);

SELECT ok(
  position(
    'FOR SHARE' IN upper(
      pg_get_functiondef('private.enforce_season_identity_availability()'::regprocedure)
    )
  ) > 0,
  'active enrollment locks referenced identities against concurrent archival'
);

SELECT throws_ok(
  $$
    INSERT INTO public.season_orgs (season_id, org_id, division_id, status)
    VALUES ('issue237-season', 'issue237-archived-org', 'terra', 'active')
  $$,
  '23514',
  'Cannot enroll unavailable org issue237-archived-org. Restore the org before assigning active season participation.',
  'an archived org cannot receive active season participation'
);

SELECT throws_ok(
  $$
    INSERT INTO public.season_rosters (
      season_id, player_id, org_id, division_id, is_captain, roster_status
    ) VALUES (
      'issue237-season', 'issue237-archived-player', NULL, 'terra', false, 'free_agent'
    )
  $$,
  '23514',
  'Cannot enroll unavailable player issue237-archived-player. Restore the player before assigning active season participation.',
  'an archived player cannot receive free-agent participation'
);

SELECT lives_ok(
  $$
    INSERT INTO public.season_rosters (
      season_id, player_id, org_id, division_id, is_captain, roster_status
    ) VALUES (
      'issue237-season', 'issue237-unassigned-captain', NULL, 'lunar', true, 'free_agent'
    )
  $$,
  'an unassigned preseason player can be marked as a captain before teams are formed'
);

ALTER TABLE public.season_rosters
  DISABLE TRIGGER season_rosters_identity_availability_guard;

INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, is_captain, roster_status
)
VALUES (
  'issue237-season', 'issue237-archived-player', NULL, 'terra', false, 'free_agent'
);

ALTER TABLE public.season_rosters
  ENABLE TRIGGER season_rosters_identity_availability_guard;

SELECT throws_ok(
  $$SELECT private.assert_season_identity_availability()$$,
  '23514',
  'Season identity availability invariant failed: 0 active org assignment(s) reference unavailable orgs; 1 active roster assignment(s) reference unavailable players; 0 active roster assignment(s) reference unavailable orgs. Repair existing assignments before applying this migration.',
  'migration validation rejects pre-existing identity drift'
);

DELETE FROM public.season_rosters
WHERE season_id = 'issue237-season'
  AND player_id = 'issue237-archived-player';

SELECT lives_ok(
  $$SELECT private.assert_season_identity_availability()$$,
  'migration validation succeeds after existing drift is repaired'
);

INSERT INTO public.season_orgs (season_id, org_id, division_id, status)
VALUES ('issue237-season', 'issue237-active-org', 'terra', 'active');

SELECT lives_ok(
  $$
    INSERT INTO public.season_orgs (season_id, org_id, division_id, status)
    VALUES ('issue237-season', 'issue237-active-org', 'lunar', 'active')
  $$,
  'one organization can field separate teams in multiple divisions in the same season'
);

SELECT throws_ok(
  $$
    UPDATE public.orgs
    SET archived_at = now()
    WHERE id = 'issue237-active-org'
  $$,
  '23514',
  'Cannot archive org issue237-active-org while active season participation exists. Remove active season assignments first.',
  'an org with active season participation cannot be archived'
);

INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, is_captain, roster_status
)
VALUES (
  'issue237-season', 'issue237-active-player', NULL, 'terra', false, 'free_agent'
);

SELECT throws_ok(
  $$
    UPDATE public.players
    SET archived_at = now()
    WHERE id = 'issue237-active-player'
  $$,
  '23514',
  'Cannot archive player issue237-active-player while active season participation exists. Remove active season roster assignments first.',
  'a player with active season participation cannot be archived'
);

SELECT lives_ok(
  $$
    INSERT INTO public.season_orgs (season_id, org_id, division_id, status)
    VALUES ('issue237-season', 'issue237-archived-org', 'terra', 'inactive')
  $$,
  'historical inactive org participation can reference an archived identity'
);

SELECT lives_ok(
  $$
    INSERT INTO public.season_rosters (
      season_id, player_id, org_id, division_id, is_captain, roster_status
    ) VALUES (
      'issue237-season', 'issue237-archived-player', 'issue237-archived-org',
      'terra', false, 'inactive'
    )
  $$,
  'historical inactive roster participation can reference archived identities'
);

SELECT has_index(
  'public',
  'season_rosters',
  'season_rosters_one_active_captain_per_org_idx',
  'one active captain per season organization is enforced'
);

UPDATE public.season_rosters
SET org_id = 'issue237-active-org', is_captain = true, roster_status = 'active'
WHERE season_id = 'issue237-season'
  AND player_id = 'issue237-active-player';

SELECT lives_ok(
  $$
    UPDATE public.season_rosters
    SET org_id = 'issue237-active-org', division_id = 'lunar',
        is_captain = true, roster_status = 'active'
    WHERE season_id = 'issue237-season'
      AND player_id = 'issue237-unassigned-captain'
  $$,
  'the same organization can have one captain for each divisional team'
);

SELECT throws_ok(
  $$
    INSERT INTO public.season_rosters (
      season_id, player_id, org_id, division_id, is_captain, roster_status
    ) VALUES (
      'issue237-season', 'issue237-second-player', 'issue237-active-org',
      'terra', true, 'active'
    )
  $$,
  '23505',
  'duplicate key value violates unique constraint "season_rosters_one_active_captain_per_org_idx"',
  'a season organization cannot have two active captains'
);

SELECT lives_ok(
  $$
    UPDATE public.players
    SET archived_at = now()
    WHERE id = 'issue237-empty-player'
  $$,
  'a player without active participation can still be archived'
);

SELECT lives_ok(
  $$
    UPDATE public.orgs
    SET archived_at = now()
    WHERE id = 'issue237-empty-org'
  $$,
  'an org without active participation can still be archived'
);

SELECT * FROM finish();
ROLLBACK;
