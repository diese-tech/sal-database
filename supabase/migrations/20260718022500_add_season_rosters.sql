-- Preserve global player and organization identities while making participation,
-- roster assignment, division, and captain status explicit per season.

ALTER TABLE public.seasons
  ADD COLUMN is_current boolean NOT NULL DEFAULT false;

WITH selected_season AS (
  SELECT id
  FROM public.seasons
  ORDER BY (status = 'active') DESC, start_date DESC, id DESC
  LIMIT 1
)
UPDATE public.seasons AS seasons
SET is_current = true
FROM selected_season
WHERE seasons.id = selected_season.id;

CREATE UNIQUE INDEX seasons_single_current
  ON public.seasons (is_current)
  WHERE is_current;

CREATE TABLE public.season_orgs (
  season_id text NOT NULL,
  org_id text NOT NULL,
  division_id text NOT NULL,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT season_orgs_pkey PRIMARY KEY (season_id, org_id),
  CONSTRAINT season_orgs_season_id_fkey
    FOREIGN KEY (season_id) REFERENCES public.seasons(id) ON DELETE CASCADE,
  CONSTRAINT season_orgs_org_id_fkey
    FOREIGN KEY (org_id) REFERENCES public.orgs(id) ON DELETE CASCADE,
  CONSTRAINT season_orgs_division_id_fkey
    FOREIGN KEY (division_id) REFERENCES public.divisions(id),
  CONSTRAINT season_orgs_status_check
    CHECK (status IN ('active', 'inactive')),
  CONSTRAINT season_orgs_season_org_division_key
    UNIQUE (season_id, org_id, division_id)
);

CREATE TABLE public.season_rosters (
  season_id text NOT NULL,
  player_id text NOT NULL,
  org_id text,
  division_id text,
  is_captain boolean NOT NULL DEFAULT false,
  roster_status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT season_rosters_pkey PRIMARY KEY (season_id, player_id),
  CONSTRAINT season_rosters_season_id_fkey
    FOREIGN KEY (season_id) REFERENCES public.seasons(id) ON DELETE CASCADE,
  CONSTRAINT season_rosters_player_id_fkey
    FOREIGN KEY (player_id) REFERENCES public.players(id) ON DELETE CASCADE,
  CONSTRAINT season_rosters_division_id_fkey
    FOREIGN KEY (division_id) REFERENCES public.divisions(id),
  CONSTRAINT season_rosters_season_org_division_fkey
    FOREIGN KEY (season_id, org_id, division_id)
    REFERENCES public.season_orgs(season_id, org_id, division_id),
  CONSTRAINT season_rosters_status_check
    CHECK (roster_status IN ('active', 'inactive', 'free_agent')),
  CONSTRAINT season_rosters_assignment_check
    CHECK (
      (roster_status = 'free_agent' AND org_id IS NULL AND NOT is_captain)
      OR
      (roster_status <> 'free_agent' AND org_id IS NOT NULL AND division_id IS NOT NULL)
    )
);

-- Reconstruct historical organization participation from scheduled and played
-- matches. The match's division is the authoritative historical value.
INSERT INTO public.season_orgs (season_id, org_id, division_id)
SELECT DISTINCT season_id, org_id, division_id
FROM (
  SELECT season_id, home_org_id AS org_id, division_id
  FROM public.matches
  WHERE season_id IS NOT NULL
  UNION
  SELECT season_id, away_org_id AS org_id, division_id
  FROM public.matches
  WHERE season_id IS NOT NULL
) AS historical_orgs
ON CONFLICT (season_id, org_id) DO NOTHING;

-- Historical stat rows provide the best available season-specific player and
-- organization evidence. Keep each player's most recently observed assignment.
INSERT INTO public.season_orgs (season_id, org_id, division_id)
SELECT DISTINCT season_id, org_id, division_id
FROM public.player_match_stats
WHERE org_id IS NOT NULL
ON CONFLICT (season_id, org_id) DO NOTHING;

INSERT INTO public.season_rosters (
  season_id,
  player_id,
  org_id,
  division_id,
  is_captain,
  roster_status
)
SELECT DISTINCT ON (stats.season_id, stats.player_id)
  stats.season_id,
  stats.player_id,
  stats.org_id,
  season_orgs.division_id,
  false,
  'active'
