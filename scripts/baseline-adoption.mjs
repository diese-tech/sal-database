import { existsSync, readFileSync } from 'node:fs';

const BASELINE_CONTRACT_VERSION = 'db-v1.0.0';
const BASELINE_MIGRATION_NAME = 'production_baseline.sql';

export const validateBaselineAdoption = ({ adoption, contract, baselineMigrationExists }) => {
  if (adoption.adoptionVersion !== 1) {
    throw new Error('baseline-adoption.json must use adoptionVersion 1.');
  }
  if (adoption.contractVersion !== BASELINE_CONTRACT_VERSION) {
    throw new Error(`Baseline adoption must remain pinned to ${BASELINE_CONTRACT_VERSION}.`);
  }
  if (!/^\d{14}$/.test(adoption.migrationHead)) {
    throw new Error('Baseline adoption requires a 14-digit migration head.');
  }
  if (!baselineMigrationExists) {
    throw new Error('The canonical production baseline migration is missing.');
  }
  if (!/^\d{14}$/.test(contract.migrationHead) || contract.migrationHead < adoption.migrationHead) {
    throw new Error('The current contract cannot precede the adopted baseline.');
  }
  if (!Array.isArray(adoption.historicalMigrations) || adoption.historicalMigrations.length === 0) {
    throw new Error('Baseline adoption requires a non-empty historical migration allowlist.');
  }

  const versions = adoption.historicalMigrations.map(({ version, name }) => {
    if (!/^\d{14}$/.test(version) || typeof name !== 'string' || name.trim() === '') {
      throw new Error('Every historical migration requires a 14-digit version and name.');
    }
    return version;
  });
  if (new Set(versions).size !== versions.length) {
    throw new Error('Historical migration versions must be unique.');
  }
  if (versions.includes(adoption.migrationHead)) {
    throw new Error('The baseline migration cannot appear in the historical allowlist.');
  }
  if (JSON.stringify(versions) !== JSON.stringify([...versions].sort())) {
    throw new Error('Historical migrations must be sorted by version.');
  }

  return { adoption, contract, versions };
};

export const readBaselineAdoption = () => {
  const contract = JSON.parse(
    readFileSync(new URL('../contract.json', import.meta.url), 'utf8'),
  );
  const adoption = JSON.parse(
    readFileSync(new URL('../baseline-adoption.json', import.meta.url), 'utf8'),
  );
  const baselineMigration = new URL(
    `../supabase/migrations/${adoption.migrationHead}_${BASELINE_MIGRATION_NAME}`,
    import.meta.url,
  );

  return validateBaselineAdoption({
    adoption,
    contract,
    baselineMigrationExists: existsSync(baselineMigration),
  });
};
