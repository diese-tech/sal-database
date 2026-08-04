-- Tighten the canonically owned avatar columns to the same Discord CDN trust
-- boundary enforced by sal-site. The historical 20260803211920 migration owns
-- column creation; this forward migration adds validation without rewriting
-- existing values.

DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.players'::regclass
      AND conname = 'players_avatar_url_discord_cdn_check'
  ) THEN
    ALTER TABLE public.players
      ADD CONSTRAINT players_avatar_url_discord_cdn_check
      CHECK (
        avatar_url IS NULL
        OR avatar_url ~ '^https://(cdn[.]discordapp[.]com|media[.]discordapp[.]net)/'
      ) NOT VALID;
  END IF;
END
$migration$;

DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.registrations'::regclass
      AND conname = 'registrations_avatar_url_discord_cdn_check'
  ) THEN
    ALTER TABLE public.registrations
      ADD CONSTRAINT registrations_avatar_url_discord_cdn_check
      CHECK (
        avatar_url IS NULL
        OR avatar_url ~ '^https://(cdn[.]discordapp[.]com|media[.]discordapp[.]net)/'
      ) NOT VALID;
  END IF;
END
$migration$;

ALTER TABLE public.players
  VALIDATE CONSTRAINT players_avatar_url_discord_cdn_check;

ALTER TABLE public.registrations
  VALIDATE CONSTRAINT registrations_avatar_url_discord_cdn_check;

COMMENT ON COLUMN public.players.avatar_url IS
  'Validated Discord CDN avatar URL captured from the player OAuth identity.';

COMMENT ON COLUMN public.registrations.avatar_url IS
  'Validated Discord CDN avatar URL captured at registration time.';

-- Captain assignment is season-scoped. Enforce the same one-captain-per-org
-- rule at the write boundary so concurrent admin saves cannot create two
-- active captains for a single season team.
CREATE UNIQUE INDEX season_rosters_one_active_captain_per_org_idx
  ON public.season_rosters (season_id, org_id)
  WHERE is_captain
    AND roster_status = 'active'
    AND org_id IS NOT NULL;
