/**
 * Kill switch / maintenance mode (production-readiness audit P0-1).
 *
 * A single Firestore document — `config/runtime` — is the emergency brake the
 * audit found missing: flip a boolean in the console and the matching
 * callables start refusing within one cache interval, without a deploy.
 *
 *   {
 *     maintenanceMode:    true → every gated callable refuses
 *     matchmakingEnabled: false → joinMatchmakingQueue refuses
 *     callsEnabled:       false → getCallMediaToken refuses
 *     discoveryEnabled:   false → getDiscoveryFeed refuses
 *     boostsEnabled:      false → activateBoost refuses
 *   }
 *
 * Deliberately NOT gated, ever: leaveMatchmakingQueue and endCallSession
 * (nobody may be trapped in a queue or a call by an outage switch),
 * blockUser / reportUser / unmatchUser (safety must always work), and
 * deleteAccount (the right to leave is not maintenance-gated).
 *
 * Missing document or missing flag mean ENABLED — this is a brake an operator
 * pulls, not a gate someone must remember to open. A Firestore error while
 * reading the flag falls back to the last successfully read value (or
 * enabled, before any read succeeds): if Firestore is down, the gated
 * callable is about to fail on its own work anyway, and the error is logged
 * as `runtime_config_error` for the alert pipeline.
 *
 * The document is cached in instance memory (default 15s, tunable via
 * RUNTIME_CONFIG_CACHE_MS — tests set 0) so the flag check does not itself
 * become a hot-document read: at 1,000 callable invocations/sec an uncached
 * check would out-hotspot the problems it guards against.
 *
 * The document is server-owned; firestore.rules never mention `config`, so
 * the deny-by-default catch-all keeps clients out.
 */
import { HttpsError } from "firebase-functions/v2/https";
import { db } from "./shared";
import { logEvent } from "./observability";

export type RuntimeFlag =
  | "matchmakingEnabled"
  | "callsEnabled"
  | "discoveryEnabled"
  | "boostsEnabled";

let cached: FirebaseFirestore.DocumentData | null = null;
let cachedAtMillis = 0;

function cacheTtlMillis(): number {
  const raw = Number(process.env.RUNTIME_CONFIG_CACHE_MS);
  return Number.isFinite(raw) && raw >= 0 ? raw : 15_000;
}

/** Test seam: forget the cached document (used between emulator tests). */
export function resetRuntimeConfigCache(): void {
  cached = null;
  cachedAtMillis = 0;
}

async function runtimeConfig(): Promise<FirebaseFirestore.DocumentData> {
  const now = Date.now();
  if (cached !== null && now - cachedAtMillis < cacheTtlMillis()) {
    return cached;
  }
  try {
    const snapshot = await db().collection("config").doc("runtime").get();
    cached = snapshot.data() ?? {};
    cachedAtMillis = now;
  } catch (error) {
    logEvent("runtime_config_error", { message: String(error) });
    // Last known good, or enabled before any successful read.
    cached = cached ?? {};
    cachedAtMillis = now;
  }
  return cached;
}

/**
 * Refuses with `unavailable` when maintenance mode is on, or when `flag` is
 * explicitly false. Call at the top of each gated callable.
 */
export async function requireEnabled(
  functionName: string,
  flag?: RuntimeFlag
): Promise<void> {
  const config = await runtimeConfig();
  const blockedBy =
    config.maintenanceMode === true
      ? "maintenanceMode"
      : flag && config[flag] === false
        ? flag
        : null;
  if (blockedBy) {
    logEvent("kill_switch_blocked", { functionName, blockedBy });
    throw new HttpsError(
      "unavailable",
      "Moomo is temporarily unavailable. Please try again soon."
    );
  }
}
