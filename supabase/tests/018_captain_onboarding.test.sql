BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(18);

SELECT ok(
  to_regprocedure('public.onboard_season_captain(text,text,text,text,text,text)') IS NOT NULL,
  'the captain onboarding RPC exists'
);

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.onboard_season_captain(text,text,text,text,text,text)',
    'EXECUTE'
  )
    AND NOT has_function_privilege(
      'authenticated',
      'public.onboard_season_captain(text,text,text,text,text,text)',
      'EXECUTE'
    ),
  'client roles cannot execute captain onboarding'
);

SELECT ok(
  has_function_privilege(
    'service_role',
    'public.onboard_season_captain(text,text,text,text,text,text)',
    'EXECUTE'
  ),
  'service_role can execute captain onboarding'
);

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES ('captain-onboarding-season', 'Captain Onboarding Season', 'pre-season', '2026-08-01', '2026-09-30', false);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
) VALUES (
  'captain-onboarding-org', 'Captain Onboarding Org', 'COO', 'solar', 'COO',
  'from-black to-white', '#000000', 'from-black to-white'
), (
  'captain-onboarding-other-org', 'Other Captain Org', 'OCO', 'lunar', 'OCO',
  'from-black to-white', '#000000', 'from-black to-white'
);

INSERT INTO public.players (
  id, discord_username, discord_id, ign, avatar_initials, avatar_gradient,
  primary_role, status, is_captain
) VALUES (
  'captain-onboarding-player', 'captain-onboarding-user', '123456789012345678',
  'Captain Onboarding Player', 'CP', 'from-black to-white', 'Support', 'active', false
), (
  'captain-onboarding-second-player', 'captain-onboarding-second-user', '223456789012345678',
  'Captain Onboarding Second Player', 'CP', 'from-black to-white', 'Support', 'active', false
);

INSERT INTO public.admin_users (
  discord_id, role, discord_username, display_name
) VALUES (
  'captain-onboarding-admin', 'admin', 'captain-onboarding-admin', 'Captain Onboarding Admin'
);

CREATE TEMP TABLE captain_onboarding_first_result AS
SELECT public.onboard_season_captain(
  'captain-onboarding-season',
  'captain-onboarding-player',
  '123456789012345678',
  'captain-onboarding-org',
  'solar',
  'captain-onboarding-admin'
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'onboarded'
      AND result ->> 'applied' = 'true'
      AND result ->> 'seasonOrganizationCreated' = 'true'
      AND result ->> 'auditRows' = '2'
   FROM captain_onboarding_first_result),
  'the first explicit mapping is applied atomically'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.season_orgs
    WHERE season_id = 'captain-onboarding-season'
      AND org_id = 'captain-onboarding-org'
      AND division_id = 'solar'
      AND status = 'active'
  ),
  'the explicit season organization mapping is created'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.season_rosters
    WHERE season_id = 'captain-onboarding-season'
      AND player_id = 'captain-onboarding-player'
      AND org_id = 'captain-onboarding-org'
      AND division_id = 'solar'
      AND is_captain
      AND roster_status = 'active'
  ),
  'the player becomes captain only in the explicit season roster'
);

SELECT is(
  (SELECT count(*)::integer
   FROM public.audit_logs
   WHERE actor_discord_id = 'captain-onboarding-admin'
     AND action_type IN ('season_organization_onboarded', 'season_captain_onboarded')),
  2,
  'the organization and captain mutations each append an immutable audit'
);

SELECT ok(
  (SELECT NOT is_captain
   FROM public.players
   WHERE id = 'captain-onboarding-player')
    AND EXISTS (
      SELECT 1 FROM public.admin_users
      WHERE discord_id = 'captain-onboarding-admin'
    ),
  'onboarding changes neither the legacy captain flag nor admin access'
);

