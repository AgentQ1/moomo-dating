/**
 * Blocking and reporting.
 *
 * Both are callables rather than direct writes so their guarantees hold
 * against tampered clients:
 *  - a block ALWAYS cascades (matches and conversations removed, live calls
 *    ended) — a half-block that leaves the chat open would be a safety bug;
 *  - reports are rate-limited and validated server-side.
 *
 * Unblocking stays a plain client delete of the block document — it cascades
 * nothing by design (unblock is not undo).
 */
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";
import {
  db,
  requireAuth,
  requireString,
  pairKey,
  conversationIdFor,
  historyRef,
  REPORT_REASONS,
  REPORTS_PER_DAY_LIMIT,
  BLOCKS_PER_DAY_LIMIT,
} from "./shared";

export const blockUser = onCall(async (request) => {
  const uid = requireAuth(request);
  const blockedUserId = requireString(request.data?.blockedUserId, "blockedUserId");
  if (blockedUserId === uid) {
    throw new HttpsError("invalid-argument", "You cannot block yourself.");
  }
  // Denormalised so the Blocked list can still name them after every other
  // surface forgets they existed.
  const displayName =
    typeof request.data?.displayName === "string" &&
    request.data.displayName.length > 0 &&
    request.data.displayName.length <= 100
      ? (request.data.displayName as string)
      : "Someone";

  const now = Timestamp.now();

  // Abuse brake, same spirit as the report cap: no legitimate user blocks
  // fifty people in a day, but a script harvesting the cascade's writes
  // might. Never a bar to blocking someone who is actually harassing you.
  const since = Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000);
  const recentBlocks = await db()
    .collection("blocks")
    .doc(uid)
    .collection("blocked")
    .where("createdAt", ">", since)
    .count()
    .get();
  if (recentBlocks.data().count >= BLOCKS_PER_DAY_LIMIT) {
    throw new HttpsError(
      "resource-exhausted",
      "Too many blocks today. If someone is harassing you, please also report them."
    );
  }

  // Step 1 — the block document, first and atomically with the match/session
  // teardown: from this instant matchmaking refuses the pair.
  await db().runTransaction(async (tx) => {
    const matchRef = db().collection("matches").doc(pairKey(uid, blockedUserId));

    // Any live call between the pair ends now.
    const activeSessions = await tx.get(
      db()
        .collection("callSessions")
        .where("participantIds", "array-contains", uid)
        .where("status", "==", "active")
        .limit(25)
    );

    tx.set(
      db().collection("blocks").doc(uid).collection("blocked").doc(blockedUserId),
      { displayName, createdAt: now }
    );
    tx.delete(matchRef);
    // The conversation document dies atomically with the block. Its messages
    // are swept afterwards (step 2) — but once the parent is gone, rules
    // already refuse every read and write to the thread, so a crash between
    // the two steps cannot leave the chat open.
    tx.delete(
      db().collection("conversations").doc(conversationIdFor(uid, blockedUserId))
    );

    for (const session of activeSessions.docs) {
      const ids = session.get("participantIds") as string[];
      if (!ids.includes(blockedUserId)) continue;
      const startedAt = session.get("startedAt") as Timestamp;
      const durationSeconds = Math.max(
        0,
        Math.min(
          (now.toMillis() - startedAt.toMillis()) / 1000,
          (session.get("maxDurationSeconds") as number) ?? 180
        )
      );
      tx.update(session.ref, {
        status: "ended",
        endedAt: now,
        endedBy: uid,
        durationSeconds,
      });
      const participants = session.get("participants") ?? {};
      tx.set(historyRef(uid, session.id), {
        sessionId: session.id,
        peer: participants[blockedUserId] ?? { uid: blockedUserId, displayName },
        mode: session.get("mode") ?? "voice",
        startedAt,
        durationSeconds,
        endReason: "blocked",
        outcome: "blocked",
        updatedAt: now,
      }, { merge: true });
      // The blocked person sees an ordinary ended call — never "blocked".
      // Merge without touching outcome: if they somehow decided already,
      // their record keeps saying what they did.
      tx.set(historyRef(blockedUserId, session.id), {
        sessionId: session.id,
        peer: participants[uid] ?? { uid, displayName: "Someone" },
        mode: session.get("mode") ?? "voice",
        startedAt,
        durationSeconds,
        endReason: "ended",
        updatedAt: now,
      }, { merge: true });
    }
  });

  // Step 2 — the orphaned messages. The parent conversation document was
  // deleted inside the transaction above; `recursiveDelete` (which cannot run
  // inside a transaction) sweeps what remains underneath it. If this crashes
  // mid-way nothing is exposed: without the parent document the rules refuse
  // every read and write to the thread, blocked pairs are refused outright,
  // and a retried block completes the cleanup.
  await db().recursiveDelete(
    db().collection("conversations").doc(conversationIdFor(uid, blockedUserId))
  );

  return { blocked: true };
});

export const reportUser = onCall(async (request) => {
  const uid = requireAuth(request);
  const reportedUserId = requireString(request.data?.reportedUserId, "reportedUserId");
  if (reportedUserId === uid) {
    throw new HttpsError("invalid-argument", "You cannot report yourself.");
  }
  const reason = requireString(request.data?.reason, "reason");
  if (!(REPORT_REASONS as readonly string[]).includes(reason)) {
    throw new HttpsError("invalid-argument", "Invalid reason.");
  }
  const details =
    typeof request.data?.details === "string" && request.data.details.length > 0
      ? (request.data.details as string).slice(0, 2000)
      : null;
  const reportedDisplayName =
    typeof request.data?.reportedDisplayName === "string" &&
    request.data.reportedDisplayName.length > 0 &&
    request.data.reportedDisplayName.length <= 100
      ? (request.data.reportedDisplayName as string)
      : null;

  // Abuse brake. Legitimate use never gets near it.
  const since = Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000);
  const recent = await db()
    .collection("reports")
    .where("reporterId", "==", uid)
    .where("createdAt", ">", since)
    .count()
    .get();
  if (recent.data().count >= REPORTS_PER_DAY_LIMIT) {
    throw new HttpsError(
      "resource-exhausted",
      "Too many reports today. If this is urgent, contact support."
    );
  }

  const ref = await db().collection("reports").add({
    reporterId: uid,
    reportedId: reportedUserId,
    ...(reportedDisplayName ? { reportedDisplayName } : {}),
    reason,
    ...(details ? { details } : {}),
    // Moderation workflow state. Only the Admin SDK ever reads or moves it.
    status: "open",
    createdAt: Timestamp.now(),
  });

  return { reportId: ref.id };
});
