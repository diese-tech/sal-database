import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const reportPath = process.argv[2];
if (!reportPath) {
  throw new Error('Usage: node scripts/normalize-migration-state.mjs <migration-list.txt>');
}

const rows = [];
const report = readFileSync(resolve(reportPath), 'utf8').replace(/\u001b\[[0-9;]*m/g, '');

for (const line of report.split(/\r?\n/)) {
  const columns = line.split(/[|│]/);
  if (columns.length < 2) continue;
  const local = columns[0].match(/\b\d{14}\b/)?.[0] ?? '';
  const remote = columns[1].match(/\b\d{14}\b/)?.[0] ?? '';
  if (local || remote) rows.push(`${local || '-'}|${remote || '-'}`);
}

const normalized = [...new Set(rows)].sort();
if (normalized.length !== rows.length) {
  throw new Error('Migration list contains duplicate version rows.');
}

process.stdout.write(`${normalized.join('\n')}\n`);
