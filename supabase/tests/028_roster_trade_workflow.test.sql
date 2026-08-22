BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(36);

SELECT has_table(
  'public',
  'roster_transactions',
  'roster transactions have one canonical durable ledger'
);

SELECT has_table('public', 'roster_transaction_revisions', 'trade revisions are durable');
SELECT has_table('public', 'roster_transaction_consents', 'revision consent is durable');
SELECT has_table('public', 'roster_transaction_movements', 'revision player movements are durable');
SELECT has_table('public', 'captain_role_mappings', 'division captain role mappings are canonical');
SELECT has_table('public', 'organization_role_mappings', 'organization role mappings are canonical');
SELECT has_function(
  'public', 'create_roster_trade',
  ARRAY['text', 'text', 'text', 'text', 'text', 'text[]', 'text[]', 'text', 'text'],
  'trade creation is a transport-neutral service-role RPC'
);
SELECT has_function(
  'public', 'mark_operation_outbox_needs_reconciliation', ARRAY['uuid', 'text', 'text'],
  'ambiguous Discord delivery has a durable non-reposting state'
);
SELECT has_function(
  'public', 'reconcile_operation_outbox', ARRAY['uuid', 'text', 'text', 'boolean'],
  'administrators can link an existing Discord message or explicitly retry ambiguous delivery'
);
SELECT has_function(
  'public', 'counter_roster_trade', ARRAY['uuid', 'integer', 'text', 'text[]', 'text[]'],
  'counteroffers append through a canonical RPC'
);
SELECT has_function(
  'public', 'accept_roster_trade', ARRAY['uuid', 'integer', 'text'],
  'exact-revision acceptance uses a canonical RPC'
);
SELECT has_function(
  'public', 'cancel_roster_trade', ARRAY['uuid', 'integer', 'text', 'text'],
  'withdrawal and consent revocation use one canonical cancellation RPC'
);
SELECT ok(
  NOT has_function_privilege('anon', 'public.create_roster_trade(text,text,text,text,text,text[],text[],text,text)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.create_roster_trade(text,text,text,text,text,text[],text[],text,text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.create_roster_trade(text,text,text,text,text,text[],text[],text,text)', 'EXECUTE'),
  'trade mutation RPCs are service-role-only'
);

UPDATE public.seasons SET is_current = false WHERE is_current;
INSERT INTO public.seasons (id, name, status, start_date, end_date, is_current)
VALUES ('trade-season', 'Trade Season', 'active', '2026-08-01', '2026-12-31', true);
INSERT INTO public.orgs (
  id, name, tag, division_id, logo_initials, logo_gradient, primary_color, accent_gradient
) VALUES
  ('trade-org-a', 'Trade Organization A', 'TOA', 'solar', 'TA', 'x', '#000000', 'x'),
  ('trade-org-b', 'Trade Organization B', 'TOB', 'solar', 'TB', 'x', '#000000', 'x');
