/**
 * Firestore rules tests — emulator only.
 *
 * These run against `backend/firestore.rules` in the Firestore emulator under a
 * throwaway project id. They never touch moomo-c7a37, and must stay that way:
 * a rules test that needs a live project is a rules test nobody will run.
 *
 * The writes here mirror what `FirestoreProfileStore` actually sends. Where a
 * test asserts a denial, it is asserting a real attack or a real client bug —
 * not an invented one.
 */
import { readFileSync } from 'node:fs';
import { test, before, after, beforeEach, describe } from 'node:test';
import assert from 'node:assert/strict';

import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';

import {
  doc,
  getDoc,
  setDoc,
  updateDoc,
  deleteDoc,
  collection,
  getDocs,
  query,
  where,
  limit,
  serverTimestamp,
  Timestamp,
} from 'firebase/firestore';

const ALICE = 'alice-uid';
const BOB = 'bob-uid';

// Must match `ConsentRecord.currentVersion` in the app and
// `isCurrentConsentVersion` in firestore.rules.
const CURRENT_CONSENT_VERSION = '2026-07-15';

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'moomo-rules-test',
    firestore: {
      rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'),
    },
  });
});

after(async () => {
  await testEnv?.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
});

/** A signed-in context for `uid`. */
const as = (uid) => testEnv.authenticatedContext(uid).firestore();
/** A signed-out context. */
const anon = () => testEnv.unauthenticatedContext().firestore();

/** Seed a document bypassing rules, for read/update tests. */
async function seedUser(uid, extra = {}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'users', uid), {
      uid,
      authProvider: 'guest',
      displayName: '',
      createdAt: Timestamp.fromDate(new Date('2026-01-01')),
      updatedAt: Timestamp.fromDate(new Date('2026-01-01')),
      ...extra,
    });
  });
}

// The exact document FirebaseProfileStore.bootstrap() writes on first sight.
const bootstrapDoc = (uid) => ({
  uid,
  authProvider: 'guest',
  displayName: '',
  createdAt: serverTimestamp(),
  updatedAt: serverTimestamp(),
});

describe('users/{uid} — the bootstrap path the app actually runs', () => {
  test('an authenticated user can CREATE their own document', async () => {
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'users', ALICE), bootstrapDoc(ALICE))
    );
  });

  test('an authenticated user can READ their own document back', async () => {
    await seedUser(ALICE);
    const snap = await assertSucceeds(getDoc(doc(as(ALICE), 'users', ALICE)));
    assert.equal(snap.data().uid, ALICE);
  });

  test('create + read back in one session (the real bootstrap sequence)', async () => {
    const db = as(ALICE);
    await assertSucceeds(setDoc(doc(db, 'users', ALICE), bootstrapDoc(ALICE)));
    const snap = await assertSucceeds(getDoc(doc(db, 'users', ALICE)));
    assert.equal(snap.exists(), true);
    assert.equal(snap.data().authProvider, 'guest');
  });

  test('consent fields are accepted on create when the version is current', async () => {
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'users', ALICE), {
        ...bootstrapDoc(ALICE),
        consentAcceptedAt: Timestamp.now(),
        consentDocumentVersion: CURRENT_CONSENT_VERSION,
      })
    );
  });

  test('a stale or fabricated consent version is rejected on create', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE), {
        ...bootstrapDoc(ALICE),
        consentAcceptedAt: Timestamp.now(),
        consentDocumentVersion: '2020-01-01',
      })
    );
  });
});

describe('users/{uid} — the 18+ backstop', () => {
  const dobYearsAgo = (years) => {
    const d = new Date();
    d.setFullYear(d.getFullYear() - years);
    return Timestamp.fromDate(d);
  };

  test('an adult date of birth is accepted on create', async () => {
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'users', ALICE), {
        ...bootstrapDoc(ALICE),
        dateOfBirth: dobYearsAgo(25),
      })
    );
  });

  test('an underage date of birth is rejected on create', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE), {
        ...bootstrapDoc(ALICE),
        dateOfBirth: dobYearsAgo(16),
      })
    );
  });

  test('an underage date of birth is rejected on update', async () => {
    await seedUser(ALICE);
    await assertFails(
      updateDoc(doc(as(ALICE), 'users', ALICE), {
        dateOfBirth: dobYearsAgo(15),
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('a non-timestamp date of birth is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE), {
        ...bootstrapDoc(ALICE),
        dateOfBirth: '1995-05-05',
      })
    );
  });
});

