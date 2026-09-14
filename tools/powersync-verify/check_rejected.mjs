// Confirms a token is REJECTED by PowerSync (used for the expired-token
// half of Prompt 10 verification item 7) - connects, waits briefly for the
// connection attempt to fail, then reports currentStatus.downloadError
// instead of hanging on waitForFirstSync (which never resolves when the
// connection is rejected).
import { PowerSyncDatabase } from '@powersync/node';
import { existsSync, unlinkSync } from 'node:fs';
import { AppSchema } from './schema.mjs';

const [, , label, token, dbFilename] = process.argv;
const ENDPOINT = process.env.POWERSYNC_ENDPOINT ?? 'http://127.0.0.1:8080';

for (const suffix of ['', '-wal', '-shm']) {
  if (existsSync(dbFilename + suffix)) unlinkSync(dbFilename + suffix);
}

class StaticTokenConnector {
  async fetchCredentials() {
    return { endpoint: ENDPOINT, token };
  }
  async uploadData() {}
}

const db = new PowerSyncDatabase({ schema: AppSchema, database: { dbFilename } });
console.log(`[${label}] connecting with token that should be rejected...`);
await db.connect(new StaticTokenConnector());

await new Promise((resolve) => setTimeout(resolve, 6000));

const status = db.currentStatus;
console.log(`[${label}] connected=${status.connected} hasSynced=${status.hasSynced}`);
console.log(`[${label}] downloadError=`, status.downloadError?.message ?? status.downloadError);

await db.disconnect();
process.exit(0);
