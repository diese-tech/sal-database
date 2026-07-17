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
   and expires within 30 days. No critical deployment input may change between
   the attested contract commit and the dispatched commit.
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

The attestation file is intentionally absent from the recovery-gated bootstrap,
so the production workflow cannot reach either credentialed job yet.

Never use `db reset`, `db push --include-all`, or destructive repair as a
production rollback. Production corrections are forward migrations.
