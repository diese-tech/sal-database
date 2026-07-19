BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS dblink WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(6);

DO $connect$
BEGIN
  PERFORM dblink_connect(
    'db02_setup',
    format(
      'hostaddr=%s port=%s dbname=%s user=%s password=%s',
      host(inet_server_addr()), inet_server_port(),
      current_database(), current_user, current_user
    )
  );
  PERFORM dblink_connect(
    'db02_worker_a',
    format(
      'hostaddr=%s port=%s dbname=%s user=%s password=%s',
      host(inet_server_addr()), inet_server_port(),
      current_database(), current_user, current_user
    )
  );
  PERFORM dblink_connect(
    'db02_worker_b',
    format(
      'hostaddr=%s port=%s dbname=%s user=%s password=%s',
      host(inet_server_addr()), inet_server_port(),
      current_database(), current_user, current_user
    )
  );
END;
$connect$;

DO $setup$
BEGIN
  PERFORM dblink_exec('db02_setup', $sql$
    DELETE FROM public.operation_outbox WHERE aggregate_id = '00000000-0000-0000-0000-00000000d299';
    DELETE FROM public.audit_logs
    WHERE actor_discord_id = 'db02-conc-admin'
       OR entity_id LIKE 'db02-conc-%'
       OR entity_id = '00000000-0000-0000-0000-00000000d299';
    DELETE FROM public.admin_audit_log
    WHERE entity_id LIKE 'db02-conc-%'
       OR entity_id = '00000000-0000-0000-0000-00000000d299';
    DELETE FROM public.player_match_stats WHERE match_id = 'db02-conc-match';
    DELETE FROM public.match_reports WHERE id = '00000000-0000-0000-0000-00000000d299'::uuid;
    DELETE FROM public.matches WHERE id = 'db02-conc-match';
    DELETE FROM public.players WHERE discord_id = 'db02-conc-registration-discord';
    DELETE FROM public.season_orgs WHERE season_id = 'db02-conc-season';
    DELETE FROM public.orgs WHERE id IN ('db02-conc-home', 'db02-conc-away');
    DELETE FROM public.registrations WHERE id = 'db02-conc-registration';
    DELETE FROM public.seasons WHERE id = 'db02-conc-season';
    DELETE FROM public.admin_users WHERE discord_id = 'db02-conc-admin';
    DROP FUNCTION IF EXISTS public.db02_concurrency_match_payload();

    INSERT INTO public.admin_users (
      discord_id, role, discord_username, display_name
    ) VALUES (
      'db02-conc-admin', 'admin', 'db02-conc-admin', 'DB02 Concurrency Admin'
    );
    INSERT INTO public.registrations (
      id, discord_id, discord_username, form_data
    ) VALUES (
      'db02-conc-registration', 'db02-conc-registration-discord',
      'db02-conc-registration',
      '{"ign":"DB02 Concurrent Player","primary_role":"Flex"}'::jsonb
    );
    INSERT INTO public.seasons (
      id, name, status, start_date, end_date, is_current
    ) VALUES (
      'db02-conc-season', 'DB02 Concurrency Season', 'pre-season',
      '2026-01-01', '2026-12-31', false
    );
    INSERT INTO public.orgs (
      id, name, tag, division_id, logo_initials, logo_gradient,
      primary_color, accent_gradient
    ) VALUES
      ('db02-conc-home', 'DB02 Concurrent Home', 'DCH', 'terra', 'CH', 'from-black to-white', '#000000', 'from-black to-white'),
      ('db02-conc-away', 'DB02 Concurrent Away', 'DCA', 'terra', 'CA', 'from-black to-white', '#000000', 'from-black to-white');
    INSERT INTO public.season_orgs (season_id, org_id, division_id)
    VALUES
      ('db02-conc-season', 'db02-conc-home', 'terra'),
      ('db02-conc-season', 'db02-conc-away', 'terra');
    INSERT INTO public.matches (
      id, division_id, home_org_id, away_org_id, scheduled_date,
      scheduled_time, status, week, season_id
    ) VALUES (
      'db02-conc-match', 'terra', 'db02-conc-home', 'db02-conc-away',
      '2026-09-01', '19:00', 'scheduled', 1, 'db02-conc-season'
    );
    INSERT INTO public.match_reports (
      id, match_id, season_id, division_id, status, submitted_by
    ) VALUES (
      '00000000-0000-0000-0000-00000000d299', 'db02-conc-match',
      'db02-conc-season', 'terra', 'review', 'db02-conc-submitter'
    );

    CREATE FUNCTION public.db02_concurrency_match_payload() RETURNS jsonb
    LANGUAGE sql
    IMMUTABLE
    SET search_path = pg_catalog, public
    AS $payload$
      SELECT jsonb_build_array(
        jsonb_build_object(
          'gameNumber', 1,
          'winningSide', 'home',
          'players', (
            SELECT jsonb_agg(
              jsonb_build_object(
                'playerIgn', CASE
                  WHEN player_number <= 5 THEN 'Concurrent Home ' || player_number
                  ELSE 'Concurrent Away ' || (player_number - 5)
                END,
                'side', CASE WHEN player_number <= 5 THEN 'home' ELSE 'away' END,
                'won', player_number <= 5,
                'kills', 3,
                'deaths', 2,
                'assists', 7
              ) ORDER BY player_number
            )
            FROM generate_series(1, 10) AS player_number
          )
        )
      )
    $payload$;
  $sql$);
