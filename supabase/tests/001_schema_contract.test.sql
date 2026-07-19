BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(20);

SELECT ok(
  (SELECT count(*) = 32
   FROM pg_class c
   JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')),
  'the contract contains all 32 application tables'
);
SELECT ok(to_regclass('public.players') IS NOT NULL, 'players exists');
SELECT ok(to_regclass('public.matches') IS NOT NULL, 'matches exists');
SELECT ok(to_regclass('public.pending_actions') IS NOT NULL, 'pending_actions exists');
SELECT ok(to_regclass('public.pending_stat_records') IS NOT NULL, 'pending_stat_records exists');
SELECT ok(to_regclass('public.match_reports') IS NOT NULL, 'match_reports exists');
SELECT ok(to_regclass('public.player_match_stats') IS NOT NULL, 'player_match_stats exists');
SELECT ok(to_regclass('public.season_orgs') IS NOT NULL, 'season_orgs exists');
SELECT ok(to_regclass('public.season_rosters') IS NOT NULL, 'season_rosters exists');
SELECT ok(to_regclass('public.operation_outbox') IS NOT NULL, 'operation_outbox exists');
SELECT has_column('public', 'seasons', 'is_current', 'seasons has an explicit current marker');
SELECT ok(
  (SELECT count(*) = 16
   FROM pg_proc p
   JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'),
  'the contract contains the 16 verified production functions'
);
SELECT ok(to_regprocedure('public.replace_standings(jsonb)') IS NOT NULL, 'replace_standings exists');
SELECT ok(to_regprocedure('public.replace_match_report_stats(uuid,jsonb)') IS NOT NULL, 'replace_match_report_stats exists');
SELECT ok(to_regprocedure('public.set_current_season(text)') IS NOT NULL, 'set_current_season exists');
SELECT ok(
  to_regprocedure('public.create_pending_action(text,text,text,text,jsonb)') IS NOT NULL
    AND to_regprocedure('public.resolve_pending_action(text,text,text,text)') IS NOT NULL
    AND to_regprocedure('public.resolve_pending_stat_record(text,text,text,text)') IS NOT NULL
    AND to_regprocedure('public.claim_operation_outbox(text,integer)') IS NOT NULL
    AND to_regprocedure('public.complete_operation_outbox(uuid,text,text)') IS NOT NULL
    AND to_regprocedure('public.fail_operation_outbox(uuid,text,text,integer)') IS NOT NULL,
  'the transactional decision and outbox RPCs exist'
);
SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'match_reports'
      AND c.conname = 'match_reports_match_id_key'
      AND c.contype = 'u'
  ),
  'match_reports keeps its production match uniqueness constraint'
);
SELECT ok(
  EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'player_match_stats'
      AND c.conname = 'player_match_stats_match_report_id_fkey'
      AND pg_get_constraintdef(c.oid) LIKE '%ON DELETE CASCADE%'
  ),
  'player_match_stats keeps the cascading report foreign key'
);
SELECT ok(
  (SELECT array_agg(id ORDER BY id) = ARRAY['lunar', 'solar', 'terra']::text[]
   FROM public.divisions),
  'the deterministic seed contains the three active divisions'
);
SELECT ok(
  (SELECT count(*) > 0 AND bool_and(length(trim(id)) > 0 AND length(trim(name)) > 0)
   FROM public.gods),
  'the live god catalog is non-empty and contains valid identities'
);

SELECT * FROM finish();
ROLLBACK;
