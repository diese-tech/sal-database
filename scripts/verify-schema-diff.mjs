import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const diffPath = process.argv[2];
if (!diffPath) {
  throw new Error('Usage: node scripts/verify-schema-diff.mjs <schema.diff>');
}

const resolvedDiffPath = resolve(diffPath);
const diff = existsSync(resolvedDiffPath)
  ? readFileSync(resolvedDiffPath, 'utf8')
  : '';

const normalized = diff
  .split(/\r?\n/)
  .map((line) => line.replace(/--.*$/, '').trim())
  .filter(Boolean)
  .join('\n');

if (normalized) {
  throw new Error(`Linked schema drift remains:\n${normalized}`);
}

console.log('Verified an empty normalized linked schema diff.');
