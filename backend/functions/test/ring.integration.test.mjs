/**
 * Ring invites end to end against the emulator: a waiting join fans out
 * banners to compatible ONLINE users, the first accepter wins the caller
 * atomically through the existing callSessions flow, and every refusal —
 * lost race, expired ring, vanished caller, busy accepter, block, pass —
 * is the same indistinguishable "unavailable" success response.
 *
 * The exclusion tests mirror the matchmaking/discovery suites on purpose:
 * a ring must never reach a person the queue would refuse to pair.
 */
import { test, describe, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fftModule from 'firebase-functions-test';

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error(
    'FIRESTORE_EMULATOR_HOST is not set. Run via `npm test` (firebase emulators:exec) — never against a live project.'
  );
}

const PROJECT_ID = 'moomo-functions-test-ring';
process.env.GCLOUD_PROJECT = PROJECT_ID;
process.env.QUEUE_SHARD_COUNT = '1';

const fftFactory = fftModule.default ?? fftModule;
const fft = fftFactory({ projectId: PROJECT_ID });

const functions = await import('../lib/index.js');
const { RING_TTL_MS, RING_FANOUT_LIMIT } = await import('../lib/shared.js');
const { getFirestore, Timestamp } = await import('firebase-admin/firestore');

const db = getFirestore();
const joinQueue = fft.wrap(functions.joinMatchmakingQueue);
const leaveQueue = fft.wrap(functions.leaveMatchmakingQueue);
const accept = fft.wrap(functions.acceptCallInvite);
const decline = fft.wrap(functions.declineCallInvite);

const CALLER = 'caller-ring-uid';
const BOB = 'bob-ring-uid';
const DAVE = 'dave-ring-uid';
const EVAN = 'evan-ring-uid';

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

/** An ONLINE, feed-visible profile, as the app + heartbeat would leave it. */
async function seedProfile(uid, extra = {}) {
  await db.doc(`publicProfiles/${uid}`).set({
    uid,
    displayName: uid,
    age: 30,
    city: 'Austin',
    gender: 'man',
    interestedIn: ['women'],
    lastActiveAt: secondsAgo(30),
    activityBucket: bucketsAgo(0),
    updatedAt: Timestamp.now(),
    ...extra,
  });
}

/** The caller everyone rings for: a woman seeking men. */
const seedCaller = (extra = {}) =>
  seedProfile(CALLER, { gender: 'woman', interestedIn: ['men'], ...extra });

const ringedIds = async () =>
  (await db.collection('callInvites').get()).docs.map((d) => d.id).sort();

