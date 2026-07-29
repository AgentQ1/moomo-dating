/**
 * Matchmaking: one queue document per user, paired inside a transaction.
 *
 * The client may only READ its own `matchmakingQueue/{uid}` document — every
 * write happens here. Pairing and session creation are one transaction, so two
 * users can never both "win" the same partner.
 *
 * `createCallSession` is deliberately internal, not a callable: a client that
 * could create call sessions could forge call history with anyone.
 *
 * Scale design (production-readiness audit P1-2). The original queue was a
 * single FIFO: every joiner's transaction read the same ten oldest entries,
 * so concurrent joins serialized on one queue head and retried each other
 * into the ground. Three changes remove that:
 *
 *  1. SHARDED WAITING POOL. Each waiting entry carries a random
 *     `shard` (0..QUEUE_SHARD_COUNT-1). A joiner scans shards starting from a
 *     random one and stops as soon as it has a candidate window, so
 *     concurrent joiners mostly read DIFFERENT documents and their
 *     transactions stop conflicting. With a sparse queue the scan falls
 *     through every shard and behaves exactly like the old single queue —
 *     contention relief scales up with load, correctness never depends on it.
 *     Fairness becomes approximate FIFO (oldest-first within the gathered
 *     window); strict global FIFO is exactly the hotspot being removed.
 *
 *  2. PROFILE READS OUTSIDE THE TRANSACTION. Compatibility/boost data comes
 *     from `publicProfiles`, which every client heartbeats. Reading those
 *     documents transactionally put them in the read-set, so ANY candidate's
 *     presence heartbeat aborted the pairing transaction — a hidden
 *     contention multiplier. Profiles are now read non-transactionally
 *     (staleness of seconds is harmless for preferences/boosts); the
 *     transaction's read-set is queue entries and block/pass documents only.
 *     Block checks deliberately STAY transactional — "blocked pairs are
 *     never paired" is a safety invariant and must serialize with blockUser.
 *     Pass tombstones ride the same transactional read: "a passed pair is
 *     never re-paired" is a user-choice invariant of the same shape.
 *
 *  3. NO PER-REQUEST SWEEP. Stale-entry hygiene moved to the scheduled
 *     `sweepMatchmakingQueue` (every minute); joins and leaves no longer run
 *     a collection-scan transaction that contended with pairing. Pairing
 *     already filters stale entries by TTL, so hygiene needs no join-time
 *     hook for correctness.
 *
 * Retries are bounded (maxAttempts: 5) and every attempt beyond the first is
 * logged as `matchmaking_txn_retry` — the observability plan alerts when the
 * retry rate climbs (contention onset).
 */
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { Timestamp } from "firebase-admin/firestore";
import { callable, scheduled } from "./options";
import {
  db,
  requireAuth,
  requireString,
  isBlockedEitherWay,
  hasPassedEitherWay,
  participantSummary,
  ParticipantSummary,
  CALL_MODES,
  CallMode,
  SPEED_CALL_SECONDS,
  QUEUE_ENTRY_TTL_MS,
  activityBucketFloor,
  callInviteRef,
} from "./shared";
import {
  PublicProfile,
  isMutuallyCompatible,
  isBoosted,
} from "./compatibility";
import { fanOutRingInvites, sweepExpiredRingInvites } from "./ring";
import { enforceRateLimit } from "./ratelimit";
import { requireEnabled } from "./runtime";
import { logEvent } from "./observability";

export interface PairedSession {
  sessionId: string;
  mode: CallMode;
  startedAtMillis: number;
  maxDurationSeconds: number;
  participants: Record<string, ParticipantSummary>;
}

/**
 * How many shards the waiting pool spreads across. Read per call so the
 * emulator tests can pin it (1 = the old deterministic FIFO); production
 * defaults to 8 — at the audit's Viral rate (~200 joins/s) that keeps
 * per-shard contention near the comfortable single-digit range.
 */
function shardCount(): number {
  const raw = Number(process.env.QUEUE_SHARD_COUNT);
  return Number.isInteger(raw) && raw >= 1 && raw <= 64 ? raw : 8;
}

/** Candidate window per join — same breadth as the old FIFO head. */
const CANDIDATE_WINDOW = 10;

