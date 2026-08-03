-- Keep active season participation and global identity availability consistent.
--
-- The row locks in the child-write branches serialize enrollment against an
-- archive of the referenced identity. The archive branches run while PostgreSQL
-- holds the identity row lock, so they see any enrollment that won the race and
-- reject the archive instead of committing a broken cross-table state.

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.enforce_season_identity_availability()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF TG_TABLE_NAME = 'season_orgs' THEN
    IF NEW.status = 'active' THEN
      PERFORM 1
      FROM public.orgs
      WHERE id = NEW.org_id
        AND archived_at IS NULL
      FOR SHARE;

      IF NOT FOUND THEN
        RAISE EXCEPTION
          'Cannot enroll unavailable org %. Restore the org before assigning active season participation.',
          NEW.org_id
          USING ERRCODE = '23514';
      END IF;
    END IF;

    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'season_rosters' THEN
    IF NEW.roster_status IN ('active', 'free_agent') THEN
      PERFORM 1
      FROM public.players
      WHERE id = NEW.player_id
        AND archived_at IS NULL
      FOR SHARE;

      IF NOT FOUND THEN
        RAISE EXCEPTION
          'Cannot enroll unavailable player %. Restore the player before assigning active season participation.',
          NEW.player_id
          USING ERRCODE = '23514';
      END IF;

      IF NEW.org_id IS NOT NULL THEN
        PERFORM 1
        FROM public.orgs
        WHERE id = NEW.org_id
          AND archived_at IS NULL
        FOR SHARE;

        IF NOT FOUND THEN
          RAISE EXCEPTION
            'Cannot enroll unavailable org %. Restore the org before assigning active season participation.',
            NEW.org_id
            USING ERRCODE = '23514';
        END IF;
      END IF;
    END IF;

    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'players' THEN
    IF OLD.archived_at IS NULL AND NEW.archived_at IS NOT NULL
       AND EXISTS (
         SELECT 1
         FROM public.season_rosters
         WHERE player_id = NEW.id
           AND roster_status IN ('active', 'free_agent')
       ) THEN
      RAISE EXCEPTION
        'Cannot archive player % while active season participation exists. Remove active season roster assignments first.',
        NEW.id
        USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'orgs' THEN
    IF OLD.archived_at IS NULL AND NEW.archived_at IS NOT NULL
       AND (
         EXISTS (
           SELECT 1
           FROM public.season_orgs
           WHERE org_id = NEW.id
             AND status = 'active'
         )
         OR EXISTS (
           SELECT 1
           FROM public.season_rosters
           WHERE org_id = NEW.id
             AND roster_status = 'active'
         )
       ) THEN
      RAISE EXCEPTION
        'Cannot archive org % while active season participation exists. Remove active season assignments first.',
        NEW.id
        USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'Unsupported identity availability trigger table: %', TG_TABLE_NAME;
END;
$$;

ALTER FUNCTION private.enforce_season_identity_availability() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.enforce_season_identity_availability() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER season_orgs_identity_availability_guard
  BEFORE INSERT OR UPDATE OF org_id, status
  ON public.season_orgs
  FOR EACH ROW
  EXECUTE FUNCTION private.enforce_season_identity_availability();

CREATE TRIGGER season_rosters_identity_availability_guard
  BEFORE INSERT OR UPDATE OF player_id, org_id, roster_status
  ON public.season_rosters
  FOR EACH ROW
  EXECUTE FUNCTION private.enforce_season_identity_availability();

CREATE TRIGGER players_active_participation_archive_guard
  BEFORE UPDATE OF archived_at
  ON public.players
  FOR EACH ROW
  EXECUTE FUNCTION private.enforce_season_identity_availability();

CREATE TRIGGER orgs_active_participation_archive_guard
  BEFORE UPDATE OF archived_at
  ON public.orgs
  FOR EACH ROW
  EXECUTE FUNCTION private.enforce_season_identity_availability();

COMMENT ON FUNCTION private.enforce_season_identity_availability() IS
  'Atomically prevents active season assignments from referencing archived identities and prevents identities with active participation from being archived.';
