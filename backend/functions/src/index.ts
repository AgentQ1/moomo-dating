/**
 * Moomo backend — Cloud Functions entry point.
 *
 * Deploys to Firebase project `moomo-c7a37` ONLY. `moomoios-2026` is the
 * Moomo AI app and must never receive these (guarded in .firebaserc; verify
 * `firebase use` before every deploy).
 *
 * App Check IS enforced on every callable (see options.ts `callable`):
 * requests without a valid App Check token are refused before any handler
 * runs. Deploy-order matters — register the iOS app (App Attest) and every
 * developer's debug token in Firebase console BEFORE deploying this, or all
 * callables lock real users out. See backend/README.md "App Check".
 */
import { initializeApp } from "firebase-admin/app";

initializeApp();

export {
  joinMatchmakingQueue,
  leaveMatchmakingQueue,
  sweepMatchmakingQueue,
} from "./matchmaking";
export { getDiscoveryFeed } from "./discovery";
export { endCallSession } from "./calls";
export { getCallMediaToken } from "./media";
export { submitCallDecision } from "./decisions";
export { blockUser, reportUser, unmatchUser } from "./safety";
export { activateBoost } from "./boost";
export { sendSystemNotification } from "./notifications";
export { onMessageCreated } from "./chat";
export { deleteAccount } from "./account";
export { resolveReport } from "./moderation";
export { syncBaybeKpisToNotion } from "./notionKpiSync";
