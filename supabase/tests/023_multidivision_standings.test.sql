BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(3);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
) VALUES (
  'standings-multidivision-org', 'Multidivision Organization', 'MDO', 'terra',
  'MDO', 'from-cyan-500 to-blue-900', '#00ffff', 'from-cyan-500 to-blue-900'
);

SELECT lives_ok(
  $test$
    SELECT public.replace_standings(
      '[
        {
          "org_id": "standings-multidivision-org",
          "division_id": "terra",
          "wins": 1,
          "losses": 0,
          "matches_played": 1,
          "points_for": 2,
          "points_against": 0,
          "streak": ["W"],
          "games_back": 0
        },
        {
          "org_id": "standings-multidivision-org",
          "division_id": "solar",
          "wins": 0,
          "losses": 1,
          "matches_played": 1,
          "points_for": 1,
          "points_against": 2,
          "streak": ["L"],
          "games_back": 1
        }
      ]'::jsonb
    )
  $test$,
  'replace_standings accepts one organization in multiple divisions'
);

SELECT results_eq(
  $$
    SELECT division_id, wins, losses
    FROM public.standings
    WHERE org_id = 'standings-multidivision-org'
    ORDER BY division_id
  $$,
  $$VALUES ('solar'::text, 0, 1), ('terra'::text, 1, 0)$$,
  'replace_standings persists independent division records for one organization'
);

SELECT public.replace_standings(
  '[
    {
      "org_id": "standings-multidivision-org",
      "division_id": "terra",
      "wins": 2,
      "losses": 0,
      "matches_played": 2,
      "points_for": 4,
      "points_against": 0,
      "streak": ["W", "W"],
      "games_back": 0
    }
  ]'::jsonb
);

SELECT results_eq(
  $$
    SELECT division_id, wins, losses
    FROM public.standings
    WHERE org_id = 'standings-multidivision-org'
    ORDER BY division_id
  $$,
  $$VALUES ('terra'::text, 2, 0)$$,
  'replace_standings removes only obsolete organization-division rows'
);

SELECT * FROM finish();
ROLLBACK;
