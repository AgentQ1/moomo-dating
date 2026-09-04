/**
 * Proximity: the one place distance becomes a ranking number.
 *
 * The product claim this file has to make true is narrow and literal —
 * "closer compatible people are shown and called first". Everything else
 * about it is a privacy problem, so the shape is deliberate:
 *
 *  - COARSE, NEVER EXACT. Positions arrive already snapped to a
 *    LOCATION_GRID_DEGREES lattice by the client, and the rules refuse an
 *    off-grid write (firestore.rules, `isCoarseGridValue`). Nothing here can
 *    recover a finer position than the grid, because a finer one was never
 *    sent.
 *  - PRIVATE, NEVER PUBLISHED. Locations live at `users/{uid}/private/location`,
 *    which is `isSelf(uid)`-only. `publicProfiles` is readable by any signed-in
 *    user who knows a uid (and a call, a match, or an invite reveals one), so
 *    a coordinate there would be a polling endpoint for someone's position —
 *    the classic dating-app trilateration failure. The Admin SDK bypasses
 *    rules, so ranking can read what no client can.
 *  - A BOOST, NEVER A FILTER. Distance only ever moves someone up or down a
 *    list that compatibility, blocks, passes and the safety rules have already
 *    decided. Nobody is excluded for being far away, and — critically —
 *    nobody without a location is excluded at all: a missing, malformed or
 *    stale position scores NEUTRAL_PROXIMITY_SCORE, which is exactly the score
 *    of someone at the half-score distance. Excluding the location-less would
 *    silently unmatch every account that predates this feature and recreate
 *    the "demo accounts can never pair" failure that got build 3 rejected.
 *  - NO NEW QUERY SHAPE. Distance is computed in memory over the bounded
 *    scans that already exist (ACTIVE_POOL, RING_POOL, CANDIDATE_WINDOW). No
 *    geohash, no geo query, no new composite index — so this adds no index
 *    build, no new hotspot, and no new Cloud Run quota pressure.
 */
import { Timestamp } from "firebase-admin/firestore";
import { db } from "./shared";

// ---------------------------------------------------------------------------
// Grid
// ---------------------------------------------------------------------------

/**
 * The lattice every stored position is snapped to, in degrees.
 *
 * 0.01° of latitude is ~1.11 km everywhere; 0.01° of longitude is ~1.11 km at
 * the equator and shrinks with the cosine of latitude, so a cell is at most
 * ~1.11 km on a side and never larger. Rounding to the nearest cell centre
 * therefore displaces a real position by up to ~0.8 km (half the diagonal),
 * and no stored value distinguishes two people in the same cell.
 *
 * MUST equal `CoarseLocation.gridDegrees` in
 * app/Moomo/Services/CoarseLocationReporter.swift and the tolerance in
 * `isCoarseGridValue` in backend/firestore.rules. All three move together or
 * legitimate writes start bouncing.
 */
export const LOCATION_GRID_DEGREES = 0.01;

/** Cell centre for a raw coordinate component. The client's `snap` mirror. */
export function snapToGrid(value: number): number {
  return Math.round(value / LOCATION_GRID_DEGREES) * LOCATION_GRID_DEGREES;
}

// ---------------------------------------------------------------------------
// Scoring constants
// ---------------------------------------------------------------------------

/**
 * The distance at which proximity scores exactly 0.5 — the half-life of the
 * boost. Chosen as a metro-area radius: inside one city everybody scores
 * high and recency decides, and the curve only starts to bite across cities.
 */
export const PROXIMITY_HALF_SCORE_KM = 25;

/**
 * What a candidate scores when distance is unknowable — either side missing a
 * location, a malformed document, or a position past LOCATION_MAX_AGE_MS.
 *
 * 0.5 is not an arbitrary middle: it is precisely the score of someone at
 * PROXIMITY_HALF_SCORE_KM. An unlocated candidate is therefore ranked as if
 * they were a metro away — behind the people known to be close, ahead of the
 * people known to be far, and never dropped.
 */
export const NEUTRAL_PROXIMITY_SCORE = 0.5;

/** Minutes of staleness at which recency scores exactly 0.5. */
export const RECENCY_HALF_SCORE_MINUTES = 30;

/**
 * The blend. Both component scores are in (0, 1], so these weights are the
 * whole trade-off and it is worth stating the boundary plainly:
 *
 *   someone active now, 500 km away    → 1.00 + 0.6·0.05 = 1.03
 *   someone active 30 min ago, 0 km    → 0.50 + 0.6·1.00 = 1.10
 *
 * so at 0.6 a same-cell neighbour outranks a distant person who is online
 * right now, while a same-city pair is separated by recency (their proximity
 * scores are within a few hundredths of each other). That is the intended
 * behaviour for a product about meeting people you could actually meet.
 * Recency keeps weight 1.0 because a live call needs someone who is awake.
 */
export const PROXIMITY_WEIGHT = 0.6;
export const RECENCY_WEIGHT = 1.0;

/**
 * How long a stored position stays usable. Past this it scores neutral rather
 * than ranking someone by where they were last summer. The client refreshes
 * on a much shorter cadence whenever permission is already granted, so this
 * only catches accounts that stopped sharing.
 */
export const LOCATION_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;

/** Mean Earth radius, km — the haversine constant. */
const EARTH_RADIUS_KM = 6371.0088;

