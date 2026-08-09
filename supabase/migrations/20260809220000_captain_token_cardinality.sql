-- A draft team can have several independently revocable one-time access links
-- (captain, organization owner, and emergency backup). Scope each credential
-- by its cryptographic hash instead of limiting a room/organization to one row.

ALTER TABLE public.captain_tokens
  DROP CONSTRAINT captain_tokens_draft_room_id_org_id_key;

-- The unique constraint gives verify/consume lookups exactly one room and
-- organization. Installation fails closed if historical duplicate hashes exist.
ALTER TABLE public.captain_tokens
  ADD CONSTRAINT captain_tokens_token_hash_key UNIQUE (token_hash);

-- The constraint owns an equivalent unique btree, so the baseline lookup index
-- would only duplicate write and storage cost.
DROP INDEX public.captain_tokens_hash_idx;

COMMENT ON CONSTRAINT captain_tokens_token_hash_key ON public.captain_tokens IS
  'Each one-time captain credential resolves to exactly one draft room and organization; multiple distinct credentials may share that scope.';
