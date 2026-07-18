import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const normalizeGeneratedTypes = (source) =>
  `${source.replace(/\r\n?/g, '\n').replace(/\n*$/, '')}\n`;

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const path = process.argv[2];
  if (!path) {
    throw new Error('Usage: node scripts/normalize-generated-types.mjs <database.types.ts>');
  }
  writeFileSync(path, normalizeGeneratedTypes(readFileSync(path, 'utf8')), 'utf8');
}
