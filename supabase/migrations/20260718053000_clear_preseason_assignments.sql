CREATE OR REPLACE FUNCTION public.clear_preseason_assignments(p_season_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_status text;
  v_roster_rows integer;
  v_org_rows integer;
BEGIN
  IF p_season_id IS NULL OR btrim(p_season_id) = '' THEN
    RAISE EXCEPTION 'Season id is required';
  END IF;

  SELECT status
  INTO v_status
  FROM public.seasons
  WHERE id = p_season_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Season % does not exist', p_season_id;
  END IF;

  IF v_status <> 'pre-season' THEN
    RAISE EXCEPTION 'Season % is not a pre-season and cannot be cleared', p_season_id;
  END IF;

  IF EXISTS (SELECT 1 FROM public.matches WHERE season_id = p_season_id) THEN
    RAISE EXCEPTION 'Season % has matches and cannot be cleared', p_season_id;
  END IF;

  IF EXISTS (SELECT 1 FROM public.draft_rooms WHERE season_id = p_season_id) THEN
    RAISE EXCEPTION 'Season % has draft rooms and cannot be cleared', p_season_id;
  END IF;

  DELETE FROM public.season_rosters
  WHERE season_id = p_season_id;
  GET DIAGNOSTICS v_roster_rows = ROW_COUNT;

  DELETE FROM public.season_orgs
  WHERE season_id = p_season_id;
  GET DIAGNOSTICS v_org_rows = ROW_COUNT;

  RETURN jsonb_build_object(
    'code', CASE
      WHEN v_roster_rows + v_org_rows = 0 THEN 'already_empty'
      ELSE 'cleared'
    END,
    'seasonId', p_season_id,
    'rosterRows', v_roster_rows,
    'organizationRows', v_org_rows
  );
END;
$$;

REVOKE ALL ON FUNCTION public.clear_preseason_assignments(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.clear_preseason_assignments(text) FROM anon;
REVOKE ALL ON FUNCTION public.clear_preseason_assignments(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.clear_preseason_assignments(text) TO service_role;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.seasons
    WHERE id = 'preseason-s2'
      AND status = 'pre-season'
  ) THEN
    PERFORM public.clear_preseason_assignments('preseason-s2');
  END IF;
END;
$$;