INSERT INTO public.season_orgs (season_id, org_id, division_id)
VALUES ('trade-season', 'trade-org-a', 'solar'), ('trade-season', 'trade-org-b', 'solar');
INSERT INTO public.season_transaction_settings (
  season_id, division_id, trades_open, max_roster_size, updated_by_discord_id
) VALUES ('trade-season', 'solar', true, 4, 'trade-admin');
INSERT INTO public.admin_users (discord_id, role, discord_username, display_name)
VALUES ('trade-admin', 'admin', 'trade-admin', 'Trade Admin');
INSERT INTO public.operation_outbox (
  id, topic, aggregate_type, aggregate_id, event_type, deduplication_key,
  state, attempts, lease_owner, lease_expires_at
) VALUES (
  'a9300000-0000-4000-8000-000000000001', 'discord_transaction_bulletin',
  'roster_transaction', 'ambiguous-trade', 'roster_trade_completed',
  'test:roster-trade:ambiguous', 'processing', 1, 'trade-worker', now() + interval '1 minute'
);
SELECT is(
  public.mark_operation_outbox_needs_reconciliation(
    'a9300000-0000-4000-8000-000000000001', 'trade-worker', 'Discord send result was ambiguous.'
  ) ->> 'state',
  'needs_reconciliation',
  'ambiguous delivery exits the automatic claim loop'
);
SELECT is(
  public.reconcile_operation_outbox(
    'a9300000-0000-4000-8000-000000000001', 'trade-admin', 'discord-message-123', false
  ) ->> 'state',
  'completed',
  'an administrator can link the discovered message without reposting'
);
INSERT INTO public.players (
  id, org_id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status, discord_id
) VALUES
  ('trade-cap-a', 'trade-org-a', 'cap-a', 'Captain A', 'CA', 'x', 'Flex', 'solar', 'active', 'discord-cap-a'),
  ('trade-a1', 'trade-org-a', 'a1', 'Alpha One', 'A1', 'x', 'Flex', 'solar', 'active', 'discord-a1'),
  ('trade-a2', 'trade-org-a', 'a2', 'Alpha Two', 'A2', 'x', 'Flex', 'solar', 'active', 'discord-a2'),
  ('trade-cap-b', 'trade-org-b', 'cap-b', 'Captain B', 'CB', 'x', 'Flex', 'solar', 'active', 'discord-cap-b'),
  ('trade-b1', 'trade-org-b', 'b1', 'Beta One', 'B1', 'x', 'Flex', 'solar', 'active', 'discord-b1'),
  ('trade-b2', 'trade-org-b', 'b2', 'Beta Two', 'B2', 'x', 'Flex', 'solar', 'active', 'discord-b2');
INSERT INTO public.season_rosters (
  season_id, player_id, org_id, division_id, is_captain, roster_status
) VALUES
  ('trade-season', 'trade-cap-a', 'trade-org-a', 'solar', true, 'active'),
  ('trade-season', 'trade-a1', 'trade-org-a', 'solar', false, 'active'),
  ('trade-season', 'trade-a2', 'trade-org-a', 'solar', false, 'active'),
  ('trade-season', 'trade-cap-b', 'trade-org-b', 'solar', true, 'active'),
  ('trade-season', 'trade-b1', 'trade-org-b', 'solar', false, 'active'),
  ('trade-season', 'trade-b2', 'trade-org-b', 'solar', false, 'active');

SELECT throws_ok(
  $$SELECT public.create_roster_trade(
    'discord-cap-a', 'trade-season', 'solar', 'trade-org-a', 'trade-org-b',
    ARRAY['trade-a1', 'trade-a1'], ARRAY['trade-b1'], 'trade-channel', 'discord_workflow'
  )$$,
  '22023', 'Offered players contains a duplicate or invalid player.',
  'duplicate player selections are rejected at the authoritative boundary'
);

CREATE TEMP TABLE trade_uneven AS
SELECT public.create_roster_trade(
  'discord-cap-a', 'trade-season', 'solar', 'trade-org-a', 'trade-org-b',
  ARRAY['trade-a2'], ARRAY['trade-b1', 'trade-b2'], 'trade-channel', 'discord_workflow'
) AS result;
SELECT ok(
  (SELECT count(*) = 3 FROM public.roster_transaction_movements
   WHERE transaction_id = (SELECT (result ->> 'transactionId')::uuid FROM trade_uneven))
  AND (SELECT org_id = 'trade-org-a' FROM public.season_rosters
       WHERE season_id = 'trade-season' AND player_id = 'trade-a2'),
  'uneven proposals preserve every movement without applying any of them'
);
SELECT lives_ok(
  format('SELECT public.cancel_roster_trade(%L::uuid, 1, %L, %L)',
    (SELECT result ->> 'transactionId' FROM trade_uneven), 'discord-cap-a', 'withdraw'),
  'an unaccepted uneven fixture can be withdrawn cleanly'
);

