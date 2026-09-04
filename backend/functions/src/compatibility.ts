/**
 * The one compatibility table, shared by matchmaking (pairing) and discovery
 * (the feed). Discover must never advertise a person the queue would refuse
 * to pair, so both paths MUST consult these same functions.
 *
 * Mirrors `MatchPreferences` in app/Moomo/Models/MatchPreferences.swift
 * — the two tables must stay identical:
 *  - empty/missing preferences read as "everyone" (pre-preference accounts
 *    must keep working);
 *  - `everyone` accepts any gender, including non-binary/other/unknown;
 *  - `women`/`men` accept exactly `woman`/`man`; non-binary, other, and
 *    unknown genders are matched only by "everyone";
 *  - dating intentions must overlap on at least one horizon, and a missing
 *    intention overlaps with everything.
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

/**
 * What each dating intention is willing to end up in. An unknown or missing
 * value seeks both horizons, so accounts from before intentions existed (and
 * anything a future client adds that this deploy has not heard of) stay
 * matchable rather than silently pairing with nobody.
 */
const HORIZONS: Record<string, readonly string[]> = {
  lifePartner: ["longTerm"],
  longTerm: ["longTerm"],
  shortTerm: ["shortTerm"],
  longTermOpenToShort: ["longTerm", "shortTerm"],
  shortTermOpenToLong: ["longTerm", "shortTerm"],
  figuringItOut: ["longTerm", "shortTerm"],
};

const BOTH_HORIZONS: readonly string[] = ["longTerm", "shortTerm"];

export function intentionOf(profile: PublicProfile): string | null {
  return typeof profile?.datingIntention === "string"
    ? profile.datingIntention
    : null;
}

function seeks(intention: string | null): readonly string[] {
  if (intention === null) return BOTH_HORIZONS;
  return HORIZONS[intention] ?? BOTH_HORIZONS;
}

/**
 * Whether two people could end up in the same kind of relationship. Someone
 * set on a life partner is never paired with someone set on a fling.
 */
export function isIntentionCompatible(a: PublicProfile, b: PublicProfile): boolean {
  const mine = seeks(intentionOf(a));
  const theirs = seeks(intentionOf(b));
  return mine.some((horizon) => theirs.includes(horizon));
}

/** Pair (or advertise) only people who would BOTH choose to meet the other. */
export function isMutuallyCompatible(a: PublicProfile, b: PublicProfile): boolean {
  return (
    wantsGender(a, genderOf(b)) &&
    wantsGender(b, genderOf(a)) &&
    isIntentionCompatible(a, b)
  );
}

/** An active boost at `now` — what "front of the matchmaking queue" means. */
export function isBoosted(profile: PublicProfile, now: Timestamp): boolean {
  const until = profile?.boostedUntil;
  return until instanceof Timestamp && until.toMillis() > now.toMillis();
}
