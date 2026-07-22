/**
 * After-call decisions, and the only code path that can mint a match.
 *
 * Invariants:
 *  - A match exists if and only if both participants of a real call session
 *    liked each other. `createMatchOnMutualLike` runs only inside this
 *    transaction — it is not callable, and rules deny client writes.
 *  - A decision is never revealed to the other person. "They passed" and
 *    "they haven't decided" are indistinguishable from the outside; both
 *    surface as `likeSent`. Decisions live in a rules-closed subcollection.
 *  - Matches are keyed by the pair (sorted uids), so a repeat call between
 *    the same two people returns the existing match instead of a duplicate.
 *  - A block severs the pair for decisions too: once either user has blocked
 *    the other — even after the session was created — no decision on that
 *    session writes anything or mints (or resurrects) a match/conversation.
 *  - A pass severs the pair for FUTURE pairing: it writes a server-owned
 *    passes/{uid}/passed/{peer} tombstone that matchmaking and discovery
 *    exclude by, in both directions. Unlike a block it tears nothing down —
 *    the pair simply never recurs. (An unmatch is deliberately different:
 *    both people liked each other once, so the pair may meet again.)
 */
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";
import { callable } from "./options";
import {
  db,
  requireAuth,
  requireString,
  assertParticipant,
  peerOf,
  pairKey,
  conversationIdFor,
  historyRef,
  writeNotification,
  isBlockedEitherWay,
  passRef,
  ParticipantSummary,
} from "./shared";
import { enforceRateLimit } from "./ratelimit";
import { requireEnabled } from "./runtime";

interface MatchPayload {
  id: string;
  conversationId: string;
  createdAtMillis: number;
  candidate: ParticipantSummary;
}

/**
 * Mints the match, its conversation, both notifications, and stamps both
 * users' call history. One transaction with the decision write that proved
 * mutuality — the match and its conversation can never exist half-made.
 */
function createMatchOnMutualLike(
  tx: FirebaseFirestore.Transaction,
  sessionId: string,
  uid: string,
  peer: string,
  participants: Record<string, ParticipantSummary>,
  now: Timestamp
): MatchPayload {
  const matchId = pairKey(uid, peer);
  const conversationId = conversationIdFor(uid, peer);
  const participantIds = [uid, peer].sort();

  tx.create(db().collection("matches").doc(matchId), {
    participantIds,
    participants,
    conversationId,
    sourceSessionId: sessionId,
    createdAt: now,
  });

  createConversation(tx, conversationId, matchId, participantIds, participants, now);

  const mine = participants[uid];
  const theirs = participants[peer];
  writeNotification(
    tx,
    uid,
    "match",
    `It's a match with ${theirs?.displayName ?? "someone"}!`,
    "You both said yes. Say hi in Chat."
  );
  writeNotification(
    tx,
    peer,
    "match",
    `It's a match with ${mine?.displayName ?? "someone"}!`,
    "You both said yes. Say hi in Chat."
  );

  return {
    id: matchId,
    conversationId,
    createdAtMillis: now.toMillis(),
    candidate: theirs ?? ({ uid: peer, displayName: "Someone", age: null, city: null, gender: null, photoPath: null } as ParticipantSummary),
  };
}

/** One conversation per match, created with it. Internal only. */
function createConversation(
  tx: FirebaseFirestore.Transaction,
  conversationId: string,
  matchId: string,
  participantIds: string[],
  participants: Record<string, ParticipantSummary>,
  now: Timestamp
): void {
  tx.create(db().collection("conversations").doc(conversationId), {
    participantIds,
    participants,
    matchId,
    createdAt: now,
    // Set so the conversation appears in `orderBy(lastMessageAt)` from the
    // first moment; documents missing an ordered field vanish from queries.
    lastMessageAt: now,
    unreadCounts: Object.fromEntries(participantIds.map((id) => [id, 0])),
  });
}

