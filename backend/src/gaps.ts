/**
 * Sound gaps: sounds stories called for that the library doesn't have yet.
 * The analysis model reports them; they're counted here (in D1) and become
 * the next generation batch (scripts/plan-batch.mjs).
 *
 * Only the model's short description is stored, never the reader's text.
 * Devices are counted by a hash of the session subject, so one child
 * re-reading a favourite book counts once.
 */
import { sha256, textEncoder, toBase64Url } from "./encoding";

export interface SoundGap {
  /** snake_case name proposed by the model, e.g. "elephant_trumpet". */
  id: string;
  kind: "oneShot" | "ambience";
  /** Short English description, e.g. "an elephant trumpeting". */
  description: string;
}

/** Subset of a D1 database we use. */
export interface GapDatabase {
  prepare(query: string): GapStatement;
}

export interface GapStatement {
  bind(...values: unknown[]): GapStatement;
  run(): Promise<{ meta: { changes?: number } }>;
}

export const GAP_ID_PATTERN = /^[a-z][a-z0-9_]{1,47}$/;
export const MAX_GAP_DESCRIPTION = 120;

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    description TEXT NOT NULL,
    requests INTEGER NOT NULL,
    devices INTEGER NOT NULL,
    first_seen TEXT NOT NULL,
    last_seen TEXT NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS gap_devices (
    gap_id TEXT NOT NULL,
    device TEXT NOT NULL,
    PRIMARY KEY (gap_id, device)
  )`,
];

const schemaReady = new WeakMap<GapDatabase, Promise<void>>();

/** Creates the tables on first use, so deploying needs no migration step. */
function ensureSchema(db: GapDatabase): Promise<void> {
  let ready = schemaReady.get(db);
  if (!ready) {
    ready = (async () => {
      for (const statement of SCHEMA) await db.prepare(statement).run();
    })();
    ready.catch(() => schemaReady.delete(db));
    schemaReady.set(db, ready);
  }
  return ready;
}

export async function recordGaps(db: GapDatabase, gaps: SoundGap[], subject: string, now = new Date()): Promise<void> {
  if (gaps.length === 0) return;
  await ensureSchema(db);
  const device = toBase64Url((await sha256(textEncoder.encode(`gap-device:${subject}`))).slice(0, 12));
  const timestamp = now.toISOString();

  for (const gap of gaps) {
    const { meta } = await db
      .prepare("INSERT OR IGNORE INTO gap_devices (gap_id, device) VALUES (?1, ?2)")
      .bind(gap.id, device)
      .run();
    const newDevice = (meta.changes ?? 0) > 0 ? 1 : 0;
    await db
      .prepare(
        `INSERT INTO gaps (id, kind, description, requests, devices, first_seen, last_seen)
         VALUES (?1, ?2, ?3, 1, ?4, ?5, ?5)
         ON CONFLICT (id) DO UPDATE SET requests = requests + 1, devices = devices + ?4, last_seen = ?5`,
      )
      .bind(gap.id, gap.kind, gap.description, newDevice, timestamp)
      .run();
  }
}
