# Consumer contract

The database release stores this repository-owned `contract.json`:

```json
{
  "version": "db-v1.0.0",
  "migrationHead": "<14-digit migration version>",
  "supabaseCliVersion": "2.109.1",
  "typesSha256": "sha256:<generated-types hash>"
}
```

Each consumer commits a separate `db-contract.lock.json` with this shape:

```json
{
  "repository": "diese-tech/sal-database",
  "release": "db-v1.0.0",
  "commit": "<40-character commit>",
  "migrationHead": "<14-digit migration version>",
  "typesSha256": "sha256:<hex>"
}
```

The matching `generated/database.types.ts` is vendored into the consumer.
Consumer CI fetches the exact database-repository commit, verifies the release
manifest and SHA, and compares the vendored type file. Runtime builds never
fetch a floating branch or depend on a Git submodule.