CREATE TEMP TABLE trade_created AS
SELECT public.create_roster_trade(
  'discord-cap-a', 'trade-season', 'solar', 'trade-org-a', 'trade-org-b',
  ARRAY['trade-a1'], ARRAY['trade-b1'], 'trade-channel', 'discord_workflow'
) AS result;
SELECT ok(
  (SELECT result ->> 'code' = 'created' FROM trade_created)
  AND (SELECT count(*) = 1 FROM public.roster_transactions WHERE status = 'awaiting_acceptance')
  AND (SELECT count(*) = 1 FROM public.pending_actions WHERE type = 'roster_trade' AND status = 'pending')
  AND (SELECT org_id = 'trade-org-a' FROM public.season_rosters WHERE season_id = 'trade-season' AND player_id = 'trade-a1'),
  'posting a 1-for-1 proposal creates durable revision and pending action without mutating rosters'
);
SELECT throws_ok(
  $$SELECT public.create_roster_trade(
    'discord-cap-a', 'trade-season', 'solar', 'trade-org-a', 'trade-org-a',
    ARRAY['trade-a1'], ARRAY['trade-a2'], 'trade-channel', 'discord_workflow'
  )$$,
  '23514', 'A trade requires two different organizations.',
  'same-organization trades are rejected'
);
SELECT throws_ok(
  $$SELECT public.create_roster_trade(
    'discord-not-captain', 'trade-season', 'solar', 'trade-org-a', 'trade-org-b',
    ARRAY['trade-a1'], ARRAY['trade-b1'], 'trade-channel', 'discord_workflow'
  )$$,
  '42501', 'Actor is not the current captain for this organization and division.',
  'global or unrelated identities cannot initiate a trade'
);
SELECT throws_ok(
  format(
    'SELECT public.accept_roster_trade(%L::uuid, 1, %L)',
    (SELECT result ->> 'transactionId' FROM trade_created), 'discord-cap-a'
  ),
  '42501', 'A proposer cannot accept their own revision.',
  'the proposer cannot accept their own current revision'
);

CREATE TEMP TABLE trade_accepted AS
SELECT public.accept_roster_trade(
  (SELECT (result ->> 'transactionId')::uuid FROM trade_created), 1, 'discord-cap-b'
) AS result;
SELECT ok(
  (SELECT result ->> 'status' = 'awaiting_admin' FROM trade_accepted)
  AND (SELECT org_id = 'trade-org-a' FROM public.season_rosters WHERE season_id = 'trade-season' AND player_id = 'trade-a1')
  AND (SELECT bool_and(consented) FROM public.roster_transaction_consents
       WHERE transaction_id = (SELECT (result ->> 'transactionId')::uuid FROM trade_created) AND revision = 1),
  'receiving-captain acceptance is revision-bound and does not mutate rosters'
);
SELECT throws_ok(
  format(
    'SELECT public.accept_roster_trade(%L::uuid, 1, %L)',
    (SELECT result ->> 'transactionId' FROM trade_created), 'discord-cap-a'
  ),
  '40001', 'This trade revision is stale.',
  'a proposer cannot reuse acceptance after the transaction leaves awaiting-acceptance state'
);

CREATE TEMP TABLE trade_completed AS
SELECT public.resolve_pending_action(
  (SELECT result ->> 'pendingActionId' FROM trade_created), 'trade-admin', 'approve', NULL
) AS result;
SELECT ok(
  (SELECT result ->> 'code' = 'completed' FROM trade_completed)
  AND (SELECT org_id = 'trade-org-b' FROM public.season_rosters WHERE season_id = 'trade-season' AND player_id = 'trade-a1')
  AND (SELECT org_id = 'trade-org-a' FROM public.season_rosters WHERE season_id = 'trade-season' AND player_id = 'trade-b1')
  AND (SELECT count(*) = 1 FROM public.operation_outbox
       WHERE topic = 'discord_transaction_bulletin'
         AND aggregate_id = (SELECT result ->> 'transactionId' FROM trade_created))
  AND (SELECT count(*) = 1 FROM public.operation_outbox
       WHERE topic = 'discord_organization_role_reconciliation'
         AND aggregate_id = (SELECT result ->> 'transactionId' FROM trade_created)),
  'admin dispatch atomically executes the trade and emits independent bulletin and role-reconciliation work'
);

