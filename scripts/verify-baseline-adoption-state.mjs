import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { readBaselineAdoption } from './baseline-adoption.mjs';

const [mode, reportPath] = process.argv.slice(2);
if (!['before', 'after'].includes(mode) || !reportPath) {
  throw new Error(
    'Usage: node scripts/verify-baseline-adoption-state.mjs <before|after> <migration-state.txt>',
  );
}

const { adoption, versions } = readBaselineAdoption();
const observed = readFileSync(resolve(reportPath), 'utf8')
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter(Boolean)
  .sort();
const expected = mode === 'before'
  ? [`${adoption.migrationHead}|-`, ...versions.map((version) => `-|${version}`)].sort()
  : [`${adoption.migrationHead}|${adoption.migrationHead}`];

if (JSON.stringify(observed) !== JSON.stringify(expected)) {
  throw new Error(
    `Baseline adoption ${mode} state mismatch. Expected ${expected.join(', ')}, observed ${observed.join(', ')}.`,
  );
}

console.log(`Verified baseline adoption ${mode} state (${observed.length} row(s)).`);
