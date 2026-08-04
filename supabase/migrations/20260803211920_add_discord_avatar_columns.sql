-- Historical production reconciliation for the avatar columns introduced
-- alongside sal-site #236. Production already records this exact migration
-- version; keeping the idempotent DDL here makes fresh environments reproduce
-- the same schema without rewriting or reverting the linked migration ledger.

ALTER TABLE public.players
  ADD COLUMN IF NOT EXISTS avatar_url text;

ALTER TABLE public.registrations
  ADD COLUMN IF NOT EXISTS avatar_url text;