describe('users/{uid} — consent version transitions', () => {
  test('a profile write may leave a stored older consent untouched', async () => {
    // Routine writes (bootstrap patches, profile saves) merge over the stored
    // consent; an account holding an older version must not be soft-locked.
    await seedUser(ALICE, { consentDocumentVersion: '2026-01-01' });
    await assertSucceeds(
      updateDoc(doc(as(ALICE), 'users', ALICE), {
        displayName: 'Alice',
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('re-consent to the current version is allowed', async () => {
    await seedUser(ALICE, { consentDocumentVersion: '2026-01-01' });
    await assertSucceeds(
      updateDoc(doc(as(ALICE), 'users', ALICE), {
        consentAcceptedAt: serverTimestamp(),
        consentDocumentVersion: CURRENT_CONSENT_VERSION,
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('changing consent to a fabricated version is rejected', async () => {
    await seedUser(ALICE, { consentDocumentVersion: CURRENT_CONSENT_VERSION });
    await assertFails(
      updateDoc(doc(as(ALICE), 'users', ALICE), {
        consentDocumentVersion: '2030-01-01',
        updatedAt: serverTimestamp(),
      })
    );
  });
});

describe('users/{uid} — another user is locked out', () => {
  test('cannot READ another user private document', async () => {
    await seedUser(BOB, { dateOfBirth: Timestamp.fromDate(new Date('1995-05-05')) });
    await assertFails(getDoc(doc(as(ALICE), 'users', BOB)));
  });

  test('cannot LIST the users collection', async () => {
    await seedUser(ALICE);
    await seedUser(BOB);
    await assertFails(getDocs(collection(as(ALICE), 'users')));
  });

  test('cannot CREATE a document under another uid', async () => {
    await assertFails(setDoc(doc(as(ALICE), 'users', BOB), bootstrapDoc(BOB)));
  });

  test('cannot UPDATE another user document', async () => {
    await seedUser(BOB);
    await assertFails(
      updateDoc(doc(as(ALICE), 'users', BOB), {
        displayName: 'hacked',
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('cannot read another user private onboarding draft', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'users', BOB, 'private', 'onboarding'), {
        step: 3,
      });
    });
    await assertFails(getDoc(doc(as(ALICE), 'users', BOB, 'private', 'onboarding')));
  });

  test('a signed-out client can do nothing', async () => {
    await seedUser(ALICE);
    await assertFails(getDoc(doc(anon(), 'users', ALICE)));
    await assertFails(setDoc(doc(anon(), 'users', ALICE), bootstrapDoc(ALICE)));
  });
});

describe('users/{uid} — server-owned fields cannot be forged', () => {
  test('a client-chosen createdAt is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE), {
        ...bootstrapDoc(ALICE),
        createdAt: Timestamp.fromDate(new Date('1999-01-01')),
      })
    );
  });

  test('a client-chosen updatedAt is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE), {
        ...bootstrapDoc(ALICE),
        updatedAt: Timestamp.fromDate(new Date('1999-01-01')),
      })
    );
  });

  test('self-granting isVerified is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE), {
        ...bootstrapDoc(ALICE),
        isVerified: true,
      })
    );
  });

  test('self-granting isPremium is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE), {
        ...bootstrapDoc(ALICE),
        isPremium: true,
      })
    );
  });

  test('a uid field disagreeing with the document id is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE), { ...bootstrapDoc(ALICE), uid: BOB })
    );
  });

  test('createdAt cannot be rewritten by an update', async () => {
    await seedUser(ALICE);
    await assertFails(
      updateDoc(doc(as(ALICE), 'users', ALICE), {
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

});

describe('account deletion — deleteAccount callable only, never the client', () => {
  test('even the owner cannot delete their user document directly', async () => {
    await seedUser(ALICE);
    await assertFails(deleteDoc(doc(as(ALICE), 'users', ALICE)));
  });

  test('the owner can still delete their onboarding draft (routine, not deletion)', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'users', ALICE, 'private', 'onboarding'), {
        step: 3,
      });
    });
    await assertSucceeds(
      deleteDoc(doc(as(ALICE), 'users', ALICE, 'private', 'onboarding'))
    );
  });

  test('even the owner cannot delete their public profile directly', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'publicProfiles', ALICE), { uid: ALICE });
    });
    await assertFails(deleteDoc(doc(as(ALICE), 'publicProfiles', ALICE)));
  });

  test('another user cannot delete someone else’s documents', async () => {
    await seedUser(BOB);
    await assertFails(deleteDoc(doc(as(ALICE), 'users', BOB)));
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'publicProfiles', BOB), { uid: BOB });
    });
    await assertFails(deleteDoc(doc(as(ALICE), 'publicProfiles', BOB)));
  });

  test('a signed-out client cannot delete anything', async () => {
    await seedUser(ALICE);
    await assertFails(deleteDoc(doc(anon(), 'users', ALICE)));
  });
});

describe('users/{uid}/private — only the two documented documents', () => {
  test('an arbitrary private document is rejected even for the owner', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE, 'private', 'stash'), { x: 1 })
    );
  });
});

// ---------------------------------------------------------------------------
// users/{uid}/private/location — the coarse position that ranks Discover,
// matchmaking and the ring fan-out by distance.
//
// Two properties are being defended, and they are the whole privacy story of
// the proximity feature:
//
//   1. NOBODY BUT THE OWNER CAN READ IT. Not another signed-in user, not
//      someone who has called them, not an anonymous client. This is why the
//      document lives here instead of on publicProfiles, where `get` is open
//      to any signed-in user who knows a uid.
//   2. IT CANNOT HOLD A PRECISE POSITION. The client is the thing trusted to
//      coarsen, so the rules re-check the grid: a tampered build that uploads
//      GPS-exact coordinates into its OWN private document is refused.
// ---------------------------------------------------------------------------
describe('users/{uid}/private/location — coarse, owner-only', () => {
  /** A position snapped to the 0.01° (~1.11 km) grid, as the app sends it. */
  const coarse = (lat, lng) => ({ lat, lng, updatedAt: serverTimestamp() });

  async function seedLocation(uid, data) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'users', uid, 'private', 'location'), {
        lat: 41.88,
        lng: -87.63,
        updatedAt: Timestamp.now(),
        ...data,
      });
    });
  }

  test('the owner can write and read back their own coarse location', async () => {
    const ref = doc(as(ALICE), 'users', ALICE, 'private', 'location');
    await assertSucceeds(setDoc(ref, coarse(41.88, -87.63)));
    const snap = await assertSucceeds(getDoc(ref));
    assert.equal(snap.data().lat, 41.88);
    assert.equal(snap.data().lng, -87.63);
  });

  test('NO other signed-in user can read it — this is the trilateration guard', async () => {
    await seedLocation(BOB);
    await assertFails(getDoc(doc(as(ALICE), 'users', BOB, 'private', 'location')));
  });

  test('an anonymous client cannot read it', async () => {
    await seedLocation(BOB);
    await assertFails(getDoc(doc(anon(), 'users', BOB, 'private', 'location')));
  });

  test('nobody can write into another user location document', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', BOB, 'private', 'location'), coarse(41.88, -87.63))
    );
  });

  test('a precise latitude is refused — the grid is enforced server-side', async () => {
    await assertFails(
      setDoc(
        doc(as(ALICE), 'users', ALICE, 'private', 'location'),
        coarse(41.8781136, -87.6297982)
      )
    );
  });

  test('a longitude one tenth of a cell off-grid is refused', async () => {
    // 0.001° ≈ 111 m — inside a cell, so it carries finer information than
    // the grid promises, and must not be storable.
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE, 'private', 'location'), coarse(41.88, -87.631))
    );
  });

  test('an out-of-range coordinate is refused', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE, 'private', 'location'), coarse(91.0, 0))
    );
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE, 'private', 'location'), coarse(0, 181.0))
    );
  });

  test('a non-numeric coordinate is refused', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE, 'private', 'location'), {
        lat: '41.88',
        lng: -87.63,
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('extra fields are refused — the document is exactly three keys', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE, 'private', 'location'), {
        ...coarse(41.88, -87.63),
        accuracy: 5,
      })
    );
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE, 'private', 'location'), {
        lat: 41.88,
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('a client-claimed timestamp is refused — staleness must be the server clock', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE, 'private', 'location'), {
        lat: 41.88,
        lng: -87.63,
        // A backdated or postdated stamp would let a stale position keep
        // ranking past LOCATION_MAX_AGE_MS.
        updatedAt: Timestamp.fromDate(new Date('2030-01-01')),
      })
    );
  });

  test('the owner can delete it — turning sharing off is always available', async () => {
    await seedLocation(ALICE);
    await assertSucceeds(
      deleteDoc(doc(as(ALICE), 'users', ALICE, 'private', 'location'))
    );
  });

  test('nobody can delete another user location', async () => {
    await seedLocation(BOB);
    await assertFails(deleteDoc(doc(as(ALICE), 'users', BOB, 'private', 'location')));
  });

  test('the grid boundary values 0 and the poles are writable', async () => {
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'users', ALICE, 'private', 'location'), coarse(0, 0))
    );
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'users', ALICE, 'private', 'location'), coarse(-90, 180))
    );
  });
});

