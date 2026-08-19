# Database release and deployment

1. Merge a backward-compatible migration and regenerated contract on `main`.
2. Set `[db].major_version` to the PostgreSQL major confirmed by the restored
   production database. Released contracts fail validation if this pin is
   absent.
3. Generate the deployment-input digest with
   `node scripts/hash-deployment-inputs.mjs <contract-commit>` and commit
   `recovery-attestation.json` separately. It references that prior contract
   commit, hashes `contract.json`, the complete critical deployment-input
   manifest, and the private restore evidence bundle, records measured RPO/RTO,
   confirms the captured ledger, migration `025` disposition, and baseline
   parity, and expires within 30 days. No critical deployment input may change
   between the attested contract commit and the dispatched commit.
4. An operator who can access the private restore bundle computes its SHA-256
   independently. Select the exact 40-character attestation commit in the
   manual workflow and enter that digest; preflight requires it to match the
   attested `restoreEvidenceSha256` without uploading the private bundle.
5. The secretless preflight binds the request, contract, commit, tag, and
   recovery evidence before any protected credential becomes available.
6. The `production-plan` job repeats local reset, lint, pgTAP, generated types,
   and a linked dry run, then publishes a hashed review artifact and job summary.
7. Protect both environments. `production-plan` requires a maintainer review of
   the exact commit before exposing planning credentials; `production` requires
   a second approval after the hashed plan is reviewed. Scope credentials only
   to the CLI steps that need them. Use distinct least-privilege planning
   credentials if the Supabase project supports them.
   All third-party actions in the workflow are pinned to full commit SHAs;
   Dependabot proposes reviewed pin updates.
8. Apply rechecks the approved remote ledger state and requires its regenerated
   dry-run bytes and SHA-256 to match the approved artifact before pushing.
9. After the push, require exact ledger parity, an empty push dry run, linked
   pgTAP assertions, and an empty normalized diff for the application-owned
   `public` schema. pgTAP separately covers managed storage and Realtime state.
10. Publish the immutable `db-vMAJOR.MINOR.PATCH` release only after success.
11. Update both consumer lock manifests and vendored type files.
12. Remove obsolete objects only in a later major release after both consumers
   stop using them.

## db-v1.18.0 match-report preflight

Before approving the protected plan for migration `20260818120000`, run these
read-only queries against production and attach the counts (not league data) to
the plan review. The first query must return no rows; otherwise the new partial
unique index would abort and the duplicate actions require a separately audited
forward repair.

```sql
SELECT match_id, count(*) AS open_result_actions
FROM public.pending_actions
WHERE type = 'match_result'
  AND status IN ('pending', 'pending_info')
GROUP BY match_id
HAVING count(*) > 1
ORDER BY match_id;

SELECT
  count(*) FILTER (
    WHERE fully_linked IS TRUE AND invalid_game_shape IS NOT TRUE
      AND scope_conflict IS NOT TRUE
      AND NOT duplicate_identities AND NOT canonical_conflict
  ) AS backfillable,
  count(*) FILTER (
    WHERE fully_linked IS NOT TRUE OR invalid_game_shape IS TRUE
      OR scope_conflict IS TRUE
  ) AS incomplete_unlinked_or_mis_scoped,
  count(*) FILTER (WHERE duplicate_identities) AS duplicate_source_identities,
  count(*) FILTER (WHERE canonical_conflict) AS canonical_provenance_conflicts
FROM (
  SELECT
    reports.id,
    reports.total_games BETWEEN 1 AND 5
      AND count(stats.id) = reports.total_games * 10
      AND count(stats.id) FILTER (WHERE stats.player_id IS NULL) = 0 AS fully_linked,
    bool_or(
      stats.id IS NOT NULL AND (
        stats.match_id IS DISTINCT FROM reports.match_id
        OR stats.season_id IS DISTINCT FROM reports.season_id
        OR stats.division_id IS DISTINCT FROM reports.division_id
      )
    ) AS scope_conflict,
    EXISTS (
      SELECT 1
      FROM public.player_match_stats AS game_stats
      JOIN public.matches AS matches ON matches.id = reports.match_id
      WHERE game_stats.match_report_id = reports.id
      GROUP BY game_stats.game_number, matches.home_org_id, matches.away_org_id
      HAVING game_stats.game_number < 1
        OR game_stats.game_number > reports.total_games
        OR count(*) <> 10
        OR count(*) FILTER (WHERE game_stats.org_id = matches.home_org_id) <> 5
        OR count(*) FILTER (WHERE game_stats.org_id = matches.away_org_id) <> 5
    ) OR count(DISTINCT stats.game_number) IS DISTINCT FROM reports.total_games
      AS invalid_game_shape,
    EXISTS (
      SELECT 1
      FROM public.player_match_stats AS duplicate_stats
      WHERE duplicate_stats.match_report_id = reports.id
      GROUP BY duplicate_stats.match_id, duplicate_stats.player_id,
        duplicate_stats.game_number
      HAVING count(*) > 1
    ) AS duplicate_identities,
    EXISTS (
      SELECT 1
      FROM public.player_stats AS official
      WHERE official.match_id = reports.match_id
    ) AS canonical_conflict
  FROM public.match_reports AS reports
  LEFT JOIN public.player_match_stats AS stats
    ON stats.match_report_id = reports.id
  WHERE reports.status = 'done'
  GROUP BY reports.id
) AS legacy_done;
```

The migration backfills only complete, fully linked reports with no existing
canonical rows for the match. Incomplete or conflicting reports remain
unchanged and require an explicit reviewed repair; never delete or reassign
their official rows during deployment.

The attestation file is intentionally absent from the recovery-gated bootstrap,
so the production workflow cannot reach either credentialed job yet.

Never use `db reset`, `db push --include-all`, or destructive repair as a
production rollback. Production corrections are forward migrations.
