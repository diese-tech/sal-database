


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."complete_god_draft"("p_session_id" "text", "p_match_id" "text", "p_game_number" integer, "p_draft_state" "jsonb", "p_bans" "jsonb", "p_picks" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  DELETE FROM god_bans  WHERE session_id = p_session_id;
  DELETE FROM god_picks WHERE session_id = p_session_id;

  INSERT INTO god_bans (session_id, match_id, game_number, org_id, god_id, god_name, slot)
  SELECT p_session_id, p_match_id, p_game_number,
         item.org_id, item.god_id, item.god_name, item.slot
  FROM jsonb_to_recordset(p_bans)
    AS item(org_id text, god_id text, god_name text, slot integer);

  INSERT INTO god_picks (session_id, match_id, game_number, org_id, god_id, god_name, slot)
  SELECT p_session_id, p_match_id, p_game_number,
         item.org_id, item.god_id, item.god_name, item.slot
  FROM jsonb_to_recordset(p_picks)
    AS item(org_id text, god_id text, god_name text, slot integer);

  UPDATE god_draft_sessions
    SET status          = 'complete',
        current_type    = NULL,
        current_side    = NULL,
        turn_started_at = NULL,
        draft_state     = p_draft_state,
        completed_at    = now(),
        updated_at      = now()
    WHERE id = p_session_id;
END;
$$;


ALTER FUNCTION "public"."complete_god_draft"("p_session_id" "text", "p_match_id" "text", "p_game_number" integer, "p_draft_state" "jsonb", "p_bans" "jsonb", "p_picks" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."replace_match_report_stats"("p_match_report_id" "uuid", "p_rows" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  PERFORM 1 FROM match_reports WHERE id = p_match_report_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Report not found.';
  END IF;

  DELETE FROM player_match_stats WHERE match_report_id = p_match_report_id;

  INSERT INTO player_match_stats (
    match_report_id, match_id, player_id, player_ign, game_number, org_id,
    won, kills, deaths, assists, god_played, role,
    damage_dealt, damage_mitigated, season_id, division_id
  )
  SELECT
    p_match_report_id, item.match_id, item.player_id, item.player_ign,
    item.game_number, item.org_id, item.won, item.kills, item.deaths,
    item.assists, item.god_played, item.role, item.damage_dealt,
    item.damage_mitigated, item.season_id, item.division_id
  FROM jsonb_to_recordset(p_rows) AS item(
    match_id text,
    player_id text,
    player_ign text,
    game_number integer,
    org_id text,
    won boolean,
    kills integer,
    deaths integer,
    assists integer,
    god_played text,
    role text,
    damage_dealt integer,
    damage_mitigated integer,
    season_id text,
    division_id text
  );
END;
$$;


ALTER FUNCTION "public"."replace_match_report_stats"("p_match_report_id" "uuid", "p_rows" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."replace_standings"("p_rows" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  DELETE FROM standings
  WHERE org_id NOT IN (
    SELECT item.org_id FROM jsonb_to_recordset(p_rows) AS item(org_id text)
  );

  INSERT INTO standings (
    org_id, division_id, wins, losses, matches_played,
    points_for, points_against, streak, games_back
  )
  SELECT
    item.org_id, item.division_id, item.wins, item.losses,
    item.matches_played, item.points_for, item.points_against,
    item.streak, item.games_back
  FROM jsonb_to_recordset(p_rows) AS item(
    org_id text,
    division_id text,
    wins integer,
    losses integer,
    matches_played integer,
    points_for integer,
    points_against integer,
    streak jsonb,
    games_back numeric
  )
  ON CONFLICT (org_id) DO UPDATE SET
    division_id = EXCLUDED.division_id,
    wins = EXCLUDED.wins,
    losses = EXCLUDED.losses,
    matches_played = EXCLUDED.matches_played,
    points_for = EXCLUDED.points_for,
    points_against = EXCLUDED.points_against,
    streak = EXCLUDED.streak,
    games_back = EXCLUDED.games_back;
END;
$$;


ALTER FUNCTION "public"."replace_standings"("p_rows" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_draft_pick"("p_draft_room_id" "text", "p_org_id" "text", "p_player_id" "text", "p_expected_pick_index" integer, "p_total_picks" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_room draft_rooms%ROWTYPE;
  v_next_index integer;
  v_is_complete boolean;
BEGIN
  SELECT * INTO v_room
  FROM draft_rooms
  WHERE id = p_draft_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Draft not found.';
  END IF;
  IF v_room.status <> 'active' THEN
    RAISE EXCEPTION 'Draft is %, picks are not allowed.', v_room.status;
  END IF;
  IF v_room.current_pick_index <> p_expected_pick_index THEN
    RAISE EXCEPTION 'PICK_CONFLICT: the pick index advanced before this pick was recorded.';
  END IF;

  INSERT INTO draft_picks (draft_room_id, pick_number, org_id, player_id)
  VALUES (p_draft_room_id, p_expected_pick_index + 1, p_org_id, p_player_id);

  v_next_index := p_expected_pick_index + 1;
  v_is_complete := v_next_index >= p_total_picks;

  UPDATE draft_rooms
  SET current_pick_index = v_next_index,
      status = CASE WHEN v_is_complete THEN 'complete' ELSE 'active' END,
      pick_started_at = CASE WHEN v_is_complete THEN NULL ELSE now() END,
      completed_at = CASE WHEN v_is_complete THEN now() ELSE NULL END
  WHERE id = p_draft_room_id;
END;
$$;


ALTER FUNCTION "public"."submit_draft_pick"("p_draft_room_id" "text", "p_org_id" "text", "p_player_id" "text", "p_expected_pick_index" integer, "p_total_picks" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."undo_last_pick"("p_draft_room_id" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_room draft_rooms%ROWTYPE;
  v_deleted integer;
BEGIN
  SELECT * INTO v_room
  FROM draft_rooms
  WHERE id = p_draft_room_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Draft room not found.';
  END IF;
  IF v_room.status <> 'active' THEN
    RAISE EXCEPTION 'Draft is not active.';
  END IF;
  IF v_room.current_pick_index <= 0 THEN
    RAISE EXCEPTION 'No picks to undo.';
  END IF;

  DELETE FROM draft_picks
  WHERE id = (
    SELECT id FROM draft_picks
    WHERE draft_room_id = p_draft_room_id
    ORDER BY pick_number DESC
    LIMIT 1
  );
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  IF v_deleted = 0 THEN
    RAISE EXCEPTION 'No picks found to undo.';
  END IF;

  UPDATE draft_rooms
  SET current_pick_index = v_room.current_pick_index - 1,
      pick_started_at = now()
  WHERE id = p_draft_room_id;
END;
$$;


ALTER FUNCTION "public"."undo_last_pick"("p_draft_room_id" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."admin_audit_log" (
    "id" bigint NOT NULL,
    "action" "text" NOT NULL,
    "entity_type" "text",
    "entity_id" "text",
    "payload" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."admin_audit_log" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."admin_audit_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."admin_audit_log_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."admin_audit_log_id_seq" OWNED BY "public"."admin_audit_log"."id";



CREATE TABLE IF NOT EXISTS "public"."admin_users" (
    "discord_id" "text" NOT NULL,
    "role" "text" NOT NULL,
    "discord_username" "text" DEFAULT ''::"text" NOT NULL,
    "display_name" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "admin_users_role_check" CHECK (("role" = ANY (ARRAY['super_admin'::"text", 'admin'::"text"])))
);


ALTER TABLE "public"."admin_users" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."announcements" (
    "id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone NOT NULL,
    "category" "text" NOT NULL,
    "pinned" boolean DEFAULT false NOT NULL,
    CONSTRAINT "announcements_category_check" CHECK (("category" = ANY (ARRAY['general'::"text", 'rules'::"text", 'draft'::"text", 'results'::"text", 'admin'::"text"])))
);


ALTER TABLE "public"."announcements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "id" "text" DEFAULT ("gen_random_uuid"())::"text" NOT NULL,
    "action_type" "text" NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "text" NOT NULL,
    "pending_action_id" "text",
    "actor_discord_id" "text" NOT NULL,
    "old_value_json" "jsonb",
    "new_value_json" "jsonb",
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."audit_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."captain_shortlists" (
    "id" "text" DEFAULT ("gen_random_uuid"())::"text" NOT NULL,
    "draft_room_id" "text" NOT NULL,
    "org_id" "text" NOT NULL,
    "player_id" "text" NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."captain_shortlists" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."captain_tokens" (
    "id" "text" NOT NULL,
    "draft_room_id" "text" NOT NULL,
    "org_id" "text" NOT NULL,
    "token_hash" "text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."captain_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."division_role_mappings" (
    "division_id" "text" NOT NULL,
    "discord_role_id" "text" NOT NULL,
    "updated_by_discord_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."division_role_mappings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."divisions" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text" NOT NULL,
    "tier" integer NOT NULL,
    "accent_color" "text" NOT NULL,
    CONSTRAINT "divisions_id_check" CHECK (("id" = ANY (ARRAY['solar'::"text", 'lunar'::"text", 'terra'::"text"])))
);


ALTER TABLE "public"."divisions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."draft_chat_messages" (
    "id" bigint NOT NULL,
    "session_id" "text" NOT NULL,
    "channel" "text" NOT NULL,
    "sender_name" "text" NOT NULL,
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "draft_chat_messages_body_check" CHECK ((("char_length"("body") >= 1) AND ("char_length"("body") <= 500))),
    CONSTRAINT "draft_chat_messages_channel_check" CHECK (("channel" = ANY (ARRAY['team'::"text", 'spectator'::"text"])))
);


ALTER TABLE "public"."draft_chat_messages" OWNER TO "postgres";


ALTER TABLE "public"."draft_chat_messages" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."draft_chat_messages_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."draft_picks" (
    "id" bigint NOT NULL,
    "draft_room_id" "text" NOT NULL,
    "pick_number" integer NOT NULL,
    "org_id" "text" NOT NULL,
    "player_id" "text" NOT NULL,
    "picked_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."draft_picks" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."draft_picks_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."draft_picks_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."draft_picks_id_seq" OWNED BY "public"."draft_picks"."id";



CREATE TABLE IF NOT EXISTS "public"."draft_rooms" (
    "id" "text" NOT NULL,
    "season_id" "text" NOT NULL,
    "division_id" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "rounds" integer DEFAULT 5 NOT NULL,
    "pick_timer_seconds" integer DEFAULT 120 NOT NULL,
    "base_order" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "current_pick_index" integer DEFAULT 0 NOT NULL,
    "pick_started_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    CONSTRAINT "draft_rooms_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'active'::"text", 'paused'::"text", 'complete'::"text"])))
);


ALTER TABLE "public"."draft_rooms" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."form_fields" (
    "id" "text" NOT NULL,
    "key" "text" NOT NULL,
    "label" "text" NOT NULL,
    "field_type" "text" NOT NULL,
    "required" boolean DEFAULT true NOT NULL,
    "field_order" integer NOT NULL,
    "options" "jsonb",
    "locked" boolean DEFAULT false NOT NULL,
    "hidden" boolean DEFAULT false NOT NULL,
    "placeholder" "text",
    "validation_hint" "text",
    CONSTRAINT "form_fields_field_type_check" CHECK (("field_type" = ANY (ARRAY['text'::"text", 'url'::"text", 'select'::"text", 'multiselect'::"text", 'checkbox'::"text", 'textarea'::"text"])))
);


ALTER TABLE "public"."form_fields" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."god_bans" (
    "id" bigint NOT NULL,
    "session_id" "text" NOT NULL,
    "match_id" "text" NOT NULL,
    "game_number" integer NOT NULL,
    "org_id" "text" NOT NULL,
    "god_id" "text" NOT NULL,
    "god_name" "text" NOT NULL,
    "slot" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."god_bans" OWNER TO "postgres";


ALTER TABLE "public"."god_bans" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."god_bans_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."god_draft_sessions" (
    "id" "text" DEFAULT ("gen_random_uuid"())::"text" NOT NULL,
    "match_id" "text" NOT NULL,
    "game_number" integer DEFAULT 1 NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "home_ready" boolean DEFAULT false NOT NULL,
    "away_ready" boolean DEFAULT false NOT NULL,
    "current_phase_index" integer DEFAULT 0 NOT NULL,
    "current_step_index" integer DEFAULT 0 NOT NULL,
    "current_type" "text",
    "current_side" "text",
    "turn_started_at" timestamp with time zone,
    "draft_state" "jsonb" DEFAULT '{"bans": [], "picks": []}'::"jsonb" NOT NULL,
    "reset_requested_by" "text",
    "completed_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "god_draft_sessions_current_side_check" CHECK (("current_side" = ANY (ARRAY['A'::"text", 'B'::"text"]))),
    CONSTRAINT "god_draft_sessions_current_type_check" CHECK (("current_type" = ANY (ARRAY['ban'::"text", 'pick'::"text"]))),
    CONSTRAINT "god_draft_sessions_reset_requested_by_check" CHECK (("reset_requested_by" = ANY (ARRAY['A'::"text", 'B'::"text"]))),
    CONSTRAINT "god_draft_sessions_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'lobby'::"text", 'banning'::"text", 'picking'::"text", 'complete'::"text"])))
);


ALTER TABLE "public"."god_draft_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."god_picks" (
    "id" bigint NOT NULL,
    "session_id" "text" NOT NULL,
    "match_id" "text" NOT NULL,
    "game_number" integer NOT NULL,
    "org_id" "text" NOT NULL,
    "god_id" "text" NOT NULL,
    "god_name" "text" NOT NULL,
    "slot" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."god_picks" OWNER TO "postgres";


ALTER TABLE "public"."god_picks" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."god_picks_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."gods" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "class" "text" NOT NULL,
    "god_class" "text" NOT NULL,
    "pantheon" "text",
    CONSTRAINT "gods_class_check" CHECK (("class" = ANY (ARRAY['Warrior'::"text", 'Guardian'::"text", 'Mage'::"text", 'Assassin'::"text", 'Hunter'::"text"]))),
    CONSTRAINT "gods_god_class_check" CHECK (("god_class" = ANY (ARRAY['Physical'::"text", 'Magical'::"text"])))
);


ALTER TABLE "public"."gods" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."match_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "match_id" "text" NOT NULL,
    "season_id" "text" NOT NULL,
    "division_id" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "submitted_by" "text" NOT NULL,
    "home_score" integer,
    "away_score" integer,
    "total_games" integer,
    "screenshot_urls" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "extracted_data" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_at" timestamp with time zone,
    "reviewed_by" "text",
    CONSTRAINT "match_reports_division_id_check" CHECK (("division_id" = ANY (ARRAY['gaia'::"text", 'solar'::"text", 'lunar'::"text"]))),
    CONSTRAINT "match_reports_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'extracting'::"text", 'review'::"text", 'done'::"text"])))
);


ALTER TABLE "public"."match_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."matches" (
    "id" "text" NOT NULL,
    "division_id" "text" NOT NULL,
    "home_org_id" "text" NOT NULL,
    "away_org_id" "text" NOT NULL,
    "scheduled_date" "date" NOT NULL,
    "scheduled_time" time without time zone NOT NULL,
    "status" "text" NOT NULL,
    "week" integer NOT NULL,
    "home_score" integer,
    "away_score" integer,
    "stream_url" "text",
    "vod_url" "text",
    "archived_at" timestamp with time zone,
    "deletion_scheduled_at" timestamp with time zone,
    "winner_org_id" "text",
    "score" "text",
    "proof_thread_id" "text",
    "proof_thread_url" "text",
    "screenshot_count" integer DEFAULT 0 NOT NULL,
    "screenshot_expected" integer,
    "season_id" "text",
    CONSTRAINT "matches_status_check" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'live'::"text", 'completed'::"text", 'postponed'::"text"])))
);