describe('users/{uid} — onboarding write and restore', () => {
  test('the owner can write and read back their onboarding draft', async () => {
    const db = as(ALICE);
    const ref = doc(db, 'users', ALICE, 'private', 'onboarding');
    await assertSucceeds(setDoc(ref, { step: 2, displayName: 'Alice' }));
    const snap = await assertSucceeds(getDoc(ref));
    assert.equal(snap.data().step, 2);
    assert.equal(snap.data().displayName, 'Alice');
  });

  test('the owner can update profile fields with a server updatedAt', async () => {
    await seedUser(ALICE);
    await assertSucceeds(
      updateDoc(doc(as(ALICE), 'users', ALICE), {
        displayName: 'Alice',
        bio: 'hello',
        interests: ['hiking'],
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('an update without a server updatedAt is rejected', async () => {
    await seedUser(ALICE);
    await assertFails(
      updateDoc(doc(as(ALICE), 'users', ALICE), { displayName: 'Alice' })
    );
  });

  test('marking onboarding complete is allowed for the owner', async () => {
    await seedUser(ALICE);
    await assertSucceeds(
      updateDoc(doc(as(ALICE), 'users', ALICE), {
        onboardingCompletedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });
});

describe('publicProfiles/{uid} — readable by signed-in users, owner-written', () => {
  test('the owner can write their own public projection', async () => {
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        uid: ALICE,
        displayName: 'Alice',
        age: 30,
        city: 'Austin',
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('another signed-in user CAN still read a single profile — a matched partner\'s card', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'publicProfiles', BOB), {
        uid: BOB,
        displayName: 'Bob',
      });
    });
    await assertSucceeds(getDoc(doc(as(ALICE), 'publicProfiles', BOB)));
  });

  // -- The anti-scrape redesign (audit P0-3): NO client list, at any size. --
  // Browsing goes through the getDiscoveryFeed callable (Admin SDK), which
  // is bounded, block-filtered, rate-limited, and cursor-free. An
  // authenticated script must not be able to page the base at all.

  test('a signed-in user cannot list the collection even in app-sized pages', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'publicProfiles', BOB), { uid: BOB });
    });
    await assertFails(
      getDocs(query(collection(as(ALICE), 'publicProfiles'), limit(25)))
    );
    await assertFails(
      getDocs(query(collection(as(ALICE), 'publicProfiles'), limit(1)))
    );
  });

  test('an unbounded list is denied', async () => {
    await assertFails(getDocs(collection(as(ALICE), 'publicProfiles')));
  });

  test('a large page is denied', async () => {
    await assertFails(
      getDocs(query(collection(as(ALICE), 'publicProfiles'), limit(500)))
    );
  });

  test('a signed-out client cannot read or list public profiles', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'publicProfiles', BOB), { uid: BOB });
    });
    await assertFails(getDoc(doc(anon(), 'publicProfiles', BOB)));
    await assertFails(getDocs(collection(anon(), 'publicProfiles')));
  });

  test('the owner can heartbeat lastActiveAt (presence)', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'publicProfiles', ALICE), {
        uid: ALICE,
        displayName: 'Alice',
      });
    });
    await assertSucceeds(
      updateDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        lastActiveAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('a client cannot flag itself wantsToTalk — only the queue callable may', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        uid: ALICE,
        displayName: 'Alice',
        wantsToTalk: true,
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('a client cannot grant itself boostedUntil', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'publicProfiles', ALICE), {
        uid: ALICE,
        displayName: 'Alice',
      });
    });
    await assertFails(
      updateDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        boostedUntil: Timestamp.fromDate(new Date('2030-01-01')),
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('an ordinary profile write leaves a server-set wantsToTalk untouched and succeeds', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'publicProfiles', ALICE), {
        uid: ALICE,
        displayName: 'Alice',
        wantsToTalk: true,
      });
    });
    await assertSucceeds(
      updateDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        displayName: 'Alice B.',
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('a public profile carrying dateOfBirth is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        uid: ALICE,
        displayName: 'Alice',
        dateOfBirth: Timestamp.fromDate(new Date('1995-05-05')),
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('a public profile carrying precise coordinates is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        uid: ALICE,
        displayName: 'Alice',
        latitude: 30.26,
        longitude: -97.74,
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('a public profile carrying consent is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        uid: ALICE,
        consent: { version: '1' },
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('cannot write another user public profile', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', BOB), {
        uid: BOB,
        displayName: 'not bob',
        updatedAt: serverTimestamp(),
      })
    );
  });

  // -- Schema hardening --

  /** The full projection FirestoreProfileStore.update() writes. */
  const fullProjection = (uid) => ({
    uid,
    displayName: 'Alice',
    age: 30,
    city: 'Austin',
    gender: 'woman',
    interestedIn: ['everyone'],
    datingIntention: 'longTerm',
    photoPaths: [`users/${uid}/photos/p1.jpg`, `users/${uid}/photos/p2.jpg`],
    updatedAt: serverTimestamp(),
  });

  test('the exact projection the app writes is accepted', async () => {
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), fullProjection(ALICE))
    );
  });

  test('a field outside the public schema is rejected — whitelist, not blacklist', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        ...fullProjection(ALICE),
        secretRating: 11,
      })
    );
  });

  test('a uid field disagreeing with the document id is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        ...fullProjection(ALICE),
        uid: BOB,
      })
    );
  });

  test('an underage or absurd public age is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        ...fullProjection(ALICE),
        age: 17,
      })
    );
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        ...fullProjection(ALICE),
        age: 121,
      })
    );
  });

  test('an unknown gender value is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        ...fullProjection(ALICE),
        gender: 'attack-helicopter',
      })
    );
  });

  test('interestedIn outside the catalog is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        ...fullProjection(ALICE),
        interestedIn: ['women', 'robots'],
      })
    );
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        ...fullProjection(ALICE),
        interestedIn: [],
      })
    );
  });

  test('datingIntention outside the catalog is rejected', async () => {
    // This field decides who the queue will pair someone with, so an
    // unrecognised value is a matching bug, not a cosmetic one.
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        ...fullProjection(ALICE),
        datingIntention: 'marriageWithinTheWeek',
      })
    );
  });

  test('every catalog datingIntention is accepted', async () => {
    for (const intention of [
      'lifePartner',
      'longTerm',
      'longTermOpenToShort',
      'shortTermOpenToLong',
      'shortTerm',
      'figuringItOut',
    ]) {
      await assertSucceeds(
        setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
          ...fullProjection(ALICE),
          datingIntention: intention,
        })
      );
    }
  });

  test('a projection with no datingIntention is still accepted', async () => {
    // Accounts from before intentions existed must keep saving.
    const { datingIntention, ...withoutIntention } = fullProjection(ALICE);
    void datingIntention;
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), withoutIntention)
    );
  });

  test("a photo path pointing into ANOTHER user's folder is rejected", async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        ...fullProjection(ALICE),
        photoPaths: [`users/${BOB}/photos/stolen.jpg`],
      })
    );
  });

  test('more than six photo paths is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        ...fullProjection(ALICE),
        photoPaths: Array.from({ length: 7 }, (_, i) => `users/${ALICE}/photos/p${i}.jpg`),
      })
    );
  });

  test('a fabricated lastActiveAt is rejected — presence may only say now', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        ...fullProjection(ALICE),
        lastActiveAt: Timestamp.fromDate(new Date('2030-01-01')),
      })
    );
  });

  test('a forged isVerified badge is rejected by the schema whitelist', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        ...fullProjection(ALICE),
        isVerified: true,
      })
    );
  });

  test('the presence heartbeat CREATE (first Discover load, no profile yet) is accepted', async () => {
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        uid: ALICE,
        lastActiveAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  // -- activityBucket: the feed's coarse ordering stamp (audit P1-1). --
  // The heartbeat quantizes lastActiveAt to a 10-minute bucket so the
  // ordering index isn't a monotonic hotspot. Honesty rules mirror
  // presenceIsHonest: aligned, and within clock-skew distance of now.

  const BUCKET_MS = 10 * 60 * 1000;
  /** The bucket a truthful client computes right now (floor of now). */
  const currentBucket = () =>
    Timestamp.fromMillis(Math.floor(Date.now() / BUCKET_MS) * BUCKET_MS);

  const heartbeat = (bucket) => ({
    uid: ALICE,
    lastActiveAt: serverTimestamp(),
    activityBucket: bucket,
    updatedAt: serverTimestamp(),
  });

  test('the throttled heartbeat with a truthful activityBucket is accepted', async () => {
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), heartbeat(currentBucket()))
    );
  });

  test('the full projection may carry a truthful activityBucket', async () => {
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), {
        ...fullProjection(ALICE),
        activityBucket: currentBucket(),
      })
    );
  });

  test('the heartbeat UPDATE over an existing full projection is accepted — the exact write Discover sends', async () => {
    // What production actually looks like: a complete profile with
    // server-set flags already present, receiving the throttled heartbeat
    // merge (uid + lastActiveAt + activityBucket + updatedAt). If this is
    // ever denied, Discover's presence write silently dies — it must stay
    // provably legal alongside the anti-scrape rules.
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'publicProfiles', ALICE), {
        uid: ALICE,
        displayName: 'Alice',
        age: 30,
        city: 'Austin',
        gender: 'woman',
        interestedIn: ['everyone'],
        photoPaths: [`users/${ALICE}/photos/p1.jpg`],
        lastActiveAt: Timestamp.fromMillis(Date.now() - 60 * 60 * 1000),
        wantsToTalk: true,
        boostedUntil: Timestamp.fromMillis(Date.now() + 60_000),
        updatedAt: Timestamp.now(),
      });
    });
    await assertSucceeds(
      setDoc(
        doc(as(ALICE), 'publicProfiles', ALICE),
        {
          uid: ALICE,
          lastActiveAt: serverTimestamp(),
          activityBucket: currentBucket(),
          updatedAt: serverTimestamp(),
        },
        { merge: true }
      )
    );
  });

  test('an unaligned activityBucket is rejected — quantization is the hotspot fix', async () => {
    await assertFails(
      setDoc(
        doc(as(ALICE), 'publicProfiles', ALICE),
        heartbeat(Timestamp.fromMillis(Math.floor(Date.now() / BUCKET_MS) * BUCKET_MS + 1234))
      )
    );
  });

  test('a future activityBucket is rejected — nobody sits atop Discover from tomorrow', async () => {
    await assertFails(
      setDoc(
        doc(as(ALICE), 'publicProfiles', ALICE),
        heartbeat(Timestamp.fromMillis((Math.floor(Date.now() / BUCKET_MS) + 2) * BUCKET_MS))
      )
    );
  });

  test('an ancient activityBucket is rejected — idle clients cannot replay activity', async () => {
    await assertFails(
      setDoc(
        doc(as(ALICE), 'publicProfiles', ALICE),
        heartbeat(Timestamp.fromMillis((Math.floor(Date.now() / BUCKET_MS) - 3) * BUCKET_MS))
      )
    );
  });

  test('a non-timestamp activityBucket is rejected', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'publicProfiles', ALICE), heartbeat(1721500000000))
    );
  });
});

