export const countSqlSeedRows = (source) =>
  (source.match(/^\s*\('/gm) ?? []).length;