ALTER TABLE "public"."matches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."org_brands" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "tag" "text" NOT NULL
);


ALTER TABLE "public"."org_brands" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."orgs" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "tag" "text" NOT NULL,
    "division_id" "text" NOT NULL,
    "logo_initials" "text" NOT NULL,
    "logo_gradient" "text" NOT NULL,
    "primary_color" "text" NOT NULL,
    "accent_gradient" "text" NOT NULL,
    "captain_id" "text",
    "founded" "text",
    "social_links" "jsonb",
    "archived_at" timestamp with time zone,
    "deletion_scheduled_at" timestamp with time zone,
    "brand_id" "text"
);


ALTER TABLE "public"."orgs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pending_actions" (
    "id" "text" DEFAULT ("gen_random_uuid"())::"text" NOT NULL,
    "type" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "requested_by_discord_id" "text" NOT NULL,
    "match_id" "text",
    "division_id" "text",
    "payload_json" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "admin_note" "text",
    "source_discord_message_url" "text",
    "admin_review_message_id" "text",
    "public_receipt_message_id" "text",
    "approved_by_discord_id" "text",
    "approved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pending_actions_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'pending_info'::"text", 'approved'::"text", 'denied'::"text", 'cancelled'::"text"]))),
    CONSTRAINT "pending_actions_type_check" CHECK (("type" = ANY (ARRAY['match_result'::"text", 'reschedule'::"text", 'admin_review'::"text", 'alias_change'::"text"])))
);


