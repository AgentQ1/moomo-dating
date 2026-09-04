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

/**
 * How long a ring invite stays acceptable server-side. The client's banner
 * shows for 7 seconds (`CallInvite.ringSeconds`) and MUST stay under this —
 * the same headroom pattern as the client's 30-second `searchTimeout` under
 * the 40-second `QUEUE_ENTRY_TTL_MS`: an accept tapped at the last visible
 * moment still lands inside the server's window.
 */
export const RING_TTL_MS = 10_000;

/** Callees rung per fan-out — a banner burst, not a broadcast. */
export const RING_FANOUT_LIMIT = 8;

/** `publicProfiles` candidates scanned per fan-out (pre-filter headroom). */
export const RING_POOL = 40;

/** One caller may not re-ring the same callee this soon (hounding brake). */
export const RING_SAME_CALLER_COOLDOWN_MS = 120_000;

/** Nobody gets rung again this soon after their last ring, whoever it was from. */
export const RING_ANY_CALLER_GAP_MS = 30_000;

/**
 * callInvites/{calleeUid} — one incoming ring per user, server-written only.
 * The callee's foreground client listens to this single document for the
 * "ringing" transition; the latest ring overwrites a terminal older one.
 */
export function callInviteRef(uid: string): FirebaseFirestore.DocumentReference {
  return db().collection("callInvites").doc(uid);
}

/**
 * The presence bucket size. Must equal the client's
 * `PresenceHeartbeat.bucketInterval` (600s) and the rules'
 * `activityBucketIsHonest` modulus (600,000 ms) — the three move together.
 */
export const ACTIVITY_BUCKET_MS = 10 * 60 * 1000;

/** `now` floored to the bucket — the same value an honest client writes. */
export function activityBucketFloor(now: Timestamp): Timestamp {
  return Timestamp.fromMillis(
    Math.floor(now.toMillis() / ACTIVITY_BUCKET_MS) * ACTIVITY_BUCKET_MS
  );
}

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

/** Must match `UnmatchReason` raw values in app/Moomo/Models/Safety.swift. */
export const UNMATCH_REASONS = [
  "no_reason",
  "not_interested",
  "fake_spam_scammer",
  "inappropriate_content",
  "underage",
  "off_app_behavior",
  "someone_in_danger",
] as const;

/**
 * Every call mode that has ever been stored.
 *
 * "voice" is the retired voice-only product (the app's "Speed Talk"). Live
 * `callSessions`, `matchmakingQueue` entries, `callInvites`, and
 * `users/{uid}/callHistory` documents in production still carry it, so
 * anything that READS a stored mode must keep accepting it — dropping it
 * would make old history undecodable and old sessions unendable.
 */
export const CALL_MODES = ["voice", "video"] as const;
export type CallMode = (typeof CALL_MODES)[number];

/**
 * The modes a NEW call may be created in. Voice-only is gone from the
 * product: no queue join, ring, or invite accept may mint one, while every
 * read path above still tolerates the stored value. Mirrors the client's
 * `CallMode.isSupported`.
 */
export const SUPPORTED_CALL_MODES = ["video"] as const;
export type SupportedCallMode = (typeof SUPPORTED_CALL_MODES)[number];

/** True for a mode a new call may actually be created in. */
export function isSupportedCallMode(mode: unknown): mode is SupportedCallMode {
  return (
    typeof mode === "string" &&
    (SUPPORTED_CALL_MODES as readonly string[]).includes(mode)
  );
}

/** How a stored mode is read back. Unknown/absent reads as the live mode. */
export function readStoredCallMode(mode: unknown): CallMode {
  return typeof mode === "string" && (CALL_MODES as readonly string[]).includes(mode)
    ? (mode as CallMode)
    : "video";
}

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

/**
 * passes/{uid}/passed/{peerUid} — the pair-level record of an after-call
 * pass, written by submitCallDecision. Entirely server-owned and never
 * readable by any client (a pass must stay indistinguishable from "hasn't
 * decided", so not even its author gets to list these).
 */
export function passRef(
  uid: string,
  peerUid: string
): FirebaseFirestore.DocumentReference {
  return db().collection("passes").doc(uid).collection("passed").doc(peerUid);
}

/**
 * True when either user has passed on the other after a call. A pass is a
 * recorded "not interested": the pair must never be paired again or
 * advertised to each other — a call needs both people, so one side's pass
 * severs it in both directions, same shape as a block (but without a block's
 * cascade: nothing existing is torn down, the pair simply never recurs).
 */
export async function hasPassedEitherWay(
  tx: FirebaseFirestore.Transaction,
  a: string,
  b: string
): Promise<boolean> {
  const [ab, ba] = await Promise.all([
    tx.get(passRef(a, b)),
    tx.get(passRef(b, a)),
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