describe('ring fan-out — a waiting join rings compatible online users', () => {
  beforeEach(clearFirestore);

  test('a waiting join rings a compatible online user with the full invite shape', async () => {
    await seedCaller();
    await seedProfile(BOB);

    const join = await joinQueue(asUser(CALLER, { mode: 'video' }));
    assert.equal(join.status, 'waiting');

    const invite = await db.doc(`callInvites/${BOB}`).get();
    assert.ok(invite.exists, 'the online compatible user is rung');
    assert.equal(invite.get('uid'), BOB);
    assert.equal(invite.get('callerUid'), CALLER);
    assert.equal(invite.get('mode'), 'video');
    assert.equal(invite.get('status'), 'ringing');
    assert.deepEqual(
      invite.get('caller'),
      {
        uid: CALLER,
        displayName: CALLER,
        age: 30,
        city: 'Austin',
        gender: 'woman',
        photoPath: null,
        isVerified: false,
      },
      'the banner summary: ParticipantSummary shape plus isVerified'
    );
    const expiresAt = invite.get('expiresAt').toMillis();
    assert.equal(
      expiresAt - invite.get('createdAt').toMillis(),
      RING_TTL_MS,
      'the acceptance window is exactly RING_TTL_MS'
    );
    assert.ok(expiresAt > Date.now(), 'and it is still open');

    // The caller's entry remembers who it rang (accept/leave use this).
    const entry = await db.doc(`matchmakingQueue/${CALLER}`).get();
    assert.deepEqual(entry.get('ringedUids'), [BOB]);
  });

  test('a one-way interest is never rung, in either direction', async () => {
    await seedCaller();
    // She is not a man — the caller's own preference rejects her.
    await seedProfile('unwanted-ring', { gender: 'woman', interestedIn: ['men'] });
    // He is wanted, but he does not want women.
    await seedProfile('unwanting-ring', { gender: 'man', interestedIn: ['men'] });
    await seedProfile(BOB);

    await joinQueue(asUser(CALLER, { mode: 'video' }));

    assert.deepEqual(await ringedIds(), [BOB], 'only the mutually compatible user rings');
  });

  test('blocked and passed pairs are never rung, in either direction', async () => {
    await seedCaller();
    for (const uid of ['blocked-by-caller', 'blocked-the-caller', 'passed-by-caller', 'passed-the-caller']) {
      await seedProfile(uid);
    }
    await seedProfile(BOB);
    await db.doc(`blocks/${CALLER}/blocked/blocked-by-caller`).set({ createdAt: Timestamp.now() });
    await db.doc(`blocks/blocked-the-caller/blocked/${CALLER}`).set({ createdAt: Timestamp.now() });
    await db.doc(`passes/${CALLER}/passed/passed-by-caller`).set({ createdAt: Timestamp.now() });
    await db.doc(`passes/passed-the-caller/passed/${CALLER}`).set({ createdAt: Timestamp.now() });

    await joinQueue(asUser(CALLER, { mode: 'video' }));

    assert.deepEqual(await ringedIds(), [BOB], 'only the unexcluded stranger rings');
  });

  test('offline and busy people are never rung', async () => {
    await seedCaller();
    // Recently bucketed but outside the five-minute online window.
    await seedProfile('offline-ring', { lastActiveAt: secondsAgo(6 * 60) });
    // On a (presumed) live call: a fresh matched queue entry.
    await seedProfile('busy-ring');
    const now = Timestamp.now();
    await db.doc('matchmakingQueue/busy-ring').set({
      uid: 'busy-ring',
      mode: 'video',
      status: 'matched',
      sessionId: 'live-elsewhere',
      createdAt: now,
      updatedAt: now,
    });
    await seedProfile(BOB);

    await joinQueue(asUser(CALLER, { mode: 'video' }));

    assert.deepEqual(await ringedIds(), [BOB], 'neither the offline nor the busy user rings');
  });

  test('the fan-out is capped at RING_FANOUT_LIMIT', async () => {
    await seedCaller();
    for (let i = 0; i < RING_FANOUT_LIMIT + 4; i += 1) {
      await seedProfile(`crowd-ring-${String(i).padStart(2, '0')}`);
    }

    await joinQueue(asUser(CALLER, { mode: 'video' }));

    assert.equal((await ringedIds()).length, RING_FANOUT_LIMIT);
    const entry = await db.doc(`matchmakingQueue/${CALLER}`).get();
    assert.equal(entry.get('ringedUids').length, RING_FANOUT_LIMIT);
  });

  test('the preferred "Talk to Him" peer is rung even when the bucket scan would miss him', async () => {
    await seedCaller();
    // No activityBucket at all: the ordered pool query excludes him, so only
    // the preferredPeerId direct read can find him.
    await db.doc(`publicProfiles/${BOB}`).set({
      uid: BOB,
      displayName: BOB,
      gender: 'man',
      interestedIn: ['women'],
      lastActiveAt: secondsAgo(10),
      updatedAt: Timestamp.now(),
    });

    const join = await joinQueue(asUser(CALLER, { mode: 'video', preferredPeerId: BOB }));

    assert.equal(join.status, 'waiting', 'he is not in the queue, so no instant pair');
    assert.equal((await db.doc(`callInvites/${BOB}`).get()).get('status'), 'ringing');
  });

  test('a decline starts the same-caller cooldown — no immediate re-ring', async () => {
    await seedCaller();
    await seedProfile(BOB);
    await joinQueue(asUser(CALLER, { mode: 'video' }));
    await decline(asUser(BOB));
    await leaveQueue(asUser(CALLER));

    const rejoin = await joinQueue(asUser(CALLER, { mode: 'video' }));

    assert.equal(rejoin.status, 'waiting');
    assert.equal(
      (await db.doc(`callInvites/${BOB}`).get()).get('status'),
      'declined',
      'the declined invite is not overwritten by a fresh ring'
    );
  });

  test('the same-caller cooldown survives another caller taking the slot in between', async () => {
    await seedCaller();
    await seedProfile(BOB);
    // Dave rang Bob 31 seconds ago (past the any-caller gap) and Bob is
    // silent — but the slot still remembers the CALLER's ring from a minute
    // ago via the carried map. Without it, Dave's overwrite would have
    // erased the CALLER's 120s hounding brake.
    await db.doc(`callInvites/${BOB}`).set({
      uid: BOB,
      callerUid: DAVE,
      mode: 'video',
      status: 'declined',
      createdAt: secondsAgo(31),
      expiresAt: secondsAgo(21),
      updatedAt: secondsAgo(31),
      recentCallers: { [CALLER]: secondsAgo(60) },
    });

    const rejoin = await joinQueue(asUser(CALLER, { mode: 'video', preferredPeerId: BOB }));

    assert.equal(rejoin.status, 'waiting');
    const invite = await db.doc(`callInvites/${BOB}`).get();
    assert.equal(invite.get('status'), 'declined', 'the cooldown still holds');
    assert.equal(invite.get('callerUid'), DAVE, 'the slot was not overwritten');
  });

  test('an overwrite carries the previous slot holder into recentCallers and prunes the expired', async () => {
    await seedCaller();
    await seedProfile(BOB);
    // Dave's ring went terminal 31s ago (ringable again per the any-caller
    // gap); the CALLER's own prior ring has aged past the 120s window.
    await db.doc(`callInvites/${BOB}`).set({
      uid: BOB,
      callerUid: DAVE,
      mode: 'video',
      status: 'declined',
      createdAt: secondsAgo(31),
      expiresAt: secondsAgo(21),
      updatedAt: secondsAgo(31),
      recentCallers: { [CALLER]: secondsAgo(130) },
    });

    const rejoin = await joinQueue(asUser(CALLER, { mode: 'video', preferredPeerId: BOB }));

    assert.equal(rejoin.status, 'waiting');
    const invite = await db.doc(`callInvites/${BOB}`).get();
    assert.equal(invite.get('status'), 'ringing', 'an expired cooldown no longer blocks');
    assert.equal(invite.get('callerUid'), CALLER);
    const carried = invite.get('recentCallers');
    assert.ok(carried[DAVE], 'the displaced slot holder is remembered');
    assert.equal(carried[CALLER], undefined, 'entries past the window are pruned');
  });
});

