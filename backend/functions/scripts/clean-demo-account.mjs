/**
 * Targeted cleanup of reviewer-facing account state.
 *
 * Companion to `inspect-demo-account.mjs`, which finds the problems; this is
 * the only thing that fixes the two that need writes. Both operations are
 * DRY-RUN by default and print exactly what they would touch — pass `--apply`
 * to commit. Production data is not recoverable once deleted.
 *
 *   node scripts/clean-demo-account.mjs --stale-invites +16505559876
 *   node scripts/clean-demo-account.mjs --delete-account +16505550109 --apply
 *
 * (run from backend/functions)
 *
 * --stale-invites <phone…>
 *     Deletes the account's `callInvites/{uid}` doc when it is already
 *     cancelled/declined or past `expiresAt`, and marks unread notifications
 *     read. Both are things the reviewer would otherwise walk into on first
 *     launch. A LIVE invite (pending and unexpired) is never touched.
 *
 * --delete-account <phone…>
 *     Full account deletion, mirroring the `deleteAccount` callable
 *     (src/account.ts) document for document, including the deliberate
 *     keeps: reports survive, and other users' callHistory projections and
 *     block entries survive. Refuses the three review accounts outright.
 *
 * Auth: application-default credentials against moomo-c7a37.
 */
import { initializeApp, applicationDefault } from 'firebase-admin/app';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';
import { getAuth } from 'firebase-admin/auth';
import { getStorage } from 'firebase-admin/storage';

const PROJECT_ID = 'moomo-c7a37';
const FORBIDDEN_PROJECT_ID = 'moomoios-2026';
if (PROJECT_ID === FORBIDDEN_PROJECT_ID) throw new Error('wrong project');

/** Never deletable by this script — these are the accounts in the ASC notes. */
const PROTECTED_PHONES = new Set(['+16505551234', '+16505555678', '+16505559876']);

const argv = process.argv.slice(2);
const APPLY = argv.includes('--apply');
const phonesFor = (flag) => {
  const i = argv.indexOf(flag);
  if (i === -1) return [];
  const out = [];
  for (let j = i + 1; j < argv.length && argv[j].startsWith('+'); j += 1) out.push(argv[j]);
  return out;
};
const staleFor = phonesFor('--stale-invites');
const deleteFor = phonesFor('--delete-account');

if (staleFor.length === 0 && deleteFor.length === 0) {
  console.error('nothing to do — pass --stale-invites and/or --delete-account with E.164 numbers');
  process.exit(2);
}

initializeApp({
  credential: applicationDefault(),
  projectId: PROJECT_ID,
  storageBucket: `${PROJECT_ID}.firebasestorage.app`,
});
const db = getFirestore();
const auth = getAuth();
const bucket = getStorage().bucket();

console.log(`\nmoomo-c7a37 — ${APPLY ? 'APPLYING CHANGES' : 'DRY RUN (pass --apply to commit)'}\n`);

const act = async (label, fn) => {
  console.log(`  ${APPLY ? 'delete' : 'would delete'}  ${label}`);
  if (APPLY) await fn();
};

async function uidFor(phone) {
  try {
    return (await auth.getUserByPhoneNumber(phone)).uid;
  } catch {
    console.log(`  ${phone}: no Auth user`);
    return null;
  }
}

// --- stale invites + unread notifications -----------------------------------