describe('rateLimits and config — operational collections stay server-only', () => {
  test('a user cannot read or reset their own rate-limit counter', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'rateLimits', `${ALICE}_joinMatchmakingQueue`), {
        uid: ALICE,
        action: 'joinMatchmakingQueue',
        windowStartMillis: Date.now(),
        count: 12,
      });
    });
    const ref = doc(as(ALICE), 'rateLimits', `${ALICE}_joinMatchmakingQueue`);
    await assertFails(getDoc(ref));
    await assertFails(setDoc(ref, { count: 0 }));
    await assertFails(deleteDoc(ref));
    await assertFails(getDocs(collection(as(ALICE), 'rateLimits')));
  });

  test('the kill-switch document is not client-readable or client-writable', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'config', 'runtime'), { maintenanceMode: false });
    });
    await assertFails(getDoc(doc(as(ALICE), 'config', 'runtime')));
    await assertFails(
      setDoc(doc(as(ALICE), 'config', 'runtime'), { maintenanceMode: false })
    );
    await assertFails(getDoc(doc(anon(), 'config', 'runtime')));
  });
});

describe('everything else fails closed', () => {
  test('a top-level messages collection is denied (threads live under conversations)', async () => {
    await assertFails(setDoc(doc(as(ALICE), 'messages', 'm1'), { text: 'hi' }));
  });

  test('an arbitrary new collection is denied', async () => {
    await assertFails(setDoc(doc(as(ALICE), 'whatever', 'x'), { a: 1 }));
  });
});

// ---------------------------------------------------------------------------
// MVP social collections. The client still runs these domains on local mocks;
// the rules land first so the backend can never ship more open than intended.
// Every seed below stands in for what the *server* (Admin SDK) will write.
// ---------------------------------------------------------------------------