END;
$setup$;

CREATE TEMP TABLE registration_results (worker text, result jsonb);
DO $registration_race$
BEGIN
  PERFORM dblink_exec('db02_worker_a', 'BEGIN');
  PERFORM locked.id
  FROM dblink(
    'db02_worker_a',
    $$SELECT id FROM public.registrations
      WHERE id = 'db02-conc-registration' FOR UPDATE$$
  ) AS locked(id text);
  PERFORM dblink_send_query(
    'db02_worker_b',
    $$SELECT public.resolve_registration_review(
      'db02-conc-registration', 'db02-conc-admin', 'approve', NULL
    )::text$$
  );
  PERFORM pg_sleep(0.1);
END;
$registration_race$;
SELECT is(
  dblink_is_busy('db02_worker_b'),
  1,
  'the second registration decision waits behind the first reviewer lock'
);
INSERT INTO registration_results
SELECT 'worker-a', result::jsonb
FROM dblink(
  'db02_worker_a',
  $$SELECT public.resolve_registration_review(
    'db02-conc-registration', 'db02-conc-admin', 'approve', NULL
  )::text$$
) AS response(result text);
DO $$ BEGIN PERFORM dblink_exec('db02_worker_a', 'COMMIT'); END $$;
INSERT INTO registration_results
SELECT 'worker-b', result::jsonb
FROM dblink_get_result('db02_worker_b') AS response(result text);
DO $$
BEGIN
  PERFORM result FROM dblink_get_result('db02_worker_b') AS response(result text);
END;
$$;
SELECT ok(
  (SELECT count(*) = 1 FROM registration_results WHERE result ->> 'code' = 'applied')
  AND
  (SELECT count(*) = 1 FROM registration_results WHERE result ->> 'code' = 'already_processed'),
  'concurrent registration decisions produce one mutation and one idempotent result'
);
SELECT ok(
  (SELECT verified FROM dblink(
    'db02_setup',
    $$SELECT
      (SELECT status = 'approved' AND player_id IS NOT NULL
        FROM public.registrations WHERE id = 'db02-conc-registration')
      AND (SELECT count(*) = 1 FROM public.players
        WHERE discord_id = 'db02-conc-registration-discord')
      AND (SELECT count(*) = 1 FROM public.audit_logs
        WHERE entity_type = 'registration' AND entity_id = 'db02-conc-registration')
      AND (SELECT count(*) = 1 FROM public.admin_audit_log
        WHERE entity_type = 'registration' AND entity_id = 'db02-conc-registration')$$
  ) AS verification(verified boolean)),
  'the registration race commits exactly one player link and one audit pair'
);

CREATE TEMP TABLE match_results (worker text, result jsonb);
DO $match_race$
BEGIN
  PERFORM dblink_exec('db02_worker_a', 'BEGIN');
  PERFORM locked.id
  FROM dblink(
    'db02_worker_a',
    $$SELECT id FROM public.match_reports
      WHERE id = '00000000-0000-0000-0000-00000000d299'::uuid FOR UPDATE$$
  ) AS locked(id uuid);
  PERFORM dblink_send_query(
    'db02_worker_b',
    $$SELECT public.resolve_match_report_review(
      '00000000-0000-0000-0000-00000000d299'::uuid,
      'db02-conc-admin', public.db02_concurrency_match_payload()
    )::text$$
  );
  PERFORM pg_sleep(0.1);
