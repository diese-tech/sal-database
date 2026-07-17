-- player_stats v2: per-game granularity, org_brands, gods reference table + seed, god draft stubs
-- All changes are additive — no existing rows broken.

-- ── player_stats: per-game granularity ────────────────────────────────────────

ALTER TABLE player_stats ADD COLUMN IF NOT EXISTS game_number INTEGER NOT NULL DEFAULT 1;
ALTER TABLE player_stats ADD COLUMN IF NOT EXISTS damage_mitigated INTEGER;
ALTER TABLE player_stats ADD COLUMN IF NOT EXISTS won BOOLEAN;

-- Replace (match_id, player_id) unique with (match_id, player_id, game_number)
-- so a BO3 where a player switches gods between games can be represented.
ALTER TABLE player_stats DROP CONSTRAINT IF EXISTS player_stats_match_id_player_id_key;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'player_stats_match_id_player_id_game_number_key'
      AND conrelid = 'player_stats'::regclass
  ) THEN
    ALTER TABLE player_stats
      ADD CONSTRAINT player_stats_match_id_player_id_game_number_key
      UNIQUE (match_id, player_id, game_number);
  END IF;
END $$;

-- ── matches: season scoping ────────────────────────────────────────────────────

ALTER TABLE matches ADD COLUMN IF NOT EXISTS season_id TEXT REFERENCES seasons(id);
CREATE INDEX IF NOT EXISTS idx_matches_season ON matches(season_id);

-- ── org_brands: parent org identity ───────────────────────────────────────────

CREATE TABLE IF NOT EXISTS org_brands (
  id   TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  tag  TEXT NOT NULL
);

ALTER TABLE orgs ADD COLUMN IF NOT EXISTS brand_id TEXT REFERENCES org_brands(id);

-- ── gods: reference table ──────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS gods (
  id        TEXT PRIMARY KEY,
  name      TEXT NOT NULL UNIQUE,
  class     TEXT NOT NULL CHECK (class IN ('Warrior', 'Guardian', 'Mage', 'Assassin', 'Hunter')),
  god_class TEXT NOT NULL CHECK (god_class IN ('Physical', 'Magical')),
  pantheon  TEXT
);

ALTER TABLE gods ENABLE ROW LEVEL SECURITY;

-- ── gods seed: full Smite 2 roster ────────────────────────────────────────────

