BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(8);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.captain_tokens'::regclass
      AND conname = 'captain_tokens_draft_room_id_org_id_key'
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.captain_tokens'::regclass
      AND conname = 'captain_tokens_token_hash_key'
      AND contype = 'u'
  ),
  'captain tokens are unique by token hash rather than room and organization'
);

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES (
  'captain-token-season', 'Captain Token Season', 'pre-season',
  '2026-08-01', '2026-09-30', false
);

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient,
  primary_color, accent_gradient
) VALUES
  ('captain-token-org-a', 'Captain Token Org A', 'CTA', 'terra', 'CA', 'from-black to-white', '#000000', 'from-black to-white'),
  ('captain-token-org-b', 'Captain Token Org B', 'CTB', 'terra', 'CB', 'from-black to-white', '#000000', 'from-black to-white');

INSERT INTO public.draft_rooms (
  id, season_id, division_id, status, base_order
) VALUES (
  'captain-token-room', 'captain-token-season', 'terra', 'pending',
  '["captain-token-org-a", "captain-token-org-b"]'::jsonb
);

INSERT INTO public.captain_tokens (
  id, draft_room_id, org_id, token_hash, expires_at
) VALUES
  ('captain-token-a-primary', 'captain-token-room', 'captain-token-org-a', 'captain-token-hash-a-primary', now() + interval '1 hour'),
  ('captain-token-a-backup', 'captain-token-room', 'captain-token-org-a', 'captain-token-hash-a-backup', now() + interval '2 hours'),
  ('captain-token-a-expired', 'captain-token-room', 'captain-token-org-a', 'captain-token-hash-a-expired', now() - interval '1 hour'),
  ('captain-token-b-primary', 'captain-token-room', 'captain-token-org-b', 'captain-token-hash-b-primary', now() + interval '1 hour');

SELECT ok(
  (SELECT count(*) = 3
   FROM public.captain_tokens
   WHERE draft_room_id = 'captain-token-room'
     AND org_id = 'captain-token-org-a'),
  'multiple independently consumable tokens can coexist for one room and organization'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.captain_tokens
    WHERE draft_room_id = 'captain-token-room'
      AND org_id = 'captain-token-org-a'
      AND token_hash = 'captain-token-hash-a-primary'
  )
  AND EXISTS (
    SELECT 1 FROM public.captain_tokens
    WHERE draft_room_id = 'captain-token-room'
      AND org_id = 'captain-token-org-b'
      AND token_hash = 'captain-token-hash-b-primary'
  ),
  'distinct organizations retain separate token scopes in the same draft room'
);

SELECT throws_ok(
  $$INSERT INTO public.captain_tokens (
      id, draft_room_id, org_id, token_hash, expires_at
    ) VALUES (
      'captain-token-duplicate-hash', 'captain-token-room', 'captain-token-org-b',
      'captain-token-hash-a-primary', now() + interval '1 hour'
    )$$,
  '23505',
  'duplicate key value violates unique constraint "captain_tokens_token_hash_key"',
  'one token hash cannot resolve to two room or organization scopes'
);

CREATE TEMP TABLE captain_token_first_consumption AS
WITH consumed AS (
  DELETE FROM public.captain_tokens
  WHERE token_hash = 'captain-token-hash-a-primary'
    AND expires_at > now()
  RETURNING draft_room_id, org_id
)
SELECT * FROM consumed;

SELECT ok(
  (SELECT count(*) = 1 FROM captain_token_first_consumption)
  AND EXISTS (
    SELECT 1 FROM captain_token_first_consumption
    WHERE draft_room_id = 'captain-token-room'
      AND org_id = 'captain-token-org-a'
  ),
  'atomic consumption returns the one room and organization bound to the token'
);

CREATE TEMP TABLE captain_token_replay AS
WITH consumed AS (
  DELETE FROM public.captain_tokens
  WHERE token_hash = 'captain-token-hash-a-primary'
    AND expires_at > now()
  RETURNING draft_room_id, org_id
)
SELECT * FROM consumed;

SELECT ok(
  (SELECT count(*) = 0 FROM captain_token_replay)
  AND EXISTS (
    SELECT 1 FROM public.captain_tokens
    WHERE token_hash = 'captain-token-hash-a-backup'
      AND expires_at > now()
  ),
  'a consumed token cannot be replayed and consuming it leaves same-scope backup tokens valid'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.captain_tokens
    WHERE token_hash = 'captain-token-hash-b-primary'
      AND draft_room_id = 'captain-token-room'
      AND org_id = 'captain-token-org-b'
      AND expires_at > now()
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.captain_tokens
    WHERE token_hash = 'captain-token-hash-a-backup'
      AND org_id = 'captain-token-org-b'
  ),
  'consumption and lookup of an organization A token cannot affect or resolve as organization B'
);

CREATE TEMP TABLE captain_token_expired_consumption AS
WITH consumed AS (
  DELETE FROM public.captain_tokens
  WHERE token_hash = 'captain-token-hash-a-expired'
    AND expires_at > now()
  RETURNING id
)
SELECT * FROM consumed;

SELECT ok(
  (SELECT count(*) = 0 FROM captain_token_expired_consumption)
  AND EXISTS (
    SELECT 1 FROM public.captain_tokens
    WHERE token_hash = 'captain-token-hash-a-expired'
  ),
  'expired tokens cannot be consumed and do not interfere with valid credentials'
);

SELECT * FROM finish();
ROLLBACK;
