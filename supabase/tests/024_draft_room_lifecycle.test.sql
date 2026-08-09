BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(25);

SELECT ok(
  to_regprocedure('public.delete_pending_draft_room(text,text)') IS NOT NULL
    AND to_regprocedure('public.void_draft_room(text,text,text)') IS NOT NULL,
  'draft room delete and void RPCs exist'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.delete_pending_draft_room(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.delete_pending_draft_room(text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.void_draft_room(text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.void_draft_room(text,text,text)', 'EXECUTE'),
  'client roles cannot call draft room lifecycle RPCs'
);

SELECT ok(
  has_function_privilege('service_role', 'public.delete_pending_draft_room(text,text)', 'EXECUTE')
    AND has_function_privilege('service_role', 'public.void_draft_room(text,text,text)', 'EXECUTE'),
  'service_role can call draft room lifecycle RPCs'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.draft_rooms'::regclass
      AND conname = 'draft_rooms_status_check'
      AND pg_get_constraintdef(oid) LIKE '%voided%'
  )
    AND EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'draft_rooms'
        AND column_name = 'voided_by_discord_id'
    ),
  'draft rooms expose durable void state and actor metadata'
);

INSERT INTO public.admin_users (discord_id, role, discord_username, display_name)
VALUES
  ('draft-lifecycle-admin', 'admin', 'draft-lifecycle-admin', 'Draft Lifecycle Admin'),
  ('draft-lifecycle-super', 'super_admin', 'draft-lifecycle-super', 'Draft Lifecycle Superadmin');

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
SELECT
  'draft-lifecycle-season-' || n,
  'Draft Lifecycle Season ' || n,
  'pre-season',
  '2026-08-01',
  '2026-09-30',
  false
FROM generate_series(1, 10) AS n;

INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
) VALUES (
  'draft-lifecycle-org', 'Draft Lifecycle Org', 'DLO', 'terra', 'DL',
  'from-black to-white', '#000000', 'from-black to-white'
);

INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status, is_captain
) VALUES (
  'draft-lifecycle-player', 'draft-lifecycle-org', 'draft-lifecycle-player',
  'Draft Lifecycle Player', 'DP', 'from-black to-white', 'Support', 'terra',
  'org-affiliated', false
);

INSERT INTO public.draft_rooms (id, season_id, division_id, status)
VALUES ('draft-delete-empty', 'draft-lifecycle-season-1', 'terra', 'pending');

CREATE TEMP TABLE draft_delete_result AS
SELECT public.delete_pending_draft_room(
  'draft-delete-empty', 'draft-lifecycle-admin'
) AS result;

SELECT is(
  (SELECT result ->> 'code' FROM draft_delete_result),
  'deleted',
  'a regular admin can delete an unused pending room'
);

SELECT ok(
  NOT EXISTS (SELECT 1 FROM public.draft_rooms WHERE id = 'draft-delete-empty'),
  'pending room is removed'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE action_type = 'draft_room_deleted'
      AND entity_id = 'draft-delete-empty'
      AND actor_discord_id = 'draft-lifecycle-admin'
  )
    AND EXISTS (
      SELECT 1 FROM public.admin_audit_log
      WHERE action = 'delete_pending_draft_room'
        AND entity_id = 'draft-delete-empty'
        AND payload ->> 'actorDiscordId' = 'draft-lifecycle-admin'
    ),
  'pending deletion records actor-attributed evidence in both audit systems'
);

SELECT is(
  public.delete_pending_draft_room(
    'draft-delete-empty', 'draft-lifecycle-admin'
  ) ->> 'code',
  'already_deleted',
  'pending deletion retries are idempotent'
);

INSERT INTO public.draft_rooms (id, season_id, division_id, status)
VALUES ('draft-delete-pick', 'draft-lifecycle-season-2', 'terra', 'pending');
INSERT INTO public.draft_picks (draft_room_id, pick_number, org_id, player_id)
VALUES ('draft-delete-pick', 1, 'draft-lifecycle-org', 'draft-lifecycle-player');