ALTER TABLE "public"."pending_actions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pending_stat_records" (
    "id" "text" DEFAULT ("gen_random_uuid"())::"text" NOT NULL,
    "match_id" "text" NOT NULL,
    "player_id" "text",
    "screenshot_url" "text" NOT NULL,
    "extracted_json" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "stats_json" "jsonb",
    "confidence" numeric(4,3) NOT NULL,
    "source" "text" DEFAULT 'ocr'::"text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reviewed_by_discord_id" "text",
    "reviewed_at" timestamp with time zone,
    "correction_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pending_stat_records_confidence_check" CHECK ((("confidence" >= (0)::numeric) AND ("confidence" <= (1)::numeric))),
    CONSTRAINT "pending_stat_records_source_check" CHECK (("source" = ANY (ARRAY['ocr'::"text", 'manual'::"text"]))),
    CONSTRAINT "pending_stat_records_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'corrected'::"text", 'superseded'::"text"])))
);


ALTER TABLE "public"."pending_stat_records" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."player_match_stats" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "match_report_id" "uuid" NOT NULL,
    "match_id" "text" NOT NULL,
    "player_id" "text",
    "player_ign" "text" NOT NULL,
    "game_number" integer NOT NULL,
    "org_id" "text",
    "won" boolean NOT NULL,
    "kills" integer DEFAULT 0 NOT NULL,
    "deaths" integer DEFAULT 0 NOT NULL,
    "assists" integer DEFAULT 0 NOT NULL,
    "god_played" "text",
    "role" "text",
    "damage_dealt" integer,
    "damage_mitigated" integer,
    "season_id" "text" NOT NULL,
    "division_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."player_match_stats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."player_stats" (
    "id" "text" DEFAULT ("gen_random_uuid"())::"text" NOT NULL,
    "match_id" "text" NOT NULL,
    "player_id" "text" NOT NULL,
    "pending_stat_record_id" "text",
    "kills" integer,
    "deaths" integer,
    "assists" integer,
    "damage_dealt" integer,
    "healing_done" integer,
    "god_played" "text",
    "role" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "game_number" integer DEFAULT 1 NOT NULL,
    "damage_mitigated" integer,
    "won" boolean
);


