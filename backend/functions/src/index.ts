/**
 * Moomo backend — Cloud Functions entry point.
 *
 * Deploys to Firebase project `moomo-c7a37` ONLY. `moomoios-2026` is the
 * Moomo AI app and must never receive these (guarded in .firebaserc; verify
 * `firebase use` before every deploy).
 *
 * App Check is not enforced yet (Phase 5): every callable currently accepts
 * requests from any client holding a valid Firebase Auth token. Flip
 * `enforceAppCheck: true` per-callable once the iOS app registers App Attest.
 */
import { initializeApp } from "firebase-admin/app";

initializeApp();

export { joinMatchmakingQueue, leaveMatchmakingQueue } from "./matchmaking";
export { endCallSession } from "./calls";
export { getCallMediaToken } from "./media";
export { submitCallDecision } from "./decisions";
export { blockUser, reportUser } from "./safety";
export { activateBoost } from "./boost";
export { sendSystemNotification } from "./notifications";
export { onMessageCreated } from "./chat";
export { deleteAccount } from "./account";
export { resolveReport } from "./moderation";
