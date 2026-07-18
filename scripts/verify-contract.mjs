import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { readDatabaseMajorVersion } from './supabase-config.mjs';
import { countSqlSeedRows, usesIdentityPreservingNameUpsert } from './seed-contract.mjs';

const contract = JSON.parse(readFileSync(new URL('../contract.json', import.meta.url), 'utf8'));
const types = readFileSync(new URL('../generated/database.types.ts', import.meta.url));
const packageJson = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
const migrations = readdirSync(fileURLToPath(new URL('../supabase/migrations', import.meta.url)))
  .filter((name) => name.endsWith('.sql'))
  .sort();
const databaseTests = readdirSync(fileURLToPath(new URL('../supabase/tests', import.meta.url)))
  .filter((name) => name.endsWith('.sql'));
const requiredDatabaseTests = [
  '001_schema_contract.test.sql',
  '002_security_contract.test.sql',
  '003_realtime_contract.test.sql',
  '004_storage_contract.test.sql',
  '005_item_catalog.test.sql',
  '006_season_isolation.test.sql',
  '007_preseason_reset.test.sql',
];
const hash = `sha256:${createHash('sha256').update(types).digest('hex')}`;
const databaseMajorVersion = readDatabaseMajorVersion();
const godSeed = readFileSync(new URL('../supabase/seeds/smite2-gods.sql', import.meta.url), 'utf8');

if (!/^db-v\d+\.\d+\.\d+$/.test(contract.version)) {
  throw new Error('contract.version must use db-vMAJOR.MINOR.PATCH.');
}
if (!/^\d{14}$/.test(contract.migrationHead)) {
  throw new Error('contract.migrationHead must be a 14-digit migration version.');
}
if (contract.supabaseCliVersion !== '2.109.1') {
  throw new Error('contract.supabaseCliVersion must match the pinned CLI version.');
}
if (packageJson.devDependencies?.supabase !== contract.supabaseCliVersion) {
  throw new Error('The package.json Supabase CLI pin must match contract.supabaseCliVersion.');
}
if (migrations.length === 0 || migrations.some((name) => !/^\d{14}_[a-z0-9_]+\.sql$/.test(name))) {
  throw new Error('Active migrations must use 14-digit versions and lowercase snake_case names.');
}
const migrationVersions = migrations.map((name) => name.slice(0, 14));
if (new Set(migrationVersions).size !== migrationVersions.length) {
  throw new Error('Active migration versions must be unique.');
}
const migrationHead = migrationVersions.at(-1);
if (contract.migrationHead !== migrationHead) {
  throw new Error(`contract.migrationHead must match the newest active migration (${migrationHead}).`);
}
const missingDatabaseTests = requiredDatabaseTests.filter((name) => !databaseTests.includes(name));
if (missingDatabaseTests.length !== 0) {
  throw new Error(`A released contract is missing required pgTAP suites: ${missingDatabaseTests.join(', ')}.`);
}
if (contract.typesSha256 !== hash) {
  throw new Error(`Generated type hash mismatch: expected ${contract.typesSha256}, received ${hash}.`);
}
if (countSqlSeedRows(godSeed) !== 86) {
  throw new Error('The reviewed local SMITE god seed must contain exactly 86 rows.');
}
if (!usesIdentityPreservingNameUpsert(godSeed)) {
  throw new Error('The SMITE god seed must reconcile by unique name without replacing historical IDs.');
}

console.log(
  `Verified ${contract.version} at migration ${contract.migrationHead} on PostgreSQL ${databaseMajorVersion}.`,
);
