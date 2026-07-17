import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import {
  deploymentInputsSha256,
  requireUnchangedDeploymentInputs,
} from './deployment-inputs.mjs';
import { readDatabaseMajorVersion } from './supabase-config.mjs';

const contractBytes = readFileSync(new URL('../contract.json', import.meta.url));
const contract = JSON.parse(contractBytes.toString('utf8'));
const attestation = JSON.parse(
  readFileSync(new URL('../recovery-attestation.json', import.meta.url), 'utf8'),
);
const hash = (value) => `sha256:${createHash('sha256').update(value).digest('hex')}`;
const requestedRelease = process.env.DEPLOY_RELEASE_TAG;
const databaseMajorVersion = readDatabaseMajorVersion();

if (attestation.attestationVersion !== 2) {
  throw new Error('recovery-attestation.json must use attestationVersion 2.');
}
if (requestedRelease && requestedRelease !== contract.version) {
  throw new Error('The requested release tag does not match contract.version.');
}
if (attestation.contractVersion !== contract.version || attestation.migrationHead !== contract.migrationHead) {
  throw new Error('Recovery evidence is not bound to the current contract version and migration head.');
}
if (attestation.contractSha256 !== hash(contractBytes)) {
  throw new Error('Recovery evidence is not bound to the current contract.json bytes.');
}
if (!/^[0-9a-f]{40}$/.test(attestation.contractCommit)) {
  throw new Error('attestation.contractCommit must be a full Git commit SHA.');
}
if (attestation.productionPostgresMajor !== databaseMajorVersion) {
  throw new Error(
    'Recovery evidence must confirm that db.major_version matches the restored production database.',
  );
}

execFileSync('git', ['merge-base', '--is-ancestor', attestation.contractCommit, 'HEAD']);
const attestedContract = execFileSync('git', ['show', `${attestation.contractCommit}:contract.json`]);
if (hash(attestedContract) !== attestation.contractSha256) {
  throw new Error('The attested commit does not contain the current contract.json.');
}
if (attestation.deploymentInputsSha256 !== deploymentInputsSha256(attestation.contractCommit)) {
  throw new Error('Recovery evidence is not bound to the attested deployment-input manifest.');
}
requireUnchangedDeploymentInputs(attestation.contractCommit);

if (!/^sha256:[0-9a-f]{64}$/.test(attestation.restoreEvidenceSha256)) {
  throw new Error('restoreEvidenceSha256 must identify the private restore evidence bundle.');
}
if (attestation.recoveryIssue !== 'https://github.com/diese-tech/sal-site/issues/156') {
  throw new Error('Recovery evidence must reference sal-site issue #156.');
}
for (const field of [
  'migration025Verified',
  'site170DeploymentVerified',
  'scratchRestoreVerified',
  'rowCountsVerified',
  'databaseObjectsVerified',
  'siteReadSmokeVerified',
  'botReadSmokeVerified',
]) {
  if (attestation[field] !== true) throw new Error(`Recovery attestation requires ${field}=true.`);
}
if (!Number.isFinite(attestation.rpoMinutes) || attestation.rpoMinutes < 0) {
  throw new Error('Recovery attestation requires a measured non-negative rpoMinutes.');
}
if (!Number.isFinite(attestation.rtoMinutes) || attestation.rtoMinutes <= 0) {
  throw new Error('Recovery attestation requires a measured positive rtoMinutes.');
}
if (typeof attestation.approvedBy !== 'string' || attestation.approvedBy.trim() === '') {
  throw new Error('Recovery attestation requires approvedBy.');
}

const approvedAt = Date.parse(attestation.approvedAt);
const expiresAt = Date.parse(attestation.expiresAt);
const now = Date.now();
if (!Number.isFinite(approvedAt) || !Number.isFinite(expiresAt) || approvedAt > now + 300_000) {
  throw new Error('Recovery attestation timestamps are invalid.');
}
if (
  expiresAt <= approvedAt ||
  expiresAt <= now ||
  expiresAt - approvedAt > 30 * 24 * 60 * 60 * 1000
) {
  throw new Error(
    'Recovery attestation must expire after approval, remain current, and be valid for no more than 30 days.',
  );
}

console.log(`Verified current recovery evidence for ${contract.version}.`);
