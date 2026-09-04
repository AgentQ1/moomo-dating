/**
 * Demo-account pairability check (and repair) — Guideline 2.1.
 *
 * App Review rejected 1.0(3) because the three accounts in the review notes
 * were mathematically incapable of matching each other, so the reviewer never
 * reached a matched state and never saw a call-request button at all
 * (docs/production-readiness/REJECTION_2026-08-05_ROOT_CAUSE.md §1).
 *
 * Both pairing paths — joinMatchmakingQueue and the ring fan-out — apply the
 * same four gates. This script checks EXACTLY those gates, in the same order,
 * against live data:
 *
 *   1. mutual gender preference   compatibility.ts  wantsGender both ways
 *   2. overlapping intention      compatibility.ts  isIntentionCompatible
 *   3. no block either way        shared.ts         isBlockedEitherWay
 *   4. no pass tombstone either way shared.ts       hasPassedEitherWay
 *
 * …plus the two reasons a profile is invisible even when compatible:
 * a missing displayName (discovery.ts `candidateFrom` returns null) and no
 * photo.
 *
 * Lives under backend/functions/ rather than backend/scripts/ because Node
 * resolves bare imports by walking up from the FILE, and firebase-admin is
 * installed only in backend/functions/node_modules.
 *
 * Usage — READ ONLY by default, and that is the default on purpose:
 *
 *   node scripts/demo-accounts.mjs                  # report only
 *   node scripts/demo-accounts.mjs --fix            # repair what it can
 *
 * (run from backend/functions)
 *
 * `--fix` only ever RELAXES a constraint between the demo accounts: it deletes
 * pass tombstones and blocks between them and widens their `interestedIn` to
 * `everyone`. It never touches a non-demo account, never writes a coordinate,
 * and never deletes profile data.
 *
 * Auth: application-default credentials (`gcloud auth application-default
 * login`) against moomo-c7a37.
 */
import { initializeApp, applicationDefault } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { getAuth } from 'firebase-admin/auth';

const PROJECT_ID = 'moomo-c7a37';
// The Moomo AI project. These writes must never land there.
const FORBIDDEN_PROJECT_ID = 'moomoios-2026';

if (PROJECT_ID === FORBIDDEN_PROJECT_ID) throw new Error('wrong project');

/** The numbers in the ASC review notes. Order matters: [0] is Apple's. */
const DEMO_PHONES = ['+16505551234', '+16505555678', '+16505559876'];

const FIX = process.argv.includes('--fix');

initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
const db = getFirestore();
const auth = getAuth();

// --- the gates, mirrored from backend/functions/src/compatibility.ts --------

function wantsGender(profile, gender) {
  const wants = profile?.interestedIn;
  if (!Array.isArray(wants) || wants.length === 0) return true;
  if (wants.includes('everyone')) return true;
  if (gender === 'woman') return wants.includes('women');
  if (gender === 'man') return wants.includes('men');
  return false;
}

const HORIZONS = {
  lifePartner: ['longTerm'],
  longTerm: ['longTerm'],
  shortTerm: ['shortTerm'],
  longTermOpenToShort: ['longTerm', 'shortTerm'],
  shortTermOpenToLong: ['longTerm', 'shortTerm'],
  figuringItOut: ['longTerm', 'shortTerm'],
};
const seeks = (intention) =>
  intention == null ? ['longTerm', 'shortTerm'] : HORIZONS[intention] ?? ['longTerm', 'shortTerm'];

const intentionsOverlap = (a, b) =>
  seeks(a?.datingIntention).some((h) => seeks(b?.datingIntention).includes(h));

// --- load -------------------------------------------------------------------

async function loadAccount(phone) {
  let user;
  try {
    user = await auth.getUserByPhoneNumber(phone);
  } catch {
    return { phone, missing: true };
  }
  const snap = await db.doc(`publicProfiles/${user.uid}`).get();
  return { phone, uid: user.uid, profile: snap.exists ? snap.data() : null };
}

async function exists(path) {
  return (await db.doc(path).get()).exists;
}

// --- report -----------------------------------------------------------------

const accounts = [];
for (const phone of DEMO_PHONES) accounts.push(await loadAccount(phone));

