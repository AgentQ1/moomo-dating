/**
 * Server-side account deletion — the only complete one.
 *
 * The client cannot do this itself: matches, conversations, call sessions,
 * queue entries, and boosts are server-owned (rules deny client writes), so a
 * client-side delete inevitably orphans social data. This callable removes
 * everything the account owns, then the Auth user — Auth last, so a crashed
 * run leaves a signed-in account that can simply retry.
 *
 * Deliberately kept:
 *  - reports (filed by or against this account) — the safety record must
 *    survive the reported account's self-deletion;
 *  - other users' data that merely mentions this account: their private
 *    callHistory projections and their block entries. Those are THEIR records
 *    of THEIR calls and blocks; denormalised display names make them
 *    self-contained once this account's documents are gone.
 */
import { onCall } from "firebase-functions/v2/https";
import { getAuth } from "firebase-admin/auth";
import { getStorage } from "firebase-admin/storage";
import { db, requireAuth } from "./shared";

export const deleteAccount = onCall(async (request) => {
  const uid = requireAuth(request);
  const firestore = db();

  // Pair artifacts: every match and conversation this account is in, with
  // full message threads. Matches and conversations share participantIds, but
  // each is queried independently — a block cascade may have left one without
  // the other.
  const [matches, conversations, sessions] = await Promise.all([
    firestore.collection("matches").where("participantIds", "array-contains", uid).get(),
    firestore.collection("conversations").where("participantIds", "array-contains", uid).get(),
    firestore.collection("callSessions").where("participantIds", "array-contains", uid).get(),
  ]);
  for (const match of matches.docs) {
    await firestore.recursiveDelete(match.ref);
  }
  for (const conversation of conversations.docs) {
    await firestore.recursiveDelete(conversation.ref);
  }
  // Sessions carry this account's denormalised profile summary; their
  // decisions subcollections go with them. The peer's view of the call
  // survives in their own callHistory projection.
  for (const session of sessions.docs) {
    await firestore.recursiveDelete(session.ref);
  }

  // Singleton documents and owned trees.
  await firestore.collection("matchmakingQueue").doc(uid).delete();
  await firestore.collection("boosts").doc(uid).delete();
  await firestore.collection("publicProfiles").doc(uid).delete();
  await firestore.recursiveDelete(firestore.collection("blocks").doc(uid));
  // users/{uid} and everything under it: private/onboarding, callHistory,
  // notifications.
  await firestore.recursiveDelete(firestore.collection("users").doc(uid));

  // Storage photos. `deleteFiles` is a no-op on an empty prefix.
  await getStorage().bucket().deleteFiles({ prefix: `users/${uid}/photos/` });

  // The Auth user goes last: while it exists, the client can retry a
  // partially-failed deletion. Tolerate "already gone" so a retry after a
  // crash between this line and the response still succeeds.
  try {
    await getAuth().deleteUser(uid);
  } catch (error: unknown) {
    if ((error as { code?: string }).code !== "auth/user-not-found") {
      throw error;
    }
  }

  return { deleted: true };
});