ALTER TABLE "public"."player_stats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."players" (
    "id" "text" NOT NULL,
    "org_id" "text",
    "discord_username" "text" NOT NULL,
    "ign" "text" NOT NULL,
    "avatar_initials" "text" NOT NULL,
    "avatar_gradient" "text" NOT NULL,
    "primary_role" "text" NOT NULL,
    "secondary_roles" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "is_starter" boolean DEFAULT false NOT NULL,
    "is_captain" boolean DEFAULT false NOT NULL,
    "division_id" "text",
    "status" "text" NOT NULL,
    "stats" "jsonb",
    "discord_id" "text",
    "profile_claimed" boolean DEFAULT false NOT NULL,
    "archived_at" timestamp with time zone,
    "deletion_scheduled_at" timestamp with time zone,
    "display_alias" "text"
);


ALTER TABLE "public"."players" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."registrations" (
    "id" "text" NOT NULL,
    "discord_id" "text" NOT NULL,
    "discord_username" "text" NOT NULL,
    "discord_display_name" "text",
    "season_id" "text",
    "player_id" "text",
    "form_data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_at" timestamp with time zone,
    "reviewer_note" "text",
    CONSTRAINT "registrations_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."registrations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."seasons" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" NOT NULL,
    "start_date" "date" NOT NULL,
    "end_date" "date" NOT NULL,
    "current_week" integer DEFAULT 1 NOT NULL,
    CONSTRAINT "seasons_status_check" CHECK (("status" = ANY (ARRAY['pre-season'::"text", 'active'::"text", 'post-season'::"text", 'offseason'::"text"])))
);


ALTER TABLE "public"."seasons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."standings" (
    "org_id" "text" NOT NULL,
    "division_id" "text" NOT NULL,
    "wins" integer DEFAULT 0 NOT NULL,
    "losses" integer DEFAULT 0 NOT NULL,
    "matches_played" integer DEFAULT 0 NOT NULL,
    "points_for" integer DEFAULT 0 NOT NULL,
    "points_against" integer DEFAULT 0 NOT NULL,
    "streak" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "games_back" numeric DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."standings" OWNER TO "postgres";


ALTER TABLE ONLY "public"."admin_audit_log" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."admin_audit_log_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."draft_picks" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."draft_picks_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."admin_audit_log"
    ADD CONSTRAINT "admin_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admin_users"
    ADD CONSTRAINT "admin_users_pkey" PRIMARY KEY ("discord_id");



ALTER TABLE ONLY "public"."announcements"
    ADD CONSTRAINT "announcements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."captain_shortlists"
    ADD CONSTRAINT "captain_shortlists_draft_room_id_org_id_player_id_key" UNIQUE ("draft_room_id", "org_id", "player_id");



ALTER TABLE ONLY "public"."captain_shortlists"
    ADD CONSTRAINT "captain_shortlists_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."captain_tokens"
    ADD CONSTRAINT "captain_tokens_draft_room_id_org_id_key" UNIQUE ("draft_room_id", "org_id");



ALTER TABLE ONLY "public"."captain_tokens"
    ADD CONSTRAINT "captain_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."division_role_mappings"
    ADD CONSTRAINT "division_role_mappings_pkey" PRIMARY KEY ("division_id");



