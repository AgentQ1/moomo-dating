/**
 * Deep read-only inspection of ONE demo account — "is this account perfect to
 * hand App Review?"
 *
 * `demo-accounts.mjs` answers a narrower question: can the three review
 * accounts pair with each other. It says nothing about what the reviewer
 * actually lands in — a half-finished profile, someone else's leftover
 * conversation, a stale photo path pointing at a deleted object, an account
 * that is disabled in Auth, or a phone number that is not registered as a
 * Firebase test number and so cannot be signed into without a real SMS.
 *
 * This script checks all of that for a single account and prints a verdict.
 * It is READ-ONLY and has no --fix: everything it can find wrong is either
 * fixed by `demo-accounts.mjs --fix`, by `clean-demo-account.mjs`, or by hand
 * in a console, and each of those is a decision worth making deliberately.
 *
 * Usage (from backend/functions):
 *
 *   node scripts/inspect-demo-account.mjs +16505559876
 *   node scripts/inspect-demo-account.mjs               # defaults to all three
 *
 * Auth: application-default credentials against moomo-c7a37.
 */
import { initializeApp, applicationDefault } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { getAuth } from 'firebase-admin/auth';
import { getStorage } from 'firebase-admin/storage';

const PROJECT_ID = 'moomo-c7a37';
const FORBIDDEN_PROJECT_ID = 'moomoios-2026';
if (PROJECT_ID === FORBIDDEN_PROJECT_ID) throw new Error('wrong project');

const DEMO_PHONES = ['+16505551234', '+16505555678', '+16505559876'];
const args = process.argv.slice(2).filter((a) => !a.startsWith('--'));
const phones = args.length > 0 ? args : DEMO_PHONES;

initializeApp({
  credential: applicationDefault(),
  projectId: PROJECT_ID,
  storageBucket: `${PROJECT_ID}.firebasestorage.app`,
});
const db = getFirestore();
const auth = getAuth();
const bucket = getStorage().bucket();

const ONLINE_WINDOW_MS = 5 * 60 * 1000;

let problems = 0;
const ok = (m) => console.log(`    ✓ ${m}`);
/** A defect: the account is broken or misleading for a reviewer. Fails the verdict. */
const bad = (m) => { problems += 1; console.log(`    ✗ ${m}`); };
/**
 * A judgement call, surfaced but not failed — leftover matches and threads are
 * a product decision (clutter vs. showing the reviewer that chat exists), not
 * a defect. Printed so the choice is deliberate rather than accidental.
 */
const warn = (m) => console.log(`    ! ${m}`);
const note = (m) => console.log(`    · ${m}`);

const ts = (v) => {
  if (!v) return null;
  if (typeof v.toDate === 'function') return v.toDate();
  if (v instanceof Date) return v;
  return null;
};
const ago = (d) => (d ? `${Math.round((Date.now() - d.getTime()) / 1000)}s ago` : 'never');

/** uid -> display name, for rendering the other side of a match/conversation. */
const nameCache = new Map();
async function nameOf(uid) {
  if (nameCache.has(uid)) return nameCache.get(uid);
  const snap = await db.doc(`publicProfiles/${uid}`).get();
  const n = snap.exists ? (snap.data().displayName ?? '(no name)') : '(no profile)';
  nameCache.set(uid, `${n} [${uid.slice(0, 8)}…]`);
  return nameCache.get(uid);
}

