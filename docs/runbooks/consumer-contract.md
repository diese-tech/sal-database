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
proposes those additions as reviewed pull requests, so the contract asserts a
floor rather than pinning an exact count that every real addition would break.
Lowering the floor is a deliberate edit here, in the manifest where the release
is declared.

The floor alone is a backstop, not a ratchet: it does not rise when growth is
accepted, so on its own it would let a later change drop back to it and quietly
lose a god that had already been reviewed. Two further guards close that:

- CI compares each seed against the same file on the pull request's base
  branch and fails if it lost rows (`scripts/verify-seed-growth.mjs`), so
  "never shrinks" holds continuously without a manual bump on every addition.
- The god seed may not repeat a name under a second id, which the old exact-row
  assertion only ever caught through the total.

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
