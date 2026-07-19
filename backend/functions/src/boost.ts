/**
 * Boost: a timed visibility bump. Free during the beta — no StoreKit, no
 * payment, and nothing here may imply one (Phase 6 adds real entitlements;
 * until then the server grants a daily allowance).
 *
 * State is server-owned at `boosts/{uid}`: the client reads it live and asks
 * for activation here. A client-writable boost would be a self-granted
 * entitlement the moment boosts cost money.
 */
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";
import {
  db,
  requireAuth,
  BOOST_DAILY_ALLOWANCE,
  BOOST_DURATION_MS,
} from "./shared";

export const activateBoost = onCall(async (request) => {
  const uid = requireAuth(request);

  return db().runTransaction(async (tx) => {
    const ref = db().collection("boosts").doc(uid);
    const snapshot = await tx.get(ref);
    const now = Timestamp.now();

    // Lazy daily refill: no cron job, same arithmetic on client and server.
    const grantedAt = snapshot.get("grantedAt") as Timestamp | undefined;
    const dayOld =
      !grantedAt || now.toMillis() - grantedAt.toMillis() >= 24 * 60 * 60 * 1000;
    const remaining = dayOld
      ? BOOST_DAILY_ALLOWANCE
      : ((snapshot.get("remainingBoosts") as number) ?? BOOST_DAILY_ALLOWANCE);

    const activeUntil = snapshot.get("activeUntil") as Timestamp | undefined;
    if (activeUntil && activeUntil.toMillis() > now.toMillis()) {
      throw new HttpsError("failed-precondition", "alreadyActive");
    }
    if (remaining <= 0) {
      throw new HttpsError("failed-precondition", "noneRemaining");
    }

    const newUntil = Timestamp.fromMillis(now.toMillis() + BOOST_DURATION_MS);
    tx.set(ref, {
      remainingBoosts: remaining - 1,
      activeUntil: newUntil,
      grantedAt: dayOld ? now : grantedAt,
      updatedAt: now,
    });
    // Surfaced on the public profile so Discover ranking can honour it.
    tx.set(
      db().collection("publicProfiles").doc(uid),
      { boostedUntil: newUntil, updatedAt: now },
      { merge: true }
    );

    return {
      remainingBoosts: remaining - 1,
      activeUntilMillis: newUntil.toMillis(),
    };
  });
});