SELECT throws_ok(
  $$SELECT public.delete_pending_draft_room('draft-delete-pick', 'draft-lifecycle-admin')$$,
  '23514',
  'Pending draft room has draft picks and must be preserved.',
  'pending room with picks cannot be deleted'
);

SELECT ok(
  EXISTS (SELECT 1 FROM public.draft_rooms WHERE id = 'draft-delete-pick')
    AND EXISTS (SELECT 1 FROM public.draft_picks WHERE draft_room_id = 'draft-delete-pick'),
  'pick blocker leaves room and history intact'
);

INSERT INTO public.draft_rooms (id, season_id, division_id, status)
VALUES ('draft-delete-token', 'draft-lifecycle-season-3', 'terra', 'pending');
INSERT INTO public.captain_tokens (id, draft_room_id, org_id, token_hash, expires_at)
VALUES (
  'draft-lifecycle-token', 'draft-delete-token', 'draft-lifecycle-org', 'hash',
  now() + interval '1 hour'
);

SELECT throws_ok(
  $$SELECT public.delete_pending_draft_room('draft-delete-token', 'draft-lifecycle-admin')$$,
  '23514',
  'Pending draft room has captain tokens and must be preserved.',
  'pending room with captain tokens cannot be deleted'
);

INSERT INTO public.draft_rooms (id, season_id, division_id, status)
VALUES ('draft-delete-shortlist', 'draft-lifecycle-season-4', 'terra', 'pending');
INSERT INTO public.captain_shortlists (draft_room_id, org_id, player_id, position)
VALUES ('draft-delete-shortlist', 'draft-lifecycle-org', 'draft-lifecycle-player', 1);

SELECT throws_ok(
  $$SELECT public.delete_pending_draft_room('draft-delete-shortlist', 'draft-lifecycle-admin')$$,
  '23514',
  'Pending draft room has captain shortlists and must be preserved.',
  'pending room with captain shortlists cannot be deleted'
);

INSERT INTO public.draft_rooms (id, season_id, division_id, status)
VALUES ('draft-delete-active', 'draft-lifecycle-season-5', 'terra', 'active');

SELECT throws_ok(
  $$SELECT public.delete_pending_draft_room('draft-delete-active', 'draft-lifecycle-admin')$$,
  '23514',
  'Only an unused pending draft room can be deleted.',
  'opened room cannot be hard-deleted'
);

INSERT INTO public.draft_rooms (id, season_id, division_id, status, started_at)
VALUES (
  'draft-void-active', 'draft-lifecycle-season-6', 'terra', 'active', now()
);
INSERT INTO public.draft_picks (draft_room_id, pick_number, org_id, player_id)
VALUES ('draft-void-active', 1, 'draft-lifecycle-org', 'draft-lifecycle-player');

CREATE TEMP TABLE draft_void_result AS
SELECT public.void_draft_room(
  'draft-void-active', 'draft-lifecycle-admin', 'Bad captain order'
) AS result;

SELECT is(
  (SELECT result ->> 'code' FROM draft_void_result),
  'voided',
  'a regular admin can void an opened room'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.draft_rooms
    WHERE id = 'draft-void-active'
      AND status = 'voided'
      AND voided_at IS NOT NULL
      AND voided_by_discord_id = 'draft-lifecycle-admin'
      AND void_reason = 'Bad captain order'
  )
    AND EXISTS (
      SELECT 1 FROM public.draft_picks
      WHERE draft_room_id = 'draft-void-active' AND pick_number = 1
    ),
  'voiding preserves the room and its competitive history'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.audit_logs
    WHERE action_type = 'draft_room_voided'
      AND entity_id = 'draft-void-active'
      AND actor_discord_id = 'draft-lifecycle-admin'
      AND new_value_json ->> 'reason' = 'Bad captain order'
  )
    AND EXISTS (
      SELECT 1 FROM public.admin_audit_log
      WHERE action = 'void_draft_room' AND entity_id = 'draft-void-active'
    ),
  'voiding records actor-attributed evidence in both audit systems'
);

