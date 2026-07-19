/**
 * getCallMediaToken — emulator integration tests.
 *
 * Runs the real callable against the Firestore emulator with throwaway
 * LiveKit credentials injected via env (exactly how params resolve in the
 * emulator). Proves the token is scoped to the session's room, to the
 * caller's identity, and to the call clock — and that non-participants and
 * dead sessions get nothing.
 */
import { test, describe, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fftModule from 'firebase-functions-test';

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error(
    'FIRESTORE_EMULATOR_HOST is not set. Run via `npm test` (firebase emulators:exec) — never against a live project.'
  );
}

const PROJECT_ID = 'moomo-functions-test-media';
process.env.GCLOUD_PROJECT = PROJECT_ID;
// Test-only LiveKit credentials, resolved by defineString/defineSecret the
// same way emulator env vars are in real local runs.
process.env.LIVEKIT_URL = 'wss://test.livekit.example';
process.env.LIVEKIT_API_KEY = 'test-api-key';
process.env.LIVEKIT_API_SECRET = 'test-api-secret-test-api-secret!';

const fftFactory = fftModule.default ?? fftModule;
const fft = fftFactory({ projectId: PROJECT_ID });

const functions = await import('../lib/index.js');
const { getFirestore, Timestamp } = await import('firebase-admin/firestore');

const db = getFirestore();
const getCallMediaToken = fft.wrap(functions.getCallMediaToken);

const ALICE = 'alice-uid';
const BOB = 'bob-uid';
const CHARLIE = 'charlie-uid';

const asUser = (uid, data) => ({ data, auth: { uid, token: {} } });

function decodeJwtPayload(jwt) {
  const [, payload] = jwt.split('.');
  return JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
}

async function clearFirestore() {
  const res = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`,
    { method: 'DELETE' }
  );
  assert.equal(res.status, 200);
}

async function seedSession(id, { status = 'active', startedAgoSeconds = 30 } = {}) {
  await db.doc(`callSessions/${id}`).set({
    participantIds: [ALICE, BOB],
    participants: {
      [ALICE]: { uid: ALICE, displayName: 'Alice', age: 28, city: null, gender: null, photoPath: null },
      [BOB]: { uid: BOB, displayName: 'Bob', age: 30, city: null, gender: null, photoPath: null },
    },
    mode: 'video',
    status,
    startedAt: Timestamp.fromMillis(Date.now() - startedAgoSeconds * 1000),
    maxDurationSeconds: 180,
  });
}

describe('getCallMediaToken', () => {
  beforeEach(clearFirestore);

  test('a participant of a live session gets a token scoped to that room and identity', async () => {
    await seedSession('s1');

    const result = await getCallMediaToken(asUser(ALICE, { sessionId: 's1' }));

    assert.equal(result.url, 'wss://test.livekit.example');
    assert.equal(result.roomName, 's1');

    const payload = decodeJwtPayload(result.token);
    assert.equal(payload.sub, ALICE, 'token identity must be the caller');
    assert.equal(payload.video.room, 's1', 'token must be scoped to the session room');
    assert.equal(payload.video.roomJoin, true);
    assert.equal(payload.video.canPublish, true);
    assert.equal(payload.video.canSubscribe, true);
    assert.equal(payload.video.canPublishData, false, 'no unmoderated data channel');

    // Clock-bound: 180s max − 30s elapsed + 90s grace = 240s; allow slack.
    const lifetime = payload.exp - Math.floor(Date.now() / 1000);
    assert.ok(lifetime > 0 && lifetime <= 245, `token lifetime ${lifetime}s must track the call clock`);
  });

  test('a non-participant is told the session does not exist', async () => {
    await seedSession('s1');
    await assert.rejects(
      getCallMediaToken(asUser(CHARLIE, { sessionId: 's1' })),
      /No such call/
    );
  });

  test('an ended session mints no token — and is marked ended, not misconfigured', async () => {
    await seedSession('s1', { status: 'ended' });
    await assert.rejects(getCallMediaToken(asUser(ALICE, { sessionId: 's1' })), (err) => {
      assert.match(err.message, /has ended/);
      assert.equal(
        err.details?.reason,
        'call-ended',
        'the marker the client uses to tell "call over" apart from "media not configured"'
      );
      return true;
    });
  });

  test('a session past its clock mints no token even if still marked active', async () => {
    await seedSession('s1', { startedAgoSeconds: 200 });
    await assert.rejects(getCallMediaToken(asUser(ALICE, { sessionId: 's1' })), (err) => {
      assert.match(err.message, /has ended/);
      assert.equal(err.details?.reason, 'call-ended');
      return true;
    });
  });

  test('an unauthenticated call is refused', async () => {
    await seedSession('s1');
    await assert.rejects(
      getCallMediaToken({ data: { sessionId: 's1' } }),
      /Sign in first/
    );
  });
});
