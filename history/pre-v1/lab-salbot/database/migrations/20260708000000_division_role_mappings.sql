-- Store Discord division role mappings that admins manage from bot commands.
-- Role IDs are not secrets; keeping them in Supabase lets league admins update
-- mappings without deployment access.

CREATE TABLE IF NOT EXISTS division_role_mappings (
  division_id           TEXT PRIMARY KEY REFERENCES divisions(id),
  discord_role_id       TEXT NOT NULL,
  updated_by_discord_id TEXT NOT NULL,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_division_role_mappings_role
  ON division_role_mappings(discord_role_id);

ALTER TABLE division_role_mappings ENABLE ROW LEVEL SECURITY;