UPDATE public.admin_users SET role = 'super_admin' WHERE discord_id = 'trade-admin';
INSERT INTO public.players (
  id, discord_username, ign, avatar_initials, avatar_gradient,
  primary_role, division_id, status
) VALUES (
  'trade-a1-canonical', 'a1-canonical', 'Alpha One Canonical', 'AC', 'x',
  'Flex', 'solar', 'active'
);
SELECT public.merge_player('trade-a1', 'trade-a1-canonical', 'trade-admin');
SELECT ok(
  NOT EXISTS (SELECT 1 FROM public.players WHERE id = 'trade-a1')
  AND EXISTS (
    SELECT 1 FROM public.roster_transaction_movements
    WHERE transaction_id = (SELECT (result ->> 'transactionId')::uuid FROM trade_created)
      AND player_id = 'trade-a1-canonical'
  ),
  'player identity merge redirects typed transaction history without deleting the movement'
);

CREATE TEMP TABLE trade_capacity_base AS
SELECT public.create_roster_trade(
  'discord-cap-a', 'trade-season', 'solar', 'trade-org-a', 'trade-org-b',
  ARRAY['trade-a2'], ARRAY['trade-b2'], 'trade-channel', 'discord_workflow'
) AS result;
SELECT public.accept_roster_trade(
  (SELECT (result ->> 'transactionId')::uuid FROM trade_capacity_base), 1, 'discord-cap-b'
);
UPDATE public.season_transaction_settings SET max_roster_size = 2
WHERE season_id = 'trade-season' AND division_id = 'solar';
CREATE TEMP TABLE trade_capacity_blocked AS
SELECT public.resolve_pending_action(
  (SELECT result ->> 'pendingActionId' FROM trade_capacity_base), 'trade-admin', 'approve', NULL
) AS result;
SELECT ok(
  (SELECT result ->> 'code' = 'blocked' FROM trade_capacity_blocked)
  AND (SELECT result ->> 'note' LIKE '%roster capacity%' FROM trade_capacity_blocked)
  AND NOT EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE topic = 'discord_transaction_bulletin'
      AND aggregate_id = (SELECT result ->> 'transactionId' FROM trade_capacity_base)
  ),
  'a capacity violation discovered at execution blocks atomically and emits no bulletin'
);
UPDATE public.season_transaction_settings SET max_roster_size = 4
WHERE season_id = 'trade-season' AND division_id = 'solar';

CREATE TEMP TABLE trade_counter_base AS
SELECT public.create_roster_trade(
  'discord-cap-a', 'trade-season', 'solar', 'trade-org-a', 'trade-org-b',
  ARRAY['trade-a2'], ARRAY['trade-b2'], NULL, 'web_workflow'
) AS result;
CREATE TEMP TABLE trade_countered AS
SELECT public.counter_roster_trade(
  (SELECT (result ->> 'transactionId')::uuid FROM trade_counter_base), 1, 'discord-cap-b',
  ARRAY['trade-b2'], ARRAY['trade-a2']
) AS result;
SELECT ok(
  (SELECT result ->> 'revision' = '2' FROM trade_countered)
  AND (SELECT proposer_org_id = 'trade-org-b' AND receiver_org_id = 'trade-org-a'
       FROM public.roster_transactions
       WHERE id = (SELECT (result ->> 'transactionId')::uuid FROM trade_counter_base))
  AND (SELECT status = 'superseded' FROM public.roster_transaction_revisions
       WHERE transaction_id = (SELECT (result ->> 'transactionId')::uuid FROM trade_counter_base) AND revision = 1),
  'a counter preserves history, supersedes consent, and flips proposer and receiver'
);
SELECT throws_ok(
  format(
    'SELECT public.accept_roster_trade(%L::uuid, 1, %L)',
    (SELECT result ->> 'transactionId' FROM trade_counter_base), 'discord-cap-b'
  ),
  '40001', 'This trade revision is stale.',
  'acceptance of a superseded revision is rejected'
);
SELECT lives_ok(
  format(
    'SELECT public.accept_roster_trade(%L::uuid, 2, %L)',
    (SELECT result ->> 'transactionId' FROM trade_counter_base), 'discord-cap-a'
  ),
  'the opposite captain can accept the current counter revision'
);
SELECT lives_ok(
  format(
    'SELECT public.cancel_roster_trade(%L::uuid, 2, %L, %L)',
    (SELECT result ->> 'transactionId' FROM trade_counter_base), 'discord-cap-b', 'revoke'
  ),
  'either participating captain can revoke accepted consent before execution is claimed'
);

