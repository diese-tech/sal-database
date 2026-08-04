BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(26);

SELECT has_table(
  'public', 'scouter_game_drafts',
  'private scouter review drafts are part of the canonical schema'
);
SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.scouter_game_drafts'::regclass),
  'RLS is enabled on scouter review drafts'
);
SELECT ok(
  NOT has_table_privilege('anon', 'public.scouter_game_drafts', 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated', 'public.scouter_game_drafts', 'SELECT,INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.scouter_game_drafts', 'SELECT,INSERT,UPDATE,DELETE'),
  'only service_role can access private scouter review drafts'
);
SELECT ok(
  to_regprocedure('public.create_scouter_game_draft(text,text,integer,text,text,jsonb,text)') IS NOT NULL
    AND to_regprocedure('public.revise_scouter_game_draft(text,text,integer,jsonb)') IS NOT NULL
    AND to_regprocedure('public.cancel_scouter_game_draft(text,text)') IS NOT NULL
    AND to_regprocedure('public.confirm_scouter_game_draft(text,text,integer,text)') IS NOT NULL,
  'the create, revise, cancel, and confirm RPCs exist'
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
  'draft RPC execution is service-role-only'
);

INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES ('scouter-review-season', 'Scouter Review Season', 'pre-season', '2026-08-01', '2026-08-31', false);

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient, primary_role, status
)
SELECT
  'scouter-review-player-' || player_number,
  'scouter-review-user-' || player_number,
  'Known ' || player_number,
  'K' || player_number,
  'from-black to-white',
  'Solo',
  'active'
FROM generate_series(1, 10) player_number;

INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient, primary_role, status
) VALUES
  ('scouter-review-ambiguous-a', 'scouter-review-ambiguous-a', 'Ambiguous', 'AA', 'from-black to-white', 'Solo', 'active'),
  ('scouter-review-ambiguous-b', 'scouter-review-ambiguous-b', 'Ambiguous', 'AB', 'from-black to-white', 'Solo', 'active');

CREATE FUNCTION pg_temp.scouter_review_game()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'smiteMatchId', 'scouter-review-smite-1',
    'gameMode', 'Conquest',
    'winningSide', 'order',
    'matchLengthSeconds', 1800,
    'participants', jsonb_build_array(
      jsonb_build_object('side', 'order', 'rawIgn', 'Known 1', 'godName', 'Achilles', 'role', 'solo', 'kills', 8, 'deaths', 2, 'assists', 7),
      jsonb_build_object('side', 'order', 'rawIgn', 'Known 2', 'role', 'jungle', 'kills', 3, 'deaths', 4, 'assists', 10),
      jsonb_build_object('side', 'order', 'rawIgn', 'Known 3', 'role', 'mid', 'kills', 7, 'deaths', 3, 'assists', 9),
      jsonb_build_object('side', 'order', 'rawIgn', 'Known 4', 'role', 'support', 'kills', 1, 'deaths', 5, 'assists', 15),
      jsonb_build_object('side', 'order', 'rawIgn', 'Known 5', 'role', 'carry', 'kills', 9, 'deaths', 1, 'assists', 6),
      jsonb_build_object('side', 'chaos', 'rawIgn', 'Known 6', 'role', 'solo', 'kills', 2, 'deaths', 6, 'assists', 5),
      jsonb_build_object('side', 'chaos', 'rawIgn', 'Known 7', 'role', 'jungle', 'kills', 4, 'deaths', 5, 'assists', 4),
      jsonb_build_object('side', 'chaos', 'rawIgn', 'Known 8', 'role', 'mid', 'kills', 5, 'deaths', 7, 'assists', 3),
      jsonb_build_object('side', 'chaos', 'rawIgn', 'Known 9', 'role', 'support', 'kills', 0, 'deaths', 8, 'assists', 11),
      jsonb_build_object('side', 'chaos', 'rawIgn', 'Known 10', 'role', 'carry', 'kills', 6, 'deaths', 4, 'assists', 2)
    )
  );
$$;

SELECT is(
  jsonb_array_length(public.scouter_game_draft_diagnostics(
    jsonb_set(pg_temp.scouter_review_game(), '{participants,1,rawIgn}', '"Known 1"'::jsonb)
  ) -> 'duplicateIgns'),
  1,
  'duplicate IGNs are visible before persistence'
);
SELECT is(
  jsonb_array_length(public.scouter_game_draft_diagnostics(
    jsonb_set(pg_temp.scouter_review_game(), '{participants,2,rawIgn}', '"Missing Player"'::jsonb)
  ) -> 'unlinkedIgns'),
  1,
  'unrecognized IGNs are visible before persistence'
);
SELECT is(
  jsonb_array_length(public.scouter_game_draft_diagnostics(
    jsonb_set(pg_temp.scouter_review_game(), '{participants,3,rawIgn}', '"Ambiguous"'::jsonb)
  ) -> 'ambiguousIgns'),
  1,
  'ambiguous canonical identity matches are visible before persistence'
);

