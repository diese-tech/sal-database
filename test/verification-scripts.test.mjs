import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';
import { validateBaselineAdoption } from '../scripts/baseline-adoption.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const runWithReport = (script, report) => {
  const directory = mkdtempSync(join(tmpdir(), 'sal-database-test-'));
  const path = join(directory, 'report.txt');
  try {
    writeFileSync(path, report, 'utf8');
    return spawnSync(process.execPath, [join(root, 'scripts', script), path], {
      cwd: root,
      encoding: 'utf8',
    });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
};

test('keeps baseline adoption pinned while allowing forward contract releases', () => {
  const adoption = {
    adoptionVersion: 1,
    contractVersion: 'db-v1.0.0',
    migrationHead: '20260717143900',
    historicalMigrations: [{ version: '20260701000000', name: 'historical' }],
  };
  const result = validateBaselineAdoption({
    adoption,
    contract: { version: 'db-v1.2.0', migrationHead: '20260718022500' },
    baselineMigrationExists: true,
  });

  assert.deepEqual(result.versions, ['20260701000000']);
  assert.throws(
    () =>
      validateBaselineAdoption({
        adoption,
        contract: { version: 'db-v1.2.0', migrationHead: '20260718022500' },
        baselineMigrationExists: false,
      }),
    /baseline migration is missing/i,
  );
});

test('normalizes local and remote migration columns deterministically', () => {
  const result = runWithReport(
    'normalize-migration-state.mjs',
    `LOCAL          │ REMOTE         │ TIME (UTC)\n20250101000000 │ 20250101000000 │ 2025-01-01\n               │ 20240101000000 │ 2024-01-01\n20260101000000 │                │ 2026-01-01\n`,
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(
    result.stdout,
    '-|20240101000000\n20250101000000|20250101000000\n20260101000000|-\n',
  );
});

test('accepts an empty schema diff containing only comments', () => {
  const result = runWithReport('verify-schema-diff.mjs', '-- normalized by Supabase\n\n');
  assert.equal(result.status, 0, result.stderr);
});

test('accepts current and legacy Supabase empty push messages', () => {
  for (const report of [
    'Remote database is up to date.\n',
    'Linked project is up to date.\n',
  ]) {
    const result = runWithReport('verify-empty-push-plan.mjs', report);
    assert.equal(result.status, 0, result.stderr);
  }
});

test('rejects a push plan that does not confirm an up-to-date database', () => {
  const result = runWithReport('verify-empty-push-plan.mjs', 'Would push these migrations:\n');
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /does not confirm an empty push/i);
});

test('accepts a missing diff file when Supabase reports no schema changes', () => {
  const missingPath = join(tmpdir(), `missing-schema-diff-${process.pid}.sql`);
  const result = spawnSync(
    process.execPath,
    [join(root, 'scripts', 'verify-schema-diff.mjs'), missingPath],
    { cwd: root, encoding: 'utf8' },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /empty normalized linked schema diff/);
});

test('rejects executable linked schema drift', () => {
  const result = runWithReport('verify-schema-diff.mjs', 'create table public.drifted(id int);\n');
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Linked schema drift remains/);
});

test('rejects a mismatched linked migration row', () => {
  const result = runWithReport(
    'verify-migration-parity.mjs',
    '20250101000000 │ 20250101000001 │ 2025-01-01\n',
  );
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Migration parity failure/);
});

test('accepts only the exact captured pre-adoption ledger', () => {
  const manifest = JSON.parse(
    readFileSync(join(root, 'baseline-adoption.json'), 'utf8'),
  );
  const report = [
    `${manifest.migrationHead}|-`,
    ...manifest.historicalMigrations.map(({ version }) => `-|${version}`),
  ].join('\n');
  const result = runWithReport('verify-baseline-adoption-state.mjs', report);
  const checked = spawnSync(
    process.execPath,
    [
      join(root, 'scripts', 'verify-baseline-adoption-state.mjs'),
      'before',
      join(tmpdir(), 'missing-report.txt'),
    ],
    { cwd: root, encoding: 'utf8' },
  );
  assert.notEqual(result.status, 0, 'mode is mandatory');
  assert.notEqual(checked.status, 0, 'missing report is rejected');

  const directory = mkdtempSync(join(tmpdir(), 'sal-database-adoption-test-'));
  const path = join(directory, 'state.txt');
  try {
    writeFileSync(path, `${report}\n`, 'utf8');
    const accepted = spawnSync(
      process.execPath,
      [join(root, 'scripts', 'verify-baseline-adoption-state.mjs'), 'before', path],
      { cwd: root, encoding: 'utf8' },
    );
    assert.equal(accepted.status, 0, accepted.stderr);

    writeFileSync(path, `${report}\n-|20260715000000\n`, 'utf8');
    const rejected = spawnSync(
      process.execPath,
      [join(root, 'scripts', 'verify-baseline-adoption-state.mjs'), 'before', path],
      { cwd: root, encoding: 'utf8' },
    );
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, /state mismatch/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('hashes deployment inputs and rejects critical changes after attestation', () => {
  const directory = mkdtempSync(join(tmpdir(), 'sal-database-git-test-'));
  const runGit = (...args) => spawnSync('git', args, { cwd: directory, encoding: 'utf8' });
  try {
    assert.equal(runGit('init', '--initial-branch=main').status, 0);
    writeFileSync(join(directory, 'package.json'), '{"private":true}\n', 'utf8');
    assert.equal(runGit('add', 'package.json').status, 0);
    assert.equal(
      runGit(
        '-c',
        'user.name=SAL Database Tests',
        '-c',
        'user.email=tests@invalid.example',
        'commit',
        '-m',
        'baseline',
      ).status,
      0,
    );
    const baseline = runGit('rev-parse', 'HEAD').stdout.trim();
    const digest = spawnSync(
      process.execPath,
      [join(root, 'scripts', 'hash-deployment-inputs.mjs'), baseline],
      { cwd: directory, encoding: 'utf8' },
    );
    assert.equal(digest.status, 0, digest.stderr);
    assert.match(digest.stdout.trim(), /^sha256:[0-9a-f]{64}$/);

    writeFileSync(join(directory, 'package.json'), '{"private":true,"changed":true}\n', 'utf8');
    assert.equal(runGit('add', 'package.json').status, 0);
    assert.equal(
      runGit(
        '-c',
        'user.name=SAL Database Tests',
        '-c',
        'user.email=tests@invalid.example',
        'commit',
        '-m',
        'critical change',
      ).status,
      0,
    );
    const helperUrl = pathToFileURL(join(root, 'scripts', 'deployment-inputs.mjs')).href;
    const changed = spawnSync(
      process.execPath,
      [
        '--input-type=module',
        '--eval',
        `import { requireUnchangedDeploymentInputs } from ${JSON.stringify(helperUrl)}; requireUnchangedDeploymentInputs(${JSON.stringify(baseline)});`,
      ],
      { cwd: directory, encoding: 'utf8' },
    );
    assert.notEqual(changed.status, 0);
    assert.match(changed.stderr, /Deployment inputs changed/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
