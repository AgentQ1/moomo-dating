#!/usr/bin/env node
/**
 * One-off backfill for `publicProfiles.activityBucket` (presence-hotspot fix,
 * audit P1-1 / rollout requirement for the getDiscoveryFeed queries).
 *
 * WHY: the discovery feed orders by `activityBucket`, and Firestore's
 * orderBy EXCLUDES documents that lack the ordered field. Profiles written
 * before the fix only have `lastActiveAt`. Until each is touched by a new
 * client heartbeat or a queue join, it is invisible to the bucketed pool
 * queries (the feed's unordered fallback covers the gap, but with degraded
 * ordering and an extra query per request — `fallbackUsed` in the
 * `discovery_feed_served` log event shows how often).
 *
 * WHAT: pages the whole collection and, for every document missing
 * `activityBucket`, stamps it with `lastActiveAt` (falling back to
 * `updatedAt`, else epoch) floored to the 10-minute bucket. Touches nothing
 * else; documents that already have the field are skipped, so re-running is
 * safe and a crashed run just resumes.
 *
 * USE (dry-run by default — prints what it would write):
 *   # Emulator rehearsal:
 *   FIRESTORE_EMULATOR_HOST=localhost:8080 node backfill-activity-buckets.mjs --project moomo-functions-test
 *   # Production (deploy checklist step; needs ADC with Firestore access):
 *   node backfill-activity-buckets.mjs --project moomo-c7a37 --confirm
 *
 * Refuses to run without an explicit --project, and never writes without
 * --confirm. `moomoios-2026` (the Moomo AI app) is refused outright.
 */
import { initializeApp } from 'firebase-admin/app';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';

const BUCKET_MS = 10 * 60 * 1000; // must match shared.ts ACTIVITY_BUCKET_MS
const PAGE_SIZE = 300;

const args = process.argv.slice(2);
const confirm = args.includes('--confirm');
const projectFlag = args.indexOf('--project');
const projectId = projectFlag >= 0 ? args[projectFlag + 1] : null;

if (!projectId) {
  console.error('Refusing to run without an explicit --project <id>.');
  process.exit(1);
}
if (projectId === 'moomoios-2026') {
  console.error('moomoios-2026 is the Moomo AI app and must never be touched.');
  process.exit(1);
}

initializeApp({ projectId });
const db = getFirestore();

const bucketFloor = (millis) =>
  Timestamp.fromMillis(Math.floor(millis / BUCKET_MS) * BUCKET_MS);

let scanned = 0;
let stamped = 0;
let cursor = null;

for (;;) {
  let query = db.collection('publicProfiles').orderBy('__name__').limit(PAGE_SIZE);
  if (cursor) query = query.startAfter(cursor);
  const page = await query.get();
  if (page.empty) break;
  cursor = page.docs[page.docs.length - 1];
  scanned += page.size;

  const writer = db.batch();
  let inBatch = 0;
  for (const doc of page.docs) {
    if (doc.get('activityBucket') !== undefined) continue;
    const source = doc.get('lastActiveAt') ?? doc.get('updatedAt');
    const bucket =
      source instanceof Timestamp ? bucketFloor(source.toMillis()) : Timestamp.fromMillis(0);
    if (confirm) {
      writer.update(doc.ref, { activityBucket: bucket });
      inBatch += 1;
    }
    stamped += 1;
  }
  if (confirm && inBatch > 0) await writer.commit();
  process.stdout.write(`\rscanned ${scanned}, ${confirm ? 'stamped' : 'would stamp'} ${stamped}`);
  if (page.size < PAGE_SIZE) break;
}

console.log(
  `\n${confirm ? 'Done' : 'Dry-run complete'}: ${scanned} profiles scanned, ` +
    `${stamped} ${confirm ? 'stamped' : 'need stamping (re-run with --confirm)'}.`
);