describe('acceptCallInvite — the first accepter wins, atomically', () => {
  beforeEach(clearFirestore);

  test('accept creates the session, matches both queue docs, and cancels sibling rings', async () => {
    await seedCaller();
    await seedProfile(BOB);
    await seedProfile(DAVE);
    await joinQueue(asUser(CALLER, { mode: 'video' }));
    assert.deepEqual(await ringedIds(), [BOB, DAVE].sort(), 'precondition: both ring');

    const result = await accept(asUser(BOB));

    assert.equal(result.status, 'accepted');
    assert.deepEqual(
      Object.keys(result.session).sort(),
      ['maxDurationSeconds', 'mode', 'participants', 'sessionId', 'startedAtMillis'],
      "exactly joinMatchmakingQueue's matched session payload shape"
    );
    const { session } = result;
    assert.equal(session.mode, 'video');
    assert.equal(session.maxDurationSeconds, 180);
    assert.equal(typeof session.startedAtMillis, 'number');
    assert.deepEqual(Object.keys(session.participants).sort(), [BOB, CALLER].sort());
    assert.equal(session.participants[CALLER].displayName, CALLER);

    // The server-owned session is live and both queue entries point at it —
    // the caller's listening client gets the same transition as a pairing.
    const sessionDoc = await db.doc(`callSessions/${session.sessionId}`).get();
    assert.equal(sessionDoc.get('status'), 'active');
    for (const uid of [CALLER, BOB]) {
      const entry = await db.doc(`matchmakingQueue/${uid}`).get();
      assert.equal(entry.get('status'), 'matched');
      assert.equal(entry.get('sessionId'), session.sessionId);
    }
    // Neither is advertised as waiting any more.
    assert.equal((await db.doc(`publicProfiles/${CALLER}`).get()).get('wantsToTalk'), false);

    // My invite is terminal-accepted with the session; the sibling's ring
    // is withdrawn.
    const myInvite = await db.doc(`callInvites/${BOB}`).get();
    assert.equal(myInvite.get('status'), 'accepted');
    assert.equal(myInvite.get('sessionId'), session.sessionId);
    assert.ok(myInvite.get('respondedAt'), 'the response moment is stamped');
    assert.equal((await db.doc(`callInvites/${DAVE}`).get()).get('status'), 'cancelled');
  });

  test('concurrent accepts: exactly one wins, the rest are unavailable, one session exists', async () => {
    await seedCaller();
    for (const uid of [BOB, DAVE, EVAN]) {
      await seedProfile(uid);
    }
    await joinQueue(asUser(CALLER, { mode: 'video' }));
    assert.equal((await ringedIds()).length, 3, 'precondition: all three ring');

    const results = await Promise.all(
      [BOB, DAVE, EVAN].map((uid) => accept(asUser(uid)))
    );

    const accepted = results.filter((r) => r.status === 'accepted');
    const unavailable = results.filter((r) => r.status === 'unavailable');
    assert.equal(accepted.length, 1, 'exactly one accepter wins');
    assert.equal(unavailable.length, 2, 'the losers get the uniform refusal');
    assert.deepEqual(Object.keys(unavailable[0]), ['status'], 'no leak rides the refusal');

    const sessions = await db.collection('callSessions').get();
    assert.equal(sessions.size, 1, 'exactly one session exists');
    assert.deepEqual(
      Object.keys(accepted[0].session.participants).sort(),
      [CALLER, ...sessions.docs[0].get('participantIds').filter((id) => id !== CALLER)].sort()
    );
    assert.equal(
      (await db.doc(`matchmakingQueue/${CALLER}`).get()).get('sessionId'),
      sessions.docs[0].id
    );
  });

  test('accept after the acceptance window closes is unavailable', async () => {
    await seedCaller();
    await seedProfile(BOB);
    await joinQueue(asUser(CALLER, { mode: 'video' }));
    await db.doc(`callInvites/${BOB}`).update({ expiresAt: secondsAgo(1) });

    const result = await accept(asUser(BOB));

    assert.deepEqual(result, { status: 'unavailable' });
    assert.equal((await db.collection('callSessions').get()).size, 0);
    assert.equal(
      (await db.doc(`matchmakingQueue/${CALLER}`).get()).get('status'),
      'waiting',
      'the caller keeps waiting out their normal window'
    );
  });

  test('a block or pass seeded AFTER the ring makes accept unavailable (transactional re-check)', async () => {
    await seedCaller();
    await seedProfile(BOB);
    await seedProfile(DAVE);
    await joinQueue(asUser(CALLER, { mode: 'video' }));
    assert.deepEqual(await ringedIds(), [BOB, DAVE].sort(), 'precondition: both ring');

    // The block lands between ring and accept — exactly the race the
    // in-transaction check exists for.
    await db.doc(`blocks/${BOB}/blocked/${CALLER}`).set({ createdAt: Timestamp.now() });
    const blockedResult = await accept(asUser(BOB));
    assert.deepEqual(blockedResult, { status: 'unavailable' }, 'indistinguishable from a lost race');

    // Same shape for a pass tombstone.
    await db.doc(`passes/${CALLER}/passed/${DAVE}`).set({ createdAt: Timestamp.now() });
    const passedResult = await accept(asUser(DAVE));
    assert.deepEqual(passedResult, { status: 'unavailable' });

    assert.equal((await db.collection('callSessions').get()).size, 0, 'no session was minted');
  });

  test('an accepter already on a live call is refused — no double-booking', async () => {
    await seedCaller();
    await seedProfile(BOB);
    await joinQueue(asUser(CALLER, { mode: 'video' }));

    // Bob got busy after the ring went out.
    const now = Timestamp.now();
    await db.doc('callSessions/live-1').set({
      participantIds: [BOB, 'someone-else'],
      participants: {},
      mode: 'video',
      status: 'active',
      startedAt: now,
      maxDurationSeconds: 180,
      createdAt: now,
    });
    await db.doc(`matchmakingQueue/${BOB}`).set({
      uid: BOB,
      mode: 'video',
      status: 'matched',
      sessionId: 'live-1',
      createdAt: now,
      updatedAt: now,
    });

    const result = await accept(asUser(BOB));

    assert.deepEqual(result, { status: 'unavailable' });
    assert.equal((await db.collection('callSessions').get()).size, 1, 'only the pre-existing session');
  });

  test('accept with no invite at all is unavailable, never an error', async () => {
    const result = await accept(asUser(BOB));
    assert.deepEqual(result, { status: 'unavailable' });
  });
});