FROM public.player_match_stats AS stats
JOIN public.season_orgs AS season_orgs
  ON season_orgs.season_id = stats.season_id
 AND season_orgs.org_id = stats.org_id
WHERE stats.player_id IS NOT NULL
  AND stats.org_id IS NOT NULL
ORDER BY stats.season_id, stats.player_id, stats.created_at DESC, stats.id DESC
ON CONFLICT (season_id, player_id) DO NOTHING;

-- Preserve the currently visible site roster exactly by assigning all active
-- global records to the selected current season. Global identity rows remain
-- intact and continue to be the source for profile and branding fields.
INSERT INTO public.season_orgs (season_id, org_id, division_id)
SELECT seasons.id, orgs.id, orgs.division_id
FROM public.seasons AS seasons
CROSS JOIN public.orgs AS orgs
WHERE seasons.is_current
  AND orgs.archived_at IS NULL
ON CONFLICT (season_id, org_id) DO UPDATE
SET division_id = EXCLUDED.division_id,
    status = 'active',
    updated_at = now();

INSERT INTO public.season_rosters (
  season_id,
  player_id,
  org_id,
  division_id,
  is_captain,
  roster_status
)
SELECT
  seasons.id,
  players.id,
  players.org_id,
  CASE
    WHEN players.org_id IS NULL THEN players.division_id
    ELSE orgs.division_id
  END,
  players.is_captain,
  CASE WHEN players.org_id IS NULL THEN 'free_agent' ELSE 'active' END
FROM public.seasons AS seasons
CROSS JOIN public.players AS players
LEFT JOIN public.orgs AS orgs ON orgs.id = players.org_id
WHERE seasons.is_current
  AND players.archived_at IS NULL
ON CONFLICT (season_id, player_id) DO UPDATE
SET org_id = EXCLUDED.org_id,
    division_id = EXCLUDED.division_id,
    is_captain = EXCLUDED.is_captain,
    roster_status = EXCLUDED.roster_status,
    updated_at = now();

ALTER TABLE public.matches
  ADD CONSTRAINT matches_home_season_org_fkey
    FOREIGN KEY (season_id, home_org_id)
    REFERENCES public.season_orgs(season_id, org_id),
  ADD CONSTRAINT matches_away_season_org_fkey
    FOREIGN KEY (season_id, away_org_id)
    REFERENCES public.season_orgs(season_id, org_id);

CREATE OR REPLACE FUNCTION public.set_current_season(p_season_id text)
RETURNS public.seasons
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  selected_season public.seasons;
BEGIN
  SELECT *
  INTO selected_season
  FROM public.seasons
  WHERE id = p_season_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Season % does not exist', p_season_id
      USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.seasons
  SET is_current = false
  WHERE is_current;

  UPDATE public.seasons
  SET is_current = true
  WHERE id = p_season_id;

  selected_season.is_current := true;
  RETURN selected_season;
END;
$$;

ALTER FUNCTION public.set_current_season(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.set_current_season(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_current_season(text) FROM anon;
REVOKE ALL ON FUNCTION public.set_current_season(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.set_current_season(text) TO service_role;

ALTER TABLE public.season_orgs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.season_rosters ENABLE ROW LEVEL SECURITY;

CREATE POLICY public_read_season_orgs
  ON public.season_orgs FOR SELECT
  USING (true);

CREATE POLICY public_read_season_rosters
  ON public.season_rosters FOR SELECT
  USING (true);

REVOKE ALL ON TABLE public.season_orgs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.season_rosters FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.season_orgs TO anon, authenticated;
GRANT SELECT ON TABLE public.season_rosters TO anon, authenticated;
GRANT ALL ON TABLE public.season_orgs TO service_role;
GRANT ALL ON TABLE public.season_rosters TO service_role;

COMMENT ON COLUMN public.seasons.is_current IS
  'Selects the single season used by integrations when no explicit season is supplied.';
COMMENT ON TABLE public.season_orgs IS
  'Organizations participating in a season with their season-specific division.';
COMMENT ON TABLE public.season_rosters IS
  'Season-specific player assignment, division, captain status, and roster state.';
