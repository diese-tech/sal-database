export const countSqlSeedRows = (source) =>
  (source.match(/^\s*\('/gm) ?? []).length;

export const usesIdentityPreservingNameUpsert = (source) =>
  /on\s+conflict\s*\(\s*name\s*\)\s+do\s+update\s+set/i.test(source) &&
  !/\bid\s*=\s*excluded\.id\b/i.test(source);
