/**
 * Ring invites — the foreground incoming-call banner behind "Talk to Her/Him".
 *
 * When joinMatchmakingQueue finds nobody waiting, the joiner used to just
 * hope somebody else would join within their 30-second patience. The fan-out
 * here actively rings a few compatible ONLINE users instead: each rung
 * user's foreground app shows a banner, the first accepter wins the caller
 * atomically, and both connect through the existing callSessions flow.
 * Foreground/in-app only — no push, no CallKit: a ring reaches exactly the
 * people whose app is open right now, and dies quietly for everyone else.
 *
 * Who gets rung is proximity-ranked (proximity.ts). The pool is already
 * narrowed to compatible, online, non-excluded people and the fan-out reaches
 * only RING_FANOUT_LIMIT of them, so distance decides which of the eligible
 * actually hear a banner — closest first, within the existing invitation and
 * boost tiers. It is strictly an ordering: no one is excluded for distance,
 * and anyone without a shared location keeps their place in the pool.
 *
 * `callInvites/{calleeUid}` is ONE document per callee — the latest ring
 * overwrites a terminal older one, so a client listens to a single document
 * (the same idiom as its matchmakingQueue listener). Server-written only:
 * a client that could write invites could ring anyone, forge an acceptance,
 * or advertise a caller who never asked.
 *
 * acceptCallInvite is the safety-critical path and carries the pairing
 * transaction's invariants unchanged:
 *  - block AND pass checks are INSIDE the transaction — they serialize with
 *    blockUser/submitCallDecision, so a block recorded after the ring went
 *    out still refuses the accept;
 *  - profile reads stay OUT of the transaction read-set (audit P1-2: a
 *    candidate's presence heartbeat must never abort the accept);
 *  - a lost race, an expired ring, a vanished caller, a busy accepter, a
 *    block, and a pass are all the SAME "unavailable" response — being
 *    blocked must stay indistinguishable from bad timing (silent-block
 *    invariant), so unavailability is a successful response, never an error.
 */
import { onCall } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";
import { callable } from "./options";
import {
  db,
  requireAuth,
  callInviteRef,
  isBlockedEitherWay,
  hasPassedEitherWay,
  participantSummary,
  ParticipantSummary,
  isSupportedCallMode,
  CallMode,
  QUEUE_ENTRY_TTL_MS,
  RING_TTL_MS,
  RING_FANOUT_LIMIT,
  RING_POOL,
  RING_SAME_CALLER_COOLDOWN_MS,
  RING_ANY_CALLER_GAP_MS,
  millis,
} from "./shared";
import { PublicProfile, isMutuallyCompatible, isBoosted } from "./compatibility";
import { loadCoarseLocations, sortByProximity } from "./proximity";
import { ONLINE_WINDOW_MS, filterExcluded } from "./discovery";
import { createCallSession, PairedSession, MATCHED_STALE_MS } from "./matchmaking";
import { enforceRateLimit } from "./ratelimit";
import { requireEnabled } from "./runtime";
import { logEvent } from "./observability";

/**
 * How many rung callees the caller's queue entry remembers (`ringedUids`) —
 * accept cancels the sibling rings through this list and leave withdraws
 * them. Union-with-cap so a long wait's repeated fan-outs cannot grow the
 * document without bound; anything that falls off the list simply expires.
 */
const RINGED_UIDS_CAP = 24;

/**
 * What the banner renders about the caller: the session's ParticipantSummary
 * shape plus the verification badge (which session summaries don't carry).
 */
interface InviteCallerSummary extends ParticipantSummary {
  isVerified: boolean;
}

/** The `ringedUids` array of a queue entry, defensively typed. */
function ringedUidsOf(entry: FirebaseFirestore.DocumentSnapshot): string[] {
  const raw = entry.get("ringedUids");
  return Array.isArray(raw)
    ? raw.filter((peer): peer is string => typeof peer === "string")
    : [];
}

/**
 * Who rang this callee within the same-caller cooldown window: the invite's
 * carried `recentCallers` map pruned to the window, plus the current slot
 * holder. `callInvites/{callee}` is one slot the latest ring overwrites, so
 * without this carry a caller's hounding brake would be erased the moment
 * ANY other caller took the slot — two accounts alternating could ring a
 * callee who declined them both at the 30s any-caller floor forever. The
 * pruning bounds the map to however many distinct callers fit in 120s.
 */
