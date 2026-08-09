BEGIN;

SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(4);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.draft_rooms'::regclass
      AND conname = 'draft_rooms_status_check'
      AND pg_get_constraintdef(oid) LIKE '%voided%'
  ),
  'draft rooms expose the terminal voided state'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'draft_rooms'
      AND indexname = 'draft_rooms_live_season_division_key'
      AND indexdef LIKE '%status = ANY%pending%active%paused%'
  ),
  'only rooms with a live lifecycle occupy the season/division slot'
);

SELECT ok(
  to_regprocedure('public.delete_pending_draft_room(text,text)') IS NOT NULL
    AND to_regprocedure('public.void_draft_room(text,text,text)') IS NOT NULL,
  'draft lifecycle RPC signatures are deployed'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.delete_pending_draft_room(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.delete_pending_draft_room(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.void_draft_room(text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.void_draft_room(text,text,text)', 'EXECUTE')
    AND has_function_privilege('service_role', 'public.delete_pending_draft_room(text,text)', 'EXECUTE')
    AND has_function_privilege('service_role', 'public.void_draft_room(text,text,text)', 'EXECUTE'),
  'draft lifecycle RPCs remain service-role-only'
);

SELECT * FROM finish();
ROLLBACK;
