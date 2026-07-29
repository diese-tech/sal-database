import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ansiSequence = /\u001B\[[0-?]*[ -/]*[@-~]/g;

export const normalizeMigrationPlan = (source) => {
  const lines = source
    .replace(/\r\n?/g, '\n')
    .replace(ansiSequence, '')
    .split('\n')
    .filter(
      (line) =>
        !line.startsWith('A new version of Supabase CLI is available:')
        && !line.startsWith('We recommend updating regularly for new features and bug fixes:'),
    );
  return `${lines.join('\n').replace(/\n*$/, '')}\n`;
};

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const inputPath = process.argv[2];
  const outputPath = process.argv[3] ?? inputPath;
  if (!inputPath) {
    throw new Error(
      'Usage: node scripts/normalize-migration-plan.mjs <input-plan.txt> [output-plan.txt]',
    );
  }
  writeFileSync(
    outputPath,
    normalizeMigrationPlan(readFileSync(inputPath, 'utf8')),
    'utf8',
  );
}
