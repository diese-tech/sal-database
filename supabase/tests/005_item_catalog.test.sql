BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(5);

SELECT has_table('public', 'items', 'the SMITE item catalog exists');

SELECT ok(
  (
    SELECT array_agg(
      format('%s:%s:%s', a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull)
      ORDER BY a.attnum
    ) = ARRAY[
      'id:text:t',
      'name:text:t',
      'source_url:text:f',
      'image_url:text:f',
      'active:boolean:t',
      'metadata:jsonb:t',
      'source_updated_at:timestamp with time zone:f',
      'created_at:timestamp with time zone:t',
      'updated_at:timestamp with time zone:t'
    ]::text[]
    FROM pg_attribute a
    WHERE a.attrelid = 'public.items'::regclass
      AND a.attnum > 0
      AND NOT a.attisdropped
  ),
  'items stores source-owned fields and lifecycle metadata'
);

SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.items'::regclass)
    AND has_table_privilege('anon', 'public.items', 'SELECT')
    AND has_table_privilege('authenticated', 'public.items', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.items', 'INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated', 'public.items', 'INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.items', 'INSERT,SELECT,UPDATE,DELETE')
    AND EXISTS (
      SELECT 1
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'items'
        AND policyname = 'items_public_read'
        AND cmd = 'SELECT'
        AND roles @> ARRAY['anon', 'authenticated']::name[]
    ),
  'clients can read items while only the service role can write them'
);

SELECT ok(
  (
    SELECT array_agg(conname ORDER BY conname) = ARRAY[
      'items_id_format_check',
      'items_image_url_check',
      'items_metadata_object_check',
      'items_name_check',
      'items_source_url_check'
    ]::name[]
    FROM pg_constraint
    WHERE conrelid = 'public.items'::regclass
      AND contype = 'c'
  ),
  'items reject malformed identifiers, names, URLs, and metadata'
);

SELECT ok(
  (
    SELECT count(*) = 260
      AND count(*) FILTER (WHERE active) = 260
      AND count(*) FILTER (WHERE source_url ~ '^https://www[.]smitefire[.]com/smite/item/') = 260
      AND count(*) FILTER (WHERE source_updated_at = '2026-06-30T15:41:28.712Z'::timestamptz) = 260
    FROM public.items
  ),
  'the deterministic seed contains the 260-item active catalog'
);

SELECT * FROM finish();
ROLLBACK;