const CHARLIE = 'charlie-uid';

async function seedMatch(id, participantIds) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'matches', id), {
      participantIds,
      conversationId: `conv-${id}`,
      createdAt: Timestamp.now(),
    });
  });
}

async function seedConversation(id, participantIds) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'conversations', id), {
      participantIds,
      matchId: `match-${id}`,
      createdAt: Timestamp.now(),
    });
  });
}

async function seedCallSession(id, participantIds) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'callSessions', id), {
      participantIds,
      mode: 'voice',
      startedAt: Timestamp.now(),
    });
  });
}

describe('matches — participant-read-only, server-owned', () => {
  test('a participant can read their match', async () => {
    await seedMatch('m1', [ALICE, BOB]);
    await assertSucceeds(getDoc(doc(as(ALICE), 'matches', 'm1')));
  });

  test('a non-participant cannot read someone else\'s match', async () => {
    await seedMatch('m1', [ALICE, BOB]);
    await assertFails(getDoc(doc(as(CHARLIE), 'matches', 'm1')));
  });

  test('a signed-out user cannot read any match', async () => {
    await seedMatch('m1', [ALICE, BOB]);
    await assertFails(getDoc(doc(anon(), 'matches', 'm1')));
  });

  test('a list constrained to the caller succeeds', async () => {
    await seedMatch('m1', [ALICE, BOB]);
    await assertSucceeds(getDocs(query(
      collection(as(ALICE), 'matches'),
      where('participantIds', 'array-contains', ALICE)
    )));
  });

  test('an unconstrained list is denied', async () => {
    await seedMatch('m1', [ALICE, BOB]);
    await assertFails(getDocs(collection(as(ALICE), 'matches')));
  });

  test('a client cannot mint a match — mutual like is server-owned', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'matches', 'forged'), {
        participantIds: [ALICE, BOB],
        conversationId: 'conv-forged',
        createdAt: serverTimestamp(),
      })
    );
  });

  test('a client cannot delete a match', async () => {
    await seedMatch('m1', [ALICE, BOB]);
    await assertFails(deleteDoc(doc(as(ALICE), 'matches', 'm1')));
  });
});

describe('callSessions — participant-read-only, server-owned', () => {
  test('a participant can read their session', async () => {
    await seedCallSession('s1', [ALICE, BOB]);
    await assertSucceeds(getDoc(doc(as(BOB), 'callSessions', 's1')));
  });

  test('a non-participant cannot read it', async () => {
    await seedCallSession('s1', [ALICE, BOB]);
    await assertFails(getDoc(doc(as(CHARLIE), 'callSessions', 's1')));
  });

  test('a client cannot create call state — a tampered client must not forge calls', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'callSessions', 'forged'), {
        participantIds: [ALICE, BOB],
        mode: 'voice',
        startedAt: serverTimestamp(),
      })
    );
  });

  test('a participant cannot update their session (no timer extension)', async () => {
    await seedCallSession('s1', [ALICE, BOB]);
    await assertFails(
      updateDoc(doc(as(ALICE), 'callSessions', 's1'), { mode: 'video' })
    );
  });
});

describe('conversations and messages', () => {
  const message = () => ({
    senderId: ALICE,
    text: 'hey!',
    sentAt: serverTimestamp(),
  });

  test('a participant can read their conversation', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertSucceeds(getDoc(doc(as(ALICE), 'conversations', 'c1')));
  });

  test('a non-participant cannot read it', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertFails(getDoc(doc(as(CHARLIE), 'conversations', 'c1')));
  });

  test('a client cannot create a conversation', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'conversations', 'forged'), {
        participantIds: [ALICE, BOB],
        matchId: 'm1',
        createdAt: serverTimestamp(),
      })
    );
  });

  test('a participant can send a message as themselves', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'conversations', 'c1', 'messages', 'msg1'), message())
    );
  });

  test('a participant can read the thread', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertSucceeds(
      getDocs(collection(as(BOB), 'conversations', 'c1', 'messages'))
    );
  });

  test('a non-participant cannot read the thread', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertFails(
      getDocs(collection(as(CHARLIE), 'conversations', 'c1', 'messages'))
    );
  });

  test('a non-participant cannot write into the thread', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertFails(
      setDoc(doc(as(CHARLIE), 'conversations', 'c1', 'messages', 'msg1'), {
        ...message(),
        senderId: CHARLIE,
      })
    );
  });

  test('a spoofed senderId is rejected — you may only speak as yourself', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertFails(
      setDoc(doc(as(ALICE), 'conversations', 'c1', 'messages', 'msg1'), {
        ...message(),
        senderId: BOB,
      })
    );
  });

  test('a client-claimed timestamp is rejected', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertFails(
      setDoc(doc(as(ALICE), 'conversations', 'c1', 'messages', 'msg1'), {
        ...message(),
        sentAt: Timestamp.fromDate(new Date('2020-01-01')),
      })
    );
  });

  test('an oversized message is rejected', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertFails(
      setDoc(doc(as(ALICE), 'conversations', 'c1', 'messages', 'msg1'), {
        ...message(),
        text: 'x'.repeat(1001),
      })
    );
  });

  test('smuggled extra fields are rejected', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertFails(
      setDoc(doc(as(ALICE), 'conversations', 'c1', 'messages', 'msg1'), {
        ...message(),
        isRead: true,
      })
    );
  });

  test('messages cannot be edited or deleted from the client', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'conversations', 'c1', 'messages', 'msg1'), message())
    );
    await assertFails(
      updateDoc(doc(as(ALICE), 'conversations', 'c1', 'messages', 'msg1'), { text: 'edited' })
    );
    await assertFails(
      deleteDoc(doc(as(ALICE), 'conversations', 'c1', 'messages', 'msg1'))
    );
  });
});

