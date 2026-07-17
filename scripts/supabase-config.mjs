import { readFileSync } from 'node:fs';

export const readDatabaseMajorVersion = () => {
  const config = readFileSync(new URL('../supabase/config.toml', import.meta.url), 'utf8');
  let inDatabaseSection = false;
  let majorVersion;

  for (const rawLine of config.split(/\r?\n/)) {
    const line = rawLine.replace(/\s+#.*$/, '').trim();
    if (/^\[[^\]]+\]$/.test(line)) {
      inDatabaseSection = line === '[db]';
      continue;
    }
    if (!inDatabaseSection) continue;
    const match = line.match(/^major_version\s*=\s*(\d+)$/);
    if (match) majorVersion = Number.parseInt(match[1], 10);
  }

  if (!Number.isInteger(majorVersion) || majorVersion < 12 || majorVersion > 99) {
    throw new Error(
      'Released contracts require an explicit integer db.major_version in supabase/config.toml.',
    );
  }
  return majorVersion;
};