// ---------------------------------------------------------------------------
// Reading positions
// ---------------------------------------------------------------------------

export interface CoarseLocation {
  lat: number;
  lng: number;
  updatedAtMillis: number;
}

/** The private document path. Client-unreadable for anyone but its owner. */
export function coarseLocationRef(uid: string) {
  return db().collection("users").doc(uid).collection("private").doc("location");
}

/**
 * A stored position, or null if there isn't a usable one. Defensive about
 * every field: this document is client-written, so a malformed or hostile
 * value must degrade to "no location" (neutral) rather than throw inside a
 * feed request.
 */
export function parseCoarseLocation(
  snapshot: FirebaseFirestore.DocumentSnapshot | undefined,
  now: Timestamp
): CoarseLocation | null {
  if (!snapshot?.exists) return null;
  const lat = snapshot.get("lat");
  const lng = snapshot.get("lng");
  if (
    typeof lat !== "number" ||
    typeof lng !== "number" ||
    !Number.isFinite(lat) ||
    !Number.isFinite(lng) ||
    lat < -90 ||
    lat > 90 ||
    lng < -180 ||
    lng > 180
  ) {
    return null;
  }
  const updatedAt = snapshot.get("updatedAt");
  const updatedAtMillis =
    updatedAt instanceof Timestamp ? updatedAt.toMillis() : 0;
  // A position with no usable timestamp is treated as expired, not as fresh:
  // "we cannot tell how old this is" must never rank someone ahead.
  if (now.toMillis() - updatedAtMillis > LOCATION_MAX_AGE_MS) return null;
  return { lat, lng, updatedAtMillis };
}

/**
 * Batch-loads the private positions for a set of uids. One `getAll` — the
 * same batching the block/pass filter uses — so proximity costs a single
 * round trip per request regardless of pool size.
 *
 * Never throws: a failed read means every candidate scores neutral and the
 * ranking degrades to exactly the recency order it had before this feature.
 * Feed and matchmaking must not fail because a location read did.
 */
export async function loadCoarseLocations(
  uids: string[],
  now: Timestamp
): Promise<Map<string, CoarseLocation | null>> {
  const located = new Map<string, CoarseLocation | null>();
  const unique = [...new Set(uids)];
  if (unique.length === 0) return located;
  try {
    const snaps = await db().getAll(...unique.map(coarseLocationRef));
    unique.forEach((uid, index) => {
      located.set(uid, parseCoarseLocation(snaps[index], now));
    });
  } catch {
    unique.forEach((uid) => located.set(uid, null));
  }
  return located;
}

// ---------------------------------------------------------------------------
// Distance and scores
// ---------------------------------------------------------------------------

const toRadians = (degrees: number): number => (degrees * Math.PI) / 180;

/** Great-circle distance in km between two coarse positions (haversine). */
export function distanceKm(a: CoarseLocation, b: CoarseLocation): number {
  const dLat = toRadians(b.lat - a.lat);
  const dLng = toRadians(b.lng - a.lng);
  const latA = toRadians(a.lat);
  const latB = toRadians(b.lat);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(latA) * Math.cos(latB) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.min(1, Math.sqrt(h)));
}

/**
 * Distance → (0, 1]. `1 / (1 + d/HALF)`: 1 at zero distance, 0.5 at the half
 * score distance, asymptotically approaching but never reaching 0. Never
 * reaching 0 is the point — the far are demoted, never removed.
 */
export function proximityScore(
  viewer: CoarseLocation | null,
  candidate: CoarseLocation | null
): number {
  if (!viewer || !candidate) return NEUTRAL_PROXIMITY_SCORE;
  return 1 / (1 + distanceKm(viewer, candidate) / PROXIMITY_HALF_SCORE_KM);
}

/** Staleness → (0, 1], same curve as proximity. 0 or missing reads as "now". */
export function recencyScore(ageMillis: number): number {
  const minutes = Math.max(0, ageMillis) / 60000;
  return 1 / (1 + minutes / RECENCY_HALF_SCORE_MINUTES);
}

/**
 * The feed's ordering key. Higher sorts first.
 *
 * Deliberately a pure function of (staleness, distance) so the ranking is
 * unit-testable without an emulator and so "closer wins when all else is
 * equal" is a property that can be asserted rather than eyeballed.
 */
export function candidateScore(
  ageMillis: number,
  viewer: CoarseLocation | null,
  candidate: CoarseLocation | null
): number {
  return (
    RECENCY_WEIGHT * recencyScore(ageMillis) +
    PROXIMITY_WEIGHT * proximityScore(viewer, candidate)
  );
}

/**
 * Stable proximity sort for pools whose order is already meaningful (the
 * ring fan-out's boost tiers, matchmaking's oldest-first window): closer
 * first, and equal scores — which includes every pair of unlocated people —
 * keep the order they came in with. Stability is what keeps this a boost
 * layered over FIFO fairness/boost priority rather than a replacement for it.
 */
export function sortByProximity<T>(
  items: T[],
  viewer: CoarseLocation | null,
  locationOf: (item: T) => CoarseLocation | null
): T[] {
  return items
    .map((item, index) => ({
      item,
      index,
      score: proximityScore(viewer, locationOf(item)),
    }))
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .map((entry) => entry.item);
}
