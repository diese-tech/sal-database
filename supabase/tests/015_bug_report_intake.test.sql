BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(18);

SELECT has_table('public', 'bug_reports', 'bug_reports exists');
SELECT has_table('public', 'bug_report_messages', 'bug_report_messages exists');
SELECT has_table('public', 'bug_report_rate_limits', 'bug_report_rate_limits exists');
SELECT has_table('public', 'bug_report_abuse_decisions', 'bug_report_abuse_decisions exists');

SELECT ok(
  NOT has_table_privilege('anon', 'public.bug_reports', 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('authenticated', 'public.bug_reports', 'SELECT,INSERT,UPDATE,DELETE')
    AND has_table_privilege('service_role', 'public.bug_reports', 'SELECT,INSERT,UPDATE,DELETE'),
  'bug reports are available only to the trusted service role'
);

CREATE TEMP TABLE bug_report_test_state (
  name text PRIMARY KEY,
  value jsonb NOT NULL
);

INSERT INTO bug_report_test_state (name, value)
SELECT 'attempt', public.begin_bug_report_attempt(
  repeat('a', 64), 'ticket_submission', 12, 3600
);

SELECT is(
  (SELECT value ->> 'allowed' FROM bug_report_test_state WHERE name = 'attempt'),
  'true',
  'the durable attempt gate issues an allowance candidate'
);

INSERT INTO bug_report_test_state (name, value)
SELECT 'allowance', public.consume_bug_report_allowance(
  (SELECT (value ->> 'decisionId')::uuid FROM bug_report_test_state WHERE name = 'attempt'),
  repeat('a', 64),
  'ticket_submission',
  1,
  3600
);

SELECT is(
  (SELECT value ->> 'allowed' FROM bug_report_test_state WHERE name = 'allowance'),
  'true',
  'the first report in the window receives a consumable durable allowance'
);

INSERT INTO bug_report_test_state (name, value)
SELECT 'created', public.create_bug_report(
  (SELECT (value ->> 'decisionId')::uuid FROM bug_report_test_state WHERE name = 'allowance'),
  'BUG-TEST0001',
  'public_test_ticket_0000000000000001',
  'website',
  'high',
  'Standings page remains blank',
  'The current standings page remains blank after selecting the active season.',
  'Open standings, select the active season, and wait for the table to load.',
  'The active season standings should be visible.',
  'Firefox on Windows 11',
  NULL,
  NULL,
  repeat('b', 64),
  repeat('c', 64),
  false
);

SELECT is(
  (SELECT value ->> 'ticketId' FROM bug_report_test_state WHERE name = 'created'),
  'BUG-TEST0001',
  'creating a report returns its public-safe ticket receipt'
);

SELECT is(
  (SELECT count(*)::integer FROM public.bug_reports WHERE ticket_id = 'BUG-TEST0001'),
  1,
  'the complete report is stored exactly once'
);

SELECT ok(
  (SELECT anonymous_access_token_hash = repeat('b', 64)
    AND recovery_code_hash = repeat('c', 64)
    FROM public.bug_reports WHERE ticket_id = 'BUG-TEST0001'),
  'only one-way access and recovery hashes are stored'
);

SELECT is(
  public.read_bug_report_status(
    'public_test_ticket_0000000000000001', repeat('d', 64), NULL
  ),
  NULL,
  'an incorrect private token is indistinguishable from a missing ticket'
);

SELECT is(
  public.read_bug_report_status(
    'public_test_ticket_0000000000000001', repeat('b', 64), NULL
  ) ->> 'ticketId',
  'BUG-TEST0001',
  'the correct private token can read the status projection'
);

INSERT INTO bug_report_test_state (name, value)
SELECT 'updated', public.update_bug_report_status(
  (SELECT id FROM public.bug_reports WHERE ticket_id = 'BUG-TEST0001'),
  'admin-test',
  'investigating'
);

SELECT is(
  (SELECT value ->> 'finalStatus' FROM bug_report_test_state WHERE name = 'updated'),
  'investigating',
  'an admin can move the report into investigation'
);

SELECT is(
  public.update_bug_report_status(
    (SELECT id FROM public.bug_reports WHERE ticket_id = 'BUG-TEST0001'),
    'admin-test',
    'investigating'
  ) ->> 'code',
  'already_processed',
  'replaying the same status change is idempotent'
);

SELECT is(
  (SELECT count(*)::integer
   FROM public.audit_logs
   WHERE entity_type = 'bug_report'
     AND entity_id = (SELECT id::text FROM public.bug_reports WHERE ticket_id = 'BUG-TEST0001')),
  2,
  'ticket creation and status changes each append one audit record'
);

SELECT throws_ok(
  format(
    $sql$SELECT public.create_bug_report(
      %L::uuid, 'BUG-TEST0002', 'public_test_ticket_0000000000000002',
      'website', 'normal', 'Duplicate allowance test',
      'This report attempts to reuse a previously consumed durable allowance.',
      'Submit the same durable allowance a second time.',
      'The second request should be rejected.', NULL, NULL, NULL,
      %L, %L, false
    )$sql$,
    (SELECT value ->> 'decisionId' FROM bug_report_test_state WHERE name = 'allowance'),
    repeat('e', 64),
    repeat('f', 64)
  ),
  '55000',
  'Bug report submission allowance is invalid or expired.',
  'a consumed durable allowance cannot create a second report'
);

INSERT INTO bug_report_test_state (name, value)
SELECT 'attempt-2', public.begin_bug_report_attempt(
  repeat('a', 64), 'ticket_submission', 12, 3600
);

INSERT INTO bug_report_test_state (name, value)
SELECT 'allowance-2', public.consume_bug_report_allowance(
  (SELECT (value ->> 'decisionId')::uuid FROM bug_report_test_state WHERE name = 'attempt-2'),
  repeat('a', 64),
  'ticket_submission',
  1,
  3600
);

SELECT is(
  (SELECT value ->> 'allowed' FROM bug_report_test_state WHERE name = 'allowance-2'),
  'false',
  'the durable submission counter rejects reports beyond the configured window limit'
);

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.create_bug_report(uuid,text,text,text,text,text,text,text,text,text,uuid,text,text,text,boolean)',
    'EXECUTE'
  )
    AND has_function_privilege(
      'service_role',
      'public.create_bug_report(uuid,text,text,text,text,text,text,text,text,text,uuid,text,text,text,boolean)',
      'EXECUTE'
    ),
  'the write RPC is executable only by the trusted service role'
);

SELECT * FROM finish();
ROLLBACK;
