# Load Test Plan

_Audit date 2026-07-20. Goal: turn the analytical bottlenecks in
`CAPACITY_MODEL.md` into **measured** break points, safely, without touching
production or real users._

## Principles

1. **Never load-test production `moomo-c7a37`.** Use the Firebase Emulator Suite
   locally for logic/contention shape, and a **dedicated staging project** (e.g.
   `moomo-staging`) with synthetic accounts for realistic numbers.
2. **No real user data.** Seed synthetic profiles only. Reuse
   `backend/scripts/cleanup-integration-data.sh` patterns to purge after runs.
3. **Isolate cost.** Staging gets its own billing budget + hard `maxInstances` so
   a test can't run up a real bill.
4. **Measure the four hot paths first** (they are where the model predicts
   failure): presence writes, matchmaking contention, Discover reads, chat fan-out.

## Environments

| Env | Use | Notes |
|---|---|---|
| Emulator Suite | contention shape, correctness under concurrency, rule/quota behavior | free, deterministic; not real latency |
| `moomo-staging` (Blaze, isolated) | realistic latency/throughput/cost | synthetic users; budget-capped; App Check debug tokens |

## Tooling

- **k6** (or Artillery) for HTTP/callable load — callables are HTTPS endpoints;
  authenticate synthetic users via the Auth emulator/REST and call functions.
- A **Node seeding script** using the Admin SDK to create N synthetic
  `users`/`publicProfiles`/`matchmakingQueue` docs.
- **Firebase Emulator** started with `firebase emulators:start`.
- Metrics: Cloud Monitoring (staging), emulator logs, k6 summary (p50/p95/p99,
  error rate, RPS).

## Scenarios and thresholds

Ramp each to the three concurrency levels (10k / 50k / 100k _simulated actors_,
scaled down against emulator limits, full-scale on staging with distributed k6).

| # | Scenario | Drives | Pass thresholds |
|---|---|---|---|
| 1 | **Auth burst** | sign-up/SMS path (staging: mock SMS or test numbers) | p95 < 2s; error rate < 1%; no quota lockout |
| 2 | **Profile creation** | `users` + `publicProfiles` writes | p95 < 1s; write success ≥ 99.9% |
| 3 | **Feed loading** | Discover query + presence write | **presence write p95 < 500ms and NO rising-latency curve** (proves/refutes hotspot P1-1) |
| 4 | **Swipe/like/pass** | `submitCallDecision` | p95 < 1s; no lost decisions; exactly-one-match invariant holds |
| 5 | **Match creation** | mutual-like txn | exactly one match+conversation per pair under concurrency |
| 6 | **Chat burst** | message writes + `onMessageCreated` | p95 send < 1s; unread counts correct; trigger backlog ~0 |
| 7 | **Realtime listeners** | N listeners × writes | fan-out read cost measured; no listener errors |
| 8 | **Presence storm** | max-rate `lastActiveAt` writes | **find the writes/sec at which p95 degrades** — expect ~500/s (P1-1) |
| 9 | **Matchmaking contention** | concurrent `joinMatchmakingQueue` | **find joins/sec at which txn retry rate > 5% / latency doubles** (P1-2) |
| 10 | **Photo upload** | Storage `putData` | p95 < 3s; rules reject >5MB/non-jpeg |
| 11 | **Push fan-out** | N/A today (no FCM) — placeholder | document as not-applicable until FCM ships |
| 12 | **Video token + room** | `getCallMediaToken` + LiveKit join | token p95 < 800ms; join success ≥ 99%; TTL bounds enforced |
| 13 | **Block/report** | cascade callables | cascade completes; rate caps (20/50) enforced |
| 14 | **Account deletion** | `deleteAccount` on a heavy account | completes < callable timeout OR document the failure (P2-3) |
| 15 | **External failure injection** | LiveKit/Storage/Firestore unavailable | client degrades gracefully; no crash; honest error UI |
| 16 | **Function timeout / retry storm** | slow/failing callable | retries bounded; **maxInstances ceiling holds** (once P0-1 fixed) |

## Measurable global thresholds

| Metric | Target |
|---|---|
| p50 / p95 / p99 latency (callables) | < 300ms / < 1s / < 2.5s |
| Error rate | < 1% sustained, < 5% during 10× spike |
| Function concurrency | stays under configured `maxInstances` |
| Firestore write rate per hot index | **< 500/s** (presence must not exceed) |
| Matchmaking txn retry rate | < 5% |
| Crash-free sessions (client) | > 99.5% |
| Function CPU / memory | < 80% of allocation |
| Trigger backlog (`onMessageCreated`) | ~0 (no growing lag) |
| Video connection success | > 99% |
| Reconnection rate | < 2% of calls |
| Notification delivery (in-app) | < 5s to bell feed |
| Cost per 1,000 active users | measured, tracked against `COST_AND_QUOTA_MODEL.md` |

## Commands (safe, local emulator first)

```sh
# 1. Start emulators (already used by the test suites)
cd backend/functions && npm run build
firebase emulators:start --only firestore,auth,storage,functions --project moomo-loadtest

# 2. Seed synthetic data (write this script; Admin SDK against the emulator)
#    Point Admin SDK at the emulator so it CANNOT reach prod:
export FIRESTORE_EMULATOR_HOST=localhost:8080
export FIREBASE_AUTH_EMULATOR_HOST=localhost:9099
node loadtest/seed.mjs --users 50000

# 3. Run a k6 scenario against the functions emulator (example: presence storm)
#    k6 script authenticates synthetic users and hammers the target endpoint.
k6 run --vus 2000 --duration 5m loadtest/presence_storm.js
k6 run --vus 2000 --duration 5m loadtest/matchmaking_contention.js

# 4. Purge
node loadtest/purge.mjs   # or adapt backend/scripts/cleanup-integration-data.sh
```

> The emulator will not reproduce production Firestore's exact hotspot behavior
> (it doesn't shard the same way), so **scenarios 8 and 9 must also run on
> `moomo-staging`** to get real break points. Cap staging with a billing budget
> and `maxInstances` before running.

## Staging run guardrails

- Separate Firebase project, separate billing account or hard budget cap.
- `maxInstances` set low enough that a runaway test self-throttles.
- Synthetic phone numbers / mocked SMS provider — never send real SMS at volume.
- Tear down all synthetic data after each run; verify with a count query.

## Exit criteria to claim "ready for 50k concurrent"

1. Presence writes sustain the Viral rate with p95 < 500ms **after** the P1-1 fix.
2. Matchmaking sustains the Viral join rate with retry rate < 5% **after** the
   P1-2 fix.
3. No unbounded cost curve; `maxInstances` ceilings observed to hold.
4. Crash-free sessions > 99.5% under the 10× spike scenario.
5. Graceful degradation verified for each external-dependency outage.
