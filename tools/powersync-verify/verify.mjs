// Verification-only PowerSync test client for Prompt 10. NOT part of the
// application (no lib/, no test/) - proves the sync config in
// docker/powersync/sync-config.yaml actually behaves as documented, using
// PowerSync's own official Node.js client SDK (@powersync/node) against a
// real JWT from this project's own POST /api/auth/login. See
// tools/powersync-verify/README.md.
//
// Usage: node verify.mjs <label> <access_token> <db_filename>
//   node verify.mjs O1 "$O1_TOKEN" o1.db
import { PowerSyncDatabase } from '@powersync/node';
import { existsSync, unlinkSync } from 'node:fs';
import { AppSchema } from './schema.mjs';

const [, , label, token, dbFilename] = process.argv;
if (!label || !token || !dbFilename) {
  console.error('usage: node verify.mjs <label> <access_token> <db_filename>');
  process.exit(1);
}

const ENDPOINT = process.env.POWERSYNC_ENDPOINT ?? 'http://127.0.0.1:8080';

// Start from a clean local database every run so results reflect this
// run's token/scope, not a previous one.
for (const suffix of ['', '-wal', '-shm']) {
  if (existsSync(dbFilename + suffix)) unlinkSync(dbFilename + suffix);
}

class StaticTokenConnector {
  async fetchCredentials() {
    return { endpoint: ENDPOINT, token };
  }
  async uploadData() {
    // Read-only verification client: nothing is ever written locally, so
    // there is never anything to upload.
  }
}

const db = new PowerSyncDatabase({
  schema: AppSchema,
  database: { dbFilename }
});

console.log(`[${label}] connecting to ${ENDPOINT} ...`);
await db.connect(new StaticTokenConnector());
await db.waitForFirstSync({ timeoutMs: 30000 });
console.log(`[${label}] first sync complete`);

const tables = [
  'faculties', 'departments', 'programmes', 'assembly_points', 'zones', 'areas',
  'department_areas', 'settings', 'people', 'users', 'activations', 'activation_zones',
  'warden_assignments', 'accountability_events', 'person_statuses', 'expected_presences'
];

console.log(`\n[${label}] row counts:`);
for (const t of tables) {
  const [{ n }] = await db.getAll(`SELECT COUNT(*) AS n FROM ${t}`);
  console.log(`  ${t.padEnd(24)} ${n}`);
}

if (process.env.VERIFY_EXTRA === '1') {
  console.log(`\n[${label}] users table columns (structural password_hash check):`);
  const cols = await db.getAll("PRAGMA table_info(users)");
  console.log('  ', cols.map((c) => c.name).join(', '));

  console.log(`\n[${label}] full users rows:`);
  console.log(await db.getAll('SELECT * FROM users'));

  console.log(`\n[${label}] person_statuses rows (id, person_id, status):`);
  console.log(await db.getAll('SELECT id, person_id, status FROM person_statuses'));

  console.log(`\n[${label}] accountability_events rows (id, person_id, area_id):`);
  console.log(await db.getAll('SELECT id, person_id, area_id FROM accountability_events'));
}

await db.disconnect();
process.exit(0);
