/**
 * Storage rules tests — emulator only.
 *
 * These run against `backend/storage.rules` in the Storage emulator under a
 * throwaway project id. They never touch moomo-c7a37, and must stay that way.
 *
 * The one behaviour worth spelling out: profile photos are readable by any
 * signed-in account, because Discover, Matches, Chat, and Calls all render
 * other people's photos. They are never public — an unauthenticated request
 * with a leaked path still gets nothing.
 */
import { readFileSync } from 'node:fs';
import { test, before, after, describe } from 'node:test';

import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';

import { ref, uploadBytes, getBytes, deleteObject } from 'firebase/storage';

const ALICE = 'alice-uid';
const BOB = 'bob-uid';

/** Enough of a JPEG for the emulator; rules only check size and contentType. */
const JPEG_BYTES = new Uint8Array([0xff, 0xd8, 0xff, 0xe0]);

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'moomo-storage-rules-test',
    storage: {
      rules: readFileSync(new URL('../storage.rules', import.meta.url), 'utf8'),
    },
  });

  // Alice's existing photo, seeded past the rules, for the read tests.
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await uploadBytes(
      ref(ctx.storage(), `users/${ALICE}/photos/main.jpg`),
      JPEG_BYTES,
      { contentType: 'image/jpeg' }
    );
  });
});

after(async () => {
  await testEnv?.cleanup();
});

/** A signed-in context for `uid`. */
const as = (uid) => testEnv.authenticatedContext(uid).storage();
/** A signed-out context. */
const anon = () => testEnv.unauthenticatedContext().storage();

describe('profile photos', () => {
  test('another signed-in user can read a profile photo', async () => {
    await assertSucceeds(getBytes(ref(as(BOB), `users/${ALICE}/photos/main.jpg`)));
  });

  test('the owner can read their own photo', async () => {
    await assertSucceeds(getBytes(ref(as(ALICE), `users/${ALICE}/photos/main.jpg`)));
  });

  test('signed-out reads are refused — a leaked path is not access', async () => {
    await assertFails(getBytes(ref(anon(), `users/${ALICE}/photos/main.jpg`)));
  });

  test('the owner can upload a jpeg', async () => {
    await assertSucceeds(
      uploadBytes(ref(as(ALICE), `users/${ALICE}/photos/second.jpg`), JPEG_BYTES, {
        contentType: 'image/jpeg',
      })
    );
  });

  test('nobody can write into someone else\'s photos', async () => {
    await assertFails(
      uploadBytes(ref(as(BOB), `users/${ALICE}/photos/planted.jpg`), JPEG_BYTES, {
        contentType: 'image/jpeg',
      })
    );
  });

  test('nobody can delete someone else\'s photo', async () => {
    await assertFails(deleteObject(ref(as(BOB), `users/${ALICE}/photos/main.jpg`)));
  });

  test('a non-image content type is refused even for the owner', async () => {
    await assertFails(
      uploadBytes(ref(as(ALICE), `users/${ALICE}/photos/evil.jpg`), JPEG_BYTES, {
        contentType: 'application/octet-stream',
      })
    );
  });

  test('paths outside users/{uid}/photos are refused', async () => {
    await assertFails(
      uploadBytes(ref(as(ALICE), `misc/${ALICE}/file.jpg`), JPEG_BYTES, {
        contentType: 'image/jpeg',
      })
    );
  });
});
