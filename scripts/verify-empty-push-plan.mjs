import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const reportPath = process.argv[2];
if (!reportPath) {
  throw new Error('Usage: node scripts/verify-empty-push-plan.mjs <push-plan.txt>');
}

const report = readFileSync(resolve(reportPath), 'utf8');
if (!/(?:Linked project|Remote database) is up to date\./.test(report)) {
  throw new Error('Supabase output does not confirm an empty push plan.');
}

console.log('Verified empty linked database push plan.');