export const submitCallDecision = onCall(callable(20), async (request) => {
  const uid = requireAuth(request);
  const sessionId = requireString(request.data?.sessionId, "sessionId");
  const decision = requireString(request.data?.decision, "decision");
  if (decision !== "like" && decision !== "pass") {
    throw new HttpsError("invalid-argument", "Invalid decision.");
  }

  // Maintenance-gated only (no feature flag: refusing decisions while calls
  // stay up would strand finished calls), and rate-limited — a decision is
  // the heaviest post-call transaction.
  await requireEnabled("submitCallDecision");
  await enforceRateLimit(uid, "submitCallDecision");

  // Deliberately NOT gated on session status:
  //  - "ended only" would break the tolerated race with endCallSession (the
  //    client fires both; calls.ts already merges outcomes for exactly this
  //    reason), and a mid-call like is harmless — it can mint nothing without
  //    the peer's own genuine like.
  //  - "blocked-ended" is not detectable from the session document by design
  //    (it never records who blocked, only ended/endedBy); the transaction-time
  //    block-registry check below is strictly stronger — it also covers blocks
  //    placed outside any call. After an unblock, an old session behaves like
  //    any unblocked pair, which matches "unblock restores discovery".
  return db().runTransaction(async (tx) => {
    const now = Timestamp.now();
    const sessionRef = db().collection("callSessions").doc(sessionId);
    const session = await tx.get(sessionRef);
    const participantIds = assertParticipant(session, uid);
    const peer = peerOf(participantIds, uid);

    const myDecisionRef = sessionRef.collection("decisions").doc(uid);
    const peerDecisionRef = sessionRef.collection("decisions").doc(peer);
    const matchRef = db().collection("matches").doc(pairKey(uid, peer));
    const conversationRef = db()
      .collection("conversations")
      .doc(conversationIdFor(uid, peer));

    const [myDecision, peerDecision, existingMatch, existingConversation, blocked] =
      await Promise.all([
        tx.get(myDecisionRef),
        tx.get(peerDecisionRef),
        tx.get(matchRef),
        tx.get(conversationRef),
        isBlockedEitherWay(tx, uid, peer),
      ]);

    // A block placed at any point — including after this session was created —
    // severs the pair. Checked inside the transaction so a block and a racing
    // like serialize: whichever commits second sees the other. When blocked,
    // nothing is written (the blocker's history may already say "blocked" and
    // no stored decision may later complete a mutual like), and no match or
    // conversation is minted or resurrected. The response is deliberately the
    // ordinary one: being blocked is silent, so a like from the blocked side
    // must look exactly like "peer hasn't decided". Refusing with an error
    // here would leak the block.
    if (blocked) {
      return { outcome: decision === "like" ? "likeSent" : "passed" };
    }

    // Decisions are one-shot. A retry with the same value is idempotent; a
    // changed mind is refused — the UI never offers it, so only a tampered
    // client asks.
    if (myDecision.exists && myDecision.get("decision") !== decision) {
      throw new HttpsError("failed-precondition", "Already decided.");
    }
    if (!myDecision.exists) {
      tx.create(myDecisionRef, { uid, decision, decidedAt: now });
    }

    const participants = (session.get("participants") ?? {}) as Record<
      string,
      ParticipantSummary
    >;

    if (decision === "pass") {
      // The pair-level tombstone matchmaking and discovery exclude by: a pass
      // is a recorded "not interested", and the queue must never put this
      // person back on a live call with someone they turned down. A set, not
      // a create — the decision retry above may land here twice.
      tx.set(passRef(uid, peer), { sessionId, createdAt: now }, { merge: true });
      tx.set(
        historyRef(uid, sessionId),
        { outcome: "passed", updatedAt: now },
        { merge: true }
      );
      return { outcome: "passed" };
    }

    // A like. Mutual only if the peer has already liked.
    const peerLiked = peerDecision.exists && peerDecision.get("decision") === "like";

    if (!peerLiked) {
      // Covers both "peer undecided" and "peer passed" — deliberately
      // indistinguishable. If the peer likes later, THEIR call to this
      // function creates the match and our listener delivers it.
      tx.set(
        historyRef(uid, sessionId),
        { outcome: "liked", updatedAt: now },
        { merge: true }
      );
      return { outcome: "likeSent" };
    }

    // Mutual. Repeat pairs reuse the existing match — never a duplicate.
    let match: MatchPayload;
    if (existingMatch.exists) {
      match = {
        id: existingMatch.id,
        conversationId: existingMatch.get("conversationId"),
        createdAtMillis: (existingMatch.get("createdAt") as Timestamp).toMillis(),
        candidate:
          participants[peer] ??
          ({ uid: peer, displayName: "Someone", age: null, city: null, gender: null, photoPath: null } as ParticipantSummary),
      };
      // The conversation may have been removed by an old block since undone;
      // recreate it so the match is usable. (A pair that is blocked right now
      // cannot reach this code: the transaction-time check above returned.)
      if (!existingConversation.exists) {
        createConversation(
          tx,
          match.conversationId,
          match.id,
          [uid, peer].sort(),
          participants,
          now
        );
      }
    } else {
      match = createMatchOnMutualLike(tx, sessionId, uid, peer, participants, now);
    }

    tx.set(
      historyRef(uid, sessionId),
      { outcome: "matched", updatedAt: now },
      { merge: true }
    );
    tx.set(
      historyRef(peer, sessionId),
      { outcome: "matched", updatedAt: now },
      { merge: true }
    );

    return { outcome: "matched", match };
  });
});