CREATE TEMP TABLE scouter_review_created AS
SELECT public.create_scouter_game_draft(
  'scouter-review-season',
  'scouter-review-host',
  1,
  'scouters/review/scoreboard-1.png',
  'scouters/review/details-1.png',
  jsonb_set(pg_temp.scouter_review_game(), '{participants,2,rawIgn}', '"Missing Player"'::jsonb),
  NULL
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'created'
      AND result ->> 'status' = 'pending'
      AND result ->> 'revision' = '1'
      AND jsonb_array_length(result -> 'diagnostics' -> 'unlinkedIgns') = 1
   FROM scouter_review_created),
  'extraction creates a pending durable draft with identity diagnostics'
);
SELECT ok(
  (SELECT count(*) = 1 FROM public.scouter_game_drafts WHERE hosted_by_discord_id = 'scouter-review-host')
    AND NOT EXISTS (SELECT 1 FROM public.scouter_matches WHERE hosted_by_discord_id = 'scouter-review-host')
    AND NOT EXISTS (
      SELECT 1 FROM public.scouter_games WHERE scoreboard_image_path = 'scouters/review/scoreboard-1.png'
    ),
  'draft creation writes no canonical match, game, or participant rows'
);
SELECT is(
  (SELECT count(*)::integer FROM public.audit_logs
   WHERE action_type = 'scouter_game_draft_created' AND actor_discord_id = 'scouter-review-host'),
  1,
  'draft creation appends one privacy-safe audit event'
);

SELECT is(
  public.create_scouter_game_draft(
    'scouter-review-season', 'scouter-review-host', 1,
    'scouters/review/scoreboard-1.png', 'scouters/review/details-1.png',
    jsonb_set(pg_temp.scouter_review_game(), '{participants,2,rawIgn}', '"Missing Player"'::jsonb),
    NULL
  ) ->> 'code',
  'existing',
  'an exact extraction retry returns the existing draft'
);
SELECT is(
  (SELECT count(*)::integer FROM public.audit_logs
   WHERE action_type = 'scouter_game_draft_created' AND actor_discord_id = 'scouter-review-host'),
  1,
  'an exact extraction retry does not duplicate its audit event'
);
SELECT throws_ok(
  $$SELECT public.create_scouter_game_draft(
    'scouter-review-season', 'different-host', 1,
    'scouters/review/scoreboard-1.png', 'scouters/review/details-1.png',
    pg_temp.scouter_review_game(), NULL
  )$$,
  '23514',
  'Existing scouter draft evidence belongs to a different host or game scope.',
  'evidence idempotency cannot be claimed by a different host'
);

CREATE TEMP TABLE scouter_review_duplicate_revision AS
SELECT public.revise_scouter_game_draft(
  (SELECT result ->> 'draftId' FROM scouter_review_created),
  'scouter-review-host',
  1,
  jsonb_set(pg_temp.scouter_review_game(), '{participants,1,rawIgn}', '"Known 1"'::jsonb)
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'revised'
      AND result ->> 'revision' = '2'
      AND jsonb_array_length(result -> 'diagnostics' -> 'duplicateIgns') = 1
   FROM scouter_review_duplicate_revision),
  'host edits are durable and increment an optimistic revision'
);
SELECT throws_ok(
  format(
    $$SELECT public.confirm_scouter_game_draft(%L, 'scouter-review-host', 2, 'override duplicate')$$,
    (SELECT result ->> 'draftId' FROM scouter_review_created)
  ),
  '23505',
  'Duplicate IGNs must be corrected before confirmation.',
  'duplicate IGNs cannot become canonical even with an override reason'
);
SELECT throws_ok(
  format(
    $$SELECT public.revise_scouter_game_draft(%L, 'scouter-review-host', 1, %L::jsonb)$$,
    (SELECT result ->> 'draftId' FROM scouter_review_created),
    pg_temp.scouter_review_game()::text
  ),
  '40001',
  'Scouter draft revision is stale.',
  'stale edits fail closed'
);

CREATE TEMP TABLE scouter_review_unlinked_revision AS
SELECT public.revise_scouter_game_draft(
  (SELECT result ->> 'draftId' FROM scouter_review_created),
  'scouter-review-host',
  2,
  jsonb_set(pg_temp.scouter_review_game(), '{participants,2,rawIgn}', '"Missing Player"'::jsonb)
) AS result;

SELECT throws_ok(
  format(
    $$SELECT public.confirm_scouter_game_draft(%L, 'scouter-review-host', 3, NULL)$$,
    (SELECT result ->> 'draftId' FROM scouter_review_created)
  ),
  '23514',
  'Unlinked or ambiguous IGNs require correction or an explicit override reason.',
  'unlinked identities require correction or an explicit override'
);

