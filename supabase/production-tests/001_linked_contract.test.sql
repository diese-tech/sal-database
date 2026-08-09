BEGIN;

SET LOCAL search_path TO extensions, public, storage, pg_catalog;

SELECT plan(70);

SELECT ok(
  (SELECT count(*) = 41
   FROM pg_class c
   JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')),
  'the released public table set is exact'
);

SELECT has_table('public', 'bug_reports', 'the private bug report table is deployed');
SELECT has_table(
  'public', 'bug_report_messages', 'the private bug report message table is deployed'
);
SELECT has_table(
  'public', 'bug_report_rate_limits', 'the durable bug report rate-limit table is deployed'
);
SELECT has_table(
  'public', 'bug_report_abuse_decisions', 'the durable bug report decision table is deployed'
);

SELECT has_table('public', 'scouter_matches', 'the scouter match table is deployed');
SELECT has_table('public', 'scouter_games', 'the scouter game table is deployed');
SELECT has_table(
  'public', 'scouter_game_participants', 'the scouter participant table is deployed'
);
SELECT has_table(
  'public', 'scouter_game_drafts', 'the private scouter review draft table is deployed'
);
SELECT has_table(
  'public', 'scouter_game_corrections', 'the private scouter correction receipt table is deployed'
);
SELECT ok(
  (
    SELECT array_agg(columns.column_name::text ORDER BY columns.column_name)
      @> ARRAY['revision', 'updated_at', 'updated_by_discord_id']::text[]
    FROM information_schema.columns AS columns
    WHERE columns.table_schema = 'public'
      AND columns.table_name = 'scouter_games'
  ),
  'scouter games expose optimistic correction metadata'
);
SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.scouter_game_corrections'::regclass)
    AND NOT has_table_privilege('anon', 'public.scouter_game_corrections', 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated', 'public.scouter_game_corrections', 'SELECT,INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.scouter_game_corrections', 'SELECT')
    AND NOT has_table_privilege('service_role', 'public.scouter_game_corrections', 'INSERT,UPDATE,DELETE'),
  'scouter correction receipts are private and application-immutable'
);
SELECT has_function(
  'public', 'correct_scouter_game',
  ARRAY['text', 'text', 'integer', 'text', 'text', 'jsonb'],
  'the atomic scouter correction RPC exists'
);
SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.correct_scouter_game(text,text,integer,text,text,jsonb)', 'EXECUTE'
  )
    AND NOT has_function_privilege(
      'authenticated', 'public.correct_scouter_game(text,text,integer,text,text,jsonb)', 'EXECUTE'
    )
    AND has_function_privilege(
      'service_role', 'public.correct_scouter_game(text,text,integer,text,text,jsonb)', 'EXECUTE'
    ),
  'only the service role can execute admin-authorized scouter corrections'
);
SELECT has_function(
  'public', 'preview_organization_merge', ARRAY['text', 'text'],
  'the organization merge preview RPC exists'
);
SELECT has_function(
  'public', 'merge_organization', ARRAY['text', 'text', 'text'],
  'the transactional organization merge RPC exists'
);
SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.preview_organization_merge(text,text)', 'EXECUTE'
  )
    AND NOT has_function_privilege(
      'authenticated', 'public.preview_organization_merge(text,text)', 'EXECUTE'
    )
    AND has_function_privilege(
      'service_role', 'public.preview_organization_merge(text,text)', 'EXECUTE'
    )
    AND NOT has_function_privilege(
      'anon', 'public.merge_organization(text,text,text)', 'EXECUTE'
    )
    AND NOT has_function_privilege(
      'authenticated', 'public.merge_organization(text,text,text)', 'EXECUTE'
    )
    AND has_function_privilege(
      'service_role', 'public.merge_organization(text,text,text)', 'EXECUTE'
    ),
  'organization merge RPCs are service-role-only'
);
SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.scouter_game_drafts'::regclass)
    AND NOT has_table_privilege('anon', 'public.scouter_game_drafts', 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated', 'public.scouter_game_drafts', 'SELECT,INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.scouter_game_drafts', 'SELECT,INSERT,UPDATE,DELETE'),
  'private scouter review drafts are service-role-only'
);
SELECT has_function(
  'public', 'create_scouter_game_draft',
  ARRAY['text', 'text', 'integer', 'text', 'text', 'jsonb', 'text'],
  'the durable scouter draft creation RPC exists'
);
SELECT has_function(
  'public', 'revise_scouter_game_draft', ARRAY['text', 'text', 'integer', 'jsonb'],
  'the host-scoped scouter draft revision RPC exists'
);
SELECT has_function(
  'public', 'cancel_scouter_game_draft', ARRAY['text', 'text'],
  'the idempotent scouter draft cancellation RPC exists'
);
SELECT has_function(
  'public', 'confirm_scouter_game_draft', ARRAY['text', 'text', 'integer', 'text'],
  'the atomic scouter draft confirmation RPC exists'
);
SELECT ok(
  NOT has_function_privilege(
    'anon', 'public.create_scouter_game_draft(text,text,integer,text,text,jsonb,text)', 'EXECUTE'
  )
    AND NOT has_function_privilege(
      'authenticated', 'public.confirm_scouter_game_draft(text,text,integer,text)', 'EXECUTE'
    )
    AND has_function_privilege(
      'service_role', 'public.create_scouter_game_draft(text,text,integer,text,text,jsonb,text)', 'EXECUTE'
    )
    AND has_function_privilege(
      'service_role', 'public.confirm_scouter_game_draft(text,text,integer,text)', 'EXECUTE'
    ),
  'scouter draft transitions are service-role-only'
);
SELECT ok(
  (
    SELECT bool_and(c.relrowsecurity)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('scouter_matches', 'scouter_games', 'scouter_game_participants')
  ),
  'RLS is enabled on every scouter table'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'public.scouter_matches',
      'public.scouter_games',
      'public.scouter_game_participants'
    ]) AS scouter_table(name)
    WHERE NOT has_table_privilege('anon', scouter_table.name, 'SELECT')
      OR NOT has_table_privilege('authenticated', scouter_table.name, 'SELECT')
  ),
  'client roles can read every scouter table'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'public.scouter_matches',
      'public.scouter_games',
      'public.scouter_game_participants'
    ]) AS scouter_table(name)
    WHERE has_table_privilege('anon', scouter_table.name, 'INSERT,UPDATE,DELETE')
      OR has_table_privilege('authenticated', scouter_table.name, 'INSERT,UPDATE,DELETE')
  ),
  'client roles cannot mutate scouter tables directly'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'public.scouter_matches',
      'public.scouter_games',
      'public.scouter_game_participants'
    ]) AS scouter_table(name)
    WHERE NOT (
      has_table_privilege('service_role', scouter_table.name, 'INSERT')
      AND has_table_privilege('service_role', scouter_table.name, 'SELECT')
      AND has_table_privilege('service_role', scouter_table.name, 'UPDATE')
      AND has_table_privilege('service_role', scouter_table.name, 'DELETE')
    )
  ),
  'service_role owns the scouter write boundary'
);
SELECT ok(
  (SELECT count(*) <= 1 FROM public.seasons WHERE is_current),
  'at most one season is current'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'players'
      AND column_name = 'avatar_url'
      AND data_type = 'text'
      AND is_nullable = 'YES'
  )
  AND EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.players'::regclass
      AND conname = 'players_avatar_url_discord_cdn_check'
  ),
  'players expose the nullable, Discord-CDN-constrained avatar URL'
);
SELECT ok(
  EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'registrations'
      AND column_name = 'avatar_url'
      AND data_type = 'text'
      AND is_nullable = 'YES'
  )
  AND EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.registrations'::regclass
      AND conname = 'registrations_avatar_url_discord_cdn_check'
  ),
  'registrations preserve the nullable, Discord-CDN-constrained signup avatar URL'
);