/**
 * Waiting and matched entries age out on DIFFERENT clocks (see
 * sweepStaleQueueEntries). A waiting entry past 2× the pairing TTL is a dead
 * client. A matched entry's createdAt is its pairing time and the call it
 * points at runs up to SPEED_CALL_SECONDS — it is presumed live (and its
 * owner busy — the ring fan-out shares this heuristic) until the call clock
 * plus reconnect grace has certainly expired.
 */
const WAITING_STALE_MS = 2 * QUEUE_ENTRY_TTL_MS;
export const MATCHED_STALE_MS = (SPEED_CALL_SECONDS + 90) * 1000;

/**
 * Creates the server-owned call session and retires both queue entries.
 * Runs inside the pairing transaction (and acceptCallInvite's, in ring.ts —
 * exported for exactly that reuse) — never a callable on its own.
 */
export function createCallSession(
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

export const joinMatchmakingQueue = onCall(callable(20), async (request) => {
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

  await requireEnabled("joinMatchmakingQueue", "matchmakingEnabled");
  await enforceRateLimit(uid, "joinMatchmakingQueue");

  let attempts = 0;
  const result = await db().runTransaction(
    async (tx) => {
      attempts += 1;
      const now = Timestamp.now();
      const staleBefore = Timestamp.fromMillis(now.toMillis() - QUEUE_ENTRY_TTL_MS);

      // -- Reads first (Admin transactions require all reads before writes) --

      // Idempotency: a duplicate join (client retry after a network timeout)
      // must return the session the first join already created, not enqueue
      // over it and orphan the peer.
      const myEntry = await tx.get(db().collection("matchmakingQueue").doc(uid));
      if (myEntry.exists && myEntry.get("status") === "matched") {
        const existingSessionId = myEntry.get("sessionId") as string | undefined;
        if (existingSessionId) {
          const existingSession = await tx.get(
            db().collection("callSessions").doc(existingSessionId)
          );
          // Mode must match: a duplicate of the SAME request returns the
          // same session, but a video join must never be handed a live
          // voice session (the client labels the call with the mode it
          // asked for).
          if (
            existingSession.exists &&
            existingSession.get("status") === "active" &&
            existingSession.get("mode") === mode
          ) {
            return {
              status: "matched" as const,
              session: {
                sessionId: existingSessionId,
                mode: (existingSession.get("mode") as CallMode) ?? mode,
                startedAtMillis: (existingSession.get("startedAt") as Timestamp).toMillis(),
                maxDurationSeconds:
                  (existingSession.get("maxDurationSeconds") as number) ??
                  SPEED_CALL_SECONDS,
                participants: (existingSession.get("participants") ??
                  {}) as Record<string, ParticipantSummary>,
              },
              rejoined: true,
            };
          }
        }
      }

      // The waiting pool, shard by shard from a random start, oldest first
      // within each shard. Stop as soon as the window is full: under load
      // the first shard fills it and the read-set stays one shard wide.
      const shards = shardCount();
      const startShard = Math.floor(Math.random() * shards);
      type QueueEntry = FirebaseFirestore.QueryDocumentSnapshot;
      const windowEntries: QueueEntry[] = [];
      let shardsScanned = 0;
      for (let offset = 0; offset < shards; offset += 1) {
        const shard = (startShard + offset) % shards;
        const shardSnap = await tx.get(
          db()
            .collection("matchmakingQueue")
            .where("status", "==", "waiting")
            .where("mode", "==", mode)
            .where("shard", "==", shard)
            // The TTL bound lives IN the query: dead-client entries (past
            // the TTL, not yet swept) must not fill the limited window and
            // hide the fresh waiters sorted behind them.
            .where("createdAt", ">=", staleBefore)
            .orderBy("createdAt", "asc")
            .limit(CANDIDATE_WINDOW)
        );
        shardsScanned += 1;
        windowEntries.push(...shardSnap.docs);
        if (windowEntries.length >= CANDIDATE_WINDOW) break;
      }

      // "Talk to Him": the featured person is asked first — but only if they
      // are genuinely waiting. Nothing is simulated on their behalf. A direct
      // document read, so sharding never hides the invited person.
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
      // Oldest-first across the gathered window, whatever shard order the
      // scan happened to visit — keeps waiting time roughly fair.
      const orderedEntries = [...windowEntries].sort(
        (a, b) =>
          (a.get("createdAt") as Timestamp).toMillis() -
          (b.get("createdAt") as Timestamp).toMillis()
      );
      for (const entry of orderedEntries) {
        const candidate = entry.get("uid") as string;
        if (candidate === uid || preferredCandidates.includes(candidate)) continue;
        if ((entry.get("createdAt") as Timestamp) < staleBefore) continue;
        fifoCandidates.push(candidate);
      }

      // Public projections for the joiner and every candidate — deliberately
      // NON-transactional reads (see the header): compatibility comes from
      // gender + interestedIn, boost ranking from boostedUntil, and the
      // participant summaries from the rest. Seconds-stale is harmless here,
      // and keeping these out of the read-set stops every candidate's
      // presence heartbeat from aborting this transaction.
      const profileIds = [uid, ...preferredCandidates, ...fifoCandidates];
      const profileSnaps = await db().getAll(
        ...profileIds.map((id) => db().collection("publicProfiles").doc(id))
      );
      const profiles = new Map<string, PublicProfile>(
        profileIds.map((id, index) => [id, profileSnaps[index].data()])
      );
      const mine = profiles.get(uid);

      // Ranking: an explicit "Talk to Him" invitation first, then waiting
      // users with an ACTIVE boost (what the boost screen promises), then
      // everyone else — both groups oldest-first.
      const rankedCandidates = [
        ...preferredCandidates,
        ...fifoCandidates.filter((id) => isBoosted(profiles.get(id), now)),
        ...fifoCandidates.filter((id) => !isBoosted(profiles.get(id), now)),
      ];

      // First candidate who is mutually compatible, not blocked either way,
      // and never passed on either way. The block check is transactional on
      // purpose — it serializes with blockUser so a racing block can never be
      // paired past. The pass check rides the same pattern: a pass is a
      // recorded "not interested", and re-pairing the pair would put someone
      // back on a live call with a person they turned down.
      let peer: string | null = null;
      for (const candidate of rankedCandidates) {
        if (!isMutuallyCompatible(mine, profiles.get(candidate))) continue;
        if (await isBlockedEitherWay(tx, uid, candidate)) continue;
        if (await hasPassedEitherWay(tx, uid, candidate)) continue;
        peer = candidate;
        break;
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
        return { status: "matched" as const, session, shardsScanned };
      }

      // Nobody available: wait in the queue, in a random shard. The client
      // listens to this document and either gets a sessionId or times out
      // and leaves.
      tx.set(db().collection("matchmakingQueue").doc(uid), {
        uid,
        mode,
        status: "waiting",
        shard: Math.floor(Math.random() * shards),
        ...(preferredPeerId ? { preferredPeerId } : {}),
        createdAt: now,
        updatedAt: now,
      });
      // `activityBucket` stamped server-side too: a waiting user is active
      // by definition, and the discovery feed's waiting-pool query orders by
      // the bucket — a waiter must never be invisible to the hero card just
      // because their throttled client heartbeat is a few minutes old (or,
      // during rollout, because their app build predates the field).
      tx.set(
        db().collection("publicProfiles").doc(uid),
        { wantsToTalk: true, activityBucket: activityBucketFloor(now), updatedAt: now },
        { merge: true }
      );
      return { status: "waiting" as const, shardsScanned };
    },
    { maxAttempts: 5 }
  );

  if (attempts > 1) {
    logEvent("matchmaking_txn_retry", { uid, mode, attempts });
  }
  const { shardsScanned, rejoined, ...response } = result as typeof result & {
    shardsScanned?: number;
    rejoined?: boolean;
  };
  logEvent(response.status === "matched" ? "matchmaking_paired" : "matchmaking_waiting", {
    uid,
    mode,
    attempts,
    ...(shardsScanned !== undefined ? { shardsScanned } : {}),
    ...(rejoined ? { rejoined } : {}),
  });
  if (response.status === "waiting") {
    // Nobody was waiting — ring a few compatible online users so their
    // foreground app can offer this caller (ring.ts). Awaited so the invites
    // exist before the client settles into its wait, but failure-isolated
    // inside fanOutRingInvites: a broken fan-out degrades to the plain
    // "waiting" experience, never to a failed join.
    await fanOutRingInvites(uid, mode, preferredPeerId);
  }
  return response;
});

export const leaveMatchmakingQueue = onCall(callable(20), async (request) => {
  const uid = requireAuth(request);

  // Never gated by the kill switch or a rate limit: nobody may be trapped
  // in the queue by an outage brake.
  await db().runTransaction(async (tx) => {
    const entry = await tx.get(db().collection("matchmakingQueue").doc(uid));
    const leavingWait = entry.exists && entry.get("status") === "waiting";

    // The rings this wait fanned out die with it — a banner for a caller who
    // already gave up is an invitation to an empty call. Read before any
    // write (Admin transactions require all reads first).
    const ringedUids = leavingWait && Array.isArray(entry.get("ringedUids"))
      ? (entry.get("ringedUids") as unknown[]).filter(
          (peer): peer is string => typeof peer === "string"
        )
      : [];
    const invites = await Promise.all(
      ringedUids.map((peer) => tx.get(callInviteRef(peer)))
    );

    const now = Timestamp.now();
    // Only a waiting entry is removed. A `matched` entry means pairing has
    // already happened — leaving then is handled by ending the call.
    if (leavingWait) {
      tx.delete(entry.ref);
    }
    for (const invite of invites) {
      // Cancel only THIS caller's still-ringing invites — never a newer
      // ring someone else already has out to the same callee.
      if (
        invite.exists &&
        invite.get("status") === "ringing" &&
        invite.get("callerUid") === uid
      ) {
        tx.update(invite.ref, { status: "cancelled", updatedAt: now });
      }
    }
    tx.set(
      db().collection("publicProfiles").doc(uid),
      { wantsToTalk: false, updatedAt: now },
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
 * Scheduled (every minute), NOT run per join/leave: the per-request sweep was
 * a collection-scan transaction contending with every pairing transaction
 * (audit P1-2). Correctness never depended on sweep timing — pairing filters
 * stale entries by TTL — so hygiene can afford a one-minute cadence.
 *
 * A transaction, not a query-then-batch: the moment between reading a stale
 * entry and deleting it is exactly when its owner may rejoin, and a blind
 * batched delete would destroy the fresh entry and un-advertise a real
 * waiter. Inside a transaction that rejoin conflicts with the read set, the
 * sweep re-runs, sees a fresh createdAt, and leaves the entry alone.
 */
async function sweepStaleQueueEntries(): Promise<number> {
  let sweptTotal = 0;
  // Bounded batches so one run can clear a large backlog without ever
  // becoming an unbounded scan inside a single transaction.
  //
  // The thresholds live at module scope (see their comment). Sweeping a
  // matched entry mid-call would void join idempotency — a duplicate join
  // could then double-book someone who is on a live call into a second
  // session — so matched entries wait out MATCHED_STALE_MS.
  for (let batch = 0; batch < 10; batch += 1) {
    const swept = await db().runTransaction(async (tx) => {
      const [staleWaiting, staleMatched] = await Promise.all([
        tx.get(
          db()
            .collection("matchmakingQueue")
            .where("status", "==", "waiting")
            .where("createdAt", "<", Timestamp.fromMillis(Date.now() - WAITING_STALE_MS))
            .limit(25)
        ),
        tx.get(
          db()
            .collection("matchmakingQueue")
            .where("status", "==", "matched")
            .where("createdAt", "<", Timestamp.fromMillis(Date.now() - MATCHED_STALE_MS))
            .limit(25)
        ),
      ]);
      if (staleWaiting.empty && staleMatched.empty) return 0;

      const now = Timestamp.now();
      for (const entry of staleWaiting.docs) {
        tx.delete(entry.ref);
        // A waiting entry is advertised; withdraw the invitation nobody is
        // behind. Matched entries already had the flag cleared at pairing.
        tx.set(
          db().collection("publicProfiles").doc(entry.id),
          { wantsToTalk: false, updatedAt: now },
          { merge: true }
        );
      }
      for (const entry of staleMatched.docs) {
        tx.delete(entry.ref);
      }
      return staleWaiting.size + staleMatched.size;
    });
    sweptTotal += swept;
    if (swept < 50) break;
  }
  return sweptTotal;
}

export const sweepMatchmakingQueue = onSchedule(
  { schedule: "every 1 minutes", ...scheduled(1) },
  async () => {
    const swept = await sweepStaleQueueEntries();
    logEvent("matchmaking_sweep", { swept });
    // Same hygiene cadence for ring invites nobody answered (ring.ts).
    await sweepExpiredRingInvites();
  }
);