// ---------------------------------------------------------------------------
// The block/message interaction. blockUser deletes the conversation in the
// same transaction as the block, so normally there is nothing left to write
// into — these tests prove the backstop: even a conversation document that
// SURVIVES a crashed cascade accepts nothing from a blocked pair.
// ---------------------------------------------------------------------------
describe('messages — blocked pairs are silenced even if the conversation survives', () => {
  const messageFrom = (sender) => ({
    senderId: sender,
    text: 'hey!',
    sentAt: serverTimestamp(),
  });

  /** What the blockUser callable (Admin SDK) writes. */
  async function seedBlock(blocker, blocked) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'blocks', blocker, 'blocked', blocked), {
        displayName: 'Someone',
        createdAt: Timestamp.now(),
      });
    });
  }

  test('the blocker cannot message a conversation that outlived the cascade', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await seedBlock(ALICE, BOB);
    await assertFails(
      setDoc(doc(as(ALICE), 'conversations', 'c1', 'messages', 'msg1'), messageFrom(ALICE))
    );
  });

  test('the blocked user cannot message either — a block silences both directions', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await seedBlock(ALICE, BOB);
    await assertFails(
      setDoc(doc(as(BOB), 'conversations', 'c1', 'messages', 'msg1'), messageFrom(BOB))
    );
  });

  test('after an unblock, messaging works again', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await seedBlock(ALICE, BOB);
    await assertSucceeds(deleteDoc(doc(as(ALICE), 'blocks', ALICE, 'blocked', BOB)));
    await assertSucceeds(
      setDoc(doc(as(ALICE), 'conversations', 'c1', 'messages', 'msg1'), messageFrom(ALICE))
    );
  });

  test('a conversation tombstoned by the backend (status != open) refuses messages', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'conversations', 'c1'), {
        participantIds: [ALICE, BOB],
        matchId: 'match-c1',
        createdAt: Timestamp.now(),
        status: 'closed',
      });
    });
    await assertFails(
      setDoc(doc(as(ALICE), 'conversations', 'c1', 'messages', 'msg1'), messageFrom(ALICE))
    );
  });

  test('a message into a nonexistent conversation is denied', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'conversations', 'ghost', 'messages', 'msg1'), messageFrom(ALICE))
    );
  });
});

describe('blocks — the blocker\'s private list, created only by the callable', () => {
  /** What the blockUser callable (Admin SDK) writes. */
  async function seedBlock(blocker, blocked) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'blocks', blocker, 'blocked', blocked), {
        displayName: 'Someone',
        createdAt: Timestamp.now(),
      });
    });
  }

  test('a direct client block-write is refused — blocks must cascade, so only the callable creates them', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'blocks', ALICE, 'blocked', BOB), {
        createdAt: serverTimestamp(),
      })
    );
  });

  test('the owner can list their blocks and unblock', async () => {
    await seedBlock(ALICE, BOB);
    await assertSucceeds(
      getDocs(collection(as(ALICE), 'blocks', ALICE, 'blocked'))
    );
    await assertSucceeds(
      deleteDoc(doc(as(ALICE), 'blocks', ALICE, 'blocked', BOB))
    );
  });

  test('nobody may learn who blocked them', async () => {
    await seedBlock(ALICE, BOB);
    await assertFails(getDoc(doc(as(BOB), 'blocks', ALICE, 'blocked', BOB)));
    await assertFails(getDocs(collection(as(BOB), 'blocks', ALICE, 'blocked')));
  });

  test('a user cannot write into someone else\'s block list', async () => {
    await assertFails(
      setDoc(doc(as(BOB), 'blocks', ALICE, 'blocked', CHARLIE), {
        createdAt: serverTimestamp(),
      })
    );
  });

  test('a user cannot delete someone else\'s block of them', async () => {
    await seedBlock(ALICE, BOB);
    await assertFails(deleteDoc(doc(as(BOB), 'blocks', ALICE, 'blocked', BOB)));
  });
});

describe('reports — entirely server-owned (reportUser callable)', () => {
  test('a direct client report-write is refused — rate limits live in the callable', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'reports', 'r1'), {
        reporterId: ALICE,
        reportedId: BOB,
        reason: 'harassment',
        createdAt: serverTimestamp(),
      })
    );
  });

  test('nobody may read, alter, or delete a report — not even its author', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'reports', 'r1'), {
        reporterId: ALICE,
        reportedId: BOB,
        reason: 'harassment',
        status: 'open',
        createdAt: Timestamp.now(),
      });
    });
    await assertFails(getDoc(doc(as(ALICE), 'reports', 'r1')));
    await assertFails(updateDoc(doc(as(ALICE), 'reports', 'r1'), { status: 'resolved' }));
    await assertFails(deleteDoc(doc(as(ALICE), 'reports', 'r1')));
    await assertFails(getDocs(collection(as(BOB), 'reports')));
  });
});

describe('matchmakingQueue — own entry readable, backend-managed', () => {
  async function seedQueueEntry(uid, extra = {}) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'matchmakingQueue', uid), {
        uid,
        mode: 'voice',
        status: 'waiting',
        createdAt: Timestamp.now(),
        updatedAt: Timestamp.now(),
        ...extra,
      });
    });
  }

  test('a user can read their own queue entry (the pairing listener)', async () => {
    await seedQueueEntry(ALICE, { status: 'matched', sessionId: 's1' });
    const snap = await assertSucceeds(getDoc(doc(as(ALICE), 'matchmakingQueue', ALICE)));
    assert.equal(snap.data().sessionId, 's1');
  });

  test('a user cannot read someone else\'s queue entry', async () => {
    await seedQueueEntry(BOB);
    await assertFails(getDoc(doc(as(ALICE), 'matchmakingQueue', BOB)));
  });

  test('the queue cannot be listed — who is waiting is not public', async () => {
    await seedQueueEntry(BOB);
    await assertFails(getDocs(collection(as(ALICE), 'matchmakingQueue')));
  });

  test('a client cannot enqueue itself directly — pairing is the callable\'s job', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'matchmakingQueue', ALICE), {
        uid: ALICE,
        mode: 'voice',
        status: 'waiting',
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('a client cannot forge a pairing onto its own entry', async () => {
    await seedQueueEntry(ALICE);
    await assertFails(
      updateDoc(doc(as(ALICE), 'matchmakingQueue', ALICE), {
        status: 'matched',
        sessionId: 'forged',
      })
    );
    await assertFails(deleteDoc(doc(as(ALICE), 'matchmakingQueue', ALICE)));
  });
});