console.log(`\nDemo accounts on ${PROJECT_ID}${FIX ? '  [--fix]' : '  [read-only]'}\n`);
for (const a of accounts) {
  if (a.missing) {
    console.log(`  ${a.phone}  MISSING from Auth`);
    continue;
  }
  const p = a.profile;
  console.log(
    `  ${a.phone}  ${a.uid}\n` +
      `      name=${p?.displayName ?? '(none)'}  gender=${p?.gender ?? '(unset)'}  ` +
      `interestedIn=${JSON.stringify(p?.interestedIn ?? null)}  ` +
      `intention=${p?.datingIntention ?? '(unset)'}  ` +
      `photos=${Array.isArray(p?.photoPaths) ? p.photoPaths.length : 0}`
  );
}

const live = accounts.filter((a) => !a.missing && a.profile);
const pairs = [];
for (let i = 0; i < live.length; i += 1) {
  for (let j = i + 1; j < live.length; j += 1) pairs.push([live[i], live[j]]);
}

console.log('\nPairability (the four gates, in the order the server applies them):\n');
const broken = [];
for (const [a, b] of pairs) {
  const reasons = [];
  if (!wantsGender(a.profile, b.profile?.gender)) {
    reasons.push(`${a.phone} prefs reject ${b.profile?.gender ?? 'unset gender'}`);
  }
  if (!wantsGender(b.profile, a.profile?.gender)) {
    reasons.push(`${b.phone} prefs reject ${a.profile?.gender ?? 'unset gender'}`);
  }
  if (!intentionsOverlap(a.profile, b.profile)) reasons.push('intentions do not overlap');

  const blocks = [
    `blocks/${a.uid}/blocked/${b.uid}`,
    `blocks/${b.uid}/blocked/${a.uid}`,
  ];
  const passes = [
    `passes/${a.uid}/passed/${b.uid}`,
    `passes/${b.uid}/passed/${a.uid}`,
  ];
  const liveBlocks = [];
  for (const path of blocks) if (await exists(path)) liveBlocks.push(path);
  const livePasses = [];
  for (const path of passes) if (await exists(path)) livePasses.push(path);
  liveBlocks.forEach((p) => reasons.push(`BLOCK ${p}`));
  livePasses.forEach((p) => reasons.push(`PASS ${p}`));

  for (const who of [a, b]) {
    if (!who.profile?.displayName) reasons.push(`${who.phone} has no displayName (invisible in feed)`);
    if (!Array.isArray(who.profile?.photoPaths) || who.profile.photoPaths.length === 0) {
      reasons.push(`${who.phone} has no photo`);
    }
  }

  const ok = reasons.length === 0;
  console.log(`  ${a.phone} <-> ${b.phone}  ${ok ? 'CAN PAIR' : 'CANNOT PAIR'}`);
  reasons.forEach((r) => console.log(`      - ${r}`));
  if (!ok) broken.push({ a, b, liveBlocks, livePasses });
}

// --- repair -----------------------------------------------------------------

if (FIX && broken.length > 0) {
  console.log('\nRepairing (relaxing constraints between demo accounts only):\n');
  for (const { a, b, liveBlocks, livePasses } of broken) {
    for (const path of [...liveBlocks, ...livePasses]) {
      await db.doc(path).delete();
      console.log(`  deleted ${path}`);
    }
  }
  // Widen preferences so every demo pair accepts every other, and give them a
  // shared intention horizon. `everyone` + figuringItOut is the most permissive
  // legal combination and is catalog-valid under firestore.rules.
  for (const a of live) {
    const updates = {};
    if (JSON.stringify(a.profile?.interestedIn) !== JSON.stringify(['everyone'])) {
      updates.interestedIn = ['everyone'];
    }
    if (a.profile?.datingIntention !== 'figuringItOut') {
      updates.datingIntention = 'figuringItOut';
    }
    if (Object.keys(updates).length > 0) {
      updates.updatedAt = new Date();
      await db.doc(`publicProfiles/${a.uid}`).set(updates, { merge: true });
      // The private profile carries the same preference fields; keep them in
      // step or the next client profile save re-publishes the old values.
      await db.doc(`users/${a.uid}`).set(
        { interestedIn: updates.interestedIn, datingIntention: updates.datingIntention, updatedAt: new Date() },
        { merge: true }
      );
      console.log(`  ${a.phone} -> ${JSON.stringify(updates)}`);
    }
  }
  console.log('\nRe-run without --fix to confirm.\n');
} else if (broken.length === 0) {
  console.log('\nAll demo pairs can pair.\n');
} else {
  console.log(`\n${broken.length} pair(s) cannot pair. Re-run with --fix to repair.\n`);
}

process.exit(0);
