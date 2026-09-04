/**
 * Pass-severance inspector (and, with --confirm, a scoped un-severer).
 *
 * Why this exists: a pass permanently excludes a pair from BOTH pairing paths
 * — `joinMatchmakingQueue` (hasPassedEitherWay) and the ring fan-out
 * (filterExcluded). That is the intended product rule (commit 8722bc2), and
 * on a production-sized pool it is invisible. On a two-account TEST pool it
 * looks exactly like "matchmaking is broken": both accounts join, both are
 * logged `matchmaking_waiting`, `ring_fanout` reports `eligible: 0`, and
 * nothing ever pairs — with no error anywhere, because nothing failed.
 *
 * This script names that state explicitly so it is never re-diagnosed from
 * scratch, and can clear it for a pair of accounts you control.
 *
 * READ-ONLY by default, deliberately. `--confirm` deletes the tombstones for
 * the named pair and NOTHING else: no blocks are touched (a block is a safety
 * decision and is never undone by tooling), no other pair is touched, and no
 * collection is scanned for deletion.
 *
 * Only ever run --confirm against accounts you own. Clearing a real user's
 * pass tombstone puts them back in the pool with someone they turned down.
 *
 * Usage (from backend/functions):
 *
 *   node scripts/pair-severance.mjs <uidA> <uidB>            # report only
 *   node scripts/pair-severance.mjs <uidA> <uidB> --confirm  # clear the pair
 *
 * Auth: application-default credentials against moomo-c7a37.
 */
import { initializeApp, applicationDefault } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';

const PROJECT_ID = 'moomo-c7a37';
const FORBIDDEN_PROJECT_ID = 'moomoios-2026';
if (PROJECT_ID === FORBIDDEN_PROJECT_ID) throw new Error('wrong project');

const args = process.argv.slice(2);
const confirm = args.includes('--confirm');
const [uidA, uidB] = args.filter((a) => !a.startsWith('--'));

if (!uidA || !uidB) {
  console.error('Usage: node scripts/pair-severance.mjs <uidA> <uidB> [--confirm]');
  process.exit(2);
}
if (uidA === uidB) {
  console.error('Two different uids, please.');
  process.exit(2);
}

initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
const db = getFirestore();

const passRef = (a, b) => db.collection('passes').doc(a).collection('passed').doc(b);
const blockRef = (a, b) => db.collection('blocks').doc(a).collection('blocked').doc(b);
const short = (uid) => `${uid.slice(0, 8)}…`;

/**
 * The same four gates both pairing paths apply, in the same order:
 * compatibility.ts (gender, intention) then shared.ts (block, pass).
 */
function wantsGender(profile, gender) {
  const preferences = Array.isArray(profile?.interestedIn)
    ? profile.interestedIn.filter((p) => typeof p === 'string')
    : [];
  if (preferences.length === 0 || preferences.includes('everyone')) return true;
  if (gender === 'woman') return preferences.includes('women');
  if (gender === 'man') return preferences.includes('men');
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
  intention == null ? ['longTerm', 'shortTerm'] : (HORIZONS[intention] ?? ['longTerm', 'shortTerm']);

async function main() {
  const [profileA, profileB] = await Promise.all([
    db.collection('publicProfiles').doc(uidA).get(),
    db.collection('publicProfiles').doc(uidB).get(),
  ]);
  const a = profileA.data();
  const b = profileB.data();

  console.log(`\nPair: ${short(uidA)} (${a?.displayName ?? 'NO PROFILE'})`
    + ` ↔ ${short(uidB)} (${b?.displayName ?? 'NO PROFILE'})\n`);

  const findings = [];
  if (!profileA.exists) findings.push(`${short(uidA)} has no publicProfiles document`);
  if (!profileB.exists) findings.push(`${short(uidB)} has no publicProfiles document`);

  const genderOK =
    wantsGender(a, typeof b?.gender === 'string' ? b.gender : null) &&
    wantsGender(b, typeof a?.gender === 'string' ? a.gender : null);
  const intentionOK = seeks(a?.datingIntention ?? null)
    .some((h) => seeks(b?.datingIntention ?? null).includes(h));

  const [passAB, passBA, blockAB, blockBA] = await Promise.all([
    passRef(uidA, uidB).get(),
    passRef(uidB, uidA).get(),
    blockRef(uidA, uidB).get(),
    blockRef(uidB, uidA).get(),
  ]);

  console.log(`  1. mutual gender preference : ${genderOK ? 'OK' : 'REFUSED'}`
    + `  (${a?.gender}/${JSON.stringify(a?.interestedIn)} ↔ ${b?.gender}/${JSON.stringify(b?.interestedIn)})`);
  console.log(`  2. overlapping intention    : ${intentionOK ? 'OK' : 'REFUSED'}`
    + `  (${a?.datingIntention ?? 'none'} ↔ ${b?.datingIntention ?? 'none'})`);
  console.log(`  3. no block either way      : ${blockAB.exists || blockBA.exists ? 'REFUSED' : 'OK'}`);
  console.log(`  4. no pass either way       : ${passAB.exists || passBA.exists ? 'REFUSED' : 'OK'}`);

  if (!genderOK) findings.push('gender preferences do not line up both ways');
  if (!intentionOK) findings.push('dating intentions cannot overlap');
  if (blockAB.exists) findings.push(`${short(uidA)} has BLOCKED ${short(uidB)} — not cleared by this script`);
  if (blockBA.exists) findings.push(`${short(uidB)} has BLOCKED ${short(uidA)} — not cleared by this script`);

  const tombstones = [];
  if (passAB.exists) {
    tombstones.push({ ref: passRef(uidA, uidB), label: `${short(uidA)} → ${short(uidB)}`, data: passAB.data() });
  }
  if (passBA.exists) {
    tombstones.push({ ref: passRef(uidB, uidA), label: `${short(uidB)} → ${short(uidA)}`, data: passBA.data() });
  }

  if (tombstones.length > 0) {
    console.log('\n  Pass tombstones:');
    for (const { label, data } of tombstones) {
      const at = data?.createdAt?.toDate?.().toISOString() ?? 'unknown time';
      console.log(`    ${label}  at ${at}  session=${data?.sessionId ?? 'none'}`);
    }
  }

  if (findings.length === 0 && tombstones.length === 0) {
    console.log('\n  VERDICT: this pair can match. Nothing to clear.\n');
    return;
  }

  console.log('\n  VERDICT: this pair CANNOT match.');
  for (const finding of findings) console.log(`    - ${finding}`);
  if (tombstones.length > 0) {
    console.log(`    - ${tombstones.length} pass tombstone(s) sever the pair permanently`);
  }

  if (!confirm) {
    console.log('\n  Read-only. Re-run with --confirm to delete ONLY the pass tombstones above.');
    console.log('  Blocks, profiles, and every other pair are left untouched.\n');
    return;
  }

  if (tombstones.length === 0) {
    console.log('\n  Nothing to delete — the refusal above is not a pass.\n');
    return;
  }

  for (const { ref, label } of tombstones) {
    await ref.delete();
    console.log(`  deleted pass ${label}`);
  }
  console.log('\n  Done. Both pairing paths will consider this pair again.\n');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('ERROR', error.code ?? '', error.message);
    process.exit(1);
  });
