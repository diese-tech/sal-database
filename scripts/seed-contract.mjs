export const countSqlSeedRows = (source) =>
  (source.match(/^\s*\('/gm) ?? []).length;

export const usesIdentityPreservingNameUpsert = (source) =>
  /on\s+conflict\s*\(\s*name\s*\)\s+do\s+update\s+set/i.test(source) &&
  !/\bid\s*=\s*excluded\.id\b/i.test(source);

// A growing seed must still name each entity once. The old exact-row assertion
// caught a duplicate only by accident, through the count; a floor would not.
export const findDuplicateSeedNames = (source) => {
  const names = [...source.matchAll(/^\s*\('[^']*',\s*'((?:[^']|'')*)'/gm)]
    .map((match) => match[1].replaceAll("''", "'").trim().toLowerCase());
  const seen = new Set();
  const duplicates = new Set();
  for (const name of names) {
    if (seen.has(name)) duplicates.add(name);
    seen.add(name);
  }
  return [...duplicates].sort();
};

// The contract.json floor is an absolute backstop, but it does not move on its
// own: once growth is accepted, a later change could drop back to the floor and
// still pass. This compares a seed against the same seed on the base branch, so
// "never shrinks" holds continuously without a manual bump on every addition.
export const findSeedRowRegression = (previousSource, nextSource) => {
  const previousRows = countSqlSeedRows(previousSource);
  const nextRows = countSqlSeedRows(nextSource);
  return nextRows < previousRows ? { previousRows, nextRows } : null;
};
