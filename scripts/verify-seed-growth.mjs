import { readFileSync } from 'node:fs';
import { findSeedRowRegression } from './seed-contract.mjs';

const [previousPath, nextPath, label = 'seed'] = process.argv.slice(2);

if (!previousPath || !nextPath) {
  throw new Error('Usage: node scripts/verify-seed-growth.mjs <base-seed> <head-seed> [label]');
}

// A base branch with no such seed yet (a brand-new seed file) cannot regress.
let previousSource;
try {
  previousSource = readFileSync(previousPath, 'utf8');
} catch {
  console.log(`No base copy of the ${label} seed to compare against; nothing to regress from.`);
  process.exit(0);
}

const regression = findSeedRowRegression(previousSource, readFileSync(nextPath, 'utf8'));
if (regression !== null) {
  throw new Error(
    `The reviewed ${label} seed lost rows against the base branch: ${regression.previousRows} to ${regression.nextRows}. ` +
      'A previously reviewed entry may only be removed in a change that says so explicitly.',
  );
}

console.log(`Verified the ${label} seed did not lose rows against the base branch.`);
