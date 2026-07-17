import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const migrations = join(root, 'supabase', 'migrations');
const tests = join(root, 'supabase', 'tests');
const sqlFiles = readdirSync(migrations).filter((name) => name.endsWith('.sql'));
const testFiles = readdirSync(tests).filter((name) => name.endsWith('.sql'));
const hasContract = existsSync(join(root, 'contract.json'));
const hasTypes = existsSync(join(root, 'generated', 'database.types.ts'));

if (!hasContract) {
  if (sqlFiles.length !== 0 || testFiles.length !== 0 || hasTypes) {
    throw new Error('Recovery-gated bootstrap cannot contain active SQL, database tests, or generated types without contract.json.');
  }
  console.log('Recovery-gated bootstrap is internally consistent; production deployment remains disabled.');
} else {
  if (sqlFiles.length === 0 || !hasTypes) {
    throw new Error('A released contract requires an active migration and generated/database.types.ts.');
  }
  await import('./verify-contract.mjs');
}