function recentCallersOf(
  invite: FirebaseFirestore.DocumentSnapshot,
  now: Timestamp
): Record<string, Timestamp> {
  const carried: Record<string, Timestamp> = {};
  if (!invite.exists) return carried;
  const cutoff = now.toMillis() - RING_SAME_CALLER_COOLDOWN_MS;
  const previous = invite.get("recentCallers");
  if (previous && typeof previous === "object") {
    for (const [caller, rangAt] of Object.entries(
      previous as Record<string, unknown>
    )) {
      const rangAtMillis = millis(rangAt);
      if (rangAtMillis !== null && rangAtMillis > cutoff) {
        carried[caller] = Timestamp.fromMillis(rangAtMillis);
      }
    }
  }
  // The slot holder's updatedAt is their decline/expiry moment — the same
  // instant the direct rule-2 check has always measured the cooldown from.
  const slotCaller = invite.get("callerUid");
  const slotRangAtMillis = millis(invite.get("updatedAt"));
  if (
    typeof slotCaller === "string" &&
    slotRangAtMillis !== null &&
    slotRangAtMillis > cutoff &&
    slotRangAtMillis > (carried[slotCaller]?.toMillis() ?? 0)
  ) {
    carried[slotCaller] = Timestamp.fromMillis(slotRangAtMillis);
  }
  return carried;
}

/**
 * Rings up to RING_FANOUT_LIMIT compatible online users for a caller whose
 * join just landed in the waiting pool. Called by joinMatchmakingQueue AFTER
 * its pairing transaction, awaited before the join returns "waiting".
 *
 * NEVER throws: a broken fan-out degrades the caller to the plain waiting
 * experience (they time out into the existing "No one's free to talk right
 * now" copy), it must not fail the join that triggered it.
 */
