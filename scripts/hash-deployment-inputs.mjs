import { deploymentInputsSha256 } from './deployment-inputs.mjs';

const commit = process.argv[2];
if (!commit) {
  throw new Error('Usage: node scripts/hash-deployment-inputs.mjs <commit>');
}

console.log(deploymentInputsSha256(commit));
