# Active migration sequence

The active sequence starts with
`20260717143900_production_baseline.sql`, a schema-only export of the verified
production state at the 2026-07-17 schema freeze.

The baseline was not assembled by concatenating the historical site and bot
migration directories. Migrations `019` through `025` from the archived site
sequence were not recorded in production and their effects were not all
present, so they must not be applied or marked as completed during adoption.

All later changes are reviewed, forward-only 14-digit migrations owned here.
Production deployment remains disabled until the protected baseline-adoption
procedure and recovery attestation are complete.
