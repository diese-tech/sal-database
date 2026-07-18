import { readFileSync } from 'node:fs';

export const readBaselineAdoption = () => {
  const contract = JSON.parse(
    readFileSync(new URL('../contract.json', import.meta.url), 'utf8'),
  );
  const adoption = JSON.parse(
    readFileSync(new URL('../baseline-adoption.json', import.meta.url), 'utf8'),
  );

  if (adoption.adoptionVersion !== 1) {
    throw new Error('baseline-adoption.json must use adoptionVersion 1.');
  }
  if (
    adoption.contractVersion !== contract.version ||
    adoption.migrationHead !== contract.migrationHead
  ) {
    throw new Error('Baseline adoption must match the current database contract.');
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
