/**
 * The whole matchmaking spine, end to end, against the emulator:
 * join → pair (one transaction) → end call → decide → mutual like →
 * match + conversation + notifications. Plus the safety property the queue
 * must never violate: blocked pairs are not paired, in either direction.
 */
import { test, describe, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fftModule from 'firebase-functions-test';

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error(
    'FIRESTORE_EMULATOR_HOST is not set. Run via `npm test` (firebase emulators:exec) — never against a live project.'
  );
}

const PROJECT_ID = 'moomo-functions-test-matchmaking';
process.env.GCLOUD_PROJECT = PROJECT_ID;
// One shard = the old deterministic FIFO. The sharded-pool describe below
// raises this on purpose; everything else in this file depends on strict
// oldest-first ordering to keep its assertions exact.
process.env.QUEUE_SHARD_COUNT = '1';

const fftFactory = fftModule.default ?? fftModule;
const fft = fftFactory({ projectId: PROJECT_ID });

const functions = await import('../lib/index.js');
const { getFirestore, Timestamp } = await import('firebase-admin/firestore');

const db = getFirestore();
const joinQueue = fft.wrap(functions.joinMatchmakingQueue);
const leaveQueue = fft.wrap(functions.leaveMatchmakingQueue);
const endCall = fft.wrap(functions.endCallSession);
const decide = fft.wrap(functions.submitCallDecision);
const block = fft.wrap(functions.blockUser);

const ALICE = 'alice-mm-uid';
const BOB = 'bob-mm-uid';
const PAIR = [ALICE, BOB].sort().join('_');

const asUser = (uid, data = {}) => ({ data, auth: { uid, token: {} } });

