-- SALbot additive migration
-- The sal-draft-league schema (seasons, divisions, orgs, players, matches, standings,
-- admin_audit_log, admin_users, draft_rooms, etc.) already exists.
-- This migration ONLY adds SALbot-specific tables and extends existing tables.

-- ── Extend matches with SALbot operational columns ────────────────────────────

ALTER TABLE matches ADD COLUMN IF NOT EXISTS winner_org_id TEXT REFERENCES orgs(id);
ALTER TABLE matches ADD COLUMN IF NOT EXISTS score TEXT;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS proof_thread_id TEXT;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS proof_thread_url TEXT;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS screenshot_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS screenshot_expected INTEGER;

-- ── Pending actions (approval queue) ─────────────────────────────────────────
-- Every captain command creates one. No match mutation happens without one.

CREATE TABLE IF NOT EXISTS pending_actions (
  id                          TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  type                        TEXT NOT NULL
    CHECK (type IN ('match_result', 'reschedule', 'admin_review')),
  status                      TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'pending_info', 'approved', 'denied', 'cancelled')),
  requested_by_discord_id     TEXT NOT NULL,
  match_id                    TEXT REFERENCES matches(id),
  division_id                 TEXT REFERENCES divisions(id),
  payload_json                JSONB NOT NULL DEFAULT '{}',
  admin_note                  TEXT,
  source_discord_message_url  TEXT,
  admin_review_message_id     TEXT,
  public_receipt_message_id   TEXT,
  approved_by_discord_id      TEXT,
  approved_at                 TIMESTAMPTZ,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── Audit logs (immutable, append-only) ──────────────────────────────────────
-- Written on every SALbot mutation. Never updated, never deleted.
-- Distinct from admin_audit_log (website admin actions) — this records bot-driven mutations.

CREATE TABLE IF NOT EXISTS audit_logs (
  id                  TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  action_type         TEXT NOT NULL,
  entity_type         TEXT NOT NULL,
  entity_id           TEXT NOT NULL,
  pending_action_id   TEXT REFERENCES pending_actions(id),
  actor_discord_id    TEXT NOT NULL,
  old_value_json      JSONB,
  new_value_json      JSONB,
  note                TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── Pending stat records (ForgeLens OCR output — not official stats) ──────────
-- Phase 4. Exists in schema now to avoid a future additive migration on matches.

CREATE TABLE IF NOT EXISTS pending_stat_records (
  id                      TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  match_id                TEXT NOT NULL REFERENCES matches(id),
  player_id               TEXT REFERENCES players(id),
  screenshot_url          TEXT NOT NULL,
  extracted_json          JSONB NOT NULL DEFAULT '{}',
  stats_json              JSONB,
  confidence              NUMERIC(4,3) NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
  source                  TEXT NOT NULL DEFAULT 'ocr'
    CHECK (source IN ('ocr', 'manual')),
  status                  TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected', 'corrected', 'superseded')),
  reviewed_by_discord_id  TEXT,
  reviewed_at             TIMESTAMPTZ,
  correction_note         TEXT,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── Official player stats (written only after admin approval) ─────────────────

CREATE TABLE IF NOT EXISTS player_stats (
  id                      TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
  match_id                TEXT NOT NULL REFERENCES matches(id),
  player_id               TEXT NOT NULL REFERENCES players(id),
  pending_stat_record_id  TEXT REFERENCES pending_stat_records(id),
  kills                   INTEGER,
  deaths                  INTEGER,
  assists                 INTEGER,
  damage_dealt            INTEGER,
  healing_done            INTEGER,
  god_played              TEXT,
  role                    TEXT,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (match_id, player_id)
);

-- ── Indexes ───────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_pending_actions_match_id ON pending_actions(match_id);
CREATE INDEX IF NOT EXISTS idx_pending_actions_status ON pending_actions(status);
CREATE INDEX IF NOT EXISTS idx_pending_actions_type ON pending_actions(type);
CREATE INDEX IF NOT EXISTS idx_pending_actions_requester ON pending_actions(requested_by_discord_id);

CREATE INDEX IF NOT EXISTS idx_audit_logs_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_pending_action ON audit_logs(pending_action_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_actor ON audit_logs(actor_discord_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_pending_stat_records_match ON pending_stat_records(match_id);
CREATE INDEX IF NOT EXISTS idx_pending_stat_records_status ON pending_stat_records(status);

CREATE INDEX IF NOT EXISTS idx_player_stats_match ON player_stats(match_id);
CREATE INDEX IF NOT EXISTS idx_player_stats_player ON player_stats(player_id);

-- ── RLS ───────────────────────────────────────────────────────────────────────
-- service_role bypasses RLS. Bot uses service_role key for all mutations.
-- No public read access to operational tables.

ALTER TABLE pending_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE pending_stat_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE player_stats ENABLE ROW LEVEL SECURITY;
