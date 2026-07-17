BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(3);

SELECT ok(
  (SELECT count(*) = 2
   FROM pg_publication_tables
   WHERE pubname = 'supabase_realtime'),
  'Realtime contains exactly the two verified tables'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'draft_chat_messages'
  ),
  'draft_chat_messages is published to Realtime'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'god_draft_sessions'
  ),
  'god_draft_sessions is published to Realtime'
);

SELECT * FROM finish();
ROLLBACK;
