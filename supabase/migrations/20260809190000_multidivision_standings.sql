-- Standings are records for divisional teams, not league-wide organization
-- identities. One organization may field a team in every division, so the
-- persisted key must match the application's (org_id, division_id) team key.

ALTER TABLE public.standings
  DROP CONSTRAINT standings_pkey,
  ADD CONSTRAINT standings_pkey PRIMARY KEY (org_id, division_id);

CREATE OR REPLACE FUNCTION public.replace_standings(p_rows jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM public.standings AS standing
  WHERE NOT EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_rows) AS item(org_id text, division_id text)
    WHERE item.org_id = standing.org_id
      AND item.division_id = standing.division_id
  );

  INSERT INTO public.standings (
    org_id, division_id, wins, losses, matches_played,
    points_for, points_against, streak, games_back
  )
  SELECT
    item.org_id, item.division_id, item.wins, item.losses,
    item.matches_played, item.points_for, item.points_against,
    item.streak, item.games_back
  FROM jsonb_to_recordset(p_rows) AS item(
    org_id text,
    division_id text,
    wins integer,
    losses integer,
    matches_played integer,
    points_for integer,
    points_against integer,
    streak jsonb,
    games_back numeric
  )
  ON CONFLICT (org_id, division_id) DO UPDATE SET
    wins = EXCLUDED.wins,
    losses = EXCLUDED.losses,
    matches_played = EXCLUDED.matches_played,
    points_for = EXCLUDED.points_for,
    points_against = EXCLUDED.points_against,
    streak = EXCLUDED.streak,
    games_back = EXCLUDED.games_back;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.replace_standings(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.replace_standings(jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.replace_standings(jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.replace_standings(jsonb) TO service_role;

COMMENT ON TABLE public.standings IS
  'Current persisted standings, one row per organization and division team.';
