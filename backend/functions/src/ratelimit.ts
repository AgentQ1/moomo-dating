/**
 * Per-user rate limiting for expensive callables (production-readiness audit
 * P1-4).
 *
 * Fixed-window counters at `rateLimits/{uid}_{action}` — one document per
 * user per action, transactionally incremented. Contention is per-user only
 * (a user racing their own retries), so the counter can never become a
 * global hotspot. The collection is server-owned: firestore.rules never
 * mention `rateLimits`, so the deny-by-default catch-all keeps clients from
 * reading or resetting their own windows.
 *
 * These are abuse brakes in the same spirit as REPORTS_PER_DAY_LIMIT —
 * ceilings a legitimate client cannot reach (Discover refreshes ~once per
 * 2 minutes; the queue is joined ~once per 4; a call mints ~1 token), sized
 * with enough headroom for retry storms from a flaky network. They exist so
 * a scripted loop cannot turn a callable into a billing lever
 * (COST_AND_QUOTA_MODEL.md "billing-attack surface").
 *
 * FAIL-CLOSED: if the limiter itself cannot run (Firestore error), the
 * callable refuses rather than waving traffic through — for these functions
 * an open failure mode is exactly the cost/abuse hole the limiter closes.
 * The refusal is `unavailable` (retryable), not `resource-exhausted`, so a
 * client can distinguish "backend hiccup" from "you are over the limit".
 */
import { HttpsError } from "firebase-functions/v2/https";
import { db } from "./shared";
import { logEvent } from "./observability";

export interface RateLimit {
  /** Requests allowed per window. */
  limit: number;
  windowMs: number;
}

/** One place to see (and test) every ceiling. */
export const RATE_LIMITS = {
  joinMatchmakingQueue: { limit: 12, windowMs: 60_000 },
  getCallMediaToken: { limit: 10, windowMs: 60_000 },
  submitCallDecision: { limit: 20, windowMs: 60_000 },
  activateBoost: { limit: 5, windowMs: 60_000 },
  getDiscoveryFeed: { limit: 20, windowMs: 60_000 },
  deleteAccount: { limit: 3, windowMs: 60 * 60_000 },
} as const satisfies Record<string, RateLimit>;

export type RateLimitedAction = keyof typeof RATE_LIMITS;

/**
 * Counts this call against `uid`'s window for `action`; throws
 * `resource-exhausted` once the window is full.
 */
export async function enforceRateLimit(
  uid: string,
  action: RateLimitedAction
): Promise<void> {
  const { limit, windowMs } = RATE_LIMITS[action];
  const ref = db().collection("rateLimits").doc(`${uid}_${action}`);

  let blocked = false;
  try {
    await db().runTransaction(async (tx) => {
      // Re-run from scratch on every attempt: a retried transaction that
      // latched `blocked` on a previous attempt may see a fresh window now,
      // and a stale latch would both count the call AND refuse it.
      blocked = false;
      const now = Date.now();
      const snapshot = await tx.get(ref);
      const windowStartMillis =
        (snapshot.get("windowStartMillis") as number) ?? 0;
      const count = (snapshot.get("count") as number) ?? 0;

      if (now - windowStartMillis >= windowMs) {
        // New window. Stamp `action`/`uid` so an operator reading the raw
        // collection can attribute a document without decoding its id.
        tx.set(ref, { uid, action, windowStartMillis: now, count: 1 });
        return;
      }
      if (count >= limit) {
        blocked = true;
        return;
      }
      tx.set(ref, { count: count + 1 }, { merge: true });
    });
  } catch (error) {
    // Fail closed (see header). Never mask an intentional refusal.
    if (error instanceof HttpsError) throw error;
    logEvent("rate_limit_blocked", {
      uid,
      action,
      reason: "limiter-error",
      message: String(error),
    });
    throw new HttpsError(
      "unavailable",
      "Please try again in a moment."
    );
  }

  if (blocked) {
    logEvent("rate_limit_blocked", { uid, action, reason: "over-limit", limit });
    throw new HttpsError(
      "resource-exhausted",
      "You're doing that too often. Please wait a bit and try again."
    );
  }
}
