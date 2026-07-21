import { readFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const forbiddenPatterns = [
  /\b(?:insert\s+into|update\s+(?:only\s+)?|delete\s+from|truncate\s+|create\s+|alter\s+|drop\s+|grant\s+|revoke\s+|comment\s+on|vacuum\s+|analyze\s+|refresh\s+materialized|reindex\s+|cluster\s+|copy\s+)\b/i,
  /\bdblink_[a-z0-9_]*\s*\(/i,
  /\bselect\s+(?:\*\s+from\s+)?public\.[a-z0-9_]+\s*\(/i,
  /\bperform\s+/i,
  /\$[a-z0-9_]*\$/i,
];

function stripSqlCommentsAndLiterals(sql) {
  return sql
    .replace(/--.*$/gm, ' ')
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/'(?:''|[^'])*'/g, ' ');
}

export function assertProductionTestSqlIsReadOnly(sql, label = 'production database test') {
  const executableSql = stripSqlCommentsAndLiterals(sql);
  const violation = forbiddenPatterns.find((pattern) => pattern.test(executableSql));
  if (violation) {
    throw new Error(
      `Production database assertions must be read-only: ${label} matched ${violation}.`,
    );
  }
  const normalized = executableSql.trim();
  if (
    !/^begin\s*;/i.test(normalized)
    || !/rollback\s*;\s*$/i.test(normalized)
    || /\bcommit\b/i.test(normalized)
  ) {
    throw new Error(
      `Production database assertions must begin with BEGIN and end with ROLLBACK: ${label}.`,
    );
  }
}

export function verifyProductionTestDirectory(directory) {
  const files = readdirSync(directory)
    .filter((name) => name.endsWith('.test.sql'))
    .sort();
  if (files.length === 0) {
    throw new Error('Production database assertion directory contains no .test.sql files.');
  }
  for (const file of files) {
    assertProductionTestSqlIsReadOnly(readFileSync(resolve(directory, file), 'utf8'), file);
  }
  return files;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const directory = resolve(process.argv[2] ?? 'supabase/production-tests');
  const files = verifyProductionTestDirectory(directory);
  console.log(`Verified ${files.length} read-only production database assertion file(s).`);
}