END;
$match_race$;
SELECT is(
  dblink_is_busy('db02_worker_b'),
  1,
  'the second match-report decision waits behind the first reviewer lock'
);
INSERT INTO match_results
SELECT 'worker-a', result::jsonb
FROM dblink(
  'db02_worker_a',
  $$SELECT public.resolve_match_report_review(
    '00000000-0000-0000-0000-00000000d299'::uuid,
    'db02-conc-admin', public.db02_concurrency_match_payload()
  )::text$$
) AS response(result text);
DO $$ BEGIN PERFORM dblink_exec('db02_worker_a', 'COMMIT'); END $$;
INSERT INTO match_results
SELECT 'worker-b', result::jsonb
FROM dblink_get_result('db02_worker_b') AS response(result text);
DO $$
BEGIN
  PERFORM result FROM dblink_get_result('db02_worker_b') AS response(result text);
END;
$$;
SELECT ok(
  (SELECT count(*) = 1 FROM match_results WHERE result ->> 'code' = 'applied')
  AND
  (SELECT count(*) = 1 FROM match_results WHERE result ->> 'code' = 'already_processed'),
  'concurrent match-report decisions produce one mutation and one idempotent result'
);
SELECT ok(
  (SELECT verified FROM dblink(
    'db02_setup',
    $$SELECT
      (SELECT status = 'completed' FROM public.matches WHERE id = 'db02-conc-match')
      AND (SELECT status = 'done' FROM public.match_reports
        WHERE id = '00000000-0000-0000-0000-00000000d299'::uuid)
      AND (SELECT count(*) = 10 FROM public.player_match_stats
        WHERE match_report_id = '00000000-0000-0000-0000-00000000d299'::uuid)
      AND (SELECT count(*) = 1 FROM public.audit_logs
        WHERE entity_type = 'match_report'
          AND entity_id = '00000000-0000-0000-0000-00000000d299')
      AND (SELECT count(*) = 1 FROM public.admin_audit_log
        WHERE entity_type = 'match_report'
          AND entity_id = '00000000-0000-0000-0000-00000000d299')
      AND (SELECT count(*) = 1 FROM public.operation_outbox
        WHERE aggregate_type = 'match_report'
          AND aggregate_id = '00000000-0000-0000-0000-00000000d299')$$
  ) AS verification(verified boolean)),
  'the match-report race commits one stat set, one audit pair, and one standings event'
);

DO $cleanup$
BEGIN
  PERFORM dblink_exec('db02_setup', $sql$
    DROP FUNCTION IF EXISTS public.db02_concurrency_match_payload();
    DELETE FROM public.operation_outbox WHERE aggregate_id = '00000000-0000-0000-0000-00000000d299';
    DELETE FROM public.audit_logs
    WHERE actor_discord_id = 'db02-conc-admin'
       OR entity_id LIKE 'db02-conc-%'
       OR entity_id = '00000000-0000-0000-0000-00000000d299';
    DELETE FROM public.admin_audit_log
    WHERE entity_id LIKE 'db02-conc-%'
       OR entity_id = '00000000-0000-0000-0000-00000000d299';
    DELETE FROM public.player_match_stats WHERE match_id = 'db02-conc-match';
    DELETE FROM public.match_reports WHERE id = '00000000-0000-0000-0000-00000000d299'::uuid;
    DELETE FROM public.matches WHERE id = 'db02-conc-match';
    DELETE FROM public.players WHERE discord_id = 'db02-conc-registration-discord';
    DELETE FROM public.season_orgs WHERE season_id = 'db02-conc-season';
    DELETE FROM public.orgs WHERE id IN ('db02-conc-home', 'db02-conc-away');
    DELETE FROM public.registrations WHERE id = 'db02-conc-registration';
    DELETE FROM public.seasons WHERE id = 'db02-conc-season';
    DELETE FROM public.admin_users WHERE discord_id = 'db02-conc-admin';
  $sql$);
  PERFORM dblink_disconnect('db02_worker_a');
  PERFORM dblink_disconnect('db02_worker_b');
  PERFORM dblink_disconnect('db02_setup');
END;
$cleanup$;

SELECT * FROM finish();
ROLLBACK;