SELECT public.revise_scouter_game_draft(
  (SELECT result ->> 'draftId' FROM scouter_review_created),
  'scouter-review-host',
  3,
  pg_temp.scouter_review_game()
);

CREATE TEMP TABLE scouter_review_confirmed AS
SELECT public.confirm_scouter_game_draft(
  (SELECT result ->> 'draftId' FROM scouter_review_created),
  'scouter-review-host',
  4,
  NULL
) AS result;

SELECT ok(
  (SELECT result ->> 'code' = 'inserted'
      AND result ->> 'status' = 'confirmed'
      AND result ->> 'identityOverrideApplied' = 'false'
   FROM scouter_review_confirmed)
    AND (SELECT count(*) = 1 FROM public.scouter_matches WHERE hosted_by_discord_id = 'scouter-review-host')
    AND (SELECT count(*) = 1 FROM public.scouter_games WHERE smite_match_id = 'scouter-review-smite-1')
    AND (SELECT count(*) = 10 FROM public.scouter_game_participants participant
      JOIN public.scouter_games game ON game.id = participant.scouter_game_id
      WHERE game.smite_match_id = 'scouter-review-smite-1'),
  'explicit confirmation persists the reviewed ten-player game atomically'
);
SELECT ok(
  (SELECT count(*) = 1 FROM public.audit_logs
   WHERE action_type = 'scouter_game_ingested' AND actor_discord_id = 'scouter-review-host')
    AND (SELECT count(*) = 1 FROM public.audit_logs
      WHERE action_type = 'scouter_game_draft_confirmed' AND actor_discord_id = 'scouter-review-host'),
  'confirmation preserves the canonical ingest audit and adds its terminal transition'
);
SELECT is(
  public.confirm_scouter_game_draft(
    (SELECT result ->> 'draftId' FROM scouter_review_created),
    'scouter-review-host',
    4,
    NULL
  ) ->> 'code',
  'already_confirmed',
  'a confirmation retry returns the existing terminal result'
);
SELECT ok(
  (SELECT count(*) = 1 FROM public.scouter_games WHERE smite_match_id = 'scouter-review-smite-1')
    AND (SELECT count(*) = 1 FROM public.audit_logs
      WHERE action_type = 'scouter_game_draft_confirmed' AND actor_discord_id = 'scouter-review-host'),
  'a confirmation retry writes no duplicate canonical or audit rows'
);

CREATE TEMP TABLE scouter_review_override_created AS
SELECT public.create_scouter_game_draft(
  'scouter-review-season',
  'scouter-review-override-host',
  1,
  'scouters/review/scoreboard-override.png',
  'scouters/review/details-override.png',
  jsonb_set(
    jsonb_set(pg_temp.scouter_review_game(), '{smiteMatchId}', '"scouter-review-smite-override"'::jsonb),
    '{participants,2,rawIgn}',
    '"Missing Player"'::jsonb
  ),
  NULL
) AS result;

SELECT ok(
  (public.confirm_scouter_game_draft(
    (SELECT result ->> 'draftId' FROM scouter_review_override_created),
    'scouter-review-override-host',
    1,
    'Verified against the screenshots; player registration is pending.'
  ) ->> 'identityOverrideApplied')::boolean
    AND EXISTS (
      SELECT 1 FROM public.scouter_game_drafts
      WHERE hosted_by_discord_id = 'scouter-review-override-host'
        AND status = 'confirmed'
        AND identity_override_reason IS NOT NULL
    ),
  'an explicit reason permits an authorized unlinked-identity override and records it'
);

CREATE TEMP TABLE scouter_review_cancel_created AS
SELECT public.create_scouter_game_draft(
  'scouter-review-season',
  'scouter-review-cancel-host',
  1,
  'scouters/review/scoreboard-cancel.png',
  'scouters/review/details-cancel.png',
  jsonb_set(pg_temp.scouter_review_game(), '{smiteMatchId}', '"scouter-review-smite-cancel"'::jsonb),
  NULL
) AS result;

SELECT is(
  public.cancel_scouter_game_draft(
    (SELECT result ->> 'draftId' FROM scouter_review_cancel_created),
    'scouter-review-cancel-host'
  ) ->> 'code',
  'cancelled',
  'the host can cancel a pending draft without persistence'
);
SELECT ok(
  NOT EXISTS (SELECT 1 FROM public.scouter_matches WHERE hosted_by_discord_id = 'scouter-review-cancel-host')
    AND (SELECT count(*) = 1 FROM public.audit_logs
      WHERE action_type = 'scouter_game_draft_cancelled'
        AND actor_discord_id = 'scouter-review-cancel-host'),
  'cancellation writes one audit transition and no canonical scouter rows'
);
SELECT is(
  public.cancel_scouter_game_draft(
    (SELECT result ->> 'draftId' FROM scouter_review_cancel_created),
    'scouter-review-cancel-host'
  ) ->> 'code',
  'already_cancelled',
  'cancellation is idempotent'
);

SELECT * FROM finish();
ROLLBACK;