INSERT INTO gods (id, name, class, god_class, pantheon) VALUES
  -- Warriors
  ('amaterasu',    'Amaterasu',    'Warrior',  'Physical', 'Japanese'),
  ('bellona',      'Bellona',      'Warrior',  'Physical', 'Roman'),
  ('cu_chulainn',  'Cu Chulainn',  'Warrior',  'Physical', 'Celtic'),
  ('gilgamesh',    'Gilgamesh',    'Warrior',  'Physical', 'Babylonian'),
  ('guan_yu',      'Guan Yu',      'Warrior',  'Physical', 'Chinese'),
  ('hercules',     'Hercules',     'Warrior',  'Physical', 'Roman'),
  ('king_arthur',  'King Arthur',  'Warrior',  'Physical', 'Arthurian'),
  ('nike',         'Nike',         'Warrior',  'Physical', 'Greek'),
  ('odin',         'Odin',         'Warrior',  'Physical', 'Norse'),
  ('osiris',       'Osiris',       'Warrior',  'Physical', 'Egyptian'),
  ('sun_wukong',   'Sun Wukong',   'Warrior',  'Physical', 'Chinese'),
  ('tyr',          'Tyr',          'Warrior',  'Physical', 'Norse'),
  ('vamana',       'Vamana',       'Warrior',  'Physical', 'Hindu'),
  -- Assassins
  ('arachne',      'Arachne',      'Assassin', 'Physical', 'Greek'),
  ('bastet',       'Bastet',       'Assassin', 'Physical', 'Egyptian'),
  ('fenrir',       'Fenrir',       'Assassin', 'Physical', 'Norse'),
  ('loki',         'Loki',         'Assassin', 'Physical', 'Norse'),
  ('mercury',      'Mercury',      'Assassin', 'Physical', 'Roman'),
  ('ne_zha',       'Ne Zha',       'Assassin', 'Physical', 'Chinese'),
  ('nemesis',      'Nemesis',      'Assassin', 'Physical', 'Greek'),
  ('serqet',       'Serqet',       'Assassin', 'Physical', 'Egyptian'),
  ('set',          'Set',          'Assassin', 'Physical', 'Egyptian'),
  ('thanatos',     'Thanatos',     'Assassin', 'Physical', 'Greek'),
  ('thor',         'Thor',         'Assassin', 'Physical', 'Norse'),
  ('tsukuyomi',    'Tsukuyomi',    'Assassin', 'Physical', 'Japanese'),
  -- Hunters
  ('anhur',        'Anhur',        'Hunter',   'Physical', 'Egyptian'),
  ('apollo',       'Apollo',       'Hunter',   'Physical', 'Greek'),
  ('artemis',      'Artemis',      'Hunter',   'Physical', 'Greek'),
  ('cernunnos',    'Cernunnos',    'Hunter',   'Physical', 'Celtic'),
  ('charybdis',    'Charybdis',    'Hunter',   'Physical', 'Greek'),
  ('cupid',        'Cupid',        'Hunter',   'Physical', 'Roman'),
  ('hou_yi',       'Hou Yi',       'Hunter',   'Physical', 'Chinese'),
  ('izanami',      'Izanami',      'Hunter',   'Physical', 'Japanese'),
  ('jing_wei',     'Jing Wei',     'Hunter',   'Physical', 'Chinese'),
  ('medusa',       'Medusa',       'Hunter',   'Physical', 'Greek'),
  ('neith',        'Neith',        'Hunter',   'Physical', 'Egyptian'),
  ('rama',         'Rama',         'Hunter',   'Physical', 'Hindu'),
  ('skadi',        'Skadi',        'Hunter',   'Physical', 'Norse'),
  ('ullr',         'Ullr',         'Hunter',   'Physical', 'Norse'),
  ('xbalanque',    'Xbalanque',    'Hunter',   'Physical', 'Mayan'),
  -- Guardians
  ('ares',         'Ares',         'Guardian', 'Magical',  'Greek'),
  ('athena',       'Athena',       'Guardian', 'Magical',  'Greek'),
  ('atlas',        'Atlas',        'Guardian', 'Magical',  'Greek'),
  ('cerberus',     'Cerberus',     'Guardian', 'Magical',  'Greek'),
  ('charon',       'Charon',       'Guardian', 'Magical',  'Greek'),
  ('ganesha',      'Ganesha',      'Guardian', 'Magical',  'Hindu'),
  ('geb',          'Geb',          'Guardian', 'Magical',  'Egyptian'),
  ('jormungandr',  'Jormungandr',  'Guardian', 'Magical',  'Norse'),
  ('khepri',       'Khepri',       'Guardian', 'Magical',  'Egyptian'),
  ('kumbhakarna',  'Kumbhakarna',  'Guardian', 'Magical',  'Hindu'),
  ('nut',          'Nut',          'Guardian', 'Magical',  'Egyptian'),
  ('sobek',        'Sobek',        'Guardian', 'Magical',  'Egyptian'),
  ('xing_tian',    'Xing Tian',    'Guardian', 'Magical',  'Chinese'),
  ('ymir',         'Ymir',         'Guardian', 'Magical',  'Norse'),
  -- Mages
  ('agni',         'Agni',         'Mage',     'Magical',  'Hindu'),
  ('ah_puch',      'Ah Puch',      'Mage',     'Magical',  'Mayan'),
  ('anubis',       'Anubis',       'Mage',     'Magical',  'Egyptian'),
  ('baba_yaga',    'Baba Yaga',    'Mage',     'Magical',  'Slavic'),
  ('baron_samedi', 'Baron Samedi', 'Mage',     'Magical',  'Voodoo'),
  ('change',       'Chang''e',     'Mage',     'Magical',  'Chinese'),
  ('chronos',      'Chronos',      'Mage',     'Magical',  'Greek'),
  ('he_bo',        'He Bo',        'Mage',     'Magical',  'Chinese'),
  ('hecate',       'Hecate',       'Mage',     'Magical',  'Greek'),
  ('hera',         'Hera',         'Mage',     'Magical',  'Greek'),
  ('hades',        'Hades',        'Mage',     'Magical',  'Greek'),
  ('isis',         'Isis',         'Mage',     'Magical',  'Egyptian'),
  ('kukulkan',     'Kukulkan',     'Mage',     'Magical',  'Mayan'),
  ('nox',          'Nox',          'Mage',     'Magical',  'Roman'),
  ('nu_wa',        'Nu Wa',        'Mage',     'Magical',  'Chinese'),
  ('persephone',   'Persephone',   'Mage',     'Magical',  'Greek'),
  ('poseidon',     'Poseidon',     'Mage',     'Magical',  'Greek'),
  ('ra',           'Ra',           'Mage',     'Magical',  'Egyptian'),
  ('scylla',       'Scylla',       'Mage',     'Magical',  'Greek'),
  ('tiamat',       'Tiamat',       'Mage',     'Magical',  'Babylonian'),
  ('zeus',         'Zeus',         'Mage',     'Magical',  'Greek'),
  ('zhong_kui',    'Zhong Kui',    'Mage',     'Magical',  'Chinese')
