/**
 * Matchmaking: one queue document per user, paired inside a transaction.
 *
 * The client may only READ its own `matchmakingQueue/{uid}` document — every
 * write happens here. Pairing and session creation are one transaction, so two
 * users can never both "win" the same partner.
 *
 * `createCallSession` is deliberately internal, not a callable: a client that
 * could create call sessions could forge call history with anyone.
 */
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";
import {
  db,
  requireAuth,
  requireString,
  isBlockedEitherWay,
  participantSummary,
  ParticipantSummary,
  CALL_MODES,
  CallMode,
  SPEED_CALL_SECONDS,
  QUEUE_ENTRY_TTL_MS,
} from "./shared";

interface PairedSession {
  sessionId: string;
  mode: CallMode;
  startedAtMillis: number;
  maxDurationSeconds: number;
  participants: Record<string, ParticipantSummary>;
}

type PublicProfile = FirebaseFirestore.DocumentData | undefined;

/**
 * Whether `profile`'s stated preferences accept someone of `gender`.
 *
 * Mirrors `MatchPreferences.wants` in app/Moomo/Models/MatchPreferences.swift
 * — the two tables must stay identical, or Discover advertises people the
 * queue refuses to pair:
 *  - empty/missing preferences read as "everyone" (pre-preference accounts
 *    must keep working);
 *  - `everyone` accepts any gender, including non-binary/other/unknown;
 *  - `women`/`men` accept exactly `woman`/`man`; non-binary, other, and
 *    unknown genders are matched only by "everyone".
 */
function wantsGender(profile: PublicProfile, gender: string | null): boolean {
  const preferences = Array.isArray(profile?.interestedIn)
    ? (profile.interestedIn as unknown[]).filter((p) => typeof p === "string")
    : [];
  if (preferences.length === 0 || preferences.includes("everyone")) return true;
  if (gender === "woman") return preferences.includes("women");
  if (gender === "man") return preferences.includes("men");
  return false;
}

function genderOf(profile: PublicProfile): string | null {
  return typeof profile?.gender === "string" ? profile.gender : null;
}

/** Pair only people who would BOTH choose to meet the other. */
function isMutuallyCompatible(a: PublicProfile, b: PublicProfile): boolean {
  return wantsGender(a, genderOf(b)) && wantsGender(b, genderOf(a));
}

/** An active boost at `now` — what "front of the matchmaking queue" means. */
function isBoosted(profile: PublicProfile, now: Timestamp): boolean {
  const until = profile?.boostedUntil;
  return until instanceof Timestamp && until.toMillis() > now.toMillis();
}

/**
 * Creates the server-owned call session and retires both queue entries.
 * Runs inside the pairing transaction — never callable on its own.
 */
function createCallSession(
  tx: FirebaseFirestore.Transaction,
  a: ParticipantSummary,
  b: ParticipantSummary,
  mode: CallMode,
  now: Timestamp
): PairedSession {
  const sessionRef = db().collection("callSessions").doc();
  const participants = { [a.uid]: a, [b.uid]: b };

  tx.create(sessionRef, {
    participantIds: [a.uid, b.uid],
    participants,
    mode,
    status: "active",
    startedAt: now,
    maxDurationSeconds: SPEED_CALL_SECONDS,
    createdAt: now,
  });

  for (const uid of [a.uid, b.uid]) {
    // `matched` rather than deleted: the waiting client is listening to its
    // own queue document for exactly this transition.
    tx.set(db().collection("matchmakingQueue").doc(uid), {
      uid,
      mode,
      status: "matched",
      sessionId: sessionRef.id,
      createdAt: now,
      updatedAt: now,
    });
    // No longer waiting; Discover should stop advertising them.
    tx.set(
      db().collection("publicProfiles").doc(uid),
      { wantsToTalk: false, updatedAt: now },
      { merge: true }
    );
  }

  return {
    sessionId: sessionRef.id,
    mode,
    startedAtMillis: now.toMillis(),
    maxDurationSeconds: SPEED_CALL_SECONDS,
    participants,
  };
}

