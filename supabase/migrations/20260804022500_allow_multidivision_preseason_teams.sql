-- A league-wide organization identity may field one team in each division for
-- the same season. Season-team identity is therefore the full
-- (season_id, org_id, division_id) tuple, never the organization alone.

ALTER TABLE public.matches
  DROP CONSTRAINT matches_home_season_org_fkey,
  DROP CONSTRAINT matches_away_season_org_fkey;

ALTER TABLE public.season_rosters
  DROP CONSTRAINT season_rosters_season_org_division_fkey;

ALTER TABLE public.season_orgs
  DROP CONSTRAINT season_orgs_pkey,
  DROP CONSTRAINT season_orgs_season_org_division_key,
  ADD CONSTRAINT season_orgs_pkey
    PRIMARY KEY (season_id, org_id, division_id);

-- Older releases enforced only the season+org pair for matches. Preserve and
-- normalize any historical match evidence before installing the stricter
-- triple foreign keys. The existing assignment's status is retained so this
-- repair cannot reactivate an archived historical identity.
INSERT INTO public.season_orgs (season_id, org_id, division_id, status)
SELECT DISTINCT
  match_teams.season_id,
  match_teams.org_id,
  match_teams.division_id,
  existing.status
FROM (
  SELECT season_id, home_org_id AS org_id, division_id
  FROM public.matches
  WHERE season_id IS NOT NULL
  UNION
  SELECT season_id, away_org_id AS org_id, division_id
  FROM public.matches
  WHERE season_id IS NOT NULL
) AS match_teams
JOIN public.season_orgs AS existing
  ON existing.season_id = match_teams.season_id
 AND existing.org_id = match_teams.org_id
ON CONFLICT (season_id, org_id, division_id) DO NOTHING;

ALTER TABLE public.season_rosters
  ADD CONSTRAINT season_rosters_season_org_division_fkey
    FOREIGN KEY (season_id, org_id, division_id)
    REFERENCES public.season_orgs(season_id, org_id, division_id);

ALTER TABLE public.matches
  ADD CONSTRAINT matches_home_season_org_fkey
    FOREIGN KEY (season_id, home_org_id, division_id)
    REFERENCES public.season_orgs(season_id, org_id, division_id),
  ADD CONSTRAINT matches_away_season_org_fkey
    FOREIGN KEY (season_id, away_org_id, division_id)
    REFERENCES public.season_orgs(season_id, org_id, division_id);

-- Captain candidacy begins before teams exist. Keep the division when known,
-- but do not require an organization merely to mark a preseason candidate.
ALTER TABLE public.season_rosters
  DROP CONSTRAINT season_rosters_assignment_check,
  ADD CONSTRAINT season_rosters_assignment_check
    CHECK (
      (roster_status = 'free_agent' AND org_id IS NULL)
      OR
      (roster_status <> 'free_agent' AND org_id IS NOT NULL AND division_id IS NOT NULL)
    );

DROP INDEX public.season_rosters_one_active_captain_per_org_idx;

CREATE UNIQUE INDEX season_rosters_one_active_captain_per_org_idx
  ON public.season_rosters (season_id, org_id, division_id)
  WHERE is_captain
    AND roster_status = 'active'
    AND org_id IS NOT NULL;

COMMENT ON TABLE public.season_orgs IS
  'Divisional teams fielded by league-wide organization identities in a season; one row per season, organization, and division.';

COMMENT ON COLUMN public.orgs.division_id IS
  'Legacy/default display division only. Season team participation is defined by season_orgs.division_id and may span multiple divisions.';
