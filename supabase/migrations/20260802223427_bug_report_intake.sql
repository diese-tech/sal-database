-- Durable, privacy-preserving text intake for the public Report a Bug page.
-- Browser callers never access these tables or functions directly: sal-site
-- validates requests and calls the service-role-only RPC boundary.

CREATE TABLE public.bug_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id text NOT NULL UNIQUE
    CHECK (ticket_id ~ '^BUG-[A-Z0-9-]{8,59}$'),
  public_ticket_id text NOT NULL UNIQUE
    CHECK (public_ticket_id ~ '^[A-Za-z0-9_-]{22,160}$'),
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN (
      'open', 'acknowledged', 'waiting_on_reporter',
      'investigating', 'resolved', 'no_response'
    )),
  category text NOT NULL
    CHECK (category IN (
      'website', 'salbot', 'account', 'stats_data',
      'scout_match_report', 'rules_ruling', 'other'
    )),
  severity text NOT NULL
    CHECK (severity IN ('low', 'normal', 'high', 'critical')),
  subject text NOT NULL CHECK (length(btrim(subject)) BETWEEN 5 AND 120),
  description text NOT NULL CHECK (length(btrim(description)) BETWEEN 20 AND 5000),
  reproduction_steps text NOT NULL
    CHECK (length(btrim(reproduction_steps)) BETWEEN 10 AND 3000),
  expected_behavior text NOT NULL
    CHECK (length(btrim(expected_behavior)) BETWEEN 10 AND 2000),
  environment text CHECK (environment IS NULL OR length(btrim(environment)) BETWEEN 1 AND 500),
  reporter_auth_user_id uuid,
  reporter_discord_id text,
  anonymous_access_token_hash text,
  recovery_code_hash text,
  reply_relay_consent boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bug_reports_reporter_access_shape CHECK (
    (
      reporter_auth_user_id IS NULL
      AND reporter_discord_id IS NULL
      AND anonymous_access_token_hash ~ '^[0-9a-f]{64}$'
      AND recovery_code_hash ~ '^[0-9a-f]{64}$'
      AND NOT reply_relay_consent
    )
    OR
    (
      reporter_auth_user_id IS NOT NULL
      AND length(btrim(reporter_discord_id)) > 0
      AND anonymous_access_token_hash IS NULL
      AND recovery_code_hash IS NULL
      AND reply_relay_consent
    )
  )
);

CREATE INDEX bug_reports_queue_idx
  ON public.bug_reports (status, created_at);
CREATE INDEX bug_reports_reporter_idx
  ON public.bug_reports (reporter_auth_user_id, created_at DESC)
  WHERE reporter_auth_user_id IS NOT NULL;