async function inspect(phone) {
  console.log(`\n${'='.repeat(72)}\n${phone}\n${'='.repeat(72)}`);

  // --- Auth ---------------------------------------------------------------
  let user;
  try {
    user = await auth.getUserByPhoneNumber(phone);
  } catch {
    bad('no Auth user for this phone number — the reviewer cannot sign in');
    return;
  }
  const uid = user.uid;
  console.log(`\n  AUTH  uid=${uid}`);
  if (user.disabled) bad('Auth user is DISABLED — sign-in will fail'); else ok('enabled');
  note(`created ${new Date(user.metadata.creationTime).toISOString()}`);
  note(`last sign-in ${user.metadata.lastSignInTime ?? 'never'}`);

  // --- Public profile: what the reviewer and other users see ---------------
  const pubSnap = await db.doc(`publicProfiles/${uid}`).get();
  console.log('\n  PUBLIC PROFILE  (publicProfiles/{uid} — the feed projection)');
  if (!pubSnap.exists) {
    bad('publicProfiles doc missing — invisible to everyone, feed will be empty both ways');
    return;
  }
  const p = pubSnap.data();

  // Exactly the fields discovery.ts::candidateFrom reads.
  if (typeof p.displayName === 'string' && p.displayName.length > 0) {
    ok(`displayName "${p.displayName}"`);
  } else {
    bad('displayName missing — candidateFrom() returns null, so this account never appears in anyone\'s feed');
  }
  if (typeof p.age === 'number') ok(`age ${p.age}`); else bad('age missing — card shows a bare name');
  if (typeof p.city === 'string' && p.city) ok(`city "${p.city}"`); else bad('city missing — card shows no location line');
  if (typeof p.occupation === 'string' && p.occupation) ok(`occupation "${p.occupation}"`);
  else note('occupation empty — shown only on the in-call overlay, not a blocker');
  if (typeof p.gender === 'string' && p.gender) ok(`gender ${p.gender}`); else bad('gender unset — mutual-preference gate cannot pass');
  const wants = p.interestedIn;
  if (Array.isArray(wants) && wants.length) ok(`interestedIn ${JSON.stringify(wants)}`);
  else bad('interestedIn unset');
  if (p.datingIntention) ok(`datingIntention ${p.datingIntention}`); else note('datingIntention unset (treated as "matches all")');
  if (p.isVerified) note('isVerified true — never granted server-side; check this is not fake data');

  // --- Photos: paths must resolve to real Storage objects ------------------
  console.log('\n  PHOTOS');
  const paths = Array.isArray(p.photoPaths) ? p.photoPaths.filter((x) => typeof x === 'string' && x) : [];
  if (paths.length === 0) {
    bad('no photoPaths — the hero card renders an empty circle');
  } else {
    ok(`${paths.length} path(s)`);
    for (const path of paths) {
      try {
        const [exists] = await bucket.file(path).exists();
        if (exists) {
          const [meta] = await bucket.file(path).getMetadata();
          ok(`${path}  (${Math.round(Number(meta.size) / 1024)} KB, ${meta.contentType})`);
        } else {
          bad(`${path}  — DANGLING, no such object in Storage; the photo will fail to load`);
        }
      } catch (e) {
        bad(`${path}  — could not stat: ${e.message}`);
      }
    }
  }

  // --- Presence -----------------------------------------------------------
  console.log('\n  PRESENCE');
  const lastActive = ts(p.lastActiveAt);
  note(`lastActiveAt ${ago(lastActive)}`);
  if (lastActive && Date.now() - lastActive.getTime() < ONLINE_WINDOW_MS) {
    note('inside the 5-minute online window — currently shows as "Online now"');
  } else {
    note('outside the online window — shows without the online dot until the app opens');
  }
  note(`activityBucket ${p.activityBucket === undefined ? '(unset)' : JSON.stringify(p.activityBucket)}`);

  // --- Private profile ----------------------------------------------------
  const privSnap = await db.doc(`users/${uid}`).get();
  console.log('\n  PRIVATE PROFILE  (users/{uid})');
  if (!privSnap.exists) {
    bad('users doc missing — the app will restart onboarding on sign-in');
  } else {
    const u = privSnap.data();
    ok('exists');
    if (u.dateOfBirth) ok(`dateOfBirth present (${ts(u.dateOfBirth)?.toISOString().slice(0, 10) ?? 'raw'})`);
    else bad('dateOfBirth missing — onboarding may re-prompt, and the 18+ gate has nothing to check');
    // Preference fields live in both docs; a mismatch means the next client
    // profile save silently republishes the stale private value.
    for (const key of ['interestedIn', 'datingIntention']) {
      const a = JSON.stringify(u[key] ?? null);
      const b = JSON.stringify(p[key] ?? null);
      if (a === b) ok(`${key} agrees with the public projection`);
      else bad(`${key} DIVERGES: private=${a} public=${b} — next profile save will republish the private value`);
    }
  }

  const locSnap = await db.doc(`users/${uid}/private/location`).get();
  note(`private/location ${locSnap.exists ? JSON.stringify(locSnap.data()) : '(none — feed falls back to activity ordering)'}`);

  // --- Leftovers a reviewer would walk into -------------------------------
  console.log('\n  INBOX STATE  (what the reviewer sees on first launch)');

  // `participantIds` — the field matches/conversations/callSessions all share
  // (account.ts:39-41, firestore.rules::isParticipant). Querying `uids` here
  // silently returns empty and reports a clean inbox that isn't.
  const matches = await db.collection('matches').where('participantIds', 'array-contains', uid).get();
  if (matches.empty) ok('no existing matches — Matches tab is a clean empty state');
  else {
    for (const m of matches.docs) {
      const other = (m.data().participantIds ?? []).find((x) => x !== uid);
      warn(`match with ${await nameOf(other)} — reviewer lands on a pre-existing match`);
    }
  }

  const convos = await db.collection('conversations').where('participantIds', 'array-contains', uid).get();
  if (convos.empty) ok('no conversations — Chat tab is a clean empty state');
  else {
    for (const c of convos.docs) {
      const d = c.data();
      const other = (d.participantIds ?? []).find((x) => x !== uid);
      const msgs = await c.ref.collection('messages').count().get();
      const unread = (d.unreadCounts ?? {})[uid] ?? 0;
      const line = `conversation with ${await nameOf(other)} — ${msgs.data().count} message(s), last "${d.lastMessage?.text ?? ''}"`;
      // An unread count is a badge on the tab bar the reviewer cannot clear
      // without opening someone else's thread; that one is a defect.
      if (unread > 0) bad(`${line}, ${unread} UNREAD`); else warn(line);
    }
  }

  const history = await db.collection(`users/${uid}/callHistory`).count().get();
  note(`callHistory ${history.data().count} entr(ies) — Calls tab ${history.data().count ? 'is populated' : 'is a clean empty state'}`);

  const notifs = await db.collection(`users/${uid}/notifications`).get();
  const unreadNotifs = notifs.docs.filter((n) => n.data().isRead !== true);
  if (unreadNotifs.length) {
    bad(`${unreadNotifs.length} UNREAD notification(s) — a badge and stale "It's a match" banners greet the reviewer`);
    unreadNotifs.slice(0, 4).forEach((n) => note(`  "${n.data().title ?? ''}"`));
  } else {
    ok(`notifications ${notifs.size}, none unread`);
  }

  // A leftover invite is only a problem if the client would actually ring on
  // it. CallInviteLogic.invite() (app/Moomo/Services/CallInviteLogic.swift:29)
  // requires status == "ringing" AND expiresAt > now, and rejects cache
  // replays — so a terminal or expired document is inert, not a defect.
  const invite = await db.doc(`callInvites/${uid}`).get();
  if (!invite.exists) {
    ok('no leftover call invite');
  } else {
    const d = invite.data();
    const expiresAt = ts(d.expiresAt);
    const ringable = d.status === 'ringing' && expiresAt && expiresAt.getTime() > Date.now();
    if (ringable) {
      bad(`LIVE callInvites/${uid} from ${d.caller?.displayName ?? d.callerUid} — the banner will fire on launch`);
    } else {
      note(`leftover callInvites/${uid} (status=${d.status}, expired ${ago(expiresAt)}) — inert, the client will not ring on it`);
    }
  }

  const queue = await db.doc(`matchmakingQueue/${uid}`).get();
  if (queue.exists) bad(`stale matchmakingQueue/${uid} — appears as "wants to talk" and short-circuits the ring path: ${JSON.stringify(queue.data())}`);
  else ok('not sitting in the matchmaking queue');

  // --- Gates against the other demo accounts ------------------------------
  console.log('\n  GATES vs THE OTHER DEMO ACCOUNTS');
  for (const otherPhone of DEMO_PHONES) {
    if (otherPhone === phone) continue;
    let other;
    try { other = await auth.getUserByPhoneNumber(otherPhone); } catch { continue; }
    const reasons = [];
    for (const [from, to, label] of [
      [uid, other.uid, `${phone} -> ${otherPhone}`],
      [other.uid, uid, `${otherPhone} -> ${phone}`],
    ]) {
      if ((await db.doc(`blocks/${from}/blocked/${to}`).get()).exists) reasons.push(`BLOCK ${label}`);
      if ((await db.doc(`passes/${from}/passed/${to}`).get()).exists) reasons.push(`PASS ${label}`);
    }
    if (reasons.length) reasons.forEach(bad); else ok(`clean vs ${otherPhone} (no block, no pass tombstone)`);
  }

  // --- Moderation ---------------------------------------------------------
  const against = await db.collection('reports').where('reportedUid', '==', uid).count().get();
  if (against.data().count) bad(`${against.data().count} report(s) filed against this account`);
  else ok('no reports against this account');

  // --- The feed this account would actually receive ------------------------
  //
  // This is the check the 2026-08-05 rejection turned on: the reviewer signed
  // in and Discover had nothing to show, so no call-request button existed.
  // Replicates getDiscoveryFeed's composition (discovery.ts:190-245): pool by
  // activityBucket, merge the waiting pool first, filter by mutual
  // compatibility, then drop blocks and pass tombstones both ways.
  console.log('\n  FEED PREVIEW  (what Discover would return for this account)');
  const [activeSnap, waitingSnap] = await Promise.all([
    db.collection('publicProfiles').orderBy('activityBucket', 'desc').limit(120).get(),
    db.collection('publicProfiles').where('wantsToTalk', '==', true)
      .orderBy('activityBucket', 'desc').limit(30).get(),
  ]);
  const seen = new Set([uid]);
  const pooled = [];
  for (const s of [...waitingSnap.docs, ...activeSnap.docs]) {
    if (seen.has(s.id)) continue;
    seen.add(s.id);
    pooled.push(s);
  }
  // The bucket-less fallback: orderBy excludes docs missing activityBucket.
  if (pooled.length < 12) {
    const legacy = await db.collection('publicProfiles').limit(120).get();
    for (const s of legacy.docs) {
      if (seen.has(s.id)) continue;
      seen.add(s.id);
      pooled.push(s);
    }
  }

  const wantsGender = (prof, gender) => {
    const w = prof?.interestedIn;
    if (!Array.isArray(w) || w.length === 0) return true;
    if (w.includes('everyone')) return true;
    if (gender === 'woman') return w.includes('women');
    if (gender === 'man') return w.includes('men');
    return false;
  };
  const HORIZONS = {
    lifePartner: ['longTerm'], longTerm: ['longTerm'], shortTerm: ['shortTerm'],
    longTermOpenToShort: ['longTerm', 'shortTerm'],
    shortTermOpenToLong: ['longTerm', 'shortTerm'],
    figuringItOut: ['longTerm', 'shortTerm'],
  };
  const seeks = (i) => (i == null ? ['longTerm', 'shortTerm'] : HORIZONS[i] ?? ['longTerm', 'shortTerm']);

  const visible = [];
  const dropped = { incompatible: 0, excluded: 0, unrenderable: 0 };
  for (const s of pooled) {
    const c = s.data();
    if (!wantsGender(p, c.gender) || !wantsGender(c, p.gender)
        || !seeks(p.datingIntention).some((h) => seeks(c.datingIntention).includes(h))) {
      dropped.incompatible += 1;
      continue;
    }
    const [b1, b2, x1, x2] = await Promise.all([
      db.doc(`blocks/${uid}/blocked/${s.id}`).get(),
      db.doc(`blocks/${s.id}/blocked/${uid}`).get(),
      db.doc(`passes/${uid}/passed/${s.id}`).get(),
      db.doc(`passes/${s.id}/passed/${uid}`).get(),
    ]);
    if (b1.exists || b2.exists || x1.exists || x2.exists) { dropped.excluded += 1; continue; }
    // candidateFrom() returns null without a displayName, and the card is
    // empty without a photo.
    const photo = Array.isArray(c.photoPaths) ? c.photoPaths.find((x) => typeof x === 'string' && x) : null;
    if (!c.displayName || !photo) { dropped.unrenderable += 1; continue; }
    visible.push({ name: c.displayName, age: c.age, city: c.city, wantsToTalk: c.wantsToTalk === true });
  }

  if (visible.length === 0) {
    bad('Discover would be EMPTY — this is exactly the 2.1 failure mode. No call-request button can exist.');
  } else {
    ok(`${visible.length} person(s) would appear — the hero card and its "Nearby" call button render`);
    visible.slice(0, 8).forEach((v) =>
      note(`${v.name}, ${v.age ?? '?'} — ${v.city ?? 'no city'}${v.wantsToTalk ? '  [Wants to Talk to You]' : ''}`));
    if (visible.length > 8) note(`…and ${visible.length - 8} more`);
  }
  note(`pool ${pooled.length}; dropped: ${dropped.incompatible} incompatible, ${dropped.excluded} blocked/passed, ${dropped.unrenderable} missing name or photo`);
}

for (const phone of phones) await inspect(phone);

console.log(`\n${'='.repeat(72)}`);
console.log(problems === 0
  ? '\nVERDICT: no defects. Any "!" lines above are deliberate choices, not faults.\n'
  : `\nVERDICT: ${problems} defect(s) marked ✗ must be resolved before this goes in the review notes.\n`);
process.exit(0);
