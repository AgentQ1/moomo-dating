# Observability and Incident Readiness Plan

_Audit date 2026-07-20. Remediation update 2026-07-21 (see "Implemented" below):
the backend now emits structured ops events and has kill switches; dashboards,
alert policies, Crashlytics, and on-call ownership are still console/process
work and remain launch blockers._

## Implemented in-repo (2026-07-21)

- **Structured events** (`backend/functions/src/observability.ts`): every
  entry is one JSON log line with a stable `event` field — build log-based
  metrics on `jsonPayload.event`:

  | Event | Emitted when | Metric/alert it feeds |
  |---|---|---|
  | `rate_limit_blocked` (WARN) | a per-user window fills, or the limiter fails closed (`reason` field distinguishes) | abuse dashboard; alert on sustained per-uid streaks |
  | `kill_switch_blocked` | a gated callable refuses (`blockedBy` names the flag) | verifies the brake is actually braking during an incident |
  | `matchmaking_paired` / `matchmaking_waiting` | every join outcome (`attempts`, `shardsScanned`, `rejoined`) | pairing success ratio; time-to-match proxy |
  | `matchmaking_txn_retry` | a pairing transaction ran >1 attempt | **the P1-2 contention early-warning** — alert when retries/joins > 5% (LOAD_TEST_PLAN threshold) |
  | `matchmaking_sweep` | each scheduled sweep (`swept` count) | queue-hygiene health; sudden spikes = client crash-loop |
  | `discovery_feed_served` | every feed response (`returned`, `pooled`, `blockedFiltered`, `fallbackUsed`, `durationMs`) | feed volume + latency; drop in `returned` = index/migration problem; sustained `fallbackUsed=true` = the activityBucket backfill hasn't run (see backend/README.md) |
  | `discovery_feed_suspicious` (WARN) | a caller rate-limits the feed | **profile-enumeration signal** (P0-3); alert on any sustained source |
  | `runtime_config_error` (WARN) | the kill-switch doc read failed | config-plane health |
  | `block_cascade_completed` | blockUser finished its message sweep | gap vs. blockUser invocations = crashed cascades accumulating |

  App Check rejections are logged by the platform itself (callable request
  verification failures) and counted in Firebase console → App Check metrics;
  alert there on rejected-request share once enforcement is live.
- **Kill switches / maintenance mode** (§5 below) exist at `config/runtime`
  and are tested (`guards.integration.test.mjs`). Flag semantics and the
  never-gated list: `backend/functions/src/runtime.ts`.
- **Rate limits** with fail-closed behavior (`src/ratelimit.ts`), tested.

Still NOT implemented (console/process, cannot live in this repo): Cloud
Monitoring dashboards and alert policies, log-based metric definitions,
Crashlytics/Performance SDKs in the iOS app, billing budget, PITR, runbook
drills, on-call ownership._

## Current state (verified in repo)

| Capability | Present? | Evidence |
|---|---|---|
| Structured client logs | Partial | `os.Logger` with subsystem/category (`auth`, `apns`, `firestore-listener`) — local only, not aggregated |
| Listener-failure surfacing | ✅ | `FirestoreListeners` publishes a "live updates paused" banner |
| Request/correlation IDs | ❌ | none in functions |
| Crash reporting | ❌ | Crashlytics not linked (only GoogleAppMeasurement/Analytics in SPM) |
| Performance monitoring | ❌ | none |
| Error-rate / latency alerts | ❌ | none |
| Billing alerts | ❌ | none |
| Function-concurrency alerts | ❌ | none |
| Firestore-usage / hotspot alerts | ❌ | none |
| Auth-abuse alerts | ❌ | none |
| LiveKit health monitoring | ❌ | none |
| AI-provider monitoring | N/A | no AI provider in use |
| Dashboards | ❌ | none |
| Runbooks | ❌ | none |
| Backups / PITR | Unverified | not in repo — check console |
| Restore testing | ❌ | none |
| Rollback procedure | ❌ | manual deploy, no documented rollback |
| Feature flags | ❌ | none |
| Kill switches | ❌ | none |
| Maintenance mode | ❌ | none |
| Degraded-mode behavior | Partial | honest failure UI for media/listeners; no global mode |
| Data-retention policy | ❌ | none (messages/reports/history grow unbounded) |
| Incident ownership | ❌ | undefined |

