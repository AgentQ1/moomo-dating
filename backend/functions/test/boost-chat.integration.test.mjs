/**
 * activateBoost and the onMessageCreated trigger — emulator integration.
 *
 * Boost is server-owned entitlement state (free allowance today, money-ready
 * shape); the trigger is what keeps every conversation's preview and unread
 * counters honest without the list screen ever reading threads.
 */
import { test, describe, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fftModule from 'firebase-functions-test';

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error(
    'FIRESTORE_EMULATOR_HOST is not set. Run via `npm test` (firebase emulators:exec) — never against a live project.'
  );
}

const PROJECT_ID = 'moomo-functions-test-boost-chat';
process.env.GCLOUD_PROJECT = PROJECT_ID;

const fftFactory = fftModule.default ?? fftModule;
const fft = fftFactory({ projectId: PROJECT_ID });

const functions = await import('../lib/index.js');
const { getFirestore, Timestamp } = await import('firebase-admin/firestore');

const db = getFirestore();
const activateBoost = fft.wrap(functions.activateBoost);
const onMessageCreated = fft.wrap(functions.onMessageCreated);

const ALICE = 'alice-bc-uid';
const BOB = 'bob-bc-uid';

const asUser = (uid, data = {}) => ({ data, auth: { uid, token: {} } });

async function clearFirestore() {
  const res = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`,
    { method: 'DELETE' }
  );
  assert.equal(res.status, 200);
}

describe('activateBoost — server-owned allowance', () => {
  beforeEach(clearFirestore);

  test('a fresh account gets the daily allowance and a real expiry', async () => {
    const result = await activateBoost(asUser(ALICE));

    assert.equal(result.remainingBoosts, 2, '3/day allowance, one spent');
    assert.ok(result.activeUntilMillis > Date.now(), 'expiry is in the future');

    const state = await db.doc(`boosts/${ALICE}`).get();
    assert.equal(state.get('remainingBoosts'), 2);
    // Discover ranking sees it — and only the server may write this field.
    const profile = await db.doc(`publicProfiles/${ALICE}`).get();
    assert.ok(profile.get('boostedUntil').toMillis() > Date.now());
  });

  test('a second activation while boosted is refused', async () => {
    await activateBoost(asUser(ALICE));
    await assert.rejects(activateBoost(asUser(ALICE)), /alreadyActive/);
  });

  test('an exhausted allowance refuses honestly until the daily refill', async () => {
    // Exhausted an hour ago, nothing active.
    await db.doc(`boosts/${ALICE}`).set({
      remainingBoosts: 0,
      activeUntil: Timestamp.fromMillis(Date.now() - 60_000),
      grantedAt: Timestamp.fromMillis(Date.now() - 60 * 60 * 1000),
      updatedAt: Timestamp.now(),
    });
    await assert.rejects(activateBoost(asUser(ALICE)), /noneRemaining/);

    // 25 hours later the lazy refill kicks in.
    await db.doc(`boosts/${ALICE}`).update({
      grantedAt: Timestamp.fromMillis(Date.now() - 25 * 60 * 60 * 1000),
    });
    const result = await activateBoost(asUser(ALICE));
    assert.equal(result.remainingBoosts, 2);
  });

  test('an unauthenticated call is refused', async () => {
    await assert.rejects(activateBoost({ data: {} }), /Sign in first/);
  });
});

describe('onMessageCreated — the conversation stays honest', () => {
  beforeEach(clearFirestore);

  const CONV = 'conv_trigger-test';

  async function seedConversation() {
    await db.doc(`conversations/${CONV}`).set({
      participantIds: [ALICE, BOB],
      matchId: 'm1',
      createdAt: Timestamp.now(),
      lastMessageAt: Timestamp.now(),
      unreadCounts: { [ALICE]: 0, [BOB]: 0 },
    });
  }

  /** Simulates the trigger firing for a message document. */
  async function fireTrigger(messageId, message) {
    const snapshot = fft.firestore.makeDocumentSnapshot(
      message,
      `conversations/${CONV}/messages/${messageId}`
    );
    await onMessageCreated({
      data: snapshot,
      params: { conversationId: CONV, messageId },
    });
  }

  test("a message updates the preview and increments only the recipient's unread count", async () => {
    await seedConversation();
    const sentAt = Timestamp.now();

    await fireTrigger('m1', { senderId: ALICE, text: 'hello bob', sentAt });

    const conversation = await db.doc(`conversations/${CONV}`).get();
    assert.equal(conversation.get('lastMessage').text, 'hello bob');
    assert.equal(conversation.get('lastMessage').senderId, ALICE);
    assert.equal(conversation.get('unreadCounts')[BOB], 1, 'the recipient gains an unread');
    assert.equal(conversation.get('unreadCounts')[ALICE], 0, 'the sender does not');
  });

  test('the preview truncates long messages; the thread keeps the full text', async () => {
    await seedConversation();
    const long = 'x'.repeat(600);

    await fireTrigger('m1', { senderId: BOB, text: long, sentAt: Timestamp.now() });

    const preview = (await db.doc(`conversations/${CONV}`).get()).get('lastMessage').text;
    assert.equal(preview.length, 200, 'preview is capped — the full text lives on the message');
  });

  test('a message whose conversation was deleted mid-flight is a clean no-op', async () => {
    // No conversation seeded — the block cascade got there first.
    await fireTrigger('m1', { senderId: ALICE, text: 'too late', sentAt: Timestamp.now() });
    assert.ok(!(await db.doc(`conversations/${CONV}`).get()).exists);
  });
});