ON CONFLICT (id) DO NOTHING;

-- ── god_draft_sessions: stub ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS god_draft_sessions (
  id          TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  match_id    TEXT NOT NULL REFERENCES matches(id),
  game_number INTEGER NOT NULL DEFAULT 1,
  status      TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'in_progress', 'completed')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (match_id, game_number)
);

-- ── god_picks: stub ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS god_picks (
  id               TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  draft_session_id TEXT NOT NULL REFERENCES god_draft_sessions(id),
  god_id           TEXT NOT NULL REFERENCES gods(id),
  player_id        TEXT REFERENCES players(id),
  org_id           TEXT NOT NULL REFERENCES orgs(id),
  pick_order       INTEGER NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── god_bans: stub ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS god_bans (
  id               TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  draft_session_id TEXT NOT NULL REFERENCES god_draft_sessions(id),
  god_id           TEXT NOT NULL REFERENCES gods(id),
  org_id           TEXT NOT NULL REFERENCES orgs(id),
  ban_order        INTEGER NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── RLS: god draft tables (service_role only, no public access) ───────────────

ALTER TABLE god_draft_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE god_picks          ENABLE ROW LEVEL SECURITY;
ALTER TABLE god_bans           ENABLE ROW LEVEL SECURITY;

-- ── RLS: player_stats and gods public read (DO block for idempotency) ───────────
-- Note: CREATE POLICY IF NOT EXISTS is not available in this PostgreSQL build.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'player_stats' AND policyname = 'player_stats_public_read'
  ) THEN
    EXECUTE 'CREATE POLICY "player_stats_public_read" ON player_stats FOR SELECT USING (true)';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'gods' AND policyname = 'gods_public_read'
  ) THEN
    EXECUTE 'CREATE POLICY "gods_public_read" ON gods FOR SELECT USING (true)';
  END IF;
END $$;

-- ── Indexes ────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_player_stats_player    ON player_stats(player_id);
CREATE INDEX IF NOT EXISTS idx_player_stats_match_game ON player_stats(match_id, game_number);
CREATE INDEX IF NOT EXISTS idx_god_picks_god           ON god_picks(god_id);
CREATE INDEX IF NOT EXISTS idx_god_bans_god            ON god_bans(god_id);
