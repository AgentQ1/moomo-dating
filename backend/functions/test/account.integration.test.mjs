/**
 * deleteAccount + resolveReport — emulator integration tests.
 *
 * deleteAccount is the app's only complete deletion (client deletes cannot
 * reach server-owned collections). These tests prove the whole cascade:
 * everything the account owns dies — including the Auth user and Storage
 * photos — while the peer's own records and the safety record (reports)
 * survive.
 */
import { test, describe, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fftModule from 'firebase-functions-test';

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error(
    'FIRESTORE_EMULATOR_HOST is not set. Run via `npm test` (firebase emulators:exec) — never against a live project.'
  );
}
if (!process.env.FIREBASE_AUTH_EMULATOR_HOST || !process.env.FIREBASE_STORAGE_EMULATOR_HOST) {
  throw new Error('Auth/Storage emulators missing — run via `npm test` (emulators:exec --only firestore,auth,storage).');
}

const PROJECT_ID = 'moomo-functions-test-account';
const BUCKET = `${PROJECT_ID}.appspot.com`;
process.env.GCLOUD_PROJECT = PROJECT_ID;

const fftFactory = fftModule.default ?? fftModule;
const fft = fftFactory({ projectId: PROJECT_ID, storageBucket: BUCKET });

const functions = await import('../lib/index.js');
const { getFirestore, Timestamp } = await import('firebase-admin/firestore');
const { getAuth } = await import('firebase-admin/auth');
const { getStorage } = await import('firebase-admin/storage');

const db = getFirestore();
const deleteAccount = fft.wrap(functions.deleteAccount);
const resolveReport = fft.wrap(functions.resolveReport);

const ALICE = 'alice-del-uid';
const BOB = 'bob-del-uid';
const PAIR = [ALICE, BOB].sort().join('_');
const CONV_ID = `conv_${PAIR}`;

