/**
 * The one compatibility table, shared by matchmaking (pairing) and discovery
 * (the feed). Discover must never advertise a person the queue would refuse
 * to pair, so both paths MUST consult these same functions.
 *
 * Mirrors `MatchPreferences.wants` in app/Moomo/Models/MatchPreferences.swift
 * — the two tables must stay identical:
 *  - empty/missing preferences read as "everyone" (pre-preference accounts
 *    must keep working);
 *  - `everyone` accepts any gender, including non-binary/other/unknown;
 *  - `women`/`men` accept exactly `woman`/`man`; non-binary, other, and
 *    unknown genders are matched only by "everyone".
 */
import { Timestamp } from "firebase-admin/firestore";

export type PublicProfile = FirebaseFirestore.DocumentData | undefined;

/** Whether `profile`'s stated preferences accept someone of `gender`. */
export function wantsGender(
  profile: PublicProfile,
  gender: string | null
): boolean {
  const preferences = Array.isArray(profile?.interestedIn)
    ? (profile.interestedIn as unknown[]).filter((p) => typeof p === "string")
    : [];
  if (preferences.length === 0 || preferences.includes("everyone")) return true;
  if (gender === "woman") return preferences.includes("women");
  if (gender === "man") return preferences.includes("men");
  return false;
}

export function genderOf(profile: PublicProfile): string | null {
  return typeof profile?.gender === "string" ? profile.gender : null;
}

/** Pair (or advertise) only people who would BOTH choose to meet the other. */
export function isMutuallyCompatible(a: PublicProfile, b: PublicProfile): boolean {
  return wantsGender(a, genderOf(b)) && wantsGender(b, genderOf(a));
}

/** An active boost at `now` — what "front of the matchmaking queue" means. */
export function isBoosted(profile: PublicProfile, now: Timestamp): boolean {
  const until = profile?.boostedUntil;
  return until instanceof Timestamp && until.toMillis() > now.toMillis();
}
