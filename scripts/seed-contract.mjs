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
