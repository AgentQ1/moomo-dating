/**
 * The abuse/operations guard rails, end to end against the emulator:
 * per-user rate limits (audit P1-4), the kill-switch / maintenance flag
 * (audit P0-1), and the structured-event contract observability rides on
 * (audit P1-5).
 *
 * What is deliberately NOT tested here: the limiter's fail-closed branch
 * (it triggers only on a Firestore outage, which the emulator cannot stage)
 * — it is covered by code review; and App Check token verification, which is
 * platform code exercised before any handler (see options.config.test.mjs
 * for the enforcement guardrails).
 */
import { test, describe, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fftModule from 'firebase-functions-test';

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error(
    'FIRESTORE_EMULATOR_HOST is not set. Run via `npm test` (firebase emulators:exec) — never against a live project.'
  );
}

const PROJECT_ID = 'moomo-functions-test-guards';
process.env.GCLOUD_PROJECT = PROJECT_ID;
// Re-read the kill-switch document on every call — these tests flip it and
// must see the flip immediately.
process.env.RUNTIME_CONFIG_CACHE_MS = '0';
process.env.QUEUE_SHARD_COUNT = '1';

const fftFactory = fftModule.default ?? fftModule;
const fft = fftFactory({ projectId: PROJECT_ID });

const functions = await import('../lib/index.js');
const { RATE_LIMITS } = await import('../lib/ratelimit.js');
const { logEvent } = await import('../lib/observability.js');
const { getFirestore, Timestamp } = await import('firebase-admin/firestore');

const db = getFirestore();
const joinQueue = fft.wrap(functions.joinMatchmakingQueue);
const leaveQueue = fft.wrap(functions.leaveMatchmakingQueue);
const activateBoost = fft.wrap(functions.activateBoost);
const feed = fft.wrap(functions.getDiscoveryFeed);

const ALICE = 'alice-guards-uid';

const asUser = (uid, data = {}) => ({ data, auth: { uid, token: {} } });

async function clearFirestore() {
  const res = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`,
    { method: 'DELETE' }
  );
  assert.equal(res.status, 200);
}

const rejectsWithCode = (code) => (error) => {
  assert.equal(error.code, code, `expected ${code}, got ${error.code}: ${error.message}`);
  return true;
};

describe('per-user rate limits — expensive callables are not free levers', () => {
  beforeEach(clearFirestore);

  test('joinMatchmakingQueue refuses once the window is full', async () => {
    const { limit } = RATE_LIMITS.joinMatchmakingQueue;
    for (let i = 0; i < limit; i += 1) {
      await joinQueue(asUser(ALICE, { mode: 'voice' }));
    }
    await assert.rejects(
      joinQueue(asUser(ALICE, { mode: 'voice' })),
      rejectsWithCode('resource-exhausted')
    );
  });

  test('the limit is per user — one user\'s storm never blocks another', async () => {
    const { limit } = RATE_LIMITS.joinMatchmakingQueue;
    for (let i = 0; i < limit; i += 1) {
      await joinQueue(asUser(ALICE, { mode: 'voice' }));
    }
    const other = await joinQueue(asUser('bob-guards-uid', { mode: 'voice' }));
    assert.ok(['matched', 'waiting'].includes(other.status));
  });

  test('an expired window resets the allowance', async () => {
    const { limit, windowMs } = RATE_LIMITS.joinMatchmakingQueue;
    await db.doc(`rateLimits/${ALICE}_joinMatchmakingQueue`).set({
      uid: ALICE,
      action: 'joinMatchmakingQueue',
      windowStartMillis: Date.now() - windowMs - 1000,
      count: limit,
    });

    const result = await joinQueue(asUser(ALICE, { mode: 'voice' }));
    assert.equal(result.status, 'waiting', 'a stale window must not still block');
  });

  test('the limiter counts attempts, not successes — a failing loop is still throttled', async () => {
    const { limit } = RATE_LIMITS.activateBoost;
    // First activation succeeds; the rest fail with alreadyActive — and every
    // one of them still consumes rate budget, so the free-to-spin loop the
    // audit called out (P1-4) hits the wall.
    await activateBoost(asUser(ALICE));
    for (let i = 1; i < limit; i += 1) {
      await assert.rejects(activateBoost(asUser(ALICE)), rejectsWithCode('failed-precondition'));
    }
    await assert.rejects(activateBoost(asUser(ALICE)), rejectsWithCode('resource-exhausted'));
  });

  test('rate-limit counters are attributable operator records', async () => {
    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const counter = await db.doc(`rateLimits/${ALICE}_joinMatchmakingQueue`).get();
    assert.ok(counter.exists);
    assert.equal(counter.get('uid'), ALICE);
    assert.equal(counter.get('action'), 'joinMatchmakingQueue');
    assert.equal(counter.get('count'), 1);
    assert.equal(typeof counter.get('windowStartMillis'), 'number');
  });
});

describe('kill switch — config/runtime flips features off without a deploy', () => {
  beforeEach(clearFirestore);

  test('a missing config document means everything is enabled', async () => {
    const result = await joinQueue(asUser(ALICE, { mode: 'voice' }));
    assert.equal(result.status, 'waiting');
  });

  test('matchmakingEnabled=false refuses joins with a retryable error', async () => {
    await db.doc('config/runtime').set({ matchmakingEnabled: false });
    await assert.rejects(
      joinQueue(asUser(ALICE, { mode: 'voice' })),
      rejectsWithCode('unavailable')
    );
  });

  test('maintenanceMode blocks gated callables but NEVER leaving the queue', async () => {
    // Waiting first, then the brake drops.
    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    await db.doc('config/runtime').set({ maintenanceMode: true });

    await assert.rejects(
      joinQueue(asUser('someone-else-uid', { mode: 'voice' })),
      rejectsWithCode('unavailable')
    );
    await assert.rejects(feed(asUser(ALICE)), rejectsWithCode('unavailable'));

    // Nobody may be trapped in the queue by an outage brake.
    const left = await leaveQueue(asUser(ALICE));
    assert.equal(left.left, true);
    assert.ok(!(await db.doc(`matchmakingQueue/${ALICE}`).get()).exists);
  });

  test('discoveryEnabled=false turns the feed off on its own', async () => {
    await db.doc('config/runtime').set({ discoveryEnabled: false });
    await assert.rejects(feed(asUser(ALICE)), rejectsWithCode('unavailable'));
    // Matchmaking is a different switch and stays up.
    const join = await joinQueue(asUser(ALICE, { mode: 'voice' }));
    assert.equal(join.status, 'waiting');
  });

  test('flags flip back on without residue', async () => {
    await db.doc('config/runtime').set({ matchmakingEnabled: false });
    await assert.rejects(joinQueue(asUser(ALICE, { mode: 'voice' })));
    await db.doc('config/runtime').set({ matchmakingEnabled: true });
    const result = await joinQueue(asUser(ALICE, { mode: 'voice' }));
    assert.equal(result.status, 'waiting');
  });
});

describe('structured events — the contract dashboards and alerts are built on', () => {
  test('logEvent stamps the stable event field alerts key on', () => {
    const entry = logEvent('rate_limit_blocked', { uid: 'u1', action: 'x' });
    assert.deepEqual(entry, { event: 'rate_limit_blocked', uid: 'u1', action: 'x' });
  });

  test('fields never clobber the event name', () => {
    const entry = logEvent('matchmaking_sweep', { swept: 3, event: 'spoofed' });
    // Object spread order: explicit fields land after `event`; the helper
    // must keep the name authoritative.
    assert.equal(entry.event, 'matchmaking_sweep');
  });
});