CREATE TEMP TABLE trade_blocked_base AS
SELECT public.create_roster_trade(
  'discord-cap-a', 'trade-season', 'solar', 'trade-org-a', 'trade-org-b',
  ARRAY['trade-a2'], ARRAY['trade-b2'], 'trade-channel', 'discord_workflow'
) AS result;
SELECT public.accept_roster_trade(
  (SELECT (result ->> 'transactionId')::uuid FROM trade_blocked_base), 1, 'discord-cap-b'
);
UPDATE public.season_rosters SET org_id = 'trade-org-b'
WHERE season_id = 'trade-season' AND player_id = 'trade-a2';
CREATE TEMP TABLE trade_blocked AS
SELECT public.resolve_pending_action(
  (SELECT result ->> 'pendingActionId' FROM trade_blocked_base), 'trade-admin', 'approve', NULL
) AS result;
SELECT ok(
  (SELECT result ->> 'code' = 'blocked' AND result ->> 'finalStatus' = 'pending_info' FROM trade_blocked)
  AND NOT EXISTS (
    SELECT 1 FROM public.operation_outbox
    WHERE topic = 'discord_transaction_bulletin'
      AND aggregate_id = (SELECT result ->> 'transactionId' FROM trade_blocked_base)
  ),
  'execution-time roster drift blocks atomically and emits no completed bulletin'
);

SELECT throws_ok(
  $$SELECT public.create_roster_trade(
    'discord-cap-a', 'trade-season', 'solar', 'trade-org-a', 'trade-org-b',
    ARRAY['trade-a2'], ARRAY['trade-b2'], 'trade-channel', 'discord_workflow'
  )$$,
  '23514', 'Offered players includes a player who is no longer on that roster.',
  'proposal-time stale roster selection is rejected by the canonical function'
);

CREATE TEMP TABLE trade_withdraw_base AS
SELECT public.create_roster_trade(
  'discord-cap-a', 'trade-season', 'solar', 'trade-org-a', 'trade-org-b',
  ARRAY['trade-b1'], ARRAY['trade-b2'], 'trade-channel', 'discord_workflow'
) AS result;
SELECT lives_ok(
  format('SELECT public.cancel_roster_trade(%L::uuid, 1, %L, %L)',
    (SELECT result ->> 'transactionId' FROM trade_withdraw_base), 'discord-cap-a', 'withdraw'),
  'the current proposer can withdraw before acceptance'
);

CREATE TEMP TABLE trade_decline_base AS
SELECT public.create_roster_trade(
  'discord-cap-a', 'trade-season', 'solar', 'trade-org-a', 'trade-org-b',
  ARRAY['trade-b1'], ARRAY['trade-b2'], 'trade-channel', 'discord_workflow'
) AS result;
SELECT lives_ok(
  format('SELECT public.decline_roster_trade(%L::uuid, 1, %L)',
    (SELECT result ->> 'transactionId' FROM trade_decline_base), 'discord-cap-b'),
  'the receiving captain can decline the current revision'
);

CREATE TEMP TABLE trade_claimed_base AS
SELECT public.create_roster_trade(
  'discord-cap-a', 'trade-season', 'solar', 'trade-org-a', 'trade-org-b',
  ARRAY['trade-b1'], ARRAY['trade-b2'], 'trade-channel', 'discord_workflow'
) AS result;
SELECT public.accept_roster_trade(
  (SELECT (result ->> 'transactionId')::uuid FROM trade_claimed_base), 1, 'discord-cap-b'
);
UPDATE public.roster_transactions SET execution_claimed_at = now()
WHERE id = (SELECT (result ->> 'transactionId')::uuid FROM trade_claimed_base);
SELECT throws_ok(
  format('SELECT public.cancel_roster_trade(%L::uuid, 1, %L, %L)',
    (SELECT result ->> 'transactionId' FROM trade_claimed_base), 'discord-cap-a', 'revoke'),
  '55000', 'This trade can no longer be cancelled.',
  'consent revocation is rejected after administrator execution is claimed'
);

SELECT * FROM finish();
ROLLBACK;
