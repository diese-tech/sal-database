import { readFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';

const reportPath = process.argv[2];
if (!reportPath) {
  throw new Error('Usage: node scripts/verify-migration-parity.mjs <migration-list.txt>');
}

const expected = readdirSync(new URL('../supabase/migrations', import.meta.url))
  .filter((name) => name.endsWith('.sql'))
  .map((name) => name.slice(0, 14))
  .sort();
const observed = [];

for (const line of readFileSync(resolve(reportPath), 'utf8').split(/\r?\n/)) {
  const versions = line.match(/\b\d{14}\b/g) ?? [];
  if (versions.length === 0) continue;
  if (versions.length !== 2 || versions[0] !== versions[1]) {
    throw new Error(`Migration parity failure: ${line.trim()}`);
  }
  observed.push(versions[0]);
}

if (JSON.stringify([...new Set(observed)].sort()) !== JSON.stringify(expected)) {
  throw new Error(`Linked migration versions do not match the repository. Expected ${expected.join(', ')}, observed ${observed.join(', ')}.`);
}

console.log(`Verified ${expected.length} linked migration version(s).`);
