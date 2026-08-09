BEGIN;

SET LOCAL search_path TO extensions, public, pg_catalog;

SELECT plan(3);

SELECT is(
  (
    SELECT string_agg(attribute.attname, ',' ORDER BY key_column.ordinality)
    FROM pg_constraint AS constraint_row
    CROSS JOIN LATERAL unnest(constraint_row.conkey)
      WITH ORDINALITY AS key_column(attnum, ordinality)
    JOIN pg_attribute AS attribute
      ON attribute.attrelid = constraint_row.conrelid
     AND attribute.attnum = key_column.attnum
    WHERE constraint_row.conrelid = 'public.standings'::regclass
      AND constraint_row.contype = 'p'
  ),
  'org_id,division_id',
  'standings identity is scoped by organization and division'
);

SELECT ok(
  pg_get_functiondef('public.replace_standings(jsonb)'::regprocedure)
    LIKE '%ON CONFLICT (org_id, division_id)%',
  'atomic standings replacement resolves conflicts per divisional team'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.replace_standings(jsonb)', 'EXECUTE')
    AND NOT has_function_privilege(
      'authenticated', 'public.replace_standings(jsonb)', 'EXECUTE'
    )
    AND has_function_privilege(
      'service_role', 'public.replace_standings(jsonb)', 'EXECUTE'
    ),
  'standings replacement remains service-role-only'
);

SELECT * FROM finish();
ROLLBACK;
