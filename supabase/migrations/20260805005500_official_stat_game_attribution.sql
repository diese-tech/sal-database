-- Official statistics belong to players, while season/team context belongs to
-- the game in which those statistics were produced. Keep that historical
-- attribution on the stat row so a later trade never rewrites prior results.

ALTER TABLE public.player_stats
  ADD COLUMN season_id text,
  ADD COLUMN org_id text,
  ADD COLUMN division_id text;

-- Preserve whatever can be derived from durable match/result evidence. Rows
-- without a safe organization derivation remain legacy-unattributed as a full
-- NULL tuple; the write trigger below requires complete attribution for every
-- new official row.
WITH attribution AS (
  SELECT
    stats.id,
    matches.season_id,
    matches.division_id,
    COALESCE(
      CASE
        WHEN NULLIF(COALESCE(pending.stats_json, pending.extracted_json) ->> 'org_id', '')
          IN (matches.home_org_id, matches.away_org_id)
        THEN NULLIF(COALESCE(pending.stats_json, pending.extracted_json) ->> 'org_id', '')
      END,
      (
        SELECT report_stats.org_id
        FROM public.player_match_stats AS report_stats
        WHERE report_stats.match_id = stats.match_id
          AND report_stats.player_id = stats.player_id
          AND report_stats.game_number = stats.game_number
          AND report_stats.org_id IN (matches.home_org_id, matches.away_org_id)
        ORDER BY report_stats.created_at, report_stats.id
        LIMIT 1
      ),
      CASE
        WHEN stats.won IS TRUE THEN matches.winner_org_id
        WHEN stats.won IS FALSE AND matches.winner_org_id = matches.home_org_id
          THEN matches.away_org_id
        WHEN stats.won IS FALSE AND matches.winner_org_id = matches.away_org_id
          THEN matches.home_org_id
      END,
      CASE
        WHEN players.org_id IN (matches.home_org_id, matches.away_org_id)
          THEN players.org_id
      END
    ) AS org_id
  FROM public.player_stats AS stats
  JOIN public.matches AS matches ON matches.id = stats.match_id
  JOIN public.players AS players ON players.id = stats.player_id
  LEFT JOIN public.pending_stat_records AS pending
    ON pending.id = stats.pending_stat_record_id
)
UPDATE public.player_stats AS stats
SET season_id = attribution.season_id,
    org_id = attribution.org_id,
    division_id = attribution.division_id
FROM attribution
WHERE attribution.id = stats.id
  AND attribution.season_id IS NOT NULL
  AND attribution.org_id IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM public.season_orgs AS teams
    WHERE teams.season_id = attribution.season_id
      AND teams.org_id = attribution.org_id
      AND teams.division_id = attribution.division_id
  );

ALTER TABLE public.player_stats
  ADD CONSTRAINT player_stats_attribution_tuple_check
    CHECK (
      (season_id IS NULL AND org_id IS NULL AND division_id IS NULL)
      OR (season_id IS NOT NULL AND org_id IS NOT NULL AND division_id IS NOT NULL)
    ),
  ADD CONSTRAINT player_stats_season_id_fkey
    FOREIGN KEY (season_id) REFERENCES public.seasons(id),
  ADD CONSTRAINT player_stats_season_org_division_fkey
    FOREIGN KEY (season_id, org_id, division_id)
    REFERENCES public.season_orgs(season_id, org_id, division_id);

CREATE INDEX idx_player_stats_player_season
  ON public.player_stats (player_id, season_id);

CREATE INDEX idx_player_stats_game_team
  ON public.player_stats (match_id, org_id, division_id);

CREATE OR REPLACE FUNCTION public.set_player_stat_game_attribution()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_match public.matches%ROWTYPE;
  v_payload jsonb;
  v_org_id text;
BEGIN
  SELECT * INTO v_match
  FROM public.matches
  WHERE id = NEW.match_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = '23503',
      MESSAGE = 'Official player stats require a known match.';
  END IF;
  IF v_match.season_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Official player stats require a season-scoped match.';
  END IF;

  v_org_id := NULLIF(btrim(COALESCE(NEW.org_id, '')), '');

  IF v_org_id IS NULL AND NEW.pending_stat_record_id IS NOT NULL THEN
    SELECT COALESCE(records.stats_json, records.extracted_json)
    INTO v_payload
    FROM public.pending_stat_records AS records
    WHERE records.id = NEW.pending_stat_record_id;

    IF jsonb_typeof(v_payload) = 'object'
      AND jsonb_typeof(v_payload -> 'org_id') = 'string' THEN
      v_org_id := NULLIF(btrim(v_payload ->> 'org_id'), '');
    END IF;
  END IF;

  IF v_org_id IS NULL THEN
    v_org_id := CASE
      WHEN NEW.won IS TRUE THEN v_match.winner_org_id
      WHEN NEW.won IS FALSE AND v_match.winner_org_id = v_match.home_org_id
        THEN v_match.away_org_id
      WHEN NEW.won IS FALSE AND v_match.winner_org_id = v_match.away_org_id
        THEN v_match.home_org_id
    END;
  END IF;

  IF v_org_id IS NULL THEN
    SELECT players.org_id INTO v_org_id
    FROM public.players
    WHERE players.id = NEW.player_id;
  END IF;

  IF v_org_id IS NULL
    OR v_org_id NOT IN (v_match.home_org_id, v_match.away_org_id) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Official player stat organization must be a team in the match.';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.season_orgs AS teams
    WHERE teams.season_id = v_match.season_id
      AND teams.org_id = v_org_id
      AND teams.division_id = v_match.division_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23503',
      MESSAGE = 'Official player stat attribution requires a valid season team.';
  END IF;

  NEW.season_id := v_match.season_id;
  NEW.org_id := v_org_id;
  NEW.division_id := v_match.division_id;
  RETURN NEW;
END;
$$;

CREATE TRIGGER player_stats_game_attribution
  BEFORE INSERT OR UPDATE OF
    match_id, player_id, pending_stat_record_id, won, season_id, org_id, division_id
  ON public.player_stats
  FOR EACH ROW
  EXECUTE FUNCTION public.set_player_stat_game_attribution();

REVOKE ALL ON FUNCTION public.set_player_stat_game_attribution()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_player_stat_game_attribution()
  TO service_role;

COMMENT ON COLUMN public.player_stats.season_id IS
  'Immutable season-at-game-time attribution for player-owned official stats.';
COMMENT ON COLUMN public.player_stats.org_id IS
  'Organization/team represented in the match; later roster changes do not rewrite it.';
COMMENT ON COLUMN public.player_stats.division_id IS
  'Division represented in the match at publication time.';
COMMENT ON FUNCTION public.set_player_stat_game_attribution() IS
  'Requires complete match-scoped historical attribution on new or corrected official player_stats rows.';