export async function fanOutRingInvites(
  callerUid: string,
  mode: CallMode,
  preferredPeerId: string | null
): Promise<void> {
  try {
    const now = Timestamp.now();

    // 1. The candidate pool — the same recency-bucketed scan Discover uses,
    //    plus a direct read of the invited "Talk to Him" person so bucket
    //    ordering can never hide them. Deliberately NON-transactional:
    //    preferences and presence are seconds-stale at worst, and none of
    //    this belongs in any transaction's read-set (audit P1-2).
    const [callerSnap, poolSnap, preferredSnap] = await Promise.all([
      db().collection("publicProfiles").doc(callerUid).get(),
      db()
        .collection("publicProfiles")
        .orderBy("activityBucket", "desc")
        .limit(RING_POOL)
        .get(),
      preferredPeerId
        ? db().collection("publicProfiles").doc(preferredPeerId).get()
        : Promise.resolve(null),
    ]);
    const caller: PublicProfile = callerSnap.data();

    // Only people whose app is plausibly foregrounded right now — a ring
    // has no push behind it, so ringing the offline is ringing nobody.
    // The raw lastActiveAt is read server-side and never leaves here.
    const isOnline = (snapshot: FirebaseFirestore.DocumentSnapshot): boolean => {
      const lastActiveAt = snapshot.get("lastActiveAt");
      return (
        lastActiveAt instanceof Timestamp &&
        now.toMillis() - lastActiveAt.toMillis() < ONLINE_WINDOW_MS
      );
    };

    // Ranking: the explicit invitation first, then actively boosted people
    // (the boost screen's promise), then bucket recency (the pool's order).
    const poolDocs = poolSnap.docs.filter((doc) => doc.id !== preferredPeerId);
    const ordered: FirebaseFirestore.DocumentSnapshot[] = [
      ...(preferredSnap?.exists ? [preferredSnap] : []),
      ...poolDocs.filter((doc) => isBoosted(doc.data(), now)),
      ...poolDocs.filter((doc) => !isBoosted(doc.data(), now)),
    ];
    const eligible = ordered.filter(
      (snapshot) =>
        snapshot.id !== callerUid &&
        isOnline(snapshot) &&
        isMutuallyCompatible(caller, snapshot.data())
    );

    // Proximity decides who actually gets rung. Everyone here is already
    // online and already compatible, so distance is the one thing left that
    // makes a ring worth answering — and RING_FANOUT_LIMIT is smaller than
    // the eligible pool, so this ordering is what "we call the closest
    // people first" means in practice.
    //
    // Sorted WITHIN the tiers above, never across them: the explicit "call
    // this person" invitation stays first and a paid boost keeps its
    // promise. Unlocated people score neutral and keep their pool position
    // (stable sort), so nobody is dropped for not sharing a location.
    const locations = await loadCoarseLocations(
      [callerUid, ...eligible.map((snapshot) => snapshot.id)],
      now
    );
    const callerLocation = locations.get(callerUid) ?? null;
    const byTier = (tier: FirebaseFirestore.DocumentSnapshot[]) =>
      sortByProximity(tier, callerLocation, (doc) => locations.get(doc.id) ?? null);
    const rankedEligible = [
      ...eligible.filter((doc) => doc.id === preferredPeerId),
      ...byTier(
        eligible.filter(
          (doc) => doc.id !== preferredPeerId && isBoosted(doc.data(), now)
        )
      ),
      ...byTier(
        eligible.filter(
          (doc) => doc.id !== preferredPeerId && !isBoosted(doc.data(), now)
        )
      ),
    ];

    // 2. Blocks and pass tombstones, both directions — never ring a person
    //    the queue would refuse to pair (the same batch check Discover uses).
    const { allowed } = await filterExcluded(callerUid, rankedEligible);

    // 3. A banner burst, not a broadcast.
    const targets = allowed.slice(0, RING_FANOUT_LIMIT);

    const callerSummary: InviteCallerSummary = {
      ...participantSummary(callerUid, caller),
      isVerified: caller?.isVerified === true,
    };

    // 4. The write transaction. Re-checks live state transactionally: the
    //    caller must still be waiting, and each target's current invite and
    //    queue entry decide whether this ring may land on them.
    let rung = 0;
    if (targets.length > 0) {
      rung = await db().runTransaction(async (tx) => {
        const now = Timestamp.now();

        // -- Reads first (Admin transactions require reads before writes) --
        const entryRef = db().collection("matchmakingQueue").doc(callerUid);
        const entry = await tx.get(entryRef);
        // Paired or gone between the pairing transaction and this one —
        // ringing now would invite people to a call nobody is behind.
        if (
          !entry.exists ||
          entry.get("status") !== "waiting" ||
          entry.get("mode") !== mode
        ) {
          return 0;
        }

        const [inviteSnaps, queueSnaps] = await Promise.all([
          Promise.all(targets.map((target) => tx.get(callInviteRef(target.id)))),
          Promise.all(
            targets.map((target) =>
              tx.get(db().collection("matchmakingQueue").doc(target.id))
            )
          ),
        ]);

        const survivors: Array<{
          calleeUid: string;
          recentCallers: Record<string, Timestamp>;
        }> = [];
        targets.forEach((target, index) => {
          const invite = inviteSnaps[index];
          // Everyone who rang this callee inside the cooldown window,
          // including the current slot holder — checked here and carried
          // onto any overwrite below, so the brake survives other callers
          // taking the slot in between.
          const recentCallers = recentCallersOf(invite, now);
          if (invite.exists) {
            const updatedAtMillis = millis(invite.get("updatedAt")) ?? 0;
            // A ring still inside its acceptance window is never overwritten…
            if (
              invite.get("status") === "ringing" &&
              (millis(invite.get("expiresAt")) ?? 0) > now.toMillis()
            ) {
              return;
            }
            // …the same caller may not hound a callee who just turned them
            // down (or just heard from them) — the map is pre-pruned to the
            // cooldown window, so presence alone means "too soon"…
            if (recentCallers[callerUid] !== undefined) {
              return;
            }
            // …and nobody's banner fires again moments after the last one,
            // whoever it was from.
            if (updatedAtMillis > now.toMillis() - RING_ANY_CALLER_GAP_MS) {
              return;
            }
          }
          // A fresh `matched` entry means they are (presumed) on a live call
          // — same staleness heuristic as the queue sweep.
          const queueEntry = queueSnaps[index];
          if (
            queueEntry.exists &&
            queueEntry.get("status") === "matched" &&
            (millis(queueEntry.get("updatedAt")) ?? 0) >
              now.toMillis() - MATCHED_STALE_MS
          ) {
            return;
          }
          survivors.push({ calleeUid: target.id, recentCallers });
        });
        if (survivors.length === 0) return 0;

        // -- Writes --
        for (const { calleeUid, recentCallers } of survivors) {
          tx.set(callInviteRef(calleeUid), {
            uid: calleeUid,
            callerUid,
            mode,
            status: "ringing",
            caller: callerSummary,
            createdAt: now,
            expiresAt: Timestamp.fromMillis(now.toMillis() + RING_TTL_MS),
            updatedAt: now,
            // Prior ringers inside the cooldown window (the slot being
            // overwritten included) — never dropped by an overwrite.
            ...(Object.keys(recentCallers).length > 0 ? { recentCallers } : {}),
          });
        }
        const previous = ringedUidsOf(entry);
        const survivorIds = survivors.map((survivor) => survivor.calleeUid);
        tx.update(entryRef, {
          ringedUids: [
            ...previous.filter((peer) => !survivorIds.includes(peer)),
            ...survivorIds,
          ].slice(-RINGED_UIDS_CAP),
          updatedAt: now,
        });
        return survivors.length;
      });
    }

    // Zero rung is fine — the caller just waits out their normal window.
    logEvent("ring_fanout", {
      uid: callerUid,
      mode,
      eligible: allowed.length,
      rung,
      callerLocated: callerLocation !== null,
      ...(preferredPeerId ? { preferred: true } : {}),
    });
  } catch (error) {
    logEvent("ring_fanout", {
      uid: callerUid,
      mode,
      rung: 0,
      error: String(error),
    });
  }
}