SELECT ok(
  (
    SELECT count(*) = 4
    FROM pg_trigger
    WHERE tgname IN (
      'season_orgs_identity_availability_guard',
      'season_rosters_identity_availability_guard',
      'players_active_participation_archive_guard',
      'orgs_active_participation_archive_guard'
    )
      AND NOT tgisinternal
  ),
  'season identity availability is enforced at both assignment and archive boundaries'
);
SELECT has_index(
  'public',
  'season_rosters',
  'season_rosters_one_active_captain_per_org_idx',
  'each season organization has at most one active captain'
);
SELECT is(
  (
    SELECT string_agg(attribute.attname, ',' ORDER BY key_column.ordinality)
    FROM pg_constraint AS constraint_row
    CROSS JOIN LATERAL unnest(constraint_row.conkey) WITH ORDINALITY AS key_column(attnum, ordinality)
    JOIN pg_attribute AS attribute
      ON attribute.attrelid = constraint_row.conrelid
     AND attribute.attnum = key_column.attnum
    WHERE constraint_row.conrelid = 'public.season_orgs'::regclass
      AND constraint_row.contype = 'p'
  ),
  'season_id,org_id,division_id',
  'season team identity is scoped by season, organization, and division'
);
SELECT ok(
  (
    SELECT pg_get_indexdef(index_row.indexrelid)
      LIKE '%(season_id, org_id, division_id)%'
    FROM pg_index AS index_row
    WHERE index_row.indexrelid = 'public.season_rosters_one_active_captain_per_org_idx'::regclass
  ),
  'captain uniqueness is scoped to each divisional season team'
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
SELECT ok(
  (
    SELECT array_agg(columns.column_name::text ORDER BY columns.column_name)
      @> ARRAY['division_id', 'org_id', 'season_id']::text[]
    FROM information_schema.columns AS columns
    WHERE columns.table_schema = 'public'
      AND columns.table_name = 'player_stats'
  ),
  'player_stats exposes the released game-time attribution tuple'
);
SELECT has_trigger(
  'public', 'player_stats', 'player_stats_game_attribution',
  'new official player stats require historical attribution'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM public.player_stats AS stats
    WHERE num_nulls(stats.season_id, stats.org_id, stats.division_id)
      NOT IN (0, 3)
  ),
  'production contains no partially attributed official player stat rows'
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