describe('decline, leave, and sweep — every ring dies cleanly', () => {
  beforeEach(clearFirestore);

  test("decline is terminal for the invite and leaves the caller's wait untouched", async () => {
    await seedCaller();
    await seedProfile(BOB);
    await joinQueue(asUser(CALLER, { mode: 'video' }));

    const result = await decline(asUser(BOB));

    assert.deepEqual(result, { status: 'ok' });
    const invite = await db.doc(`callInvites/${BOB}`).get();
    assert.equal(invite.get('status'), 'declined');
    assert.ok(invite.get('respondedAt'));
    assert.equal(
      (await db.doc(`matchmakingQueue/${CALLER}`).get()).get('status'),
      'waiting',
      'the caller keeps waiting — a decline is silent'
    );

    // A repeat decline (or one with nothing to decline) is a clean no-op.
    assert.deepEqual(await decline(asUser(BOB)), { status: 'ok' });
    assert.equal((await db.doc(`callInvites/${BOB}`).get()).get('status'), 'declined');
  });

  test('leaveMatchmakingQueue cancels its still-ringing invites', async () => {
    await seedCaller();
    await seedProfile(BOB);
    await seedProfile(DAVE);
    await joinQueue(asUser(CALLER, { mode: 'video' }));
    assert.deepEqual(await ringedIds(), [BOB, DAVE].sort(), 'precondition: both ring');

    await leaveQueue(asUser(CALLER));

    for (const uid of [BOB, DAVE]) {
      assert.equal(
        (await db.doc(`callInvites/${uid}`).get()).get('status'),
        'cancelled',
        `${uid}'s banner is withdrawn with the wait`
      );
    }
    // Accepting a cancelled ring is the uniform refusal.
    assert.deepEqual(await accept(asUser(BOB)), { status: 'unavailable' });
  });

  test('the sweep expires stale ringing invites and leaves live ones alone', async () => {
    await seedCaller();
    await seedProfile(BOB);
    await seedProfile(DAVE);
    await joinQueue(asUser(CALLER, { mode: 'video' }));
    await db.doc(`callInvites/${BOB}`).update({ expiresAt: secondsAgo(1) });

    await functions.sweepMatchmakingQueue.run({});

    assert.equal((await db.doc(`callInvites/${BOB}`).get()).get('status'), 'expired');
    assert.equal(
      (await db.doc(`callInvites/${DAVE}`).get()).get('status'),
      'ringing',
      'a ring still inside its window survives the sweep'
    );
  });
});

