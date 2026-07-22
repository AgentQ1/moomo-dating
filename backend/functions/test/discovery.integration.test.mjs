/**
 * The server-composed Discover feed (audit P0-3 / P1-3 / P2-2), against the
 * emulator: bounded, block-filtered both directions, compatibility-filtered
 * with the matchmaking table, PII-minimal, and rate-limited.
 *
 * The scrape-resistance claim itself is two-sided and split across suites:
 * the rules tests prove clients can no longer LIST publicProfiles at all;
 * this file proves the only remaining browse path returns a bounded,
 * cursor-free, minimal payload.
 */
import { test, describe, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fftModule from 'firebase-functions-test';

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error(
    'FIRESTORE_EMULATOR_HOST is not set. Run via `npm test` (firebase emulators:exec) — never against a live project.'
  );
}

const PROJECT_ID = 'moomo-functions-test-discovery';
process.env.GCLOUD_PROJECT = PROJECT_ID;

const fftFactory = fftModule.default ?? fftModule;
const fft = fftFactory({ projectId: PROJECT_ID });

const functions = await import('../lib/index.js');
const { RATE_LIMITS } = await import('../lib/ratelimit.js');
const { getFirestore, Timestamp } = await import('firebase-admin/firestore');

const db = getFirestore();
const feed = fft.wrap(functions.getDiscoveryFeed);

const VIEWER = 'viewer-feed-uid';

const asUser = (uid, data = {}) => ({ data, auth: { uid, token: {} } });