async function clearFirestore() {
  const res = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`,
    { method: 'DELETE' }
  );
  assert.equal(res.status, 200);
}

/** Alice's whole world: profile docs, a match+conversation+messages with Bob,
 *  a finished call, queue entry, boosts, a block, notifications, a photo, an
 *  Auth user, and reports in both directions. */
async function seedAliceWorld() {
  const now = Timestamp.now();
  await getAuth().createUser({ uid: ALICE }).catch(() => {});

  await db.doc(`users/${ALICE}`).set({ uid: ALICE, createdAt: now, updatedAt: now });
  await db.doc(`users/${ALICE}/private/onboarding`).set({ step: 'done' });
  await db.doc(`users/${ALICE}/callHistory/s1`).set({ sessionId: 's1', endReason: 'ended', updatedAt: now });
  await db.doc(`users/${ALICE}/notifications/n1`).set({ kind: 'match', title: 't', body: 'b', isRead: false, createdAt: now });
  await db.doc(`publicProfiles/${ALICE}`).set({ displayName: 'Alice', updatedAt: now });
  await db.doc(`matchmakingQueue/${ALICE}`).set({ mode: 'voice', status: 'waiting', createdAt: now });
  await db.doc(`boosts/${ALICE}`).set({ remainingBoosts: 2, grantedAt: now });
  await db.doc(`blocks/${ALICE}/blocked/some-third-uid`).set({ displayName: 'Third', createdAt: now });

  await db.doc(`matches/${PAIR}`).set({ participantIds: [ALICE, BOB].sort(), conversationId: CONV_ID, createdAt: now });
  await db.doc(`conversations/${CONV_ID}`).set({ participantIds: [ALICE, BOB].sort(), matchId: PAIR, createdAt: now, lastMessageAt: now });
  await db.doc(`conversations/${CONV_ID}/messages/m1`).set({ senderId: ALICE, text: 'hi', sentAt: now });
  await db.doc('callSessions/s1').set({ participantIds: [ALICE, BOB], mode: 'voice', status: 'ended', startedAt: now });
  await db.doc('callSessions/s1/decisions/' + ALICE).set({ uid: ALICE, decision: 'like', decidedAt: now });

  // Bob's own records that merely mention Alice — these must survive.
  await db.doc(`users/${BOB}`).set({ uid: BOB, createdAt: now, updatedAt: now });
  await db.doc(`users/${BOB}/callHistory/s1`).set({ sessionId: 's1', endReason: 'ended', peer: { uid: ALICE, displayName: 'Alice' }, updatedAt: now });
  await db.doc(`blocks/${BOB}/blocked/${ALICE}`).set({ displayName: 'Alice', createdAt: now });

  // The safety record, both directions.
  await db.doc('reports/r-by-alice').set({ reporterId: ALICE, reportedId: 'someone', reason: 'spam', status: 'open', createdAt: now });
  await db.doc('reports/r-about-alice').set({ reporterId: BOB, reportedId: ALICE, reason: 'harassment', status: 'open', createdAt: now });

  await getStorage().bucket().file(`users/${ALICE}/photos/p1.jpg`).save(Buffer.from('jpeg-bytes'));
}

describe('deleteAccount — the complete cascade', () => {
  beforeEach(clearFirestore);

  test('removes everything the account owns, the photos, and the Auth user', async () => {
    await seedAliceWorld();

    const result = await deleteAccount({ data: {}, auth: { uid: ALICE, token: {} } });
    assert.deepEqual(result, { deleted: true });

    for (const path of [
      `users/${ALICE}`,
      `users/${ALICE}/private/onboarding`,
      `users/${ALICE}/callHistory/s1`,
      `users/${ALICE}/notifications/n1`,
      `publicProfiles/${ALICE}`,
      `matchmakingQueue/${ALICE}`,
      `boosts/${ALICE}`,
      `blocks/${ALICE}/blocked/some-third-uid`,
      `matches/${PAIR}`,
      `conversations/${CONV_ID}`,
      `conversations/${CONV_ID}/messages/m1`,
      'callSessions/s1',
      `callSessions/s1/decisions/${ALICE}`,
    ]) {
      assert.ok(!(await db.doc(path).get()).exists, `${path} must be deleted`);
    }

    const [photoExists] = await getStorage().bucket().file(`users/${ALICE}/photos/p1.jpg`).exists();
    assert.equal(photoExists, false, 'photos must be deleted');

    await assert.rejects(getAuth().getUser(ALICE), /no user record/i);
  });

  test("leaves the peer's records and the safety record intact", async () => {
    await seedAliceWorld();

    await deleteAccount({ data: {}, auth: { uid: ALICE, token: {} } });

    assert.ok((await db.doc(`users/${BOB}`).get()).exists, "Bob's account survives");
    assert.ok(
      (await db.doc(`users/${BOB}/callHistory/s1`).get()).exists,
      "Bob's own record of his call survives"
    );
    assert.ok(
      (await db.doc(`blocks/${BOB}/blocked/${ALICE}`).get()).exists,
      "Bob's block survives — his safety choice is his record"
    );
    assert.ok((await db.doc('reports/r-by-alice').get()).exists, 'reports survive deletion');
    assert.ok((await db.doc('reports/r-about-alice').get()).exists, 'being deleted does not clear the safety record');
  });

  test('a retry after a partial failure completes cleanly', async () => {
    await seedAliceWorld();
    // First run deleted the Auth user; a retry (same client session) must not
    // trip over the missing user.
    await getAuth().deleteUser(ALICE);
    const result = await deleteAccount({ data: {}, auth: { uid: ALICE, token: {} } });
    assert.deepEqual(result, { deleted: true });
    assert.ok(!(await db.doc(`users/${ALICE}`).get()).exists);
  });

  test('an unauthenticated call is refused', async () => {
    await assert.rejects(deleteAccount({ data: {} }), /Sign in first/);
  });
});

describe('resolveReport — admin-only moderation', () => {
  beforeEach(clearFirestore);

  async function seedReport() {
    await db.doc('reports/r1').set({
      reporterId: BOB,
      reportedId: ALICE,
      reason: 'harassment',
      status: 'open',
      createdAt: Timestamp.now(),
    });
  }

  test('an admin can resolve a report with a resolution note', async () => {
    await seedReport();

    const result = await resolveReport({
      data: { reportId: 'r1', status: 'resolved', resolution: 'warned the user' },
      auth: { uid: 'admin-uid', token: { admin: true } },
    });
    assert.deepEqual(result, { status: 'resolved' });

    const report = await db.doc('reports/r1').get();
    assert.equal(report.get('status'), 'resolved');
    assert.equal(report.get('resolution'), 'warned the user');
    assert.equal(report.get('resolvedBy'), 'admin-uid');
    assert.ok(report.get('resolvedAt'));
  });

  test('a non-admin is refused — even the reporter', async () => {
    await seedReport();
    await assert.rejects(
      resolveReport({
        data: { reportId: 'r1', status: 'dismissed' },
        auth: { uid: BOB, token: {} },
      }),
      /Admin only/
    );
    assert.equal((await db.doc('reports/r1').get()).get('status'), 'open');
  });

  test('an invalid status is refused', async () => {
    await seedReport();
    await assert.rejects(
      resolveReport({
        data: { reportId: 'r1', status: 'shadowbanned' },
        auth: { uid: 'admin-uid', token: { admin: true } },
      }),
      /Invalid status/
    );
  });

  test('a missing report 404s', async () => {
    await assert.rejects(
      resolveReport({
        data: { reportId: 'ghost', status: 'resolved' },
        auth: { uid: 'admin-uid', token: { admin: true } },
      }),
      /No such report/
    );
  });
});
