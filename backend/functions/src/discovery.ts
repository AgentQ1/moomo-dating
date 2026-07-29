/**
 * The Discover feed, composed server-side (production-readiness audit P0-3,
 * P1-3 partial, P2-2).
 *
 * Discover used to be a raw client query over `publicProfiles` — which meant
 * any authenticated script could page the entire collection with cursors and
 * dump 1M users' names, ages, cities, photos. The rules now deny client
 * `list` on `publicProfiles` outright; this callable is the only way to
 * browse, and it is deliberately useless for scraping:
 *
 *  - NO CURSOR. Every call returns the current top of the feed, never "the
 *    next page". A scraper's tenth call sees roughly the same people as its
 *    first; enumeration of the base is structurally impossible, not just
 *    rate-limited. (Real pagination, when the product wants it, belongs here
 *    too — server-side, with an opaque, per-user, expiring cursor.)
 *  - BOUNDED. Two fixed-size pool queries (recently active + genuinely
 *    waiting), at most FEED_LIMIT candidates returned.
 *  - MINIMAL DTO. Exactly the fields the Discover screen renders. Raw
 *    `lastActiveAt` never leaves the server — the client gets a computed
 *    `isOnline` boolean, so precise activity times can't be harvested.
 *  - BLOCK-FILTERED BOTH DIRECTIONS, server-side (the old client-side filter
 *    could be stripped by a tampered client). After-call passes are filtered
 *    the same way: a pass severs the pair for matchmaking, so neither side
 *    may keep seeing the other here.
 *  - COMPATIBILITY-FILTERED with the same table matchmaking pairs by —
 *    Discover must never advertise a person the queue would refuse.
 *  - Rate-limited per user and behind the `discoveryEnabled` kill switch.
 *
 * Ordering rides on `activityBucket` — the client heartbeat's 10-minute
 * quantized activity stamp (see FirestoreDiscoveryService.swift). The exact
 * `lastActiveAt` is deliberately NOT an ordering key: a monotonically
 * increasing indexed timestamp was the audit's #1 write hotspot (P1-1), so
 * its single-field indexes are disabled in firestore.indexes.json and the
 * feed orders by the coarse bucket instead, breaking ties in memory.
 */
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";
import { callable } from "./options";
import { db, requireAuth } from "./shared";
import { PublicProfile, isMutuallyCompatible } from "./compatibility";
import { enforceRateLimit } from "./ratelimit";
import { requireEnabled } from "./runtime";
import { logEvent } from "./observability";

/** Candidates returned per call — what the Discover screen actually shows. */
const FEED_LIMIT = 25;
/** Recently-active pool scanned per call (pre-filter headroom). */
const ACTIVE_POOL = 60;
/** Reserved feed seats for genuinely-waiting users (hero-card supply). */
const WAITING_POOL = 10;
/**
 * Waiting docs FETCHED per call — headroom over the seats, because the
 * compat/block filters run after the fetch: a viewer whose preferences
 * reject the ten newest waiters must still see the compatible one behind
 * them.
 */
const WAITING_FETCH = 30;
/**
 * Mirrors `FirestoreDiscoveryService.onlineWindow` in the app. Exported for
 * the ring fan-out (ring.ts), which only rings people inside this window —
 * the raw `lastActiveAt` itself still never leaves the server.
 */
export const ONLINE_WINDOW_MS = 5 * 60 * 1000;

/** The exact shape the client renders — nothing more leaves the server. */
interface FeedCandidate {
  uid: string;
  displayName: string;
  age: number | null;
  city: string | null;
  occupation: string | null;
  photoPath: string | null;
  gender: string | null;
  isOnline: boolean;
  wantsToTalk: boolean;
  isVerified: boolean;
}

