import { readFileSync, readdirSync } from 'node:fs';
import { basename, extname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const ignoredDirectories = new Set(['.git', '.supabase', 'node_modules']);
const textExtensions = new Set(['.json', '.md', '.mjs', '.sql', '.toml', '.ts', '.yml', '.yaml']);
const textNames = new Set(['.gitattributes', '.gitignore', 'CODEOWNERS', 'LICENSE']);
const files = [];

const collect = (directory) => {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.isDirectory() && ignoredDirectories.has(entry.name)) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) collect(path);
    else if (textExtensions.has(extname(entry.name)) || textNames.has(basename(entry.name))) files.push(path);
  }
};
collect(root);

for (const path of files) {
  const text = readFileSync(path, 'utf8');
  const portablePath = relative(root, path).replaceAll('\\', '/');
  if (text.length !== 0 && !text.endsWith('\n')) throw new Error(`${portablePath} must end with a newline.`);
  const lines = text.split(/\r?\n/);
  const badLine = lines.findIndex((line) => /[ \t]+$/.test(line));
  if (badLine !== -1) throw new Error(`${portablePath}:${badLine + 1} has trailing whitespace.`);
}

console.log(`Verified whitespace in ${files.length} text files.`);