type AcceptOutcome =
  | { status: "accepted"; session: PairedSession }
  | { status: "unavailable"; reason: string };

export const acceptCallInvite = onCall(callable(20), async (request) => {
  const uid = requireAuth(request);
  await requireEnabled("acceptCallInvite", "matchmakingEnabled");
  await enforceRateLimit(uid, "acceptCallInvite");

  const result = await db().runTransaction(
    async (tx): Promise<AcceptOutcome> => {
      const now = Timestamp.now();

      // -- Reads first (Admin transactions require all reads before writes) --

      // My invite (the document is keyed by the callee): must still be
      // ringing, inside the acceptance window, and well-formed.
      const invite = await tx.get(callInviteRef(uid));
      const mode = invite.get("mode") as CallMode;
      const callerUid = invite.get("callerUid") as string;
      if (
        !invite.exists ||
        invite.get("status") !== "ringing" ||
        (millis(invite.get("expiresAt")) ?? 0) <= now.toMillis() ||
        // Voice-only rings are unanswerable now. An old one still ringing
        // when the client updated reads as "no live ring" — the same honest
        // dead end as an expired invite — rather than pairing a video
        // client into a voice session.
        !isSupportedCallMode(mode) ||
        typeof callerUid !== "string"
      ) {
        return { status: "unavailable", reason: "no-live-ring" };
      }

      // The caller: must still be genuinely waiting for this exact ring —
      // same mode, entry younger than the TTL that bounds every pairing.
      const callerEntry = await tx.get(
        db().collection("matchmakingQueue").doc(callerUid)
      );
      if (
        !callerEntry.exists ||
        callerEntry.get("status") !== "waiting" ||
        callerEntry.get("mode") !== mode ||
        (millis(callerEntry.get("createdAt")) ?? 0) <
          now.toMillis() - QUEUE_ENTRY_TTL_MS
      ) {
        return { status: "unavailable", reason: "caller-gone" };
      }

      // Me: accepting while already on a live call would double-book me
      // into a second session (the same invariant join idempotency guards).
      const myEntry = await tx.get(db().collection("matchmakingQueue").doc(uid));
      if (myEntry.exists && myEntry.get("status") === "matched") {
        const mySessionId = myEntry.get("sessionId") as string | undefined;
        if (mySessionId) {
          const mySession = await tx.get(
            db().collection("callSessions").doc(mySessionId)
          );
          if (mySession.exists && mySession.get("status") === "active") {
            return { status: "unavailable", reason: "busy" };
          }
        }
      }

      // The safety invariant, transactional on purpose: a block or a pass
      // recorded AFTER the ring went out must still refuse the accept —
      // and look exactly like any other lost race.
      if (
        (await isBlockedEitherWay(tx, uid, callerUid)) ||
        (await hasPassedEitherWay(tx, uid, callerUid))
      ) {
        return { status: "unavailable", reason: "excluded" };
      }

      // The sibling rings this caller has in flight, to withdraw on success.
      const siblingSnaps = await Promise.all(
        ringedUidsOf(callerEntry)
          .filter((peer) => peer !== uid)
          .map((peer) => tx.get(callInviteRef(peer)))
      );

      // Participant summaries from publicProfiles — deliberately
      // NON-transactional (audit P1-2: profile reads stay out of the
      // read-set, so a presence heartbeat can never abort the accept).
      const [myProfile, callerProfile] = await db().getAll(
        db().collection("publicProfiles").doc(uid),
        db().collection("publicProfiles").doc(callerUid)
      );

      // -- Writes --
      const session = createCallSession(
        tx,
        participantSummary(uid, myProfile.data()),
        participantSummary(callerUid, callerProfile.data()),
        mode,
        now
      );
      tx.update(invite.ref, {
        status: "accepted",
        sessionId: session.sessionId,
        respondedAt: now,
        updatedAt: now,
      });
      // The losing rings are withdrawn — but never someone's newer invite
      // from a different caller.
      for (const sibling of siblingSnaps) {
        if (
          sibling.exists &&
          sibling.get("status") === "ringing" &&
          sibling.get("callerUid") === callerUid
        ) {
          tx.update(sibling.ref, { status: "cancelled", updatedAt: now });
        }
      }
      return { status: "accepted", session };
    },
    { maxAttempts: 5 }
  );

  if (result.status === "accepted") {
    logEvent("ring_accepted", {
      uid,
      mode: result.session.mode,
      sessionId: result.session.sessionId,
    });
    return { status: "accepted", session: result.session };
  }
  // The reason stays in the server log for operators; the client response is
  // uniform on purpose (silent-block invariant).
  logEvent("ring_unavailable", { uid, reason: result.reason });
  return { status: "unavailable" };
});