function candidateFrom(
  snapshot: FirebaseFirestore.QueryDocumentSnapshot,
  now: Timestamp
): FeedCandidate | null {
  const data = snapshot.data();
  // A projection that never finished onboarding (no name yet) isn't ready
  // to be shown to strangers.
  if (typeof data.displayName !== "string" || data.displayName.length === 0) {
    return null;
  }
  const lastActiveAt = data.lastActiveAt;
  const photoPaths = data.photoPaths;
  const firstPhoto = Array.isArray(photoPaths)
    ? photoPaths.find((p) => typeof p === "string" && p.length > 0)
    : undefined;
  return {
    uid: snapshot.id,
    displayName: data.displayName,
    age: typeof data.age === "number" ? data.age : null,
    city: typeof data.city === "string" ? data.city : null,
    occupation:
      typeof data.occupation === "string" && data.occupation.length > 0
        ? data.occupation
        : null,
    photoPath: typeof firstPhoto === "string" ? firstPhoto : null,
    gender: typeof data.gender === "string" ? data.gender : null,
    isOnline:
      lastActiveAt instanceof Timestamp &&
      now.toMillis() - lastActiveAt.toMillis() < ONLINE_WINDOW_MS,
    wantsToTalk: data.wantsToTalk === true,
    // Server-set when photo verification ships; absent means unverified.
    isVerified: data.isVerified === true,
  };
}

/**
 * Non-transactional both-directions exclusion check for a batch of
 * candidates: blocks AND after-call pass tombstones. Discover must never
 * advertise a person the queue would refuse to pair — and the queue refuses
 * both blocked and passed-on pairs. Shared with the ring fan-out (ring.ts)
 * for exactly the same reason: never ring that person either. Generic over
 * the snapshot type because the fan-out mixes query docs with a direct read.
 */
export async function filterExcluded<T extends { id: string }>(
  uid: string,
  candidates: T[]
): Promise<{
  allowed: T[];
  blockedRemoved: number;
  passedRemoved: number;
}> {
  if (candidates.length === 0) {
    return { allowed: [], blockedRemoved: 0, passedRemoved: 0 };
  }
  const refs = candidates.flatMap((c) => [
    db().collection("blocks").doc(uid).collection("blocked").doc(c.id),
    db().collection("blocks").doc(c.id).collection("blocked").doc(uid),
    db().collection("passes").doc(uid).collection("passed").doc(c.id),
    db().collection("passes").doc(c.id).collection("passed").doc(uid),
  ]);
  const snaps = await db().getAll(...refs);
  const allowed: T[] = [];
  let blockedRemoved = 0;
  let passedRemoved = 0;
  candidates.forEach((c, i) => {
    if (snaps[4 * i].exists || snaps[4 * i + 1].exists) {
      blockedRemoved += 1;
    } else if (snaps[4 * i + 2].exists || snaps[4 * i + 3].exists) {
      passedRemoved += 1;
    } else {
      allowed.push(c);
    }
  });
  return { allowed, blockedRemoved, passedRemoved };
}

