/**
 * Call lifecycle: ending a session and writing each participant's private
 * history projection.
 *
 * History lives at `users/{uid}/callHistory/{sessionId}` — one document per
 * user per call — because the two participants must not share a record:
 * the person who blocked sees "Blocked", the person who was blocked sees an
 * ordinary "Call ended" and is never told. A shared record cannot do that.
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
  historyRef,
  END_REASONS,
  EndReason,
  SPEED_CALL_SECONDS,
} from "./shared";

export const endCallSession = onCall(callable(20), async (request) => {
  const uid = requireAuth(request);
  const sessionId = requireString(request.data?.sessionId, "sessionId");
  const reason = requireString(request.data?.reason, "reason") as EndReason;
  if (!END_REASONS.includes(reason)) {
    throw new HttpsError("invalid-argument", "Invalid end reason.");
  }

  await db().runTransaction(async (tx) => {
    const sessionRef = db().collection("callSessions").doc(sessionId);
    const session = await tx.get(sessionRef);
    const participantIds = assertParticipant(session, uid);
    const peer = peerOf(participantIds, uid);

    // Both sides end their call independently (each runs its own clock), so
    // the second end must be a clean no-op, not an error.
    if (session.get("status") === "ended") {
      return;
    }

    // A decision may already have merged an outcome into a history doc
    // (the two callables race); an existing outcome must never be clobbered
    // back to "undecided".
    const [myHistory, peerHistory] = await Promise.all([
      tx.get(historyRef(uid, sessionId)),
      tx.get(historyRef(peer, sessionId)),
    ]);

    const now = Timestamp.now();
    const startedAt = session.get("startedAt") as Timestamp;
    const maxDuration =
      (session.get("maxDurationSeconds") as number) ?? SPEED_CALL_SECONDS;
    const durationSeconds = Math.max(
      0,
      Math.min((now.toMillis() - startedAt.toMillis()) / 1000, maxDuration)
    );

    // The shared session document stays neutral: status and timing only.
    // Anything one side must not learn (who blocked) never lands here.
    tx.update(sessionRef, {
      status: "ended",
      endedAt: now,
      endedBy: uid,
      durationSeconds,
    });

    const participants = session.get("participants") ?? {};
    const mode = session.get("mode") ?? "voice";

    // The ender's record carries the truth of why.
    tx.set(historyRef(uid, sessionId), {
      sessionId,
      peer: participants[peer] ?? { uid: peer, displayName: "Someone" },
      mode,
      startedAt,
      durationSeconds,
      endReason: reason,
      outcome:
        reason === "blocked"
          ? "blocked"
          : myHistory.get("outcome") ?? "undecided",
      updatedAt: now,
    }, { merge: true });

    // The peer's record never says "blocked" — being blocked is silent.
    tx.set(historyRef(peer, sessionId), {
      sessionId,
      peer: participants[uid] ?? { uid, displayName: "Someone" },
      mode,
      startedAt,
      durationSeconds,
      endReason: reason === "blocked" ? "ended" : reason,
      outcome: peerHistory.get("outcome") ?? "undecided",
      updatedAt: now,
    }, { merge: true });
  });

  return { ended: true };
});