describe('callInvites — own ring readable, backend-managed', () => {
  async function seedInvite(uid, extra = {}) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'callInvites', uid), {
        uid,
        callerUid: BOB,
        mode: 'voice',
        status: 'ringing',
        caller: { uid: BOB, displayName: 'Bob', age: 30, city: 'Austin', gender: 'man', photoPath: null, isVerified: false },
        createdAt: Timestamp.now(),
        expiresAt: Timestamp.fromMillis(Date.now() + 10_000),
        updatedAt: Timestamp.now(),
        ...extra,
      });
    });
  }

  test('a user can read their own invite (the banner listener)', async () => {
    await seedInvite(ALICE);
    const snap = await assertSucceeds(getDoc(doc(as(ALICE), 'callInvites', ALICE)));
    assert.equal(snap.data().callerUid, BOB);
  });

  test('a user cannot read someone else\'s invite', async () => {
    await seedInvite(BOB, { callerUid: ALICE });
    await assertFails(getDoc(doc(as(ALICE), 'callInvites', BOB)));
  });

  test('invites cannot be listed — who is being rung is not public', async () => {
    await seedInvite(BOB, { callerUid: ALICE });
    await assertFails(getDocs(collection(as(ALICE), 'callInvites')));
  });

  test('a client cannot ring anyone directly — fan-out is the backend\'s job', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'callInvites', BOB), {
        uid: BOB,
        callerUid: ALICE,
        mode: 'voice',
        status: 'ringing',
        createdAt: serverTimestamp(),
        expiresAt: Timestamp.fromMillis(Date.now() + 10_000),
        updatedAt: serverTimestamp(),
      })
    );
  });

  test('a client cannot forge a response onto its own invite', async () => {
    await seedInvite(ALICE);
    await assertFails(
      updateDoc(doc(as(ALICE), 'callInvites', ALICE), {
        status: 'accepted',
        sessionId: 'forged',
      })
    );
    await assertFails(deleteDoc(doc(as(ALICE), 'callInvites', ALICE)));
  });
});

describe('callSessions/{id}/decisions — closed to both participants', () => {
  test('neither participant may read or write a decision document', async () => {
    await seedCallSession('s1', [ALICE, BOB]);
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'callSessions', 's1', 'decisions', BOB), {
        uid: BOB,
        decision: 'pass',
        decidedAt: Timestamp.now(),
      });
    });
    // "They passed" must be unreadable — likeSent and undecided stay
    // indistinguishable from the client's point of view.
    await assertFails(getDoc(doc(as(ALICE), 'callSessions', 's1', 'decisions', BOB)));
    await assertFails(getDoc(doc(as(BOB), 'callSessions', 's1', 'decisions', BOB)));
    await assertFails(
      setDoc(doc(as(ALICE), 'callSessions', 's1', 'decisions', ALICE), {
        uid: ALICE,
        decision: 'like',
        decidedAt: serverTimestamp(),
      })
    );
    await assertFails(
      getDocs(collection(as(ALICE), 'callSessions', 's1', 'decisions'))
    );
  });
});

describe('conversations — markRead is the only client write', () => {
  async function seedConversationWithCounts(id, participantIds, unreadCounts) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'conversations', id), {
        participantIds,
        matchId: `match-${id}`,
        createdAt: Timestamp.now(),
        lastMessageAt: Timestamp.now(),
        lastMessage: { senderId: BOB, text: 'hey', sentAt: Timestamp.now() },
        unreadCounts,
      });
    });
  }

  test('a participant can zero their own unread counter', async () => {
    await seedConversationWithCounts('c1', [ALICE, BOB], { [ALICE]: 3, [BOB]: 0 });
    await assertSucceeds(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), {
        [`unreadCounts.${ALICE}`]: 0,
      })
    );
  });

  test('a participant cannot touch the other person\'s counter', async () => {
    await seedConversationWithCounts('c1', [ALICE, BOB], { [ALICE]: 3, [BOB]: 2 });
    await assertFails(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), {
        [`unreadCounts.${BOB}`]: 0,
      })
    );
  });

  test('a participant cannot inflate their own counter — only zero it', async () => {
    await seedConversationWithCounts('c1', [ALICE, BOB], { [ALICE]: 3, [BOB]: 0 });
    await assertFails(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), {
        [`unreadCounts.${ALICE}`]: 99,
      })
    );
  });

  test('markRead cannot smuggle other fields along', async () => {
    await seedConversationWithCounts('c1', [ALICE, BOB], { [ALICE]: 3, [BOB]: 0 });
    await assertFails(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), {
        [`unreadCounts.${ALICE}`]: 0,
        lastMessage: { senderId: ALICE, text: 'forged preview', sentAt: Timestamp.now() },
      })
    );
    await assertFails(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), {
        [`unreadCounts.${ALICE}`]: 0,
        participantIds: [ALICE, CHARLIE],
      })
    );
  });

  test('a non-participant cannot mark anything read', async () => {
    await seedConversationWithCounts('c1', [ALICE, BOB], { [ALICE]: 3, [BOB]: 0 });
    await assertFails(
      updateDoc(doc(as(CHARLIE), 'conversations', 'c1'), {
        [`unreadCounts.${CHARLIE}`]: 0,
      })
    );
  });

  test('a participant can list their conversations constrained to themselves', async () => {
    await seedConversationWithCounts('c1', [ALICE, BOB], { [ALICE]: 0, [BOB]: 0 });
    await assertSucceeds(getDocs(query(
      collection(as(ALICE), 'conversations'),
      where('participantIds', 'array-contains', ALICE)
    )));
  });
});

describe('conversations — per-user hiddenBy/metBy flags', () => {
  async function seedConversation(id, participantIds, extra = {}) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'conversations', id), {
        participantIds,
        matchId: `match-${id}`,
        createdAt: Timestamp.now(),
        lastMessageAt: Timestamp.now(),
        unreadCounts: Object.fromEntries(participantIds.map((p) => [p, 0])),
        ...extra,
      });
    });
  }

  test('a participant can hide and unhide for themselves', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertSucceeds(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), { [`hiddenBy.${ALICE}`]: true })
    );
    await assertSucceeds(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), { [`hiddenBy.${ALICE}`]: false })
    );
  });

  test('a participant can record their own we-met answer', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertSucceeds(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), { [`metBy.${ALICE}`]: true })
    );
  });

  test("a participant cannot touch the other person's flags", async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertFails(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), { [`hiddenBy.${BOB}`]: true })
    );
    await assertFails(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), { [`metBy.${BOB}`]: true })
    );
  });

  test('flags must be booleans', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertFails(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), { [`hiddenBy.${ALICE}`]: 'yes' })
    );
    await assertFails(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), { [`metBy.${ALICE}`]: 1 })
    );
  });

  test('flag writes cannot smuggle other fields along', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertFails(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), {
        [`hiddenBy.${ALICE}`]: true,
        lastMessage: { senderId: ALICE, text: 'forged', sentAt: Timestamp.now() },
      })
    );
  });

  test('a combined own-keys write (markRead + hide + met) is allowed', async () => {
    await seedConversation('c1', [ALICE, BOB], { unreadCounts: { [ALICE]: 3, [BOB]: 0 } });
    await assertSucceeds(
      updateDoc(doc(as(ALICE), 'conversations', 'c1'), {
        [`unreadCounts.${ALICE}`]: 0,
        [`hiddenBy.${ALICE}`]: true,
        [`metBy.${ALICE}`]: true,
      })
    );
  });

  test('a non-participant cannot hide anything', async () => {
    await seedConversation('c1', [ALICE, BOB]);
    await assertFails(
      updateDoc(doc(as(CHARLIE), 'conversations', 'c1'), { [`hiddenBy.${CHARLIE}`]: true })
    );
  });
});