export const getDiscoveryFeed = onCall(callable(20), async (request) => {
  const startedAtMillis = Date.now();
  const uid = requireAuth(request);
  await requireEnabled("getDiscoveryFeed", "discoveryEnabled");
  try {
    await enforceRateLimit(uid, "getDiscoveryFeed");
  } catch (error) {
    if (error instanceof HttpsError && error.code === "resource-exhausted") {
      // The one legitimate reason to hit this ceiling is a scraper probing
      // the feed — surface it on the enumeration alert, not just the
      // generic rate-limit metric.
      logEvent("discovery_feed_suspicious", { uid, reason: "rate-limited" });
    }
    throw error;
  }

  const now = Timestamp.now();

  // The viewer's own projection is the compatibility source — the same
  // document matchmaking pairs by, so feed and queue can never disagree.
  const viewerSnap = await db().collection("publicProfiles").doc(uid).get();
  const viewer: PublicProfile = viewerSnap.data();

  const [activeSnap, waitingSnap] = await Promise.all([
    db()
      .collection("publicProfiles")
      .orderBy("activityBucket", "desc")
      .limit(ACTIVE_POOL)
      .get(),
    // Waiting users must surface even when the newest activity bucket holds
    // far more people than the pool — the hero card is the product.
    db()
      .collection("publicProfiles")
      .where("wantsToTalk", "==", true)
      .orderBy("activityBucket", "desc")
      .limit(WAITING_FETCH)
      .get(),
  ]);

  // Merge, waiting pool first so it survives every downstream cap.
  const seen = new Set<string>();
  const pooled: FirebaseFirestore.QueryDocumentSnapshot[] = [];
  for (const snapshot of [...waitingSnap.docs, ...activeSnap.docs]) {
    if (snapshot.id === uid || seen.has(snapshot.id)) continue;
    seen.add(snapshot.id);
    pooled.push(snapshot);
  }

  // Rollout fallback: `activityBucket` exists only on profiles touched since
  // the presence fix shipped (client heartbeat, server stamp on queue join,
  // or the scripts/backfill-activity-buckets.mjs run the deploy checklist
  // requires), and orderBy EXCLUDES documents missing the ordered field. If
  // the bucketed pools come back thin, top up from an unordered scan (needs
  // no index; includes bucket-less docs) — the in-memory recency sort below
  // still puts genuinely recent people first. Post-backfill this never runs.
  let fallbackUsed = false;
  if (pooled.length < FEED_LIMIT) {
    fallbackUsed = true;
    const legacySnap = await db()
      .collection("publicProfiles")
      .limit(ACTIVE_POOL)
      .get();
    for (const snapshot of legacySnap.docs) {
      if (snapshot.id === uid || seen.has(snapshot.id)) continue;
      seen.add(snapshot.id);
      pooled.push(snapshot);
    }
  }

  const compatible = pooled.filter((snapshot) =>
    isMutuallyCompatible(viewer, snapshot.data())
  );
  const { allowed, blockedRemoved, passedRemoved } = await filterExcluded(
    uid,
    compatible
  );

  const ranked = allowed
    .map((snapshot) => ({
      uid: snapshot.id,
      candidate: candidateFrom(snapshot, now),
      lastActiveMillis:
        snapshot.get("lastActiveAt") instanceof Timestamp
          ? (snapshot.get("lastActiveAt") as Timestamp).toMillis()
          : 0,
    }))
    .filter((entry) => entry.candidate !== null)
    // Exact recency is fine as an in-memory tiebreak — it is only the
    // INDEX on lastActiveAt that hotspots, and that index is gone.
    .sort((a, b) => b.lastActiveMillis - a.lastActiveMillis);

  // Genuinely-waiting people are reserved seats — the hero card is the
  // product, and pure recency would squeeze them out the moment one
  // activity bucket holds more people than the feed. The final list stays
  // recency-ordered; the client finds its hero by `wantsToTalk` wherever
  // it sits.
  const waiting = ranked
    .filter((entry) => entry.candidate?.wantsToTalk)
    .slice(0, WAITING_POOL);
  const waitingIds = new Set(waiting.map((entry) => entry.uid));
  const rest = ranked.filter((entry) => !waitingIds.has(entry.uid));
  const candidates = [
    ...waiting,
    ...rest.slice(0, Math.max(0, FEED_LIMIT - waiting.length)),
  ]
    .sort((a, b) => b.lastActiveMillis - a.lastActiveMillis)
    .map((entry) => entry.candidate as FeedCandidate);

  logEvent("discovery_feed_served", {
    uid,
    returned: candidates.length,
    pooled: pooled.length,
    blockedFiltered: blockedRemoved,
    passedFiltered: passedRemoved,
    // Sustained `true` in production means the activityBucket backfill has
    // not run — alert on it (see OBSERVABILITY_AND_INCIDENT_PLAN.md).
    fallbackUsed,
    durationMs: Date.now() - startedAtMillis,
  });

  return { candidates };
});
