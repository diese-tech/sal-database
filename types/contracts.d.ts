export interface DatabaseContract {
  version: `db-v${number}.${number}.${number}`;
  migrationHead: string;
  supabaseCliVersion: string;
  typesSha256: `sha256:${string}`;
}

export interface ConsumerDatabaseLock {
  repository: 'diese-tech/sal-database';
  release: DatabaseContract['version'];
  commit: string;
  migrationHead: string;
  typesSha256: `sha256:${string}`;
}