async function clearFirestore() {
  const res = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`,
    { method: 'DELETE' }
  );
  assert.equal(res.status, 200);
}

const BUCKET_MS = 10 * 60 * 1000;
/** The activity bucket a live client heartbeat would write, n buckets back. */
const bucketsAgo = (n = 0) =>
  Timestamp.fromMillis(Math.floor(Date.now() / BUCKET_MS - n) * BUCKET_MS);
const secondsAgo = (s) => Timestamp.fromMillis(Date.now() - s * 1000);

/** A finished, feed-visible profile, as the app + heartbeat would leave it. */
async function seedProfile(uid, extra = {}) {
  await db.doc(`publicProfiles/${uid}`).set({
    uid,
    displayName: uid,
    age: 30,
    city: 'Austin',
    gender: 'man',
    interestedIn: ['everyone'],
    lastActiveAt: secondsAgo(30),
    activityBucket: bucketsAgo(0),
    updatedAt: Timestamp.now(),
    ...extra,
  });
}

const uids = (result) => result.candidates.map((c) => c.uid);

describe('getDiscoveryFeed — the only way to browse profiles', () => {
  beforeEach(clearFirestore);

  test('requires a signed-in caller', async () => {
    await assert.rejects(feed({ data: {} }), (error) => {
      assert.equal(error.code, 'unauthenticated');
      return true;
    });
  });

  test('returns compatible candidates and never the viewer themself', async () => {
    await seedProfile(VIEWER, { gender: 'woman', interestedIn: ['men'] });
    await seedProfile('bob-feed', { gender: 'man', interestedIn: ['women'] });

    const result = await feed(asUser(VIEWER));

    assert.deepEqual(uids(result), ['bob-feed']);
  });

  test('one-way interest is filtered with the same table matchmaking pairs by', async () => {
    await seedProfile(VIEWER, { gender: 'woman', interestedIn: ['men'] });
    // Wants the viewer, but the viewer doesn't want her — must not appear.
    await seedProfile('carol-feed', { gender: 'woman', interestedIn: ['women'] });
    // Wanted by the viewer, but doesn't want women — must not appear.
    await seedProfile('dave-feed', { gender: 'man', interestedIn: ['men'] });

    const result = await feed(asUser(VIEWER));

    assert.deepEqual(uids(result), []);
  });

  test('blocked pairs are invisible in BOTH directions — server-side, not client-side', async () => {
    await seedProfile(VIEWER);
    await seedProfile('blocked-by-viewer');
    await seedProfile('blocked-the-viewer');
    await seedProfile('stranger-feed');
    await db.doc(`blocks/${VIEWER}/blocked/blocked-by-viewer`).set({ createdAt: Timestamp.now() });
    await db.doc(`blocks/blocked-the-viewer/blocked/${VIEWER}`).set({ createdAt: Timestamp.now() });

    const result = await feed(asUser(VIEWER));

    assert.deepEqual(uids(result), ['stranger-feed']);
  });

  test('an after-call pass hides the pair from BOTH feeds — passer and passed-on alike', async () => {
    await seedProfile(VIEWER);
    await seedProfile('passed-by-viewer');
    await seedProfile('passed-the-viewer');
    await seedProfile('stranger-feed');
    await db.doc(`passes/${VIEWER}/passed/passed-by-viewer`).set({ createdAt: Timestamp.now() });
    await db.doc(`passes/passed-the-viewer/passed/${VIEWER}`).set({ createdAt: Timestamp.now() });

    const result = await feed(asUser(VIEWER));

    assert.deepEqual(uids(result), ['stranger-feed']);
  });

  test('profiles that never finished onboarding are not shown to strangers', async () => {
    await seedProfile(VIEWER);
    await seedProfile('unnamed-feed', { displayName: '' });

    const result = await feed(asUser(VIEWER));

    assert.deepEqual(uids(result), []);
  });

  test('the payload is the render-minimal DTO — raw activity times never leave the server', async () => {
    await seedProfile(VIEWER);
    await seedProfile('bob-feed', {
      occupation: 'Designer',
      photoPaths: ['users/bob-feed/photos/p1.jpg'],
      wantsToTalk: true,
      boostedUntil: Timestamp.fromMillis(Date.now() + 60_000),
    });

    const result = await feed(asUser(VIEWER));
    const [bob] = result.candidates;

    assert.deepEqual(
      Object.keys(bob).sort(),
      [
        'age', 'city', 'displayName', 'gender', 'isOnline', 'isVerified',
        'occupation', 'photoPath', 'uid', 'wantsToTalk',
      ],
      'exactly the fields Discover renders — no lastActiveAt, no preferences, no server flags'
    );
    assert.equal(bob.photoPath, 'users/bob-feed/photos/p1.jpg');
    assert.equal(bob.wantsToTalk, true);
  });

  test('isOnline is computed server-side from the five-minute window', async () => {
    await seedProfile(VIEWER);
    await seedProfile('fresh-feed', { lastActiveAt: secondsAgo(30) });
    await seedProfile('stale-feed', { lastActiveAt: secondsAgo(6 * 60) });

    const result = await feed(asUser(VIEWER));
    const byUid = Object.fromEntries(result.candidates.map((c) => [c.uid, c]));

    assert.equal(byUid['fresh-feed'].isOnline, true);
    assert.equal(byUid['stale-feed'].isOnline, false);
  });

  test('the feed is bounded at 25 — never a page cursor, never the whole base', async () => {
    await seedProfile(VIEWER);
    for (let i = 0; i < 40; i += 1) {
      await seedProfile(`crowd-${String(i).padStart(2, '0')}`);
    }

    const result = await feed(asUser(VIEWER));

    assert.equal(result.candidates.length, 25);
    assert.ok(!('cursor' in result), 'no pagination handle exists to enumerate with');
  });

  test('a genuinely waiting user surfaces even when a whole bucket of fresher people exists', async () => {
    await seedProfile(VIEWER);
    // Enough recently-active users to fill the entire scan pool…
    for (let i = 0; i < 60; i += 1) {
      await seedProfile(`crowd-${String(i).padStart(2, '0')}`);
    }
    // …and one waiting person from an older bucket, whom recency alone
    // would bury: the hero card is the product, they must appear.
    await seedProfile('waiting-feed', {
      wantsToTalk: true,
      activityBucket: bucketsAgo(2),
      lastActiveAt: secondsAgo(15 * 60),
    });

    const result = await feed(asUser(VIEWER));

    assert.ok(uids(result).includes('waiting-feed'), 'the waiting user is in the feed');
    assert.equal(result.candidates.length, 25, 'the bound still holds');
  });

  test('recently active people come first', async () => {
    await seedProfile(VIEWER);
    await seedProfile('older-feed', { lastActiveAt: secondsAgo(240) });
    await seedProfile('newer-feed', { lastActiveAt: secondsAgo(10) });

    const result = await feed(asUser(VIEWER));

    assert.deepEqual(uids(result), ['newer-feed', 'older-feed']);
  });

  test('legacy profiles without activityBucket are still served via the rollout fallback', async () => {
    // Pre-remediation documents have lastActiveAt but no activityBucket, and
    // orderBy excludes them — the fallback must keep Discover alive until
    // the backfill script runs.
    await seedProfile(VIEWER);
    for (const uid of ['legacy-a', 'legacy-b', 'legacy-c']) {
      await db.doc(`publicProfiles/${uid}`).set({
        uid,
        displayName: uid,
        age: 31,
        city: 'Austin',
        gender: 'man',
        interestedIn: ['everyone'],
        lastActiveAt: secondsAgo(45),
        updatedAt: Timestamp.now(),
        // deliberately NO activityBucket
      });
    }

    const result = await feed(asUser(VIEWER));

    for (const uid of ['legacy-a', 'legacy-b', 'legacy-c']) {
      assert.ok(uids(result).includes(uid), `${uid} must not vanish on deploy day`);
    }
  });

  test('a compatible waiting user surfaces even behind a wall of incompatible waiters', async () => {
    // The waiting pool is fetched with headroom because compat/block filters
    // run after the fetch — ten incompatible waiters at the top must not
    // exhaust the hero-card supply.
    await seedProfile(VIEWER, { gender: 'woman', interestedIn: ['men'] });
    for (let i = 0; i < 12; i += 1) {
      await seedProfile(`waiting-woman-${String(i).padStart(2, '0')}`, {
        gender: 'woman',
        interestedIn: ['men'],
        wantsToTalk: true,
      });
    }
    await seedProfile('waiting-man', {
      gender: 'man',
      interestedIn: ['women'],
      wantsToTalk: true,
      activityBucket: bucketsAgo(1),
      lastActiveAt: secondsAgo(8 * 60),
    });

    const result = await feed(asUser(VIEWER));

    assert.deepEqual(uids(result), ['waiting-man'], 'the only compatible waiter is found');
  });

  test('the feed is rate-limited per user (anti-enumeration)', async () => {
    await seedProfile(VIEWER);
    const { limit } = RATE_LIMITS.getDiscoveryFeed;
    for (let i = 0; i < limit; i += 1) {
      await feed(asUser(VIEWER));
    }
    await assert.rejects(feed(asUser(VIEWER)), (error) => {
      assert.equal(error.code, 'resource-exhausted');
      return true;
    });
  });
});