export const declineCallInvite = onCall(callable(20), async (request) => {
  const uid = requireAuth(request);

  // Deliberately NOT kill-switched and NOT rate-limited — the same rationale
  // as leaveMatchmakingQueue: this is the cleanup path, and nobody may be
  // left with a banner they cannot dismiss by an outage brake or a full
  // rate window.
  let declined = false;
  await db().runTransaction(async (tx) => {
    // Re-run from scratch on every attempt (see enforceRateLimit's latch
    // comment for the same pattern).
    declined = false;
    const invite = await tx.get(callInviteRef(uid));
    // Only a live ring is declinable; anything else is a stale retry and a
    // clean no-op.
    if (invite.exists && invite.get("status") === "ringing") {
      const now = Timestamp.now();
      tx.update(invite.ref, {
        status: "declined",
        respondedAt: now,
        updatedAt: now,
      });
      declined = true;
    }
  });
  if (declined) {
    logEvent("ring_declined", { uid });
  }
  return { status: "ok" };
});

/**
 * Flips ringing invites past their acceptance window to "expired". The
 * callee's banner hides itself after `CallInvite.ringSeconds` regardless —
 * this is hygiene for the DOCUMENT, so accept's expiry check and the
 * fan-out's skip rules never reason about ancient rings, and listeners
 * replaying a stale "ringing" doc see a terminal status soon after.
 *
 * Bounded transactional batches, same shape (and same rationale) as
 * sweepStaleQueueEntries: a blind query-then-batch write could clobber an
 * invite accepted between read and write; inside a transaction that accept
 * conflicts, the sweep re-runs and leaves it alone. Runs from
 * sweepMatchmakingQueue's minute cadence.
 */
export async function sweepExpiredRingInvites(): Promise<number> {
  let sweptTotal = 0;
  for (let batch = 0; batch < 10; batch += 1) {
    const swept = await db().runTransaction(async (tx) => {
      const stale = await tx.get(
        db()
          .collection("callInvites")
          .where("status", "==", "ringing")
          .where("expiresAt", "<=", Timestamp.now())
          .limit(50)
      );
      if (stale.empty) return 0;
      const now = Timestamp.now();
      for (const invite of stale.docs) {
        tx.update(invite.ref, { status: "expired", updatedAt: now });
      }
      return stale.size;
    });
    sweptTotal += swept;
    if (swept < 50) break;
  }
  if (sweptTotal > 0) {
    logEvent("ring_expired_swept", { swept: sweptTotal });
  }
  return sweptTotal;
}
