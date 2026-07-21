BEGIN;

SET LOCAL search_path TO extensions, public, storage, pg_catalog;

SELECT plan(35);

SELECT ok(
  (SELECT count(*) = 32
   FROM pg_class c
   JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')),
  'the released public table set is exact'
);
SELECT ok(
  (SELECT count(*) <= 1 FROM public.seasons WHERE is_current),
  'at most one season is current'
);

SELECT has_table('public', 'operation_outbox', 'the durable operation outbox exists');
SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.operation_outbox'::regclass),
  'RLS is enabled on the operation outbox'
);
SELECT ok(
  (
    SELECT array_agg(a.attname ORDER BY a.attnum) @> ARRAY[
      'id', 'event_type', 'aggregate_type', 'aggregate_id', 'payload',
      'deduplication_key', 'state', 'lease_owner', 'lease_expires_at',
      'attempts', 'available_at', 'last_error', 'external_id', 'completed_at'
    ]::name[]
    FROM pg_attribute a
    WHERE a.attrelid = 'public.operation_outbox'::regclass
      AND a.attnum > 0
      AND NOT a.attisdropped
  ),
  'the operation outbox exposes the released lease and retry contract'
);
SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.operation_outbox'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%pending%processing%completed%dead_letter%'
  ),
  'the operation outbox state constraint is present'
);

SELECT has_function(
  'public', 'create_pending_action', ARRAY['text', 'text', 'text', 'text', 'jsonb'],
  'the pending-action creation RPC exists'
);
SELECT has_function(
  'public', 'resolve_pending_action', ARRAY['text', 'text', 'text', 'text'],
  'the pending-action decision RPC exists'
);
SELECT has_function(
  'public', 'resolve_pending_stat_record', ARRAY['text', 'text', 'text', 'text'],
  'the stat decision RPC exists'
);
SELECT has_function(
  'public', 'claim_operation_outbox', ARRAY['text', 'integer'],
  'the outbox claim RPC exists'
);
SELECT has_function(
  'public', 'complete_operation_outbox', ARRAY['uuid', 'text', 'text'],
  'the outbox completion RPC exists'
);
SELECT has_function(
  'public', 'fail_operation_outbox', ARRAY['uuid', 'text', 'text', 'integer'],
  'the outbox failure RPC exists'
);
SELECT has_function(
  'public', 'enqueue_operation_outbox', ARRAY['text', 'text', 'text', 'text', 'text', 'jsonb'],
  'the idempotent outbox enqueue helper exists'
);
SELECT has_function(
  'public', 'resolve_registration_review', ARRAY['text', 'text', 'text', 'text'],
  'the transactional registration review RPC exists'
);
SELECT has_function(
  'public', 'resolve_match_report_review', ARRAY['uuid', 'text', 'jsonb'],
  'the transactional match-report review RPC exists'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'create_pending_action', 'resolve_pending_action', 'resolve_pending_stat_record',
        'claim_operation_outbox', 'complete_operation_outbox', 'fail_operation_outbox',
        'enqueue_operation_outbox', 'resolve_registration_review',
        'resolve_match_report_review'
      )
      AND (
        has_function_privilege('anon', p.oid, 'EXECUTE')
        OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
      )
  ),
  'client roles cannot execute the decision or outbox RPCs'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) acl
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'create_pending_action', 'resolve_pending_action', 'resolve_pending_stat_record',
        'claim_operation_outbox', 'complete_operation_outbox', 'fail_operation_outbox',
        'enqueue_operation_outbox', 'resolve_registration_review',
        'resolve_match_report_review'
      )
      AND acl.grantee = 0
      AND acl.privilege_type = 'EXECUTE'
  ),
  'PUBLIC has no implicit execution grant on decision or outbox RPCs'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'create_pending_action', 'resolve_pending_action', 'resolve_pending_stat_record',
        'claim_operation_outbox', 'complete_operation_outbox', 'fail_operation_outbox',
        'enqueue_operation_outbox', 'resolve_registration_review',
        'resolve_match_report_review'
      )
      AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
  ),
  'service_role can execute every decision and outbox RPC'
);
SELECT ok(
  NOT has_table_privilege('anon', 'public.operation_outbox', 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated', 'public.operation_outbox', 'SELECT,INSERT,UPDATE,DELETE'),
  'client roles have no direct outbox privileges'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_class c
    CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) acl
    WHERE c.oid = 'public.operation_outbox'::regclass
      AND acl.grantee = 0
  ),
  'PUBLIC has no implicit table privilege on the operation outbox'
);
SELECT ok(
  has_table_privilege('service_role', 'public.operation_outbox', 'SELECT,INSERT,UPDATE,DELETE'),
  'service_role owns the outbox data boundary'
);

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

SELECT has_table('public', 'items', 'the SMITE item catalog exists');
SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.items'::regclass)
    AND has_table_privilege('anon', 'public.items', 'SELECT')
    AND has_table_privilege('authenticated', 'public.items', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.items', 'INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated', 'public.items', 'INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.items', 'INSERT,SELECT,UPDATE,DELETE'),
  'clients can read items while only the service role can write them'
);
SELECT ok(
  (
    SELECT count(*) > 0
      AND bool_and(length(btrim(id)) > 0 AND length(btrim(name)) > 0)
    FROM public.gods
  ),
  'the live god catalog is non-empty and contains valid identities'
);
SELECT ok(
  (
    SELECT count(*) > 0
      AND count(*) FILTER (WHERE active) > 0
      AND bool_and(length(btrim(id)) > 0 AND length(btrim(name)) > 0)
    FROM public.items
  ),
  'the live item catalog is non-empty and contains valid identities'
);
SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.match_reports'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%gaia%'
      AND pg_get_constraintdef(oid) LIKE '%terra%'
  ),
  'match reports retain historical Gaia values and accept Terra'
);

SELECT * FROM finish();
ROLLBACK;