## Minimum viable observability before launch

### 1. Crash + performance (client)
- Add **Firebase Crashlytics** and **Performance Monitoring** (SDKs already
  adjacent in the Firebase package).
- Track: crash-free sessions (target > 99.5%), cold-start time, Discover load
  time, call-connect success, screen-hang rate.

### 2. Structured logs + correlation IDs (backend)
- Emit structured JSON logs from every callable with a generated `requestId`, the
  `uid`, function name, duration, and outcome. Cloud Functions logs → Cloud
  Logging automatically; add the fields.
- Log **decisions that matter**: pairing found/none, txn retry counts, rate-limit
  rejections, cascade completions.

### 3. Dashboards (Cloud Monitoring)
- Function invocations, error rate, p50/p95/p99 latency, active instances per
  function.
- Firestore: read/write/delete ops/sec, **per-collection write rate** (watch
  `publicProfiles` for the presence hotspot), listener count.
- Auth: sign-ins/sec, SMS sends/sec, verification failure rate.
- LiveKit: pull from LiveKit Cloud dashboard/webhooks — rooms, participant-minutes,
  bandwidth.
- Billing: current-month spend vs budget.

### 4. Alerts (with thresholds)

| Alert | Threshold | Why |
|---|---|---|
| Function error rate | > 2% over 5 min | early failure signal |
| Callable p95 latency | > 2s over 5 min | matchmaking contention onset |
| **`publicProfiles` write rate** | > 400/s (5-min avg) | approaching hotspot ceiling (P1-1) |
| Matchmaking txn retry rate | > 5% | contention (P1-2) |
| Function active instances | > 80% of `maxInstances` | scaling ceiling / possible abuse |
| **Daily spend** | > 50% / 80% / 100% of budget | billing attack / runaway (P0-1) |
| SMS sends | > 3× 7-day baseline | toll fraud (P1-6) |
| Auth failures | > 20% of attempts | credential stuffing / outage |
| LiveKit bandwidth | > daily cap | cost blowout |
| Crash-free sessions | < 99% | bad release |
| Storage egress | > 3× baseline | photo scrape (P0-3) |

### 5. Kill switches / feature flags / maintenance mode
- A `config/runtime` Firestore doc (Admin-write, client-read) with booleans:
  `matchmakingEnabled`, `callsEnabled`, `signupsEnabled`, `maintenanceMode`.
- Each heavy callable checks its flag and returns `unavailable` when off; the
  client shows a maintenance banner. This is the emergency brake P0-1 currently
  lacks.

### 6. Backups + retention
- Enable **Firestore PITR** (7-day) and scheduled daily exports to GCS.
- Define retention/TTL: messages (e.g. keep, or archive old threads), callHistory,
  reports (retain per legal policy), notifications (TTL 90d). Firestore TTL
  policies for time-boxed collections.
- **Test a restore** into staging at least once before launch.

### 7. Rollback + CI/CD
- CI (GitHub Actions): run rules tests, function tests, iOS unit tests,
  `npm audit`, build on every PR. Block deploy on failure.
- Document rollback: `firebase deploy` of a previous known-good ruleset/functions
  revision; Cloud Run keeps revisions for functions rollback.

## Incident response

- **Ownership:** assign an on-call owner and an escalation path before launch
  (currently undefined).
- **Runbooks to write** (one page each):
  1. Billing spike / suspected abuse → check dashboards, flip `maintenanceMode` /
     tighten `maxInstances`, enforce App Check, rotate API key if needed.
  2. Matchmaking degraded → check txn retry rate, disable matchmaking flag, scale.
  3. Firestore hotspot → identify hot collection, throttle presence, deploy fix.
  4. LiveKit outage → calls fail honestly already; post status, disable calls flag.
  5. Bad release → rollback functions/rules; disable feature flag.
  6. Data-loss suspicion → stop writes (maintenance), restore from PITR into
     staging, validate, then production.

## Degraded-mode targets

- LiveKit down → calls disabled with honest UI (already partially true); chat +
  Discover keep working.
- Firestore hotspot → presence throttled, Discover served stale, matchmaking
  paused rather than timing out for everyone.
- Functions at ceiling → shed non-critical callables (boost) before critical
  (matchmaking/decision) via flags.
