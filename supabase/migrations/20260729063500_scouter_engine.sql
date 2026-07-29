CREATE TABLE public.scouter_matches (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  season_id text NOT NULL REFERENCES public.seasons(id),
  hosted_by_discord_id text NOT NULL,
  hosted_at timestamptz NOT NULL DEFAULT now(),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT scouter_matches_host_check CHECK (btrim(hosted_by_discord_id) <> '')
);

CREATE TABLE public.scouter_games (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  scouter_match_id text NOT NULL
    REFERENCES public.scouter_matches(id) ON DELETE CASCADE,
  game_ordinal integer NOT NULL,
  smite_match_id text UNIQUE,
  game_mode text,
  winning_side text,
  match_length_seconds integer,
  scoreboard_image_path text NOT NULL,
  details_image_path text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT scouter_games_match_ordinal_key
    UNIQUE (scouter_match_id, game_ordinal),
  CONSTRAINT scouter_games_ordinal_check CHECK (game_ordinal > 0),
  CONSTRAINT scouter_games_smite_match_id_check
    CHECK (smite_match_id IS NULL OR btrim(smite_match_id) <> ''),
  CONSTRAINT scouter_games_winning_side_check
    CHECK (winning_side IN ('order', 'chaos')),
  CONSTRAINT scouter_games_match_length_check
    CHECK (match_length_seconds IS NULL OR match_length_seconds >= 0),
  CONSTRAINT scouter_games_scoreboard_path_check
    CHECK (btrim(scoreboard_image_path) <> ''),
  CONSTRAINT scouter_games_details_path_check
    CHECK (btrim(details_image_path) <> '')
);

CREATE TABLE public.scouter_game_participants (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  scouter_game_id text NOT NULL
    REFERENCES public.scouter_games(id) ON DELETE CASCADE,
  side text NOT NULL,
  raw_ign text NOT NULL,
  player_id text REFERENCES public.players(id) ON DELETE SET NULL,
  god_id text REFERENCES public.gods(id),
  role text,
  player_level integer,
  kills integer NOT NULL DEFAULT 0,
  deaths integer NOT NULL DEFAULT 0,
  assists integer NOT NULL DEFAULT 0,
  gpm integer,
  player_damage bigint,
  minion_damage bigint,
  jungle_damage bigint,
  structure_damage bigint,
  damage_taken bigint,
  damage_mitigated bigint,
  self_healing bigint,
  ally_healing bigint,
  wards_placed integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by_discord_id text,
  CONSTRAINT scouter_game_participants_game_side_ign_key
    UNIQUE (scouter_game_id, side, raw_ign),
  CONSTRAINT scouter_game_participants_side_check
    CHECK (side IN ('order', 'chaos')),
  CONSTRAINT scouter_game_participants_raw_ign_check CHECK (btrim(raw_ign) <> ''),
  CONSTRAINT scouter_game_participants_role_check
    CHECK (role IS NULL OR role IN ('solo', 'jungle', 'mid', 'support', 'carry')),
  CONSTRAINT scouter_game_participants_level_check
    CHECK (player_level IS NULL OR player_level BETWEEN 1 AND 20),
  CONSTRAINT scouter_game_participants_kda_check
    CHECK (kills >= 0 AND deaths >= 0 AND assists >= 0),
  CONSTRAINT scouter_game_participants_gpm_check CHECK (gpm IS NULL OR gpm >= 0),
  CONSTRAINT scouter_game_participants_damage_check CHECK (
    (player_damage IS NULL OR player_damage >= 0)
    AND (minion_damage IS NULL OR minion_damage >= 0)
    AND (jungle_damage IS NULL OR jungle_damage >= 0)
    AND (structure_damage IS NULL OR structure_damage >= 0)
    AND (damage_taken IS NULL OR damage_taken >= 0)
    AND (damage_mitigated IS NULL OR damage_mitigated >= 0)
  ),
  CONSTRAINT scouter_game_participants_healing_check CHECK (
    (self_healing IS NULL OR self_healing >= 0)
    AND (ally_healing IS NULL OR ally_healing >= 0)
  ),
  CONSTRAINT scouter_game_participants_wards_check
    CHECK (wards_placed IS NULL OR wards_placed >= 0),
  CONSTRAINT scouter_game_participants_updated_by_check
    CHECK (updated_by_discord_id IS NULL OR btrim(updated_by_discord_id) <> '')
);

CREATE INDEX scouter_matches_season_hosted_idx
  ON public.scouter_matches (season_id, hosted_at DESC);

CREATE INDEX scouter_games_match_idx
  ON public.scouter_games (scouter_match_id, game_ordinal);

CREATE INDEX scouter_participants_player_idx
  ON public.scouter_game_participants (player_id)
  WHERE player_id IS NOT NULL;

ALTER TABLE public.scouter_matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scouter_games ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scouter_game_participants ENABLE ROW LEVEL SECURITY;

CREATE POLICY scouter_matches_public_read
  ON public.scouter_matches FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY scouter_games_public_read
  ON public.scouter_games FOR SELECT
  TO anon, authenticated
  USING (true);

CREATE POLICY scouter_game_participants_public_read
  ON public.scouter_game_participants FOR SELECT
  TO anon, authenticated
  USING (true);

REVOKE ALL ON TABLE public.scouter_matches FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.scouter_games FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.scouter_game_participants FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.scouter_matches TO anon, authenticated;
GRANT SELECT ON TABLE public.scouter_games TO anon, authenticated;
GRANT SELECT ON TABLE public.scouter_game_participants TO anon, authenticated;

GRANT ALL ON TABLE public.scouter_matches TO service_role;
GRANT ALL ON TABLE public.scouter_games TO service_role;
GRANT ALL ON TABLE public.scouter_game_participants TO service_role;

COMMENT ON TABLE public.scouter_matches IS
  'Preseason scouter sessions hosted through Discord and scoped to one season.';
COMMENT ON TABLE public.scouter_games IS
  'Per-game metadata and immutable source-image keys for a scouter session.';
COMMENT ON TABLE public.scouter_game_participants IS
  'OCR-extracted per-player game statistics with optional canonical identity links.';
