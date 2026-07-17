import { execFileSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const files = [];
const collect = (directory) => {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) collect(path);
    else if (entry.name.endsWith('.mjs')) files.push(path);
  }
};

collect(join(root, 'scripts'));
collect(join(root, 'test'));
for (const file of files.sort()) execFileSync(process.execPath, ['--check', file], { stdio: 'inherit' });
console.log(`Syntax-checked ${files.length} JavaScript files.`);
