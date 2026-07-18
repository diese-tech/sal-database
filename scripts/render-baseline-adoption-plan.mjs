import { readBaselineAdoption } from './baseline-adoption.mjs';

const { adoption } = readBaselineAdoption();

console.log(`contract=${adoption.contractVersion}`);
console.log(`baseline=${adoption.migrationHead}`);
console.log('operation=bookkeeping-only');
console.log('schema-ddl=none');
for (const migration of adoption.historicalMigrations) {
  console.log(`revert=${migration.version}|${migration.name}`);
}
console.log(`apply=${adoption.migrationHead}|production_baseline`);