ALTER TABLE ONLY "public"."divisions"
    ADD CONSTRAINT "divisions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."draft_chat_messages"
    ADD CONSTRAINT "draft_chat_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."draft_picks"
    ADD CONSTRAINT "draft_picks_draft_room_id_pick_number_key" UNIQUE ("draft_room_id", "pick_number");



ALTER TABLE ONLY "public"."draft_picks"
    ADD CONSTRAINT "draft_picks_draft_room_id_player_id_key" UNIQUE ("draft_room_id", "player_id");



ALTER TABLE ONLY "public"."draft_picks"
    ADD CONSTRAINT "draft_picks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."draft_rooms"
    ADD CONSTRAINT "draft_rooms_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."draft_rooms"
    ADD CONSTRAINT "draft_rooms_season_id_division_id_key" UNIQUE ("season_id", "division_id");



ALTER TABLE ONLY "public"."form_fields"
    ADD CONSTRAINT "form_fields_key_key" UNIQUE ("key");



ALTER TABLE ONLY "public"."form_fields"
    ADD CONSTRAINT "form_fields_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."god_bans"
    ADD CONSTRAINT "god_bans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."god_draft_sessions"
    ADD CONSTRAINT "god_draft_sessions_match_id_game_number_key" UNIQUE ("match_id", "game_number");



ALTER TABLE ONLY "public"."god_draft_sessions"
    ADD CONSTRAINT "god_draft_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."god_picks"
    ADD CONSTRAINT "god_picks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gods"
    ADD CONSTRAINT "gods_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."gods"
    ADD CONSTRAINT "gods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."match_reports"
    ADD CONSTRAINT "match_reports_match_id_key" UNIQUE ("match_id");



ALTER TABLE ONLY "public"."match_reports"
    ADD CONSTRAINT "match_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."org_brands"
    ADD CONSTRAINT "org_brands_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."orgs"
    ADD CONSTRAINT "orgs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pending_actions"
    ADD CONSTRAINT "pending_actions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pending_stat_records"
    ADD CONSTRAINT "pending_stat_records_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."player_match_stats"
    ADD CONSTRAINT "player_match_stats_match_report_id_player_ign_game_number_key" UNIQUE ("match_report_id", "player_ign", "game_number");



ALTER TABLE ONLY "public"."player_match_stats"
    ADD CONSTRAINT "player_match_stats_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."player_stats"
    ADD CONSTRAINT "player_stats_match_id_player_id_game_number_key" UNIQUE ("match_id", "player_id", "game_number");



ALTER TABLE ONLY "public"."player_stats"
    ADD CONSTRAINT "player_stats_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."players"
    ADD CONSTRAINT "players_discord_id_key" UNIQUE ("discord_id");



ALTER TABLE ONLY "public"."players"
    ADD CONSTRAINT "players_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."registrations"
    ADD CONSTRAINT "registrations_discord_id_key" UNIQUE ("discord_id");



ALTER TABLE ONLY "public"."registrations"
    ADD CONSTRAINT "registrations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."seasons"
    ADD CONSTRAINT "seasons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."standings"
    ADD CONSTRAINT "standings_pkey" PRIMARY KEY ("org_id");



CREATE INDEX "admin_audit_log_created_idx" ON "public"."admin_audit_log" USING "btree" ("created_at" DESC);



CREATE INDEX "captain_tokens_hash_idx" ON "public"."captain_tokens" USING "btree" ("token_hash");



CREATE INDEX "draft_chat_messages_session_idx" ON "public"."draft_chat_messages" USING "btree" ("session_id", "created_at");



CREATE INDEX "draft_picks_room_idx" ON "public"."draft_picks" USING "btree" ("draft_room_id", "pick_number");



CREATE INDEX "god_bans_session_idx" ON "public"."god_bans" USING "btree" ("session_id");



CREATE INDEX "god_draft_sessions_match_idx" ON "public"."god_draft_sessions" USING "btree" ("match_id", "game_number");



CREATE INDEX "god_picks_vault_idx" ON "public"."god_picks" USING "btree" ("match_id", "game_number", "god_id");



CREATE INDEX "idx_audit_logs_actor" ON "public"."audit_logs" USING "btree" ("actor_discord_id");



CREATE INDEX "idx_audit_logs_created_at" ON "public"."audit_logs" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_audit_logs_entity" ON "public"."audit_logs" USING "btree" ("entity_type", "entity_id");



CREATE INDEX "idx_audit_logs_pending_action" ON "public"."audit_logs" USING "btree" ("pending_action_id");



CREATE INDEX "idx_division_role_mappings_role" ON "public"."division_role_mappings" USING "btree" ("discord_role_id");



CREATE INDEX "idx_matches_pending_delete" ON "public"."matches" USING "btree" ("deletion_scheduled_at") WHERE ("deletion_scheduled_at" IS NOT NULL);



CREATE INDEX "idx_matches_season" ON "public"."matches" USING "btree" ("season_id");



CREATE INDEX "idx_orgs_pending_delete" ON "public"."orgs" USING "btree" ("deletion_scheduled_at") WHERE ("deletion_scheduled_at" IS NOT NULL);



CREATE INDEX "idx_pending_actions_match_id" ON "public"."pending_actions" USING "btree" ("match_id");



CREATE INDEX "idx_pending_actions_requester" ON "public"."pending_actions" USING "btree" ("requested_by_discord_id");



CREATE INDEX "idx_pending_actions_status" ON "public"."pending_actions" USING "btree" ("status");



CREATE INDEX "idx_pending_actions_type" ON "public"."pending_actions" USING "btree" ("type");



CREATE INDEX "idx_pending_stat_records_match" ON "public"."pending_stat_records" USING "btree" ("match_id");



CREATE INDEX "idx_pending_stat_records_status" ON "public"."pending_stat_records" USING "btree" ("status");



