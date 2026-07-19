/**
 * Report moderation. Admin custom claim only — the same gate as
 * sendSystemNotification. Ordinary accounts (including the reporter) can
 * never read or move a report.
 *
 * Workflow model on `reports/{id}`:
 *   status: "open" → "resolved" | "dismissed"
 *   resolution, resolvedBy, resolvedAt stamped on close.
 *
 * This is the primitive a review tool drives; it exists so moderation work
 * needs no schema migration and no Admin-SDK ad-hockery.
 */
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";
import { db, requireString } from "./shared";

export const REPORT_RESOLUTIONS = ["resolved", "dismissed"] as const;

export const resolveReport = onCall(async (request) => {
  if (request.auth?.token?.admin !== true) {
    throw new HttpsError("permission-denied", "Admin only.");
  }
  const reportId = requireString(request.data?.reportId, "reportId");
  const status = requireString(request.data?.status, "status");
  if (!(REPORT_RESOLUTIONS as readonly string[]).includes(status)) {
    throw new HttpsError("invalid-argument", "Invalid status.");
  }
  const resolution =
    typeof request.data?.resolution === "string" && request.data.resolution.length > 0
      ? (request.data.resolution as string).slice(0, 2000)
      : null;

  const ref = db().collection("reports").doc(reportId);
  const report = await ref.get();
  if (!report.exists) {
    throw new HttpsError("not-found", "No such report.");
  }

  await ref.update({
    status,
    ...(resolution ? { resolution } : {}),
    resolvedBy: request.auth!.uid,
    resolvedAt: Timestamp.now(),
  });

  return { status };
});