CREATE TABLE public.bug_report_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bug_report_id uuid NOT NULL REFERENCES public.bug_reports(id) ON DELETE CASCADE,
  direction text NOT NULL
    CHECK (direction IN ('reporter_to_admin', 'admin_to_reporter')),
  message text NOT NULL CHECK (length(btrim(message)) BETWEEN 1 AND 5000),
  delivery_status text NOT NULL DEFAULT 'queued'
    CHECK (delivery_status IN ('queued', 'delivered', 'failed')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX bug_report_messages_ticket_idx
  ON public.bug_report_messages (bug_report_id, created_at, id);

CREATE TABLE public.bug_report_rate_limits (
  bucket_hash text NOT NULL CHECK (bucket_hash ~ '^[0-9a-f]{64}$'),
  action text NOT NULL CHECK (action IN ('ticket_submission')),
  window_started_at timestamptz NOT NULL DEFAULT now(),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  consumed_count integer NOT NULL DEFAULT 0 CHECK (consumed_count >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (bucket_hash, action)
);

CREATE TABLE public.bug_report_abuse_decisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_hash text NOT NULL CHECK (bucket_hash ~ '^[0-9a-f]{64}$'),
  action text NOT NULL CHECK (action IN ('ticket_submission')),
  phase text NOT NULL CHECK (phase IN ('attempt', 'consume')),
  parent_decision_id uuid REFERENCES public.bug_report_abuse_decisions(id),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bug_report_abuse_decision_parent_shape CHECK (
    (phase = 'attempt' AND parent_decision_id IS NULL)
    OR (phase = 'consume' AND parent_decision_id IS NOT NULL)
  )
);

CREATE INDEX bug_report_abuse_decisions_expiry_idx
  ON public.bug_report_abuse_decisions (expires_at)
  WHERE consumed_at IS NULL;

ALTER TABLE public.bug_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bug_report_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bug_report_rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bug_report_abuse_decisions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.bug_reports FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.bug_report_messages FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.bug_report_rate_limits FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.bug_report_abuse_decisions FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.bug_reports TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.bug_report_messages TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.bug_report_rate_limits TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.bug_report_abuse_decisions TO service_role;

CREATE POLICY service_role_all_bug_reports
  ON public.bug_reports
  TO service_role
  USING (true)
  WITH CHECK (true);
CREATE POLICY service_role_all_bug_report_messages
  ON public.bug_report_messages
  TO service_role
  USING (true)
  WITH CHECK (true);
CREATE POLICY service_role_all_bug_report_rate_limits
  ON public.bug_report_rate_limits
  TO service_role
  USING (true)
  WITH CHECK (true);
CREATE POLICY service_role_all_bug_report_abuse_decisions
  ON public.bug_report_abuse_decisions
  TO service_role
  USING (true)
  WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.begin_bug_report_attempt(
  p_bucket_hash text,
  p_action text,
  p_attempt_limit integer DEFAULT 12,
  p_window_seconds integer DEFAULT 3600
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_limit public.bug_report_rate_limits%ROWTYPE;
  v_decision_id uuid;
  v_retry_after integer;
BEGIN
  IF p_bucket_hash IS NULL OR p_bucket_hash !~ '^[0-9a-f]{64}$'
    OR p_action <> 'ticket_submission'
    OR p_attempt_limit < 1 OR p_attempt_limit > 100
    OR p_window_seconds < 60 OR p_window_seconds > 86400 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Invalid bug report attempt policy.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('bug-report-limit:' || p_action || ':' || p_bucket_hash, 0));

  INSERT INTO public.bug_report_rate_limits (
    bucket_hash, action, window_started_at, attempt_count, consumed_count, updated_at
  ) VALUES (
    p_bucket_hash, p_action, v_now, 1, 0, v_now
  )
  ON CONFLICT (bucket_hash, action) DO UPDATE SET
    window_started_at = CASE
      WHEN public.bug_report_rate_limits.window_started_at
        <= v_now - make_interval(secs => p_window_seconds)
      THEN v_now
      ELSE public.bug_report_rate_limits.window_started_at
    END,
    attempt_count = CASE
      WHEN public.bug_report_rate_limits.window_started_at
        <= v_now - make_interval(secs => p_window_seconds)
      THEN 1
      ELSE public.bug_report_rate_limits.attempt_count + 1
    END,
    consumed_count = CASE
      WHEN public.bug_report_rate_limits.window_started_at
        <= v_now - make_interval(secs => p_window_seconds)
      THEN 0
      ELSE public.bug_report_rate_limits.consumed_count
    END,
    updated_at = v_now
  RETURNING * INTO v_limit;

  IF v_limit.attempt_count > p_attempt_limit THEN
    v_retry_after := GREATEST(
      1,
      CEIL(EXTRACT(EPOCH FROM (
        v_limit.window_started_at + make_interval(secs => p_window_seconds) - v_now
      )))::integer
    );
    RETURN jsonb_build_object(
      'allowed', false,
      'retryAfterSeconds', v_retry_after,
      'captchaRequired', false
    );
  END IF;

  INSERT INTO public.bug_report_abuse_decisions (
    bucket_hash, action, phase, expires_at
  ) VALUES (
    p_bucket_hash, p_action, 'attempt', v_now + interval '10 minutes'
  ) RETURNING id INTO v_decision_id;

  RETURN jsonb_build_object(
    'allowed', true,
    'decisionId', v_decision_id,
    'captchaVerified', false
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.consume_bug_report_allowance(
  p_attempt_decision_id uuid,
  p_bucket_hash text,
  p_action text,
  p_submission_limit integer DEFAULT 3,
  p_window_seconds integer DEFAULT 3600
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_attempt public.bug_report_abuse_decisions%ROWTYPE;
  v_limit public.bug_report_rate_limits%ROWTYPE;
  v_decision_id uuid;
  v_retry_after integer;
BEGIN
  IF p_attempt_decision_id IS NULL
    OR p_bucket_hash IS NULL OR p_bucket_hash !~ '^[0-9a-f]{64}$'
    OR p_action <> 'ticket_submission'
    OR p_submission_limit < 1 OR p_submission_limit > 20
    OR p_window_seconds < 60 OR p_window_seconds > 86400 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Invalid bug report allowance policy.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('bug-report-limit:' || p_action || ':' || p_bucket_hash, 0));

  SELECT * INTO v_attempt
  FROM public.bug_report_abuse_decisions
  WHERE id = p_attempt_decision_id
    AND bucket_hash = p_bucket_hash
    AND action = p_action
    AND phase = 'attempt'
  FOR UPDATE;

  IF NOT FOUND OR v_attempt.consumed_at IS NOT NULL OR v_attempt.expires_at <= v_now THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Bug report attempt decision is invalid or expired.';
  END IF;

  UPDATE public.bug_report_abuse_decisions
  SET consumed_at = v_now
  WHERE id = v_attempt.id;

  UPDATE public.bug_report_rate_limits
  SET
    window_started_at = CASE
      WHEN window_started_at <= v_now - make_interval(secs => p_window_seconds)
      THEN v_now ELSE window_started_at END,
    attempt_count = CASE
      WHEN window_started_at <= v_now - make_interval(secs => p_window_seconds)
      THEN 0 ELSE attempt_count END,
    consumed_count = CASE
      WHEN window_started_at <= v_now - make_interval(secs => p_window_seconds)
      THEN 1 ELSE consumed_count + 1 END,
    updated_at = v_now
  WHERE bucket_hash = p_bucket_hash AND action = p_action
  RETURNING * INTO v_limit;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Bug report rate limit state is missing.';
  END IF;

  IF v_limit.consumed_count > p_submission_limit THEN
    v_retry_after := GREATEST(
      1,
      CEIL(EXTRACT(EPOCH FROM (
        v_limit.window_started_at + make_interval(secs => p_window_seconds) - v_now
      )))::integer
    );
    RETURN jsonb_build_object(
      'allowed', false,
      'retryAfterSeconds', v_retry_after,
      'captchaRequired', false
    );
  END IF;

  INSERT INTO public.bug_report_abuse_decisions (
    bucket_hash, action, phase, parent_decision_id, expires_at
  ) VALUES (
    p_bucket_hash, p_action, 'consume', v_attempt.id, v_now + interval '10 minutes'
  ) RETURNING id INTO v_decision_id;

  RETURN jsonb_build_object(
    'allowed', true,
    'decisionId', v_decision_id,
    'captchaVerified', false
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.create_bug_report(
  p_abuse_decision_id uuid,
  p_ticket_id text,
  p_public_ticket_id text,
  p_category text,
  p_severity text,
  p_subject text,
  p_description text,
  p_reproduction_steps text,
  p_expected_behavior text,
  p_environment text DEFAULT NULL,
  p_reporter_auth_user_id uuid DEFAULT NULL,
  p_reporter_discord_id text DEFAULT NULL,
  p_anonymous_access_token_hash text DEFAULT NULL,
  p_recovery_code_hash text DEFAULT NULL,
  p_reply_relay_consent boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_decision public.bug_report_abuse_decisions%ROWTYPE;
  v_report public.bug_reports%ROWTYPE;
BEGIN
  SELECT * INTO v_decision
  FROM public.bug_report_abuse_decisions
  WHERE id = p_abuse_decision_id
    AND action = 'ticket_submission'
    AND phase = 'consume'
  FOR UPDATE;

  IF NOT FOUND OR v_decision.consumed_at IS NOT NULL OR v_decision.expires_at <= v_now THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Bug report submission allowance is invalid or expired.';
  END IF;

  INSERT INTO public.bug_reports (
    ticket_id,
    public_ticket_id,
    category,
    severity,
    subject,
    description,
    reproduction_steps,
    expected_behavior,
    environment,
    reporter_auth_user_id,
    reporter_discord_id,
    anonymous_access_token_hash,
    recovery_code_hash,
    reply_relay_consent,
    created_at,
    updated_at
  ) VALUES (
    btrim(p_ticket_id),
    btrim(p_public_ticket_id),
    p_category,
    p_severity,
    btrim(p_subject),
    btrim(p_description),
    btrim(p_reproduction_steps),
    btrim(p_expected_behavior),
    NULLIF(btrim(COALESCE(p_environment, '')), ''),
    p_reporter_auth_user_id,
    NULLIF(btrim(COALESCE(p_reporter_discord_id, '')), ''),
    p_anonymous_access_token_hash,
    p_recovery_code_hash,
    p_reply_relay_consent,
    v_now,
    v_now
  ) RETURNING * INTO v_report;

  UPDATE public.bug_report_abuse_decisions
  SET consumed_at = v_now
  WHERE id = v_decision.id;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, actor_discord_id, new_value_json
  ) VALUES (
    'bug_report_created',
    'bug_report',
    v_report.id::text,
    COALESCE(v_report.reporter_discord_id, 'anonymous'),
    jsonb_build_object(
      'ticketId', v_report.ticket_id,
      'category', v_report.category,
      'severity', v_report.severity,
      'status', v_report.status
    )
  );

  RETURN jsonb_build_object(
    'ticketId', v_report.ticket_id,
    'publicTicketId', v_report.public_ticket_id,
    'status', v_report.status
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.read_bug_report_status(
  p_public_ticket_id text,
  p_access_token_hash text DEFAULT NULL,
  p_auth_user_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_report public.bug_reports%ROWTYPE;
  v_messages jsonb;
BEGIN
  SELECT * INTO v_report
  FROM public.bug_reports
  WHERE public_ticket_id = p_public_ticket_id
    AND (
      (p_access_token_hash IS NOT NULL AND anonymous_access_token_hash = p_access_token_hash)
      OR (p_auth_user_id IS NOT NULL AND reporter_auth_user_id = p_auth_user_id)
    );

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', message.id,
        'direction', message.direction,
        'message', message.message,
        'deliveryStatus', message.delivery_status,
        'createdAt', message.created_at
      ) ORDER BY message.created_at, message.id
    ),
    '[]'::jsonb
  ) INTO v_messages
  FROM public.bug_report_messages message
  WHERE message.bug_report_id = v_report.id;

  RETURN jsonb_build_object(
    'ticketId', v_report.ticket_id,
    'status', v_report.status,
    'updatedAt', v_report.updated_at,
    'messages', v_messages
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_bug_report_status(
  p_bug_report_id uuid,
  p_actor_discord_id text,
  p_status text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_report public.bug_reports%ROWTYPE;
  v_old_status text;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_actor_discord_id IS NULL OR btrim(p_actor_discord_id) = ''
    OR p_status NOT IN (
      'acknowledged', 'waiting_on_reporter', 'investigating', 'resolved', 'no_response'
    ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A valid actor and bug report status are required.';
  END IF;

  SELECT * INTO v_report
  FROM public.bug_reports
  WHERE id = p_bug_report_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Bug report not found.';
  END IF;

  IF v_report.status = p_status THEN
    RETURN jsonb_build_object(
      'code', 'already_processed',
      'bugReportId', v_report.id,
      'finalStatus', v_report.status,
      'applied', false
    );
  END IF;

  IF v_report.status = 'resolved' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Resolved bug reports cannot be reopened through this workflow.';
  END IF;

  v_old_status := v_report.status;

  UPDATE public.bug_reports
  SET status = p_status, updated_at = v_now
  WHERE id = v_report.id
  RETURNING * INTO v_report;

  INSERT INTO public.audit_logs (
    action_type, entity_type, entity_id, actor_discord_id, old_value_json, new_value_json
  ) VALUES (
    'bug_report_status_changed',
    'bug_report',
    v_report.id::text,
    btrim(p_actor_discord_id),
    jsonb_build_object('status', v_old_status),
    jsonb_build_object('status', v_report.status, 'ticketId', v_report.ticket_id)
  );

  RETURN jsonb_build_object(
    'code', 'applied',
    'bugReportId', v_report.id,
    'finalStatus', v_report.status,
    'applied', true
  );
END;
$$;

REVOKE ALL ON FUNCTION public.begin_bug_report_attempt(text, text, integer, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.consume_bug_report_allowance(uuid, text, text, integer, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_bug_report(
  uuid, text, text, text, text, text, text, text, text, text,
  uuid, text, text, text, boolean
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.read_bug_report_status(text, text, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.update_bug_report_status(uuid, text, text)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.begin_bug_report_attempt(text, text, integer, integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.consume_bug_report_allowance(uuid, text, text, integer, integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.create_bug_report(
  uuid, text, text, text, text, text, text, text, text, text,
  uuid, text, text, text, boolean
) TO service_role;
GRANT EXECUTE ON FUNCTION public.read_bug_report_status(text, text, uuid)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.update_bug_report_status(uuid, text, text)
  TO service_role;

COMMENT ON TABLE public.bug_reports
  IS 'Private text bug reports submitted through sal-site; never exposed to browser roles.';
COMMENT ON TABLE public.bug_report_messages
  IS 'Private reporter/admin messages reserved for authenticated relay and status updates.';
COMMENT ON FUNCTION public.create_bug_report(
  uuid, text, text, text, text, text, text, text, text, text,
  uuid, text, text, text, boolean
) IS 'Atomically consumes one durable allowance, stores a private bug report, and appends a privacy-safe audit event.';
