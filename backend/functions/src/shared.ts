/**
 * Shared plumbing for every Moomo function.
 *
 * The invariants the whole backend hangs off:
 *  - `callSessions`, `matches`, `conversations`, `blocks`, `reports`, `boosts`
 *    and notification/history projections are written ONLY here (Admin SDK).
 *    Firestore rules deny every client write to them.
 *  - Anything one user must never learn about another (their like/pass, being
 *    blocked) lives in per-user projections, never on a shared document.
 */
import { getFirestore, Timestamp, FieldValue } from "firebase-admin/firestore";
import { HttpsError, CallableRequest } from "firebase-functions/v2/https";

export const db = () => getFirestore();

/** The product's 3-minute speed call, in seconds. Mirrors `CallSession.speedCallDuration`. */
export const SPEED_CALL_SECONDS = 180;

/**
 * Queue entries older than this are dead clients, never valid partners.
 * Just above the client's 30-second search patience
 * (`FirestoreCallService.searchTimeout`): a genuinely waiting client is
 * always younger than this, while an abandoned entry — a killed or
 * suspended app that never managed to leave — ages out before it can be
 * paired into a call with nobody on the other side.
 */
export const QUEUE_ENTRY_TTL_MS = 40 * 1000;

/** Boosts granted per 24h window. Mirrors the free-beta client copy. */
export const BOOST_DAILY_ALLOWANCE = 3;
export const BOOST_DURATION_MS = 30 * 60 * 1000;

/** Reports accepted per reporter per 24h — an abuse brake, not a quota. */
export const REPORTS_PER_DAY_LIMIT = 20;

/** Blocks accepted per user per 24h — same spirit: brake, not quota. */
export const BLOCKS_PER_DAY_LIMIT = 50;

/** Must match `ReportReason` raw values in app/Moomo/Models/Safety.swift. */
export const REPORT_REASONS = [
  "harassment",
  "inappropriate_content",
  "spam",
  "underage",
  "other",
] as const;

export const CALL_MODES = ["voice", "video"] as const;
export type CallMode = (typeof CALL_MODES)[number];

export const END_REASONS = ["ended", "timeExpired", "blocked"] as const;
export type EndReason = (typeof END_REASONS)[number];

/** The uid of a verified caller, or an HttpsError. */
export function requireAuth(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }
  return uid;
}

export function requireString(
  value: unknown,
  field: string,
  maxLength = 256
): string {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
    throw new HttpsError("invalid-argument", `Invalid ${field}.`);
  }
  return value;
}

/**
 * Deterministic id for a pair of users, order-independent. Matches and their
 * conversations are keyed by it so a repeat call between the same two people
 * can never mint a duplicate match.
 */
export function pairKey(a: string, b: string): string {
  return [a, b].sort().join("_");
}

export function conversationIdFor(a: string, b: string): string {
  return `conv_${pairKey(a, b)}`;
}

/** What one participant is allowed to know about the other, denormalised. */
export interface ParticipantSummary {
  uid: string;
  displayName: string;
  age: number | null;
  city: string | null;
  gender: string | null;
  photoPath: string | null;
}

/**
 * The public projection of `uid`, from `publicProfiles`. Falls back to a
 * minimal record rather than failing: a guest who never wrote a public
 * profile can still be called, and rendering "Someone" honestly beats a
 * crashed matchmaking transaction.
 */
export function participantSummary(
  uid: string,
  publicProfile: FirebaseFirestore.DocumentData | undefined
): ParticipantSummary {
  const photoPaths = publicProfile?.photoPaths;
  return {
    uid,
    displayName:
      typeof publicProfile?.displayName === "string" &&
      publicProfile.displayName.length > 0
        ? publicProfile.displayName
        : "Someone",
    age: typeof publicProfile?.age === "number" ? publicProfile.age : null,
    city: typeof publicProfile?.city === "string" ? publicProfile.city : null,
    gender: typeof publicProfile?.gender === "string" ? publicProfile.gender : null,
    photoPath:
      Array.isArray(photoPaths) && typeof photoPaths[0] === "string"
        ? photoPaths[0]
        : null,
  };
}

/**
 * True when either user has blocked the other. Both directions on purpose:
 * a block removes the pair from each other's world, whoever placed it.
 */
export async function isBlockedEitherWay(
  tx: FirebaseFirestore.Transaction,
  a: string,
  b: string
): Promise<boolean> {
  const [ab, ba] = await Promise.all([
    tx.get(db().collection("blocks").doc(a).collection("blocked").doc(b)),
    tx.get(db().collection("blocks").doc(b).collection("blocked").doc(a)),
  ]);
  return ab.exists || ba.exists;
}

/** Appends to `users/{uid}/notifications` — the feed behind the Discover bell. */
export function writeNotification(
  writer: FirebaseFirestore.Transaction | FirebaseFirestore.WriteBatch,
  uid: string,
  kind: "match" | "system" | "wantsToTalk",
  title: string,
  body: string
): void {
  const ref = db()
    .collection("users")
    .doc(uid)
    .collection("notifications")
    .doc();
  const data = {
    kind,
    title,
    body,
    isRead: false,
    createdAt: FieldValue.serverTimestamp(),
  };
  // Transaction.create and WriteBatch.create share a signature.
  writer.create(ref, data);
}

/** users/{uid}/callHistory/{sessionId} — this user's private view of a call. */
export function historyRef(
  uid: string,
  sessionId: string
): FirebaseFirestore.DocumentReference {
  return db()
    .collection("users")
    .doc(uid)
    .collection("callHistory")
    .doc(sessionId);
}

export function assertParticipant(
  session: FirebaseFirestore.DocumentSnapshot,
  uid: string
): string[] {
  const participantIds = session.get("participantIds");
  if (!session.exists || !Array.isArray(participantIds) || !participantIds.includes(uid)) {
    // "not-found" for non-participants too: revealing that a session exists
    // is itself a leak.
    throw new HttpsError("not-found", "No such call.");
  }
  return participantIds as string[];
}

export function peerOf(participantIds: string[], uid: string): string {
  const peer = participantIds.find((p) => p !== uid);
  if (!peer) {
    throw new HttpsError("internal", "Malformed session.");
  }
  return peer;
}

export function millis(value: unknown): number | null {
  return value instanceof Timestamp ? value.toMillis() : null;
}
