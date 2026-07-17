import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const archiveRoot = fileURLToPath(new URL('../history/pre-v1/', import.meta.url));
const sums = readFileSync(join(archiveRoot, 'SHA256SUMS'), 'utf8')
  .trim()
  .split(/\r?\n/);
const listed = new Set();

for (const line of sums) {
  const match = line.match(/^([0-9a-f]{64}) {2}(.+)$/);
  if (!match) throw new Error(`Invalid SHA256SUMS line: ${line}`);
  const [, expected, portablePath] = match;
  if (portablePath.includes('..') || portablePath.startsWith('/')) {
    throw new Error(`Unsafe archive path: ${portablePath}`);
  }
  const path = resolve(archiveRoot, ...portablePath.split('/'));
  if (!path.startsWith(`${resolve(archiveRoot)}${sep}`)) {
    throw new Error(`Archive path escapes history/pre-v1: ${portablePath}`);
  }
  const actual = createHash('sha256').update(readFileSync(path)).digest('hex');
  if (actual !== expected) throw new Error(`Archive hash mismatch: ${portablePath}`);
  if (listed.has(portablePath)) throw new Error(`Duplicate archive manifest path: ${portablePath}`);
  listed.add(portablePath);
}

const sqlFiles = [];
const walk = (directory) => {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) walk(path);
    else if (entry.name.endsWith('.sql')) sqlFiles.push(relative(archiveRoot, path).split(sep).join('/'));
  }
};
walk(archiveRoot);

const unlisted = sqlFiles.filter((path) => !listed.has(path));
if (listed.size !== sqlFiles.length || unlisted.length !== 0) {
  throw new Error(`Archive manifest mismatch; unlisted files: ${unlisted.join(', ') || 'none'}.`);
}

console.log(`Verified ${listed.size} archived pre-v1 SQL files.`);