for (const phone of staleFor) {
  console.log(`\n--stale-invites ${phone}`);
  const uid = await uidFor(phone);
  if (!uid) continue;

  const inviteRef = db.doc(`callInvites/${uid}`);
  const invite = await inviteRef.get();
  if (!invite.exists) {
    console.log('  no callInvites doc');
  } else {
    const d = invite.data();
    const expiresAt = d.expiresAt instanceof Timestamp ? d.expiresAt.toMillis() : 0;
    const dead = d.status !== 'pending' || (expiresAt > 0 && expiresAt < Date.now());
    if (!dead) {
      console.log(`  SKIPPED — invite is live (status=${d.status}, expires in ${Math.round((expiresAt - Date.now()) / 1000)}s)`);
    } else {
      await act(`callInvites/${uid}  (status=${d.status}, expired ${Math.round((Date.now() - expiresAt) / 1000)}s ago)`,
        () => inviteRef.delete());
    }
  }

  const notifs = await db.collection(`users/${uid}/notifications`).get();
  const unread = notifs.docs.filter((n) => n.data().isRead !== true);
  if (unread.length === 0) {
    console.log('  no unread notifications');
  } else {
    console.log(`  ${APPLY ? 'marking' : 'would mark'} ${unread.length} notification(s) read:`);
    unread.forEach((n) => console.log(`      "${n.data().title ?? ''}"`));
    if (APPLY) {
      const batch = db.batch();
      unread.forEach((n) => batch.update(n.ref, { isRead: true }));
      await batch.commit();
    }
  }
}

// --- full account deletion ---------------------------------------------------

for (const phone of deleteFor) {
  console.log(`\n--delete-account ${phone}`);
  if (PROTECTED_PHONES.has(phone)) {
    console.log('  REFUSED — this is one of the three App Review accounts');
    continue;
  }
  const uid = await uidFor(phone);
  if (!uid) continue;

  const profile = await db.doc(`publicProfiles/${uid}`).get();
  console.log(`  uid=${uid}  name=${profile.exists ? profile.data().displayName : '(no profile)'}`);

  // Same four queries, in the same order, as account.ts:38-43.
  const [matches, conversations, sessions, fannedOutRings] = await Promise.all([
    db.collection('matches').where('participantIds', 'array-contains', uid).get(),
    db.collection('conversations').where('participantIds', 'array-contains', uid).get(),
    db.collection('callSessions').where('participantIds', 'array-contains', uid).get(),
    db.collection('callInvites').where('callerUid', '==', uid).get(),
  ]);
  for (const m of matches.docs) await act(`matches/${m.id}`, () => db.recursiveDelete(m.ref));
  for (const c of conversations.docs) {
    const n = await c.ref.collection('messages').count().get();
    await act(`conversations/${c.id}  (${n.data().count} message(s))`, () => db.recursiveDelete(c.ref));
  }
  for (const s of sessions.docs) await act(`callSessions/${s.id}`, () => db.recursiveDelete(s.ref));
  for (const r of fannedOutRings.docs) await act(`callInvites/${r.id}  (fanned-out ring)`, () => r.ref.delete());

  await act(`matchmakingQueue/${uid}`, () => db.doc(`matchmakingQueue/${uid}`).delete());
  await act(`callInvites/${uid}`, () => db.doc(`callInvites/${uid}`).delete());
  await act(`boosts/${uid}`, () => db.doc(`boosts/${uid}`).delete());
  await act(`publicProfiles/${uid}`, () => db.doc(`publicProfiles/${uid}`).delete());
  await act(`blocks/${uid}/**`, () => db.recursiveDelete(db.collection('blocks').doc(uid)));
  await act(`passes/${uid}/**`, () => db.recursiveDelete(db.collection('passes').doc(uid)));
  await act(`users/${uid}/**  (private profile, callHistory, notifications)`,
    () => db.recursiveDelete(db.collection('users').doc(uid)));
  await act(`Storage users/${uid}/photos/`, () => bucket.deleteFiles({ prefix: `users/${uid}/photos/` }));
  // Auth last, exactly as account.ts:85 — a crashed run can then be retried.
  await act(`Auth user ${uid}`, async () => {
    try {
      await auth.deleteUser(uid);
    } catch (e) {
      if (e.code !== 'auth/user-not-found') throw e;
    }
  });

  console.log('  KEPT (deliberately, per account.ts): reports filed by or against this account;');
  console.log("         other users' callHistory projections and block entries naming it.");
}

console.log(`\n${APPLY ? 'Done. Re-run inspect-demo-account.mjs to confirm.' : 'Dry run only — nothing was written.'}\n`);
process.exit(0);