SELECT is(
  public.void_draft_room(
    'draft-void-active', 'draft-lifecycle-admin', 'Retry after timeout'
  ) ->> 'code',
  'already_voided',
  'void retries are idempotent'
);

INSERT INTO public.draft_rooms (id, season_id, division_id, status)
VALUES (
  'draft-void-replacement', 'draft-lifecycle-season-6', 'terra', 'pending'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.draft_rooms
    WHERE season_id = 'draft-lifecycle-season-6' AND division_id = 'terra'
      AND id = 'draft-void-replacement' AND status = 'pending'
  ),
  'a voided room no longer blocks its replacement'
);

INSERT INTO public.draft_rooms (id, season_id, division_id, status, completed_at)
VALUES (
  'draft-void-complete', 'draft-lifecycle-season-7', 'terra', 'complete', now()
);

SELECT throws_ok(
  $$SELECT public.void_draft_room('draft-void-complete', 'draft-lifecycle-admin', 'No longer needed')$$,
  '23514',
  'Completed draft rooms are immutable and cannot be voided.',
  'completed room cannot be voided'
);

INSERT INTO public.draft_rooms (id, season_id, division_id, status)
VALUES ('draft-void-pending', 'draft-lifecycle-season-8', 'terra', 'pending');

SELECT throws_ok(
  $$SELECT public.void_draft_room('draft-void-pending', 'draft-lifecycle-admin', 'Wrong setup')$$,
  '23514',
  'Pending draft rooms must use the delete-pending workflow.',
  'pending room cannot bypass the guarded delete workflow'
);

SELECT throws_ok(
  $$SELECT public.void_draft_room('draft-void-pending', 'not-an-admin', 'Wrong setup')$$,
  '42501',
  'Only a SAL admin can manage draft room lifecycle.',
  'non-admin actors cannot manage draft room lifecycle'
);

INSERT INTO public.draft_rooms (id, season_id, division_id, status, started_at)
VALUES ('draft-void-rollback', 'draft-lifecycle-season-9', 'terra', 'active', now());

CREATE FUNCTION pg_temp.fail_draft_lifecycle_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.entity_id IN ('draft-void-rollback', 'draft-delete-rollback') THEN
    RAISE EXCEPTION 'forced audit failure';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER draft_lifecycle_force_audit_failure
BEFORE INSERT ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_draft_lifecycle_audit();

SELECT throws_ok(
  $$SELECT public.void_draft_room('draft-void-rollback', 'draft-lifecycle-admin', 'Rollback test')$$,
  'P0001',
  'forced audit failure',
  'void transaction fails when immutable audit insertion fails'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM public.draft_rooms
    WHERE id = 'draft-void-rollback' AND status = 'active'
      AND voided_at IS NULL AND voided_by_discord_id IS NULL
  )
    AND NOT EXISTS (
      SELECT 1 FROM public.admin_audit_log WHERE entity_id = 'draft-void-rollback'
    ),
  'audit failure rolls the complete void transaction back'
);

DROP TRIGGER draft_lifecycle_force_audit_failure ON public.audit_logs;

INSERT INTO public.draft_rooms (id, season_id, division_id, status)
VALUES ('draft-delete-rollback', 'draft-lifecycle-season-10', 'terra', 'pending');

CREATE TRIGGER draft_lifecycle_force_audit_failure
BEFORE INSERT ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_draft_lifecycle_audit();

SELECT throws_ok(
  $$SELECT public.delete_pending_draft_room('draft-delete-rollback', 'draft-lifecycle-admin')$$,
  'P0001',
  'forced audit failure',
  'delete transaction fails when immutable audit insertion fails'
);

SELECT ok(
  EXISTS (SELECT 1 FROM public.draft_rooms WHERE id = 'draft-delete-rollback')
    AND NOT EXISTS (
      SELECT 1 FROM public.admin_audit_log WHERE entity_id = 'draft-delete-rollback'
    ),
  'audit failure rolls the complete pending deletion transaction back'
);

DROP TRIGGER draft_lifecycle_force_audit_failure ON public.audit_logs;

SELECT * FROM finish();
ROLLBACK;
