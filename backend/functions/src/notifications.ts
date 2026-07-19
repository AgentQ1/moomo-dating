/**
 * System notifications.
 *
 * Match notifications are written inside the decision transaction
 * (decisions.ts); this callable exists for operational announcements only
 * and requires the `admin` custom claim — an ordinary account calling it is
 * refused. Nothing client-reachable may write into another user's feed.
 */
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { db, requireString, writeNotification } from "./shared";

export const sendSystemNotification = onCall(async (request) => {
  if (request.auth?.token?.admin !== true) {
    throw new HttpsError("permission-denied", "Admin only.");
  }
  const userId = requireString(request.data?.userId, "userId");
  const title = requireString(request.data?.title, "title", 200);
  const body = requireString(request.data?.body, "body", 1000);

  const batch = db().batch();
  writeNotification(batch, userId, "system", title, body);
  await batch.commit();

  return { sent: true };
});
