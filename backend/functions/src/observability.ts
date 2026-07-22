/**
 * Structured operational events (production-readiness audit P1-5).
 *
 * Every event lands in Cloud Logging as one JSON entry with a stable
 * `event` field, so log-based metrics and alerts can be built per event name
 * without parsing message strings — see
 * docs/production-readiness/OBSERVABILITY_AND_INCIDENT_PLAN.md for the
 * metrics/alerts each event feeds.
 *
 * Only decisions that matter are logged: rate-limit rejections, kill-switch
 * rejections, matchmaking outcomes and transaction retries, sweep results,
 * discovery feed stats. Per-invocation counts/latency/errors come from the
 * platform's built-in function metrics; duplicating them here would be noise.
 */
import { logger } from "firebase-functions";

/** Event names, closed set — an alert on a typo'd name never fires. */
export type OpsEvent =
  | "rate_limit_blocked"
  | "kill_switch_blocked"
  | "runtime_config_error"
  | "matchmaking_paired"
  | "matchmaking_waiting"
  | "matchmaking_txn_retry"
  | "matchmaking_sweep"
  | "discovery_feed_served"
  | "discovery_feed_suspicious"
  | "block_cascade_completed";

export interface OpsEntry {
  event: OpsEvent;
  [key: string]: unknown;
}

/**
 * Emits one structured log entry and returns it (returned for tests — the
 * emulator suite asserts shapes without scraping stdout).
 *
 * `warn` severity for the abuse-shaped events so a Cloud Logging sink on
 * severity>=WARNING catches exactly the operator-attention set.
 */
export function logEvent(
  event: OpsEvent,
  fields: Record<string, unknown> = {}
): OpsEntry {
  // `event` after the spread: the name is the alert key and stays
  // authoritative even if a caller's fields carry an `event` key.
  const entry: OpsEntry = { ...fields, event };
  if (
    event === "rate_limit_blocked" ||
    event === "discovery_feed_suspicious" ||
    event === "runtime_config_error"
  ) {
    logger.warn(event, entry);
  } else {
    logger.info(event, entry);
  }
  return entry;
}