CREATE INDEX "idx_player_stats_match" ON "public"."player_stats" USING "btree" ("match_id");



CREATE INDEX "idx_player_stats_match_game" ON "public"."player_stats" USING "btree" ("match_id", "game_number");



CREATE INDEX "idx_player_stats_player" ON "public"."player_stats" USING "btree" ("player_id");



CREATE INDEX "idx_players_pending_delete" ON "public"."players" USING "btree" ("deletion_scheduled_at") WHERE ("deletion_scheduled_at" IS NOT NULL);



CREATE INDEX "matches_schedule_idx" ON "public"."matches" USING "btree" ("scheduled_date", "scheduled_time");



CREATE INDEX "orgs_division_idx" ON "public"."orgs" USING "btree" ("division_id");



CREATE INDEX "players_org_idx" ON "public"."players" USING "btree" ("org_id");



CREATE UNIQUE INDEX "seasons_single_active" ON "public"."seasons" USING "btree" ("status") WHERE ("status" = 'active'::"text");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pending_action_id_fkey" FOREIGN KEY ("pending_action_id") REFERENCES "public"."pending_actions"("id");



ALTER TABLE ONLY "public"."captain_shortlists"
    ADD CONSTRAINT "captain_shortlists_draft_room_id_fkey" FOREIGN KEY ("draft_room_id") REFERENCES "public"."draft_rooms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."captain_tokens"
    ADD CONSTRAINT "captain_tokens_draft_room_id_fkey" FOREIGN KEY ("draft_room_id") REFERENCES "public"."draft_rooms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."captain_tokens"
    ADD CONSTRAINT "captain_tokens_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "public"."orgs"("id");



ALTER TABLE ONLY "public"."division_role_mappings"
    ADD CONSTRAINT "division_role_mappings_division_id_fkey" FOREIGN KEY ("division_id") REFERENCES "public"."divisions"("id");



ALTER TABLE ONLY "public"."draft_chat_messages"
    ADD CONSTRAINT "draft_chat_messages_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."god_draft_sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."draft_picks"
    ADD CONSTRAINT "draft_picks_draft_room_id_fkey" FOREIGN KEY ("draft_room_id") REFERENCES "public"."draft_rooms"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."draft_picks"
    ADD CONSTRAINT "draft_picks_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "public"."orgs"("id");



ALTER TABLE ONLY "public"."draft_picks"
    ADD CONSTRAINT "draft_picks_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id");



ALTER TABLE ONLY "public"."draft_rooms"
    ADD CONSTRAINT "draft_rooms_division_id_fkey" FOREIGN KEY ("division_id") REFERENCES "public"."divisions"("id");



ALTER TABLE ONLY "public"."draft_rooms"
    ADD CONSTRAINT "draft_rooms_season_id_fkey" FOREIGN KEY ("season_id") REFERENCES "public"."seasons"("id");



ALTER TABLE ONLY "public"."god_bans"
    ADD CONSTRAINT "god_bans_god_id_fkey" FOREIGN KEY ("god_id") REFERENCES "public"."gods"("id");



ALTER TABLE ONLY "public"."god_bans"
    ADD CONSTRAINT "god_bans_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."matches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."god_bans"
    ADD CONSTRAINT "god_bans_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "public"."orgs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."god_bans"
    ADD CONSTRAINT "god_bans_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."god_draft_sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."god_draft_sessions"
    ADD CONSTRAINT "god_draft_sessions_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."matches"("id");



ALTER TABLE ONLY "public"."god_picks"
    ADD CONSTRAINT "god_picks_god_id_fkey" FOREIGN KEY ("god_id") REFERENCES "public"."gods"("id");



ALTER TABLE ONLY "public"."god_picks"
    ADD CONSTRAINT "god_picks_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."matches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."god_picks"
    ADD CONSTRAINT "god_picks_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "public"."orgs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."god_picks"
    ADD CONSTRAINT "god_picks_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."god_draft_sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."match_reports"
    ADD CONSTRAINT "match_reports_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."matches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_away_org_id_fkey" FOREIGN KEY ("away_org_id") REFERENCES "public"."orgs"("id");



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_division_id_fkey" FOREIGN KEY ("division_id") REFERENCES "public"."divisions"("id");



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_home_org_id_fkey" FOREIGN KEY ("home_org_id") REFERENCES "public"."orgs"("id");



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_season_id_fkey" FOREIGN KEY ("season_id") REFERENCES "public"."seasons"("id");



ALTER TABLE ONLY "public"."matches"
    ADD CONSTRAINT "matches_winner_org_id_fkey" FOREIGN KEY ("winner_org_id") REFERENCES "public"."orgs"("id");



ALTER TABLE ONLY "public"."orgs"
    ADD CONSTRAINT "orgs_brand_id_fkey" FOREIGN KEY ("brand_id") REFERENCES "public"."org_brands"("id");



ALTER TABLE ONLY "public"."orgs"
    ADD CONSTRAINT "orgs_captain_id_fkey" FOREIGN KEY ("captain_id") REFERENCES "public"."players"("id") DEFERRABLE INITIALLY DEFERRED;



ALTER TABLE ONLY "public"."orgs"
    ADD CONSTRAINT "orgs_division_id_fkey" FOREIGN KEY ("division_id") REFERENCES "public"."divisions"("id");



ALTER TABLE ONLY "public"."pending_actions"
    ADD CONSTRAINT "pending_actions_division_id_fkey" FOREIGN KEY ("division_id") REFERENCES "public"."divisions"("id");



ALTER TABLE ONLY "public"."pending_actions"
    ADD CONSTRAINT "pending_actions_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."matches"("id");



ALTER TABLE ONLY "public"."pending_stat_records"
    ADD CONSTRAINT "pending_stat_records_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."matches"("id");



