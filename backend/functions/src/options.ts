/**
 * Runtime option ceilings for every function.
 *
 * Why this file exists (production-readiness audit P0-1): the callables were all
 * bare `onCall(...)` with no runtime options, so there was no upper bound on
 * Cloud Run instances — a viral spike, a retry storm, or an abuse loop could
 * scale the backend (and the bill) without limit, with no kill switch.
 *
 * Everything here is a CAPACITY GUARDRAIL, not product logic. `concurrency`,
 * `memory`, and `timeoutSeconds` are pinned to the existing Firebase v2 defaults
 * (80 / 256MiB / 60s) so behaviour is unchanged; the one thing that is genuinely
 * added is `maxInstances` — a real ceiling. Region is pinned explicitly rather
 * than relying on the platform default (still us-central1).
 *
 * These are per-function options passed directly to `onCall` so there is no
 * module-evaluation-order dependency (unlike `setGlobalOptions`, which must run
 * before any function is defined and is fragile under re-exports).
 *
 * Ceilings are deliberately conservative starting points — a brake, to be tuned
 * upward with real load-test data (see docs/production-readiness/LOAD_TEST_PLAN.md).
 *
 * QUOTA CEILING (discovered on first deploy, 2026-07-22): this project's
 * Cloud Run regional CPU allocation in us-central1 is 20 vCPU, and each
 * instance reserves one, so Cloud Run refuses any service with
 * maxInstances > 20. Every ceiling here therefore tops out at 20 until a
 * quota increase is granted — request it before the load test, which is
 * where the hot paths may genuinely want 40.
 */
import { CallableOptions } from "firebase-functions/v2/https";
import { DocumentOptions } from "firebase-functions/v2/firestore";
import { ScheduleOptions } from "firebase-functions/v2/scheduler";

/** All functions run here. Pinned, not left to the platform default. */
export const REGION = "us-central1";

/**
 * Baseline callable options with an explicit instance ceiling.
 *
 * App Check (production-readiness audit P0-2) is enforced HERE, on every
 * callable at once, so a new function cannot ship unattested by omission.
 * Requests without a valid App Check token are rejected with UNAUTHENTICATED
 * before the handler runs. Deploy-order matters — the iOS app must be
 * registered (App Attest + debug tokens) in Firebase console BEFORE this
 * reaches production, or every callable locks real users out; see
 * backend/README.md "App Check".
 *
 * @param maxInstances hard cap on concurrent Cloud Run instances for this
 *   function — the cost/abuse brake.
 * @param extra per-function additions (e.g. `secrets`) merged on top.
 */
export function callable(
  maxInstances: number,
  extra: CallableOptions = {}
): CallableOptions {
  return {
    region: REGION,
    // The following three are the current Firebase v2 defaults, made explicit so
    // a future default change can't silently move them. Not behaviour changes.
    // An extra MAY tune them (a future heavy function raising memory).
    concurrency: 80,
    memory: "256MiB",
    timeoutSeconds: 60,
    ...extra,
    // AFTER the spread on purpose: the instance ceiling and App Check are
    // mandatory — no per-function extra may drop the brake or ship an
    // unattested endpoint. There is no legitimate opt-out.
    maxInstances,
    enforceAppCheck: true,
  };
}

/** Same brake for the Firestore trigger. */
export function trigger(
  maxInstances: number,
  extra: Omit<DocumentOptions, "document"> = {}
): Omit<DocumentOptions, "document"> {
  return {
    region: REGION,
    maxInstances,
    memory: "256MiB",
    timeoutSeconds: 60,
    ...extra,
  };
}

/**
 * Same brake for scheduled functions. `maxInstances` is normally 1 — a cron
 * job that needs horizontal scale is a design smell, and a ceiling of one
 * makes overlapping runs impossible at the infrastructure level.
 */
export function scheduled(
  maxInstances: number,
  extra: Omit<ScheduleOptions, "schedule"> = {}
): Omit<ScheduleOptions, "schedule"> {
  return {
    region: REGION,
    maxInstances,
    memory: "256MiB",
    timeoutSeconds: 60,
    ...extra,
  };
}