describe('retired call modes — a voice-only ring is unanswerable', () => {
  beforeEach(clearFirestore);

  test('accepting a still-ringing voice invite reads as no live ring', async () => {
    // A ring created before Speed Talk was removed can still be sitting in
    // `callInvites` when a client updates. Answering it would pair a video
    // client into a voice session, so it reads as the same honest dead end
    // as an expired ring — never as an error that leaks what happened.
    await seedCaller();
    await seedProfile(BOB);
    await joinQueue(asUser(CALLER, { mode: 'video' }));

    // Rewrite the live ring (and the caller's entry) as the retired mode,
    // exactly as a pre-removal fan-out would have left them.
    await db.doc(`callInvites/${BOB}`).update({ mode: 'voice' });
    await db.doc(`matchmakingQueue/${CALLER}`).update({ mode: 'voice' });

    assert.deepEqual(await accept(asUser(BOB)), { status: 'unavailable' });
    const sessions = await db.collection('callSessions').get();
    assert.equal(sessions.size, 0, 'no session may be created for a retired mode');
  });

  test('a video ring is still answerable', async () => {
    await seedCaller();
    await seedProfile(BOB);
    await joinQueue(asUser(CALLER, { mode: 'video' }));

    const result = await accept(asUser(BOB));

    assert.equal(result.status, 'accepted');
    assert.equal(result.session.mode, 'video');
  });
});
