# Consumer contract

The database release stores this repository-owned `contract.json`:

```json
{
  "version": "db-v1.0.0",
  "migrationHead": "<14-digit migration version>",
  "supabaseCliVersion": "2.109.1",
  "typesSha256": "sha256:<generated-types hash>",
  "smiteGodSeedMinimumRows": 88
}
```

`smiteGodSeedMinimumRows` is the floor the reviewed SMITE god seed must meet.
The catalog grows as SMITE ships gods, and `diese-tech/smite-content-sync`
proposes those additions as reviewed pull requests, so the contract asserts the
seed never *shrinks* rather than pinning an exact count that every real addition
would break. A seed that loses rows, or repeats a name under a second id, still
fails closed. Lowering the floor is a deliberate edit here, in the manifest
where the release is declared.

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