ALTER TABLE ONLY "public"."pending_stat_records"
    ADD CONSTRAINT "pending_stat_records_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id");



ALTER TABLE ONLY "public"."player_match_stats"
    ADD CONSTRAINT "player_match_stats_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."matches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_match_stats"
    ADD CONSTRAINT "player_match_stats_match_report_id_fkey" FOREIGN KEY ("match_report_id") REFERENCES "public"."match_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_match_stats"
    ADD CONSTRAINT "player_match_stats_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "public"."orgs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."player_match_stats"
    ADD CONSTRAINT "player_match_stats_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."player_stats"
    ADD CONSTRAINT "player_stats_match_id_fkey" FOREIGN KEY ("match_id") REFERENCES "public"."matches"("id");



ALTER TABLE ONLY "public"."player_stats"
    ADD CONSTRAINT "player_stats_pending_stat_record_id_fkey" FOREIGN KEY ("pending_stat_record_id") REFERENCES "public"."pending_stat_records"("id");



ALTER TABLE ONLY "public"."player_stats"
    ADD CONSTRAINT "player_stats_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id");



ALTER TABLE ONLY "public"."players"
    ADD CONSTRAINT "players_division_id_fkey" FOREIGN KEY ("division_id") REFERENCES "public"."divisions"("id");



ALTER TABLE ONLY "public"."players"
    ADD CONSTRAINT "players_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "public"."orgs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."registrations"
    ADD CONSTRAINT "registrations_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."registrations"
    ADD CONSTRAINT "registrations_season_id_fkey" FOREIGN KEY ("season_id") REFERENCES "public"."seasons"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."standings"
    ADD CONSTRAINT "standings_division_id_fkey" FOREIGN KEY ("division_id") REFERENCES "public"."divisions"("id");



ALTER TABLE ONLY "public"."standings"
    ADD CONSTRAINT "standings_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "public"."orgs"("id") ON DELETE CASCADE;



ALTER TABLE "public"."admin_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."admin_users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."announcements" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "anon insert" ON "public"."registrations" FOR INSERT WITH CHECK (true);



ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."captain_shortlists" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."captain_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."division_role_mappings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."divisions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."draft_chat_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."draft_picks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."draft_rooms" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."form_fields" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."god_bans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."god_draft_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."god_picks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gods" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "gods_public_read" ON "public"."gods" FOR SELECT USING (true);



ALTER TABLE "public"."match_reports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."matches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."org_brands" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."orgs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pending_actions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pending_stat_records" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."player_match_stats" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."player_stats" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "player_stats_public_read" ON "public"."player_stats" FOR SELECT USING (true);



ALTER TABLE "public"."players" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "public read" ON "public"."announcements" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."divisions" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."draft_chat_messages" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."draft_picks" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."draft_rooms" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."form_fields" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."god_bans" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."god_draft_sessions" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."god_picks" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."matches" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."org_brands" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."orgs" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."players" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."seasons" FOR SELECT USING (true);



CREATE POLICY "public read" ON "public"."standings" FOR SELECT USING (true);



CREATE POLICY "public_read_player_match_stats" ON "public"."player_match_stats" FOR SELECT TO "anon" USING (true);



