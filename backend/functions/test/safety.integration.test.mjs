/**
 * blockUser cascade — emulator integration tests.
 *
 * Runs the REAL callable (compiled lib/, Admin SDK) against the Firestore
 * emulator via `npm test`, which wraps this in `firebase emulators:exec`.
 * Never touches a live project: it refuses to run without
 * FIRESTORE_EMULATOR_HOST.
 *
 * The one invariant these tests exist to hold: the conversation document dies
 * in the SAME transaction as the block. A crash after the transaction (the
 * recursiveDelete sweep) must never leave a conversation the pair could still
 * write into.
 */
import { test, describe, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fftModule from 'firebase-functions-test';

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error(
    'FIRESTORE_EMULATOR_HOST is not set. Run via `npm test` (firebase emulators:exec) — never against a live project.'
  );
}

const PROJECT_ID = 'moomo-functions-test-safety';
process.env.GCLOUD_PROJECT = PROJECT_ID;

const fftFactory = fftModule.default ?? fftModule;
const fft = fftFactory({ projectId: PROJECT_ID });

// Dynamic import so initializeApp() inside index.js runs AFTER the env setup.
const functions = await import('../lib/index.js');
const { getFirestore, Timestamp } = await import('firebase-admin/firestore');

const db = getFirestore();
const blockUser = fft.wrap(functions.blockUser);

const ALICE = 'alice-uid';
const BOB = 'bob-uid';
const PAIR = [ALICE, BOB].sort().join('_');
const CONV_ID = `conv_${PAIR}`;

const asAlice = (data) => ({ data, auth: { uid: ALICE, token: {} } });

async function clearFirestore() {
  const res = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`,
    { method: 'DELETE' }
  );
  assert.equal(res.status, 200);
}

/** The world as the backend leaves it mid-relationship: match, conversation
 *  with messages, and a live call. Exactly what a block must tear down. */
async function seedPair() {
  const now = Timestamp.now();
  const participants = {
    [ALICE]: { uid: ALICE, displayName: 'Alice', age: 28, city: null, gender: null, photoPath: null },
    [BOB]: { uid: BOB, displayName: 'Bob', age: 30, city: null, gender: null, photoPath: null },
  };
  await db.doc(`matches/${PAIR}`).set({
    participantIds: [ALICE, BOB].sort(),
    participants,
    conversationId: CONV_ID,
    sourceSessionId: 's1',
    createdAt: now,
  });
  await db.doc(`conversations/${CONV_ID}`).set({
    participantIds: [ALICE, BOB].sort(),
    participants,
    matchId: PAIR,
    createdAt: now,
    lastMessageAt: now,
    unreadCounts: { [ALICE]: 0, [BOB]: 0 },
  });
  await db.doc(`conversations/${CONV_ID}/messages/m1`).set({ senderId: ALICE, text: 'hi', sentAt: now });
  await db.doc(`conversations/${CONV_ID}/messages/m2`).set({ senderId: BOB, text: 'hey', sentAt: now });
  await db.doc('callSessions/s1').set({
    participantIds: [ALICE, BOB],
    participants,
    mode: 'voice',
    status: 'active',
    startedAt: Timestamp.fromMillis(now.toMillis() - 60_000),
    maxDurationSeconds: 180,
  });
}

describe('blockUser — the cascade', () => {
  beforeEach(clearFirestore);

  test('tears down block, match, conversation, messages, and the live call', async () => {
    await seedPair();

    const result = await blockUser(asAlice({ blockedUserId: BOB, displayName: 'Bob' }));
    assert.deepEqual(result, { blocked: true });

    const block = await db.doc(`blocks/${ALICE}/blocked/${BOB}`).get();
    assert.ok(block.exists, 'block document must exist');
    assert.equal(block.get('displayName'), 'Bob');

    assert.ok(!(await db.doc(`matches/${PAIR}`).get()).exists, 'match must be deleted');
    assert.ok(!(await db.doc(`conversations/${CONV_ID}`).get()).exists, 'conversation must be deleted');
    const messages = await db.collection(`conversations/${CONV_ID}/messages`).get();
    assert.equal(messages.size, 0, 'messages must be swept');

    const session = await db.doc('callSessions/s1').get();
    assert.equal(session.get('status'), 'ended');
    assert.equal(session.get('endedBy'), ALICE);

    // The blocker's history says blocked; the blocked person's never does.
    const aliceHistory = await db.doc(`users/${ALICE}/callHistory/s1`).get();
    assert.equal(aliceHistory.get('endReason'), 'blocked');
    assert.equal(aliceHistory.get('outcome'), 'blocked');
    const bobHistory = await db.doc(`users/${BOB}/callHistory/s1`).get();
    assert.equal(bobHistory.get('endReason'), 'ended');
    assert.equal(bobHistory.get('outcome'), undefined);
  });

  test('the conversation dies with the block even when the message sweep crashes', async () => {
    await seedPair();

    // Simulate the exact failure the fix exists for: the transaction commits,
    // then recursiveDelete never runs.
    const original = db.recursiveDelete;
    db.recursiveDelete = async () => {
      throw new Error('simulated crash before the message sweep');
    };
    try {
      await assert.rejects(blockUser(asAlice({ blockedUserId: BOB, displayName: 'Bob' })));
    } finally {
      db.recursiveDelete = original;
    }

    // The block and the conversation teardown were one transaction — both hold.
    assert.ok((await db.doc(`blocks/${ALICE}/blocked/${BOB}`).get()).exists);
    assert.ok(
      !(await db.doc(`conversations/${CONV_ID}`).get()).exists,
      'conversation document must be gone even though recursiveDelete crashed'
    );
    assert.ok(!(await db.doc(`matches/${PAIR}`).get()).exists);

    // Orphaned messages may linger (rules make them unreachable); a retried
    // block completes the sweep.
    await blockUser(asAlice({ blockedUserId: BOB, displayName: 'Bob' }));
    const messages = await db.collection(`conversations/${CONV_ID}/messages`).get();
    assert.equal(messages.size, 0, 'retry must sweep the orphaned messages');
  });

  test('blocking with nothing to tear down still records the block', async () => {
    const result = await blockUser(asAlice({ blockedUserId: BOB, displayName: 'Bob' }));
    assert.deepEqual(result, { blocked: true });
    assert.ok((await db.doc(`blocks/${ALICE}/blocked/${BOB}`).get()).exists);
  });

  test('self-block is refused', async () => {
    await assert.rejects(
      blockUser(asAlice({ blockedUserId: ALICE })),
      /cannot block yourself/
    );
  });

  test('an unauthenticated call is refused', async () => {
    await assert.rejects(
      blockUser({ data: { blockedUserId: BOB } }),
      /Sign in first/
    );
  });
});
