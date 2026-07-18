BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(7);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND NOT c.relrowsecurity
  ),
  'RLS is enabled on every public application table'
);
SELECT ok(
  (SELECT count(*) = 22 FROM pg_policies WHERE schemaname = 'public'),
  'the 22 verified public-schema policies are present'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('admin_users', 'admin_audit_log', 'audit_logs', 'pending_actions', 'pending_stat_records')
      AND roles && ARRAY['anon', 'authenticated', 'public']::name[]
  ),
  'sensitive administration and approval tables expose no client policy'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'match_reports'
      AND policyname = 'service_role_all_match_reports'
      AND roles = ARRAY['service_role']::name[]
  ),
  'match reports retain their service-role policy'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'player_match_stats'
      AND policyname = 'public_read_player_match_stats'
      AND roles = ARRAY['anon']::name[]
      AND cmd = 'SELECT'
  ),
  'player match stats retain their anonymous read policy'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND (
        has_function_privilege('anon', p.oid, 'EXECUTE')
        OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
      )
  ),
  'SECURITY DEFINER functions are not executable by client roles'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
  ),
  'SECURITY DEFINER functions remain executable by service_role'
);

SELECT * FROM finish();
ROLLBACK;