ALTER TABLE "public"."registrations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."seasons" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "service_role_all_match_reports" ON "public"."match_reports" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_role_all_player_match_stats" ON "public"."player_match_stats" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."standings" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."draft_chat_messages";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."god_draft_sessions";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."complete_god_draft"("p_session_id" "text", "p_match_id" "text", "p_game_number" integer, "p_draft_state" "jsonb", "p_bans" "jsonb", "p_picks" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."complete_god_draft"("p_session_id" "text", "p_match_id" "text", "p_game_number" integer, "p_draft_state" "jsonb", "p_bans" "jsonb", "p_picks" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."complete_god_draft"("p_session_id" "text", "p_match_id" "text", "p_game_number" integer, "p_draft_state" "jsonb", "p_bans" "jsonb", "p_picks" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."replace_match_report_stats"("p_match_report_id" "uuid", "p_rows" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."replace_match_report_stats"("p_match_report_id" "uuid", "p_rows" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."replace_standings"("p_rows" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."replace_standings"("p_rows" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_draft_pick"("p_draft_room_id" "text", "p_org_id" "text", "p_player_id" "text", "p_expected_pick_index" integer, "p_total_picks" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_draft_pick"("p_draft_room_id" "text", "p_org_id" "text", "p_player_id" "text", "p_expected_pick_index" integer, "p_total_picks" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."undo_last_pick"("p_draft_room_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."undo_last_pick"("p_draft_room_id" "text") TO "service_role";


















GRANT ALL ON TABLE "public"."admin_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."admin_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_audit_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."admin_audit_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."admin_audit_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."admin_audit_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."admin_users" TO "anon";
GRANT ALL ON TABLE "public"."admin_users" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_users" TO "service_role";



GRANT ALL ON TABLE "public"."announcements" TO "anon";
GRANT ALL ON TABLE "public"."announcements" TO "authenticated";
GRANT ALL ON TABLE "public"."announcements" TO "service_role";



GRANT ALL ON TABLE "public"."audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."captain_shortlists" TO "anon";
GRANT ALL ON TABLE "public"."captain_shortlists" TO "authenticated";
GRANT ALL ON TABLE "public"."captain_shortlists" TO "service_role";



GRANT ALL ON TABLE "public"."captain_tokens" TO "anon";
GRANT ALL ON TABLE "public"."captain_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."captain_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."division_role_mappings" TO "anon";
GRANT ALL ON TABLE "public"."division_role_mappings" TO "authenticated";
GRANT ALL ON TABLE "public"."division_role_mappings" TO "service_role";



GRANT ALL ON TABLE "public"."divisions" TO "anon";
GRANT ALL ON TABLE "public"."divisions" TO "authenticated";
GRANT ALL ON TABLE "public"."divisions" TO "service_role";



GRANT ALL ON TABLE "public"."draft_chat_messages" TO "anon";
GRANT ALL ON TABLE "public"."draft_chat_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."draft_chat_messages" TO "service_role";



GRANT ALL ON SEQUENCE "public"."draft_chat_messages_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."draft_chat_messages_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."draft_chat_messages_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."draft_picks" TO "anon";
GRANT ALL ON TABLE "public"."draft_picks" TO "authenticated";
GRANT ALL ON TABLE "public"."draft_picks" TO "service_role";



GRANT ALL ON SEQUENCE "public"."draft_picks_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."draft_picks_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."draft_picks_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."draft_rooms" TO "anon";
GRANT ALL ON TABLE "public"."draft_rooms" TO "authenticated";
GRANT ALL ON TABLE "public"."draft_rooms" TO "service_role";



GRANT ALL ON TABLE "public"."form_fields" TO "anon";
GRANT ALL ON TABLE "public"."form_fields" TO "authenticated";
GRANT ALL ON TABLE "public"."form_fields" TO "service_role";



GRANT ALL ON TABLE "public"."god_bans" TO "anon";
GRANT ALL ON TABLE "public"."god_bans" TO "authenticated";
GRANT ALL ON TABLE "public"."god_bans" TO "service_role";



GRANT ALL ON SEQUENCE "public"."god_bans_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."god_bans_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."god_bans_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."god_draft_sessions" TO "anon";
GRANT ALL ON TABLE "public"."god_draft_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."god_draft_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."god_picks" TO "anon";
GRANT ALL ON TABLE "public"."god_picks" TO "authenticated";
GRANT ALL ON TABLE "public"."god_picks" TO "service_role";



GRANT ALL ON SEQUENCE "public"."god_picks_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."god_picks_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."god_picks_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."gods" TO "anon";
GRANT ALL ON TABLE "public"."gods" TO "authenticated";
GRANT ALL ON TABLE "public"."gods" TO "service_role";



GRANT ALL ON TABLE "public"."match_reports" TO "anon";
GRANT ALL ON TABLE "public"."match_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."match_reports" TO "service_role";



GRANT ALL ON TABLE "public"."matches" TO "anon";
GRANT ALL ON TABLE "public"."matches" TO "authenticated";
GRANT ALL ON TABLE "public"."matches" TO "service_role";



GRANT ALL ON TABLE "public"."org_brands" TO "anon";
GRANT ALL ON TABLE "public"."org_brands" TO "authenticated";
GRANT ALL ON TABLE "public"."org_brands" TO "service_role";



GRANT ALL ON TABLE "public"."orgs" TO "anon";
GRANT ALL ON TABLE "public"."orgs" TO "authenticated";
GRANT ALL ON TABLE "public"."orgs" TO "service_role";



GRANT ALL ON TABLE "public"."pending_actions" TO "anon";
GRANT ALL ON TABLE "public"."pending_actions" TO "authenticated";
GRANT ALL ON TABLE "public"."pending_actions" TO "service_role";



GRANT ALL ON TABLE "public"."pending_stat_records" TO "anon";
GRANT ALL ON TABLE "public"."pending_stat_records" TO "authenticated";
GRANT ALL ON TABLE "public"."pending_stat_records" TO "service_role";



GRANT ALL ON TABLE "public"."player_match_stats" TO "anon";
GRANT ALL ON TABLE "public"."player_match_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."player_match_stats" TO "service_role";



GRANT ALL ON TABLE "public"."player_stats" TO "anon";
GRANT ALL ON TABLE "public"."player_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."player_stats" TO "service_role";



GRANT ALL ON TABLE "public"."players" TO "anon";
GRANT ALL ON TABLE "public"."players" TO "authenticated";
GRANT ALL ON TABLE "public"."players" TO "service_role";



GRANT ALL ON TABLE "public"."registrations" TO "anon";
GRANT ALL ON TABLE "public"."registrations" TO "authenticated";
GRANT ALL ON TABLE "public"."registrations" TO "service_role";



GRANT ALL ON TABLE "public"."seasons" TO "anon";
GRANT ALL ON TABLE "public"."seasons" TO "authenticated";
GRANT ALL ON TABLE "public"."seasons" TO "service_role";



GRANT ALL ON TABLE "public"."standings" TO "anon";
GRANT ALL ON TABLE "public"."standings" TO "authenticated";
GRANT ALL ON TABLE "public"."standings" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";


-- Application-owned Storage configuration is excluded from Supabase's default
-- schema dump, so capture the verified production bucket and policies here.
INSERT INTO "storage"."buckets" (
  "id",
  "name",
  "public",
  "file_size_limit",
  "allowed_mime_types"
) VALUES (
  'match-screenshots',
  'match-screenshots',
  true,
  10485760,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']::text[]
)
ON CONFLICT ("id") DO UPDATE SET
  "name" = EXCLUDED."name",
  "public" = EXCLUDED."public",
  "file_size_limit" = EXCLUDED."file_size_limit",
  "allowed_mime_types" = EXCLUDED."allowed_mime_types";

DROP POLICY IF EXISTS "public_read_match_screenshots" ON "storage"."objects";
CREATE POLICY "public_read_match_screenshots"
  ON "storage"."objects"
  FOR SELECT
  TO "anon"
  USING (("bucket_id" = 'match-screenshots'::text));

DROP POLICY IF EXISTS "service_role_storage_match_screenshots" ON "storage"."objects";
CREATE POLICY "service_role_storage_match_screenshots"
  ON "storage"."objects"
  TO "service_role"
  USING (("bucket_id" = 'match-screenshots'::text))
  WITH CHECK (("bucket_id" = 'match-screenshots'::text));






























