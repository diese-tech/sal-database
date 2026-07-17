-- Player alias / IGN change support
-- display_alias defaults to null (falls back to ign in display logic)
-- When a player's IGN changes, both ign and display_alias are updated together.

ALTER TABLE players ADD COLUMN IF NOT EXISTS display_alias TEXT;

-- Extend the type constraint to support alias_change requests through the
-- shared pending_actions approval pipeline.
ALTER TABLE pending_actions DROP CONSTRAINT IF EXISTS pending_actions_type_check;
ALTER TABLE pending_actions ADD CONSTRAINT pending_actions_type_check
  CHECK (type IN ('match_result', 'reschedule', 'admin_review', 'alias_change'));