export const joinMatchmakingQueue = onCall(async (request) => {
  const uid = requireAuth(request);
  const mode = requireString(request.data?.mode, "mode") as CallMode;
  if (!CALL_MODES.includes(mode)) {
    throw new HttpsError("invalid-argument", "Invalid mode.");
  }
  const preferredPeerId =
    typeof request.data?.preferredPeerId === "string" &&
    request.data.preferredPeerId.length > 0 &&
    request.data.preferredPeerId !== uid
      ? (request.data.preferredPeerId as string)
      : null;

  // Housekeeping on the way in: a join is the moment stale state hurts most
  // (someone is looking at Discover and about to wait), and running it here
  // means the queue heals even if nobody ever leaves cleanly.
  await sweepStaleQueueEntries();

  return db().runTransaction(async (tx) => {
    const now = Timestamp.now();
    const staleBefore = Timestamp.fromMillis(now.toMillis() - QUEUE_ENTRY_TTL_MS);

    // -- Reads first (Admin transactions require all reads before writes) --

    // The waiting pool, oldest first, same mode. A small page is enough: we
    // only need one usable partner.
    const waitingSnap = await tx.get(
      db()
        .collection("matchmakingQueue")
        .where("status", "==", "waiting")
        .where("mode", "==", mode)
        .orderBy("createdAt", "asc")
        .limit(10)
    );

    // "Talk to Him": the featured person is asked first — but only if they
    // are genuinely waiting. Nothing is simulated on their behalf.
    const preferredCandidates: string[] = [];
    if (preferredPeerId) {
      const preferredEntry = await tx.get(
        db().collection("matchmakingQueue").doc(preferredPeerId)
      );
      if (
        preferredEntry.exists &&
        preferredEntry.get("status") === "waiting" &&
        preferredEntry.get("mode") === mode &&
        (preferredEntry.get("createdAt") as Timestamp) >= staleBefore
      ) {
        preferredCandidates.push(preferredPeerId);
      }
    }
    const fifoCandidates: string[] = [];
    for (const entry of waitingSnap.docs) {
      const candidate = entry.get("uid") as string;
      if (candidate === uid || preferredCandidates.includes(candidate)) continue;
      if ((entry.get("createdAt") as Timestamp) < staleBefore) continue;
      fifoCandidates.push(candidate);
    }

    // Public projections for the joiner and every candidate, read inside the
    // transaction: compatibility comes from gender + interestedIn, boost
    // ranking from boostedUntil, and the participant summaries from the rest.
    const profileIds = [uid, ...preferredCandidates, ...fifoCandidates];
    const profileSnaps = await Promise.all(
      profileIds.map((id) => tx.get(db().collection("publicProfiles").doc(id)))
    );
    const profiles = new Map<string, PublicProfile>(
      profileIds.map((id, index) => [id, profileSnaps[index].data()])
    );
    const mine = profiles.get(uid);

    // Ranking: an explicit "Talk to Him" invitation first, then waiting users
    // with an ACTIVE boost (what the boost screen promises), then everyone
    // else — both groups oldest-first, as the query delivered them.
    const rankedCandidates = [
      ...preferredCandidates,
      ...fifoCandidates.filter((id) => isBoosted(profiles.get(id), now)),
      ...fifoCandidates.filter((id) => !isBoosted(profiles.get(id), now)),
    ];

    // First candidate who is mutually compatible and not blocked either way.
    let peer: string | null = null;
    for (const candidate of rankedCandidates) {
      if (!isMutuallyCompatible(mine, profiles.get(candidate))) continue;
      if (!(await isBlockedEitherWay(tx, uid, candidate))) {
        peer = candidate;
        break;
      }
    }

    if (peer) {
      // -- Writes --
      const session = createCallSession(
        tx,
        participantSummary(uid, mine),
        participantSummary(peer, profiles.get(peer)),
        mode,
        now
      );
      return { status: "matched", session };
    }

    // Nobody available: wait in the queue. The client listens to this
    // document and either gets a sessionId or times out and leaves.
    tx.set(db().collection("matchmakingQueue").doc(uid), {
      uid,
      mode,
      status: "waiting",
      ...(preferredPeerId ? { preferredPeerId } : {}),
      createdAt: now,
      updatedAt: now,
    });
    tx.set(
      db().collection("publicProfiles").doc(uid),
      { wantsToTalk: true, updatedAt: now },
      { merge: true }
    );
    return { status: "waiting" };
  });
});

export const leaveMatchmakingQueue = onCall(async (request) => {
  const uid = requireAuth(request);

  // Piggybacked housekeeping, same as on join: joins and leaves together are
  // frequent enough to keep the queue clean without a scheduled job.
  await sweepStaleQueueEntries();

  await db().runTransaction(async (tx) => {
    const entry = await tx.get(db().collection("matchmakingQueue").doc(uid));
    // Only a waiting entry is removed. A `matched` entry means pairing has
    // already happened — leaving then is handled by ending the call.
    if (entry.exists && entry.get("status") === "waiting") {
      tx.delete(entry.ref);
    }
    tx.set(
      db().collection("publicProfiles").doc(uid),
      { wantsToTalk: false, updatedAt: Timestamp.now() },
      { merge: true }
    );
  });
  return { left: true };
});

/**
 * Removes queue entries abandoned by crashed or suspended clients, and — for
 * entries that were still advertising — withdraws their owner's `wantsToTalk`
 * flag: a stale flag is a "Talk to Him" invitation nobody is behind, and
 * nothing else ever clears it for a client that died mid-wait.
 *
 * Runs opportunistically on every join and leave — cheap and cron-free.
 *
 * A transaction, not a query-then-batch: the moment between reading a stale
 * entry and deleting it is exactly when its owner may rejoin, and a blind
 * batched delete would destroy the fresh entry and un-advertise a real
 * waiter. Inside a transaction that rejoin conflicts with the read set, the
 * sweep re-runs, sees a fresh createdAt, and leaves the entry alone.
 */
async function sweepStaleQueueEntries(): Promise<number> {
  return db().runTransaction(async (tx) => {
    const staleBefore = Timestamp.fromMillis(Date.now() - 2 * QUEUE_ENTRY_TTL_MS);
    const stale = await tx.get(
      db()
        .collection("matchmakingQueue")
        .where("createdAt", "<", staleBefore)
        .limit(50)
    );
    if (stale.empty) return 0;

    const now = Timestamp.now();
    for (const entry of stale.docs) {
      tx.delete(entry.ref);
      // Only a waiting entry is advertised; a stale `matched` entry already
      // had its owner's flag cleared at pairing time.
      if (entry.get("status") === "waiting") {
        tx.set(
          db().collection("publicProfiles").doc(entry.id),
          { wantsToTalk: false, updatedAt: now },
          { merge: true }
        );
      }
    }
    return stale.size;
  });
}
