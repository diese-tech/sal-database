BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, storage, pg_catalog;

SELECT plan(6);

SELECT ok(
  EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id = 'match-screenshots'
      AND name = 'match-screenshots'
      AND public
      AND file_size_limit = 10485760
  ),
  'the match-screenshots bucket configuration is reproducible'
);
SELECT ok(
  (SELECT allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']::text[]
   FROM storage.buckets
   WHERE id = 'match-screenshots'),
  'the screenshot MIME allowlist matches production'
);
SELECT ok(
  (SELECT count(*) = 2
   FROM pg_policies
   WHERE schemaname = 'storage'
     AND tablename = 'objects'),
  'the two application-owned Storage policies are present'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'public_read_match_screenshots'
      AND roles = ARRAY['anon']::name[]
      AND cmd = 'SELECT'
  ),
  'anonymous screenshot reads match production'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'service_role_storage_match_screenshots'
      AND roles = ARRAY['service_role']::name[]
      AND cmd = 'ALL'
  ),
  'service-role screenshot access matches production'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND roles && ARRAY['authenticated', 'public']::name[]
  ),
  'no additional client role receives a Storage policy'
);

SELECT * FROM finish();
ROLLBACK;
