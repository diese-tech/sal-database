import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';

export const deploymentInputPaths = [
  '.gitattributes',
  '.github/workflows/deploy.yml',
  '.node-version',
  '.npmrc',
  'contract.json',
  'generated/database.types.ts',
  'package-lock.json',
  'package.json',
  'scripts',
  'supabase',
  'test',
  'tsconfig.json',
  'types',
];

const sha256 = (value) => `sha256:${createHash('sha256').update(value).digest('hex')}`;

export const deploymentInputsSha256 = (commit) => {
  const manifest = execFileSync(
    'git',
    ['ls-tree', '-r', '--full-tree', commit, '--', ...deploymentInputPaths],
    { encoding: 'utf8' },
  );
  if (manifest.trim() === '') {
    throw new Error(`No deployment inputs were found at ${commit}.`);
  }
  return sha256(manifest);
};

export const requireUnchangedDeploymentInputs = (fromCommit, toCommit = 'HEAD') => {
  try {
    execFileSync(
      'git',
      ['diff', '--quiet', fromCommit, toCommit, '--', ...deploymentInputPaths],
      { stdio: 'ignore' },
    );
  } catch {
    throw new Error(
      `Deployment inputs changed between the recovery-attested commit ${fromCommit} and ${toCommit}.`,
    );
  }
};