describe('unmatches — entirely server-owned (unmatchUser callable)', () => {
  test('nobody can file, read, or list unmatch records from the client', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'unmatches', 'u1'), {
        unmatchedBy: ALICE,
        otherUserId: BOB,
        matchId: 'm1',
        reason: 'not_interested',
        createdAt: Timestamp.now(),
      });
    });

    // Not the author, not the subject, not a stranger.
    await assertFails(getDoc(doc(as(ALICE), 'unmatches', 'u1')));
    await assertFails(getDoc(doc(as(BOB), 'unmatches', 'u1')));
    await assertFails(getDocs(collection(as(CHARLIE), 'unmatches')));
    await assertFails(
      setDoc(doc(as(ALICE), 'unmatches', 'forged'), {
        unmatchedBy: ALICE,
        otherUserId: BOB,
        reason: 'no_reason',
        createdAt: Timestamp.now(),
      })
    );
  });
});

describe('passes — entirely server-owned (submitCallDecision)', () => {
  test('nobody can read, list, forge, or delete pass tombstones — not even their author', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'passes', ALICE, 'passed', BOB), {
        sessionId: 's1',
        createdAt: Timestamp.now(),
      });
    });

    // Not the author, not the person passed on, no list, no forgery, no undo.
    await assertFails(getDoc(doc(as(ALICE), 'passes', ALICE, 'passed', BOB)));
    await assertFails(getDoc(doc(as(BOB), 'passes', ALICE, 'passed', BOB)));
    await assertFails(getDocs(collection(as(ALICE), 'passes', ALICE, 'passed')));
    await assertFails(
      setDoc(doc(as(BOB), 'passes', BOB, 'passed', ALICE), { createdAt: Timestamp.now() })
    );
    await assertFails(deleteDoc(doc(as(ALICE), 'passes', ALICE, 'passed', BOB)));
  });
});

describe('users/{uid}/callHistory — private, server-written', () => {
  async function seedHistory(uid, sessionId, extra = {}) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'users', uid, 'callHistory', sessionId), {
        sessionId,
        peer: { uid: BOB, displayName: 'Bob' },
        mode: 'voice',
        startedAt: Timestamp.now(),
        durationSeconds: 42,
        endReason: 'ended',
        outcome: 'undecided',
        updatedAt: Timestamp.now(),
        ...extra,
      });
    });
  }

  test('the owner can read and list their history', async () => {
    await seedHistory(ALICE, 's1');
    await assertSucceeds(getDoc(doc(as(ALICE), 'users', ALICE, 'callHistory', 's1')));
    await assertSucceeds(getDocs(collection(as(ALICE), 'users', ALICE, 'callHistory')));
  });

  test('another user cannot read it — including the other participant of the call', async () => {
    await seedHistory(ALICE, 's1', { endReason: 'blocked', outcome: 'blocked' });
    await assertFails(getDoc(doc(as(BOB), 'users', ALICE, 'callHistory', 's1')));
  });

  test('the owner cannot forge or edit history', async () => {
    await seedHistory(ALICE, 's1');
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE, 'callHistory', 'forged'), {
        sessionId: 'forged',
        outcome: 'matched',
      })
    );
    await assertFails(
      updateDoc(doc(as(ALICE), 'users', ALICE, 'callHistory', 's1'), {
        outcome: 'matched',
      })
    );
  });
});

describe('users/{uid}/notifications — bell feed, mark-read only', () => {
  async function seedNotification(uid, id, extra = {}) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'users', uid, 'notifications', id), {
        kind: 'match',
        title: 'It\'s a match!',
        body: 'Say hi.',
        isRead: false,
        createdAt: Timestamp.now(),
        ...extra,
      });
    });
  }

  test('the owner can list their notifications and mark one read', async () => {
    await seedNotification(ALICE, 'n1');
    await assertSucceeds(getDocs(collection(as(ALICE), 'users', ALICE, 'notifications')));
    await assertSucceeds(
      updateDoc(doc(as(ALICE), 'users', ALICE, 'notifications', 'n1'), { isRead: true })
    );
  });

  test('marking back to unread is refused', async () => {
    await seedNotification(ALICE, 'n1', { isRead: true });
    await assertFails(
      updateDoc(doc(as(ALICE), 'users', ALICE, 'notifications', 'n1'), { isRead: false })
    );
  });

  test('editing the content is refused', async () => {
    await seedNotification(ALICE, 'n1');
    await assertFails(
      updateDoc(doc(as(ALICE), 'users', ALICE, 'notifications', 'n1'), {
        isRead: true,
        title: 'forged',
      })
    );
  });

  test('a client cannot create or delete notifications', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'users', ALICE, 'notifications', 'n2'), {
        kind: 'system',
        title: 'self-served',
        body: '',
        isRead: false,
        createdAt: serverTimestamp(),
      })
    );
    await seedNotification(ALICE, 'n1');
    await assertFails(deleteDoc(doc(as(ALICE), 'users', ALICE, 'notifications', 'n1')));
  });

  test('another user cannot read someone\'s notifications', async () => {
    await seedNotification(ALICE, 'n1');
    await assertFails(getDoc(doc(as(BOB), 'users', ALICE, 'notifications', 'n1')));
    await assertFails(getDocs(collection(as(BOB), 'users', ALICE, 'notifications')));
  });
});

describe('boosts/{uid} — server-owned entitlement state', () => {
  async function seedBoost(uid) {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'boosts', uid), {
        remainingBoosts: 2,
        activeUntil: Timestamp.fromDate(new Date(Date.now() + 60_000)),
        grantedAt: Timestamp.now(),
        updatedAt: Timestamp.now(),
      });
    });
  }

  test('the owner can read their boost state', async () => {
    await seedBoost(ALICE);
    await assertSucceeds(getDoc(doc(as(ALICE), 'boosts', ALICE)));
  });

  test('another user cannot read it', async () => {
    await seedBoost(ALICE);
    await assertFails(getDoc(doc(as(BOB), 'boosts', ALICE)));
  });

  test('a client cannot grant itself boosts', async () => {
    await assertFails(
      setDoc(doc(as(ALICE), 'boosts', ALICE), {
        remainingBoosts: 999,
        updatedAt: serverTimestamp(),
      })
    );
    await seedBoost(ALICE);
    await assertFails(
      updateDoc(doc(as(ALICE), 'boosts', ALICE), { remainingBoosts: 999 })
    );
  });
});
