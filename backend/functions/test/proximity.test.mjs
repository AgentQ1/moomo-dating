/**
 * The proximity algorithm itself — pure functions, no emulator interaction.
 *
 * The integration suites prove proximity reaches the feed, the queue and the
 * ring fan-out. This file pins the MATHS those paths depend on, because the
 * product claim ("closer compatible people rank higher") and the privacy
 * claim ("nothing finer than a ~1 km grid is ever stored") are both
 * properties of these functions and both need to be regression-proof.
 *
 * Runs under `npm test` alongside the emulator suites; it needs nothing from
 * them but is loaded the same way, so the guard below matches its siblings.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error(
    'FIRESTORE_EMULATOR_HOST is not set. Run via `npm test` (firebase emulators:exec) — never against a live project.'
  );
}

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT ?? 'moomo-functions-test-proximity';

const {
  LOCATION_GRID_DEGREES,
  snapToGrid,
  distanceKm,
  proximityScore,
  recencyScore,
  candidateScore,
  sortByProximity,
  parseCoarseLocation,
  PROXIMITY_HALF_SCORE_KM,
  NEUTRAL_PROXIMITY_SCORE,
  RECENCY_HALF_SCORE_MINUTES,
  LOCATION_MAX_AGE_MS,
} = await import('../lib/proximity.js');
const { Timestamp } = await import('firebase-admin/firestore');

const at = (lat, lng) => ({ lat, lng, updatedAtMillis: Date.now() });
const MINUTE = 60 * 1000;

// Reference points, snapped to the grid the client would have used.
const CHICAGO = at(41.88, -87.63);
const CHICAGO_NEXT_CELL = at(41.89, -87.63); // ~1.1 km north
const EVANSTON = at(42.05, -87.68); // ~19 km north
const MILWAUKEE = at(43.04, -87.91); // ~132 km north
const NEW_YORK = at(40.71, -74.01); // ~1145 km east

describe('the grid — nothing finer than ~1.11 km is ever representable', () => {
  test('snapping lands on cell centres', () => {
    assert.equal(Number(snapToGrid(41.8781136).toFixed(6)), 41.88);
    assert.equal(Number(snapToGrid(-87.6297982).toFixed(6)), -87.63);
    assert.equal(Number(snapToGrid(0).toFixed(6)), 0);
  });

  test('the cell is 0.01 degrees — at most ~1.11 km on a side', () => {
    assert.equal(LOCATION_GRID_DEGREES, 0.01);
    // One cell of latitude, measured. The worst case for a cell diagonal is
    // at the equator, where a degree of longitude is also ~111 km.
    const oneCellNorth = distanceKm(at(0, 0), at(LOCATION_GRID_DEGREES, 0));
    assert.ok(oneCellNorth > 1.0 && oneCellNorth < 1.2, `${oneCellNorth} km`);
  });

  test('snapping is idempotent — a snapped value survives a second pass', () => {
    const once = snapToGrid(41.8781136);
    assert.equal(snapToGrid(once), once);
  });

  test('two positions in the same cell snap to one indistinguishable point', () => {
    // ~400 m apart in reality; identical once stored. This is the privacy
    // property: the stored value cannot separate them.
    const a = { lat: snapToGrid(41.8781), lng: snapToGrid(-87.6298) };
    const b = { lat: snapToGrid(41.8815), lng: snapToGrid(-87.6262) };
    assert.deepEqual(a, b);
  });
});

describe('distance', () => {
  test('a point is zero km from itself', () => {
    assert.equal(distanceKm(CHICAGO, CHICAGO), 0);
  });

  test('known separations land within a few percent of the real distance', () => {
    assert.ok(Math.abs(distanceKm(CHICAGO, EVANSTON) - 19) < 3);
    assert.ok(Math.abs(distanceKm(CHICAGO, MILWAUKEE) - 132) < 8);
    assert.ok(Math.abs(distanceKm(CHICAGO, NEW_YORK) - 1145) < 40);
  });

  test('is symmetric', () => {
    assert.equal(
      distanceKm(CHICAGO, MILWAUKEE).toFixed(9),
      distanceKm(MILWAUKEE, CHICAGO).toFixed(9)
    );
  });
});

describe('proximity score — a boost that never reaches zero', () => {
  test('same cell scores 1', () => {
    assert.equal(proximityScore(CHICAGO, CHICAGO), 1);
  });

  test('the half-score distance scores exactly 0.5', () => {
    const halfAway = at(CHICAGO.lat + PROXIMITY_HALF_SCORE_KM / 111.32, CHICAGO.lng);
    assert.ok(Math.abs(proximityScore(CHICAGO, halfAway) - 0.5) < 0.01);
  });

  test('monotonically decreasing with distance', () => {
    const scores = [CHICAGO, CHICAGO_NEXT_CELL, EVANSTON, MILWAUKEE, NEW_YORK].map(
      (p) => proximityScore(CHICAGO, p)
    );
    for (let i = 1; i < scores.length; i += 1) {
      assert.ok(scores[i] < scores[i - 1], `${scores[i]} !< ${scores[i - 1]}`);
    }
  });

  test('never reaches zero — the far are demoted, never excluded', () => {
    const antipode = at(-41.88, 92.37);
    assert.ok(proximityScore(CHICAGO, antipode) > 0);
  });

  test('a missing location on EITHER side scores neutral, not zero', () => {
    assert.equal(proximityScore(null, CHICAGO), NEUTRAL_PROXIMITY_SCORE);
    assert.equal(proximityScore(CHICAGO, null), NEUTRAL_PROXIMITY_SCORE);
    assert.equal(proximityScore(null, null), NEUTRAL_PROXIMITY_SCORE);
  });

  test('neutral is literally the half-score distance — the documented middle', () => {
    const halfAway = at(CHICAGO.lat + PROXIMITY_HALF_SCORE_KM / 111.32, CHICAGO.lng);
    assert.ok(
      Math.abs(proximityScore(CHICAGO, halfAway) - NEUTRAL_PROXIMITY_SCORE) < 0.01
    );
  });

  test('an unlocated candidate outranks a distant one and trails a near one', () => {
    const near = proximityScore(CHICAGO, CHICAGO_NEXT_CELL);
    const unlocated = proximityScore(CHICAGO, null);
    const far = proximityScore(CHICAGO, NEW_YORK);
    assert.ok(near > unlocated, 'near must beat unlocated');
    assert.ok(unlocated > far, 'unlocated must beat far');
  });
});

describe('recency score', () => {
  test('active now scores 1', () => {
    assert.equal(recencyScore(0), 1);
  });

  test('the half-score age scores exactly 0.5', () => {
    assert.equal(recencyScore(RECENCY_HALF_SCORE_MINUTES * MINUTE), 0.5);
  });

  test('a negative age (clock skew) is clamped, never inflated', () => {
    assert.equal(recencyScore(-5 * MINUTE), 1);
  });
});

describe('candidate score — the feed ordering key', () => {
  test('THE CLAIM: all else equal, the closer person ranks higher', () => {
    const age = 2 * MINUTE;
    const near = candidateScore(age, CHICAGO, CHICAGO_NEXT_CELL);
    const far = candidateScore(age, CHICAGO, NEW_YORK);
    assert.ok(near > far, `near ${near} must outrank far ${far}`);
  });

  test('all else equal, the more recently active person ranks higher', () => {
    const fresh = candidateScore(0, CHICAGO, EVANSTON);
    const stale = candidateScore(60 * MINUTE, CHICAGO, EVANSTON);
    assert.ok(fresh > stale);
  });

  test('with NO viewer location every candidate gets the same proximity term', () => {
    // The denied-permission fallback: ordering must collapse to pure recency,
    // which is exactly the behaviour that shipped before proximity existed.
    const a = candidateScore(1 * MINUTE, null, CHICAGO);
    const b = candidateScore(1 * MINUTE, null, NEW_YORK);
    const c = candidateScore(1 * MINUTE, null, null);
    assert.equal(a, b);
    assert.equal(b, c);
    // …and recency still separates them.
    assert.ok(candidateScore(0, null, NEW_YORK) > candidateScore(30 * MINUTE, null, CHICAGO));
  });

  test('an unlocated candidate is never scored below a located far one', () => {
    const age = 5 * MINUTE;
    assert.ok(candidateScore(age, CHICAGO, null) > candidateScore(age, CHICAGO, NEW_YORK));
  });

  test('proximity is a boost, not an override: a same-city pair is split by recency', () => {
    // Two people in the same metro, one active now and one an hour ago. The
    // proximity terms are close enough that recency decides — the documented
    // intent of the weights.
    const freshFarSideOfTown = candidateScore(0, CHICAGO, EVANSTON);
    const staleNextDoor = candidateScore(60 * MINUTE, CHICAGO, CHICAGO);
    assert.ok(freshFarSideOfTown > staleNextDoor);
  });

  test('a neighbour still outranks someone online a continent away', () => {
    const neighbourHalfHourAgo = candidateScore(30 * MINUTE, CHICAGO, CHICAGO);
    const distantOnlineNow = candidateScore(0, CHICAGO, NEW_YORK);
    assert.ok(neighbourHalfHourAgo > distantOnlineNow);
  });
});

describe('sortByProximity — stable, so it layers over FIFO and boost tiers', () => {
  const located = new Map([
    ['far', NEW_YORK],
    ['near', CHICAGO_NEXT_CELL],
    ['mid', MILWAUKEE],
  ]);
  const lookup = (id) => located.get(id) ?? null;

  test('closest first', () => {
    assert.deepEqual(
      sortByProximity(['far', 'mid', 'near'], CHICAGO, lookup),
      ['near', 'mid', 'far']
    );
  });

  test('unlocated entries keep their incoming order among themselves', () => {
    // Two unlocated people tie on score; the stable sort must preserve the
    // oldest-first order the matchmaking window handed in.
    assert.deepEqual(
      sortByProximity(['oldest', 'newest'], CHICAGO, lookup),
      ['oldest', 'newest']
    );
  });

  test('with no viewer location the incoming order is returned untouched', () => {
    const input = ['far', 'near', 'mid'];
    assert.deepEqual(sortByProximity(input, null, lookup), input);
  });

  test('an unlocated entry sorts between the near and the far', () => {
    assert.deepEqual(
      sortByProximity(['far', 'unknown', 'near'], CHICAGO, lookup),
      ['near', 'unknown', 'far']
    );
  });
});

describe('parseCoarseLocation — a client-written document, treated as hostile', () => {
  const now = Timestamp.now();
  /** A stand-in for a DocumentSnapshot. */
  const snap = (data) => ({
    exists: data !== null,
    get: (key) => (data === null ? undefined : data[key]),
  });

  test('reads a well-formed position', () => {
    const parsed = parseCoarseLocation(
      snap({ lat: 41.88, lng: -87.63, updatedAt: now }),
      now
    );
    assert.equal(parsed.lat, 41.88);
    assert.equal(parsed.lng, -87.63);
  });

  test('a missing document is null, not a throw', () => {
    assert.equal(parseCoarseLocation(undefined, now), null);
    assert.equal(parseCoarseLocation(snap(null), now), null);
  });

  test('junk types are null', () => {
    assert.equal(parseCoarseLocation(snap({ lat: 'x', lng: -87.63, updatedAt: now }), now), null);
    assert.equal(parseCoarseLocation(snap({ lat: NaN, lng: -87.63, updatedAt: now }), now), null);
    assert.equal(
      parseCoarseLocation(snap({ lat: Infinity, lng: -87.63, updatedAt: now }), now),
      null
    );
    assert.equal(parseCoarseLocation(snap({ lng: -87.63, updatedAt: now }), now), null);
  });

  test('out-of-range coordinates are null', () => {
    assert.equal(parseCoarseLocation(snap({ lat: 91, lng: 0, updatedAt: now }), now), null);
    assert.equal(parseCoarseLocation(snap({ lat: 0, lng: -181, updatedAt: now }), now), null);
  });

  test('a position past the max age reads as absent — it ranks neutral, not stale', () => {
    const old = Timestamp.fromMillis(now.toMillis() - LOCATION_MAX_AGE_MS - 1000);
    assert.equal(
      parseCoarseLocation(snap({ lat: 41.88, lng: -87.63, updatedAt: old }), now),
      null
    );
  });

  test('a document with no usable timestamp is treated as expired, never as fresh', () => {
    assert.equal(parseCoarseLocation(snap({ lat: 41.88, lng: -87.63 }), now), null);
    assert.equal(
      parseCoarseLocation(snap({ lat: 41.88, lng: -87.63, updatedAt: 'now' }), now),
      null
    );
  });
});