async function clearFirestore() {
  const res = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`,
    { method: 'DELETE' }
  );
  assert.equal(res.status, 200);
}

async function seedProfiles() {
  const now = Timestamp.now();
  await db.doc(`publicProfiles/${ALICE}`).set({ displayName: 'Alice', age: 28, updatedAt: now });
  await db.doc(`publicProfiles/${BOB}`).set({ displayName: 'Bob', age: 30, updatedAt: now });
}

describe('matchmaking spine — join → pair → end → decide → match', () => {
  beforeEach(clearFirestore);

  test('the full happy path produces exactly one session, one match, one conversation', async () => {
    await seedProfiles();

    // Alice joins an empty queue: she waits, and Discover advertises her.
    const aliceJoin = await joinQueue(asUser(ALICE, { mode: 'voice' }));
    assert.equal(aliceJoin.status, 'waiting');
    assert.equal((await db.doc(`matchmakingQueue/${ALICE}`).get()).get('status'), 'waiting');
    assert.equal((await db.doc(`publicProfiles/${ALICE}`).get()).get('wantsToTalk'), true);

    // Bob joins: paired immediately, one transaction.
    const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice' }));
    assert.equal(bobJoin.status, 'matched');
    const { sessionId, participants } = bobJoin.session;
    assert.deepEqual(Object.keys(participants).sort(), [ALICE, BOB].sort());
    assert.equal(participants[ALICE].displayName, 'Alice');

    const session = await db.doc(`callSessions/${sessionId}`).get();
    assert.equal(session.get('status'), 'active');
    assert.equal(session.get('maxDurationSeconds'), 180);

    // Alice's queue entry flipped to matched with the same session — the
    // transition her listening client is waiting for.
    const aliceEntry = await db.doc(`matchmakingQueue/${ALICE}`).get();
    assert.equal(aliceEntry.get('status'), 'matched');
    assert.equal(aliceEntry.get('sessionId'), sessionId);
    // Neither is advertised as waiting any more.
    assert.equal((await db.doc(`publicProfiles/${ALICE}`).get()).get('wantsToTalk'), false);
    assert.equal((await db.doc(`publicProfiles/${BOB}`).get()).get('wantsToTalk'), false);

    // The call ends (Alice hangs up); the second end is a clean no-op.
    await endCall(asUser(ALICE, { sessionId, reason: 'ended' }));
    await endCall(asUser(BOB, { sessionId, reason: 'ended' }));
    assert.equal((await db.doc(`callSessions/${sessionId}`).get()).get('status'), 'ended');
    assert.equal((await db.doc(`users/${ALICE}/callHistory/${sessionId}`).get()).get('endReason'), 'ended');

    // Alice likes: not mutual yet, and Bob must not be able to tell.
    const aliceDecision = await decide(asUser(ALICE, { sessionId, decision: 'like' }));
    assert.equal(aliceDecision.outcome, 'likeSent');
    assert.ok(!(await db.doc(`matches/${PAIR}`).get()).exists, 'no match on a one-sided like');

    // Bob likes back: the match, its conversation, and both notifications
    // are minted in one transaction.
    const bobDecision = await decide(asUser(BOB, { sessionId, decision: 'like' }));
    assert.equal(bobDecision.outcome, 'matched');
    assert.equal(bobDecision.match.id, PAIR);

    const match = await db.doc(`matches/${PAIR}`).get();
    assert.ok(match.exists);
    assert.equal(match.get('sourceSessionId'), sessionId);
    const conversation = await db.doc(`conversations/${match.get('conversationId')}`).get();
    assert.ok(conversation.exists, 'the conversation exists the moment the match does');
    assert.deepEqual(conversation.get('unreadCounts'), { [ALICE]: 0, [BOB]: 0 });

    for (const uid of [ALICE, BOB]) {
      const notifications = await db.collection(`users/${uid}/notifications`).get();
      assert.equal(notifications.size, 1, `${uid} is told about the match`);
      assert.equal(notifications.docs[0].get('kind'), 'match');
      assert.equal(
        (await db.doc(`users/${uid}/callHistory/${sessionId}`).get()).get('outcome'),
        'matched'
      );
    }
  });

  test('a repeat pairing between the same two people reuses the match', async () => {
    await seedProfiles();
    // First round: pair, end, mutual like.
    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const first = await joinQueue(asUser(BOB, { mode: 'voice' }));
    await endCall(asUser(ALICE, { sessionId: first.session.sessionId, reason: 'ended' }));
    await decide(asUser(ALICE, { sessionId: first.session.sessionId, decision: 'like' }));
    await decide(asUser(BOB, { sessionId: first.session.sessionId, decision: 'like' }));

    // Second round, same pair.
    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const second = await joinQueue(asUser(BOB, { mode: 'voice' }));
    await endCall(asUser(ALICE, { sessionId: second.session.sessionId, reason: 'ended' }));
    await decide(asUser(ALICE, { sessionId: second.session.sessionId, decision: 'like' }));
    const outcome = await decide(asUser(BOB, { sessionId: second.session.sessionId, decision: 'like' }));

    assert.equal(outcome.outcome, 'matched');
    assert.equal(outcome.match.id, PAIR, 'the existing match is returned, never a duplicate');
    const matches = await db.collection('matches').where('participantIds', 'array-contains', ALICE).get();
    assert.equal(matches.size, 1);
  });

  test('a pass stays invisible: the liker sees likeSent, no match ever exists', async () => {
    await seedProfiles();
    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const { session } = await joinQueue(asUser(BOB, { mode: 'voice' }));
    await endCall(asUser(BOB, { sessionId: session.sessionId, reason: 'ended' }));

    await decide(asUser(BOB, { sessionId: session.sessionId, decision: 'pass' }));
    const outcome = await decide(asUser(ALICE, { sessionId: session.sessionId, decision: 'like' }));

    assert.equal(outcome.outcome, 'likeSent', '"they passed" and "they haven\'t decided" must be indistinguishable');
    assert.ok(!(await db.doc(`matches/${PAIR}`).get()).exists);
  });

  test('blocked pairs are never paired, in either direction', async () => {
    await seedProfiles();
    await db.doc(`blocks/${ALICE}/blocked/${BOB}`).set({ displayName: 'Bob', createdAt: Timestamp.now() });

    // Alice waits; Bob (whom she blocked) joins — he must NOT get her.
    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice' }));
    assert.equal(bobJoin.status, 'waiting', 'the blocked pair must not be matched');

    // Different mode never pairs either.
    const videoJoin = await joinQueue(asUser('carol-mm-uid', { mode: 'video' }));
    assert.equal(videoJoin.status, 'waiting', 'voice and video queues are separate');
  });

  test('leaving the queue removes the waiting entry and the advertisement', async () => {
    await seedProfiles();
    await joinQueue(asUser(ALICE, { mode: 'voice' }));

    await leaveQueue(asUser(ALICE));

    assert.ok(!(await db.doc(`matchmakingQueue/${ALICE}`).get()).exists);
    assert.equal((await db.doc(`publicProfiles/${ALICE}`).get()).get('wantsToTalk'), false);
  });
});

describe('preference-aware pairing — only mutually compatible users are paired', () => {
  beforeEach(clearFirestore);

  async function seedProfile(uid, data = {}) {
    await db
      .doc(`publicProfiles/${uid}`)
      .set({ displayName: uid, updatedAt: Timestamp.now(), ...data });
  }

  test('a one-way interest never pairs: she wants women, he wants women', async () => {
    await seedProfile(ALICE, { gender: 'woman', interestedIn: ['women'] });
    await seedProfile(BOB, { gender: 'man', interestedIn: ['women'] });

    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice' }));

    assert.equal(bobJoin.status, 'waiting', 'he wants her, she does not want him — no pair');
    assert.equal((await db.collection('callSessions').get()).size, 0);
  });

  test('mutually compatible users pair', async () => {
    await seedProfile(ALICE, { gender: 'woman', interestedIn: ['men'] });
    await seedProfile(BOB, { gender: 'man', interestedIn: ['women'] });

    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice' }));

    assert.equal(bobJoin.status, 'matched');
  });

  test('"everyone" accepts non-binary people; a binary-only preference does not', async () => {
    const CAROL = 'carol-nb-uid';
    await seedProfile(CAROL, { gender: 'nonBinary', interestedIn: ['everyone'] });
    await seedProfile(BOB, { gender: 'man', interestedIn: ['women'] });
    await seedProfile(ALICE, { gender: 'woman', interestedIn: ['everyone'] });

    // Bob (wants women only) joins while Carol (non-binary) waits: no pair.
    await joinQueue(asUser(CAROL, { mode: 'voice' }));
    const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice' }));
    assert.equal(bobJoin.status, 'waiting');

    // Alice (everyone) joins: she pairs with Carol, the older waiter.
    const aliceJoin = await joinQueue(asUser(ALICE, { mode: 'voice' }));
    assert.equal(aliceJoin.status, 'matched');
    assert.ok(aliceJoin.session.participants[CAROL], 'everyone ↔ everyone pairs');
  });

  test('missing preferences read as "everyone" — legacy accounts still pair', async () => {
    await seedProfile(ALICE, {});
    await seedProfile(BOB, { gender: 'man', interestedIn: ['everyone'] });

    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice' }));

    assert.equal(bobJoin.status, 'matched');
  });

  test('the preferred "Talk to Him" peer is skipped when incompatible', async () => {
    await seedProfile(ALICE, { gender: 'woman', interestedIn: ['women'] });
    await seedProfile(BOB, { gender: 'man', interestedIn: ['women'] });

    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice', preferredPeerId: ALICE }));

    assert.equal(bobJoin.status, 'waiting', 'an explicit invitation must not override her preferences');
    assert.equal((await db.collection('callSessions').get()).size, 0);
  });
});

describe('pass severance — a pass is a recorded choice the queue must respect', () => {
  beforeEach(clearFirestore);

  const CAROL = 'carol-pass-uid';

  async function seedProfile(uid, data = {}) {
    await db
      .doc(`publicProfiles/${uid}`)
      .set({ displayName: uid, updatedAt: Timestamp.now(), ...data });
  }

  /** Pair Alice and Bob, end the call, record Alice's pass on Bob. */
  async function pairAndPass() {
    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const { session } = await joinQueue(asUser(BOB, { mode: 'voice' }));
    await endCall(asUser(ALICE, { sessionId: session.sessionId, reason: 'ended' }));
    await decide(asUser(ALICE, { sessionId: session.sessionId, decision: 'pass' }));
    return session.sessionId;
  }

  test('a pass writes the pair tombstone; a like never does', async () => {
    await seedProfiles();
    const sessionId = await pairAndPass();
    const outcome = await decide(asUser(BOB, { sessionId, decision: 'like' }));

    assert.equal(outcome.outcome, 'likeSent');
    const tombstone = await db.doc(`passes/${ALICE}/passed/${BOB}`).get();
    assert.ok(tombstone.exists, "Alice's pass is recorded at pair level");
    assert.equal(tombstone.get('sessionId'), sessionId);
    assert.ok(
      !(await db.doc(`passes/${BOB}/passed/${ALICE}`).get()).exists,
      "Bob's like must not write a tombstone"
    );
  });

  test('a passed pair is never re-paired — and both still pair with other people', async () => {
    await seedProfiles();
    await seedProfile(CAROL);
    await pairAndPass();

    // Bob rejoins first and waits; Alice's join must skip past him.
    const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice' }));
    assert.equal(bobJoin.status, 'waiting');
    const aliceJoin = await joinQueue(asUser(ALICE, { mode: 'voice' }));
    assert.equal(aliceJoin.status, 'waiting', 'she passed on him — never again');

    // Carol joins: she pairs with Bob, the older waiter — the severance
    // belongs to the pair, not to either person.
    const carolJoin = await joinQueue(asUser(CAROL, { mode: 'voice' }));
    assert.equal(carolJoin.status, 'matched');
    assert.ok(carolJoin.session.participants[BOB], 'Bob is still matchable with others');
    assert.equal(
      (await db.doc(`matchmakingQueue/${ALICE}`).get()).get('status'),
      'waiting',
      'Alice keeps waiting for someone she has not passed on'
    );
  });

  test('the passed-on side cannot force a rematch via "Talk to Him"', async () => {
    await seedProfiles();
    await pairAndPass();

    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice', preferredPeerId: ALICE }));

    assert.equal(bobJoin.status, 'waiting', 'an invitation must not override her pass');
    const active = await db.collection('callSessions').where('status', '==', 'active').get();
    assert.equal(active.size, 0);
  });
});

describe('boost priority — an active boost really moves you up the queue', () => {
  beforeEach(clearFirestore);

  const CAROL = 'carol-boost-uid';
  const DAVE = 'dave-boost-uid';

  async function seedProfile(uid, data = {}) {
    await db
      .doc(`publicProfiles/${uid}`)
      .set({ displayName: uid, updatedAt: Timestamp.now(), ...data });
  }

  /**
   * Carol and Dave both wait (men seeking women — mutually incompatible, so
   * they cannot pair with each other); Alice (woman seeking men) joins and
   * must get whichever of them ranks first.
   */
  async function seedTriangle({ daveBoostedUntil }) {
    await seedProfile(CAROL, { gender: 'man', interestedIn: ['women'] });
    await seedProfile(DAVE, {
      gender: 'man',
      interestedIn: ['women'],
      ...(daveBoostedUntil ? { boostedUntil: daveBoostedUntil } : {}),
    });
    await seedProfile(ALICE, { gender: 'woman', interestedIn: ['men'] });

    await joinQueue(asUser(CAROL, { mode: 'voice' }));
    const daveJoin = await joinQueue(asUser(DAVE, { mode: 'voice' }));
    assert.equal(daveJoin.status, 'waiting', 'precondition: both are waiting');
  }

  test('an actively boosted waiter is paired before an earlier non-boosted one', async () => {
    await seedTriangle({
      daveBoostedUntil: Timestamp.fromMillis(Date.now() + 30 * 60 * 1000),
    });

    const aliceJoin = await joinQueue(asUser(ALICE, { mode: 'voice' }));

    assert.equal(aliceJoin.status, 'matched');
    assert.ok(
      aliceJoin.session.participants[DAVE],
      'the boosted waiter wins even though Carol queued first'
    );
    assert.equal(
      (await db.doc(`matchmakingQueue/${CAROL}`).get()).get('status'),
      'waiting',
      'Carol keeps waiting for the next joiner'
    );
  });

  test('an expired boost grants no priority — FIFO wins', async () => {
    await seedTriangle({
      daveBoostedUntil: Timestamp.fromMillis(Date.now() - 1000),
    });

    const aliceJoin = await joinQueue(asUser(ALICE, { mode: 'voice' }));

    assert.equal(aliceJoin.status, 'matched');
    assert.ok(aliceJoin.session.participants[CAROL], 'oldest waiter wins without a live boost');
  });

  test('an explicit "Talk to Him" invitation outranks a boost', async () => {
    await seedTriangle({
      daveBoostedUntil: Timestamp.fromMillis(Date.now() + 30 * 60 * 1000),
    });

    const aliceJoin = await joinQueue(
      asUser(ALICE, { mode: 'voice', preferredPeerId: CAROL })
    );

    assert.equal(aliceJoin.status, 'matched');
    assert.ok(aliceJoin.session.participants[CAROL]);
  });
});

describe('stale queue hygiene — abandoned entries never become ghost calls', () => {
  beforeEach(clearFirestore);

  const secondsAgo = (s) => Timestamp.fromMillis(Date.now() - s * 1000);

  /** A queue entry whose client died mid-wait: still advertised, never left. */
  async function seedAbandonedEntry(uid, ageSeconds) {
    await db.doc(`matchmakingQueue/${uid}`).set({
      uid,
      mode: 'voice',
      status: 'waiting',
      createdAt: secondsAgo(ageSeconds),
      updatedAt: secondsAgo(ageSeconds),
    });
    await db
      .doc(`publicProfiles/${uid}`)
      .set({ wantsToTalk: true, updatedAt: Timestamp.now() }, { merge: true });
  }

  test('an entry past the TTL is never paired — even as the preferred peer', async () => {
    await seedProfiles();
    // 60s: past the 40s TTL (dead client) but under the 80s sweep threshold.
    await seedAbandonedEntry(ALICE, 60);

    const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice', preferredPeerId: ALICE }));

    assert.equal(bobJoin.status, 'waiting', 'a 60s-old entry is a dead client, not a partner');
    assert.equal((await db.collection('callSessions').get()).size, 0, 'no ghost session exists');
  });

  test('the scheduled sweep removes entries past twice the TTL and withdraws their advertisement', async () => {
    await seedProfiles();
    await seedAbandonedEntry(ALICE, 120);

    await functions.sweepMatchmakingQueue.run({});

    assert.ok(!(await db.doc(`matchmakingQueue/${ALICE}`).get()).exists, 'abandoned entry swept');
    assert.equal(
      (await db.doc(`publicProfiles/${ALICE}`).get()).get('wantsToTalk'),
      false,
      'Discover must stop featuring someone who is not really waiting'
    );
  });

  test('the scheduled sweep leaves genuinely waiting entries alone', async () => {
    await seedProfiles();
    await joinQueue(asUser(BOB, { mode: 'voice' }));
    await seedAbandonedEntry(ALICE, 120);

    await functions.sweepMatchmakingQueue.run({});

    assert.ok(!(await db.doc(`matchmakingQueue/${ALICE}`).get()).exists);
    assert.equal((await db.doc(`publicProfiles/${ALICE}`).get()).get('wantsToTalk'), false);
    // The joiner is genuinely waiting and must survive the sweep.
    assert.equal((await db.doc(`matchmakingQueue/${BOB}`).get()).get('status'), 'waiting');
    assert.equal((await db.doc(`publicProfiles/${BOB}`).get()).get('wantsToTalk'), true);
  });

  test('join no longer sweeps — hygiene is the cron\'s job, not the hot path\'s (P1-2)', async () => {
    await seedProfiles();
    await seedAbandonedEntry(ALICE, 120);

    const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice' }));
    assert.equal(bobJoin.status, 'waiting', 'a 120s-old entry is still never a partner');

    // The stale entry remains until the scheduled sweep — the join-time
    // collection-scan transaction was the FIFO-contention amplifier the
    // audit flagged, and it must not quietly come back.
    assert.ok((await db.doc(`matchmakingQueue/${ALICE}`).get()).exists);
  });

  test('the sweep never touches matched entries of a call that may still be live', async () => {
    await seedProfiles();
    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const paired = await joinQueue(asUser(BOB, { mode: 'voice' }));
    assert.equal(paired.status, 'matched');

    // 100s into a 180s call: past the waiting-stale threshold (80s), but the
    // call clock is still running — sweeping now would let a duplicate join
    // double-book someone who is mid-call.
    for (const uid of [ALICE, BOB]) {
      await db.doc(`matchmakingQueue/${uid}`).update({ createdAt: secondsAgo(100) });
    }
    await functions.sweepMatchmakingQueue.run({});
    assert.ok((await db.doc(`matchmakingQueue/${ALICE}`).get()).exists, 'live-call entry survives');
    assert.ok((await db.doc(`matchmakingQueue/${BOB}`).get()).exists);

    // Past the call clock + reconnect grace (270s), the entries are litter.
    for (const uid of [ALICE, BOB]) {
      await db.doc(`matchmakingQueue/${uid}`).update({ createdAt: secondsAgo(300) });
    }
    await functions.sweepMatchmakingQueue.run({});
    assert.ok(!(await db.doc(`matchmakingQueue/${ALICE}`).get()).exists, 'expired entry swept');
    assert.ok(!(await db.doc(`matchmakingQueue/${BOB}`).get()).exists);
  });

  test('dead-client entries cannot bury a fresh waiter under the candidate window', async () => {
    await seedProfiles();
    // Ten abandoned entries aged past the TTL (40s) but under the sweep
    // threshold (80s) — the sweep cannot help, so the pairing query itself
    // must exclude them or they consume the whole limit-10 window.
    for (let i = 0; i < 10; i += 1) {
      await seedAbandonedEntry(`dead-${i}`, 50);
      await db.doc(`matchmakingQueue/dead-${i}`).update({ shard: 0 });
    }
    const aliceJoin = await joinQueue(asUser(ALICE, { mode: 'voice' }));
    assert.equal(aliceJoin.status, 'waiting', 'Alice waits — the dead are not partners');

    const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice' }));

    assert.equal(bobJoin.status, 'matched', 'the fresh waiter is found behind the dead window');
    assert.ok(bobJoin.session.participants[ALICE]);
  });

  test('a user who rejoins over their own abandoned entry gets a fresh waiting entry', async () => {
    await seedProfiles();
    await seedAbandonedEntry(ALICE, 120);

    const rejoin = await joinQueue(asUser(ALICE, { mode: 'voice' }));

    assert.equal(rejoin.status, 'waiting');
    const entry = await db.doc(`matchmakingQueue/${ALICE}`).get();
    assert.equal(entry.get('status'), 'waiting', 'the fresh entry exists');
    assert.ok(
      entry.get('createdAt').toMillis() > Date.now() - 10_000,
      'and it is the fresh one, not the abandoned one'
    );
    assert.equal(
      (await db.doc(`publicProfiles/${ALICE}`).get()).get('wantsToTalk'),
      true,
      'the rejoin is advertised'
    );
  });
});

describe('join idempotency — a duplicate join returns the existing live session', () => {
  beforeEach(clearFirestore);

  test('a retried join after pairing returns the same session, never a second one', async () => {
    await seedProfiles();
    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const first = await joinQueue(asUser(BOB, { mode: 'voice' }));
    assert.equal(first.status, 'matched');

    // The client's network dropped the response; it retries the call.
    const retry = await joinQueue(asUser(BOB, { mode: 'voice' }));

    assert.equal(retry.status, 'matched');
    assert.equal(retry.session.sessionId, first.session.sessionId, 'same session, not a new pairing');
    assert.equal((await db.collection('callSessions').get()).size, 1, 'exactly one session exists');
    // The peer's entry still points at the same session.
    assert.equal((await db.doc(`matchmakingQueue/${ALICE}`).get()).get('sessionId'), first.session.sessionId);
  });

  test('after the call ends, a rejoin is a genuine new join', async () => {
    await seedProfiles();
    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const first = await joinQueue(asUser(BOB, { mode: 'voice' }));
    await endCall(asUser(BOB, { sessionId: first.session.sessionId, reason: 'ended' }));

    const rejoin = await joinQueue(asUser(BOB, { mode: 'voice' }));

    assert.equal(rejoin.status, 'waiting', 'an ended session is not resurrected');
    assert.equal((await db.doc(`matchmakingQueue/${BOB}`).get()).get('status'), 'waiting');
  });

  test('a join for a DIFFERENT mode never returns the live session of the old one', async () => {
    await seedProfiles();
    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const voice = await joinQueue(asUser(BOB, { mode: 'voice' }));
    assert.equal(voice.status, 'matched');

    // The client labels a call with the mode it requested — handing a video
    // join a live voice session would render the wrong call entirely.
    const videoJoin = await joinQueue(asUser(BOB, { mode: 'video' }));

    assert.equal(videoJoin.status, 'waiting', 'a video join is a new join, not the voice session');
  });

  test('enqueueing stamps the public activityBucket server-side (feed visibility)', async () => {
    await seedProfiles();
    await joinQueue(asUser(ALICE, { mode: 'voice' }));

    const profile = await db.doc(`publicProfiles/${ALICE}`).get();
    const bucket = profile.get('activityBucket');
    assert.ok(bucket, 'a waiting user is visible to the bucketed feed queries');
    assert.equal(bucket.toMillis() % 600_000, 0, 'aligned exactly as the rules demand');
    assert.ok(bucket.toMillis() <= Date.now(), 'never from the future');
  });
});

describe('sharded waiting pool — contention relief must never hide waiting users', () => {
  beforeEach(clearFirestore);

  const SHARDS = 4;
  before(() => {
    process.env.QUEUE_SHARD_COUNT = String(SHARDS);
  });
  after(() => {
    process.env.QUEUE_SHARD_COUNT = '1';
  });

  /** A waiting entry as joinMatchmakingQueue writes it, pinned to a shard. */
  async function seedWaiting(uid, shard) {
    const now = Timestamp.now();
    await db.doc(`matchmakingQueue/${uid}`).set({
      uid,
      mode: 'voice',
      status: 'waiting',
      shard,
      createdAt: now,
      updatedAt: now,
    });
  }

  test('a waiter is found whatever shard they landed in', async () => {
    // One waiter, once per shard: the scan must fall through empty shards
    // and reach them every time.
    for (let shard = 0; shard < SHARDS; shard += 1) {
      await clearFirestore();
      await seedProfiles();
      await seedWaiting(ALICE, shard);

      const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice' }));

      assert.equal(bobJoin.status, 'matched', `waiter in shard ${shard} must be found`);
      assert.ok(bobJoin.session.participants[ALICE]);
    }
  });

  test('concurrent joins never double-book anyone (duplicate prevention)', async () => {
    const users = ['con-a', 'con-b', 'con-c', 'con-d', 'con-e', 'con-f'];
    const now = Timestamp.now();
    for (const uid of users) {
      await db.doc(`publicProfiles/${uid}`).set({ displayName: uid, updatedAt: now });
    }

    const results = await Promise.all(
      users.map((uid) => joinQueue(asUser(uid, { mode: 'voice' })))
    );

    // Every call resolved to a definite state.
    for (const result of results) {
      assert.ok(['matched', 'waiting'].includes(result.status));
    }

    // No user appears in more than one session, and every session has
    // exactly two distinct participants — the invariant the pairing
    // transaction exists to protect, now under real concurrency.
    const sessions = await db.collection('callSessions').get();
    const seen = new Map();
    for (const session of sessions.docs) {
      const ids = session.get('participantIds');
      assert.equal(ids.length, 2);
      assert.notEqual(ids[0], ids[1]);
      for (const uid of ids) {
        assert.ok(!seen.has(uid), `${uid} was paired into two sessions`);
        seen.set(uid, session.id);
      }
    }

    // Everyone is accounted for: in exactly one session, or genuinely waiting.
    for (const uid of users) {
      const entry = await db.doc(`matchmakingQueue/${uid}`).get();
      assert.ok(entry.exists, `${uid} has a queue entry`);
      if (entry.get('status') === 'matched') {
        assert.equal(seen.get(uid), entry.get('sessionId'));
      } else {
        assert.equal(entry.get('status'), 'waiting');
        assert.ok(!seen.has(uid), `${uid} is waiting yet also in a session`);
      }
    }
  });
});

describe('decisions after a block — a block placed after the session severs the pair', () => {
  beforeEach(clearFirestore);

  const CONV = `conv_${PAIR}`;

  /** Pair the two through the real queue and return the session id. */
  async function pairUp() {
    await seedProfiles();
    await joinQueue(asUser(ALICE, { mode: 'voice' }));
    const bobJoin = await joinQueue(asUser(BOB, { mode: 'voice' }));
    return bobJoin.session.sessionId;
  }

  test('one likes, the other blocks: a stale/tampered like must not create the match or conversation', async () => {
    const sessionId = await pairUp();
    await endCall(asUser(ALICE, { sessionId, reason: 'ended' }));

    // Alice decides first — an honest like into what is still a live pair.
    const aliceOutcome = await decide(asUser(ALICE, { sessionId, decision: 'like' }));
    assert.equal(aliceOutcome.outcome, 'likeSent');

    // Bob blocks her. From this instant the pair is severed.
    await block(asUser(BOB, { blockedUserId: ALICE, displayName: 'Alice' }));

    // Bob's like now arrives anyway — his UI never offers it after blocking,
    // so this is a stale retry or a tampered client. It must mint nothing.
    const bobOutcome = await decide(asUser(BOB, { sessionId, decision: 'like' }));
    assert.equal(bobOutcome.outcome, 'likeSent', 'acknowledged, never an error that would leak state');
    assert.equal(bobOutcome.match, undefined);
    assert.ok(!(await db.doc(`matches/${PAIR}`).get()).exists, 'no match for a blocked pair');
    assert.ok(!(await db.doc(`conversations/${CONV}`).get()).exists, 'no conversation for a blocked pair');
    assert.ok(
      !(await db.doc(`callSessions/${sessionId}/decisions/${BOB}`).get()).exists,
      'nothing recorded: a stored like must never complete a mutual like later'
    );
  });

  test('an existing match destroyed by a block is never resurrected by a stale like retry', async () => {
    const sessionId = await pairUp();
    await endCall(asUser(ALICE, { sessionId, reason: 'ended' }));
    await decide(asUser(ALICE, { sessionId, decision: 'like' }));
    await decide(asUser(BOB, { sessionId, decision: 'like' }));
    assert.ok((await db.doc(`matches/${PAIR}`).get()).exists, 'precondition: the pair matched');

    // Alice blocks Bob; the cascade removes the match and the conversation.
    await block(asUser(ALICE, { blockedUserId: BOB, displayName: 'Bob' }));
    assert.ok(!(await db.doc(`matches/${PAIR}`).get()).exists);
    assert.ok(!(await db.doc(`conversations/${CONV}`).get()).exists);

    // Bob replays his like (idempotent retries are normally allowed, and both
    // decisions still exist — before the fix this recreated match AND
    // conversation through the repeat-pair path).
    const replay = await decide(asUser(BOB, { sessionId, decision: 'like' }));
    assert.equal(replay.outcome, 'likeSent');
    assert.ok(!(await db.doc(`matches/${PAIR}`).get()).exists, 'the block outlives the stale like');
    assert.ok(!(await db.doc(`conversations/${CONV}`).get()).exists);
  });

  test('a mid-call block: the blocked side may still decide, learns nothing, and the blocker\'s history survives untouched', async () => {
    const sessionId = await pairUp();

    // Bob likes early (allowed — decisions are not gated on session status),
    // then blocks Alice mid-call. The cascade ends the call and stamps his
    // history "blocked"; hers says an ordinary "ended".
    await decide(asUser(BOB, { sessionId, decision: 'like' }));
    await block(asUser(BOB, { blockedUserId: ALICE, displayName: 'Alice' }));
    assert.equal((await db.doc(`callSessions/${sessionId}`).get()).get('status'), 'ended');
    assert.equal((await db.doc(`users/${BOB}/callHistory/${sessionId}`).get()).get('outcome'), 'blocked');
    assert.equal((await db.doc(`users/${ALICE}/callHistory/${sessionId}`).get()).get('endReason'), 'ended');

    // Alice, none the wiser, decides like from her ordinary decision screen.
    // Bob's like is already on file — without the block check this is a
    // mutual like and would mint the match.
    const aliceOutcome = await decide(asUser(ALICE, { sessionId, decision: 'like' }));
    assert.equal(aliceOutcome.outcome, 'likeSent', 'indistinguishable from an undecided peer');
    assert.ok(!(await db.doc(`matches/${PAIR}`).get()).exists);
    assert.ok(!(await db.doc(`conversations/${CONV}`).get()).exists);
    assert.equal((await db.collection(`users/${ALICE}/notifications`).get()).size, 0, 'no match notification');

    // A tampered pass from Bob is acknowledged but writes nothing: his
    // history must keep saying "blocked", not get clobbered to "passed".
    const bobPass = await decide(asUser(BOB, { sessionId, decision: 'pass' }));
    assert.equal(bobPass.outcome, 'passed');
    assert.equal((await db.doc(`users/${BOB}/callHistory/${sessionId}`).get()).get('outcome'), 'blocked');
  });
});