-- The same organization fields an independent second team in another
-- division this season. season_orgs identity is the full (season, org,
-- division) triple, so onboarding a captain for this second division must
-- succeed and must not be blocked by the organization's first division.
CREATE TEMP TABLE captain_onboarding_second_division_result AS
SELECT public.onboard_season_captain(
  'captain-onboarding-season',
  'captain-onboarding-second-player',
  '223456789012345678',
  'captain-onboarding-org',
  'terra',
  'captain-onboarding-admin'
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'onboarded'
      AND result ->> 'applied' = 'true'
      AND result ->> 'seasonOrganizationCreated' = 'true'
   FROM captain_onboarding_second_division_result),
  'onboarding a captain for the same organization''s second division succeeds'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.season_orgs
    WHERE season_id = 'captain-onboarding-season'
      AND org_id = 'captain-onboarding-org'
      AND division_id = 'terra'
      AND status = 'active'
  )
    AND EXISTS (
      SELECT 1
      FROM public.season_orgs
      WHERE season_id = 'captain-onboarding-season'
        AND org_id = 'captain-onboarding-org'
        AND division_id = 'solar'
        AND status = 'active'
    ),
  'the organization now has independent season teams in both divisions'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.season_rosters
    WHERE season_id = 'captain-onboarding-season'
      AND player_id = 'captain-onboarding-second-player'
      AND org_id = 'captain-onboarding-org'
      AND division_id = 'terra'
      AND is_captain
      AND roster_status = 'active'
  ),
  'the second division''s captain is recorded independently of the first'
);

CREATE TEMP TABLE captain_onboarding_retry_result AS
SELECT public.onboard_season_captain(
  'captain-onboarding-season',
  'captain-onboarding-player',
  '123456789012345678',
  'captain-onboarding-org',
  'solar',
  'captain-onboarding-admin'
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'already_onboarded'
      AND result ->> 'applied' = 'false'
      AND result ->> 'auditRows' = '0'
   FROM captain_onboarding_retry_result),
  'an exact replay is idempotent'
);

SELECT ok(
  (SELECT count(*) = 1
   FROM public.season_rosters
   WHERE season_id = 'captain-onboarding-season'
     AND player_id = 'captain-onboarding-player')
    AND (SELECT count(*) = 2
         FROM public.audit_logs
         WHERE actor_discord_id = 'captain-onboarding-admin'
           AND action_type IN ('season_organization_onboarded', 'season_captain_onboarded')),
  'an exact replay writes no duplicate roster or audit rows'
);

SELECT throws_ok(
  $$SELECT public.onboard_season_captain(
    'captain-onboarding-season',
    'captain-onboarding-player',
    '999999999999999999',
    'captain-onboarding-org',
    'solar',
    'captain-onboarding-admin'
  )$$,
  '23514',
  'Player captain-onboarding-player is not linked to the supplied Discord id; run /division-sync first',
  'a Discord mapping must already match the canonical player identity'
);

SELECT throws_ok(
  $$SELECT public.onboard_season_captain(
    'captain-onboarding-season',
    'captain-onboarding-player',
    '123456789012345678',
    'captain-onboarding-other-org',
    'lunar',
    'captain-onboarding-admin'
  )$$,
  '23514',
  'Player captain-onboarding-player already has a conflicting roster assignment in season captain-onboarding-season',
  'a conflicting season roster mapping is rejected atomically'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM public.season_orgs
    WHERE season_id = 'captain-onboarding-season'
      AND org_id = 'captain-onboarding-other-org'
  ),
  'a rejected conflicting mapping rolls back its provisional organization row'
);

SELECT throws_ok(
  $$SELECT public.onboard_season_captain(
    'captain-onboarding-season',
    'captain-onboarding-player',
    '123456789012345678',
    'captain-onboarding-org',
    'solar',
    'not-an-admin'
  )$$,
  '42501',
  'Only a SAL admin can onboard a season captain.',
  'the database rejects a non-admin actor even through the service role'
);

SELECT ok(
  (SELECT discord_id = '123456789012345678'
   FROM public.players
   WHERE id = 'captain-onboarding-player'),
  'the operation verifies but never mutates the Discord identity link'
);

SELECT * FROM finish();
ROLLBACK;
