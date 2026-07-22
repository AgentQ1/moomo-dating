# Remediation Roadmap

_Audit date 2026-07-20. Ordered by risk-reduction per unit effort. Each item maps
to a finding in `MILLION_USER_READINESS_AUDIT.md`._

## Status update — 2026-07-21 remediation pass (repo only, nothing deployed)

Done in-repo with passing tests: **0.2** (maxInstances, all functions),
**0.3** (kill switches at `config/runtime`), **1.2** (`enforceAppCheck` in
code — console registration 1.1 still open and MUST precede deploy), **1.3**
(rate limits: join/feed/token/decision/boost/delete), **2.1** (heartbeat
throttle + quantized `activityBucket` + hot-index overrides), **2.2**
(scheduled sweep), **2.3** (sharded waiting pool + out-of-txn profile reads +
idempotent joins — code, not load-proven), **2.4** (server-composed
`getDiscoveryFeed`; client `list` denied — no pagination yet), plus the
structured-events half of **1.5**.

Still open: 0.1/0.4 (billing budget, PITR — console), 0.5 (CI), 1.1 (App
Check console), 1.4 (SMS allowlist), dashboards/alerts/Crashlytics (1.5),
2.5 (Firestore-product App Check), all of Stage 3/4, and **the load test that
gates every 50k claim**.

## Stage 0 — Cheap safety nets (hours, before ANY public exposure)

| # | Action | Finding | Effort | Notes |
|---|---|---|---|---|
| 0.1 | Set a **Cloud Billing budget + alerts** (50/80/100%) | P0-1 | 1h | console; no code |
| 0.2 | Set **`maxInstances`** on every function | P0-1 | 2h | code (see below); pick per-function ceilings |
| 0.3 | Add a **kill-switch / maintenance flag** checked in each callable | P0-1, P1-5 | 0.5d | `config/runtime` doc |
| 0.4 | Enable **Firestore PITR** + daily export | P2-6 | 1h | console |
| 0.5 | Add **CI** running the 3 test suites + audit + build | P2-5 | 0.5d | GitHub Actions |

Stage 0 removes the "unbounded bill / no brakes" class of risk without changing
product behavior. **0.2 is implemented in this audit (see Phase 9 below).**

## Stage 1 — Abuse controls (days, before launch)

| # | Action | Finding | Effort |
|---|---|---|---|
| 1.1 | Enable App Check API, register App Attest + debug tokens, **monitor** | P0-2 | 1d |
| 1.2 | Flip `enforceAppCheck` per callable once metrics show real traffic | P0-2 | 0.5d |
| 1.3 | Per-user **rate limits** on `joinMatchmakingQueue`, `getCallMediaToken`, `activateBoost`, `submitCallDecision` | P1-4 | 2–3d |
| 1.4 | **SMS region allowlist** + auth-abuse alerts | P1-6 | 0.5d |
| 1.5 | Observability: Crashlytics + Perf Mon + dashboards + alerts | P1-5 | 3–5d |

## Stage 2 — Scale the hot paths (1–2 weeks, before 50k target)

| # | Action | Finding | Effort |
|---|---|---|---|
| 2.1 | **Throttle presence heartbeat** client-side (write ≤ 1/N min) + quantize `lastActiveAt` off the hot ordering index | P1-1 | 2–3d |
| 2.2 | Move `sweepStaleQueueEntries` to a **scheduled function**; stop running it per request | P1-2 | 1d |
| 2.3 | **Shard the matchmaking waiting pool** to remove FIFO-head contention | P1-2 | 1–2wk |
| 2.4 | **Server-composed Discover feed** callable: bounded, block-filtered, paginated, geo/pref-sharded — replaces raw `publicProfiles` reads | P0-3, P1-3, P2-2 | 1–2wk |
| 2.5 | Enforce App Check on `publicProfiles` reads once feed lands | P0-3 | 0.5d |

## Stage 3 — Operability + trust & safety (parallel with Stage 2)

| # | Action | Finding | Effort |
|---|---|---|---|
| 3.1 | **Moderation queue UI** + staffing + SLA + auto-suspend on N distinct reporters | P2-3(safety) | 1–2wk |
| 3.2 | **`deleteAccount` → queued job** with progress | P2-3 | 3–5d |
| 3.3 | Data-retention/TTL policies (messages, history, notifications, reports) | P2-6 | 2–3d |
| 3.4 | Runbooks + on-call ownership + restore test | P1-5 | 2–3d |
| 3.5 | Idempotent `onMessageCreated` (dedupe by message id) | P2-1 | 0.5d |

## Stage 4 — Global scale (post-launch)

| # | Action | Finding | Effort |
|---|---|---|---|
| 4.1 | Multi-region strategy (functions + data locality) | P2-4 | weeks |
| 4.2 | Push notifications (FCM) + model its fan-out cost | P3-2 | 1–2wk |
| 4.3 | Track/upgrade transitive deps; `npm audit` gate | P3-1 | ongoing |

## Suggested `maxInstances` starting points (Stage 0.2)

Ceilings are deliberately conservative — a real brake, tune up with load data.
Matchmaking is kept lowest because it is the most contention- and cost-sensitive.

| Function | maxInstances | Rationale |
|---|---|---|
| joinMatchmakingQueue | 40 | heaviest txn; contention-bound anyway |
| leaveMatchmakingQueue | 20 | light |
| submitCallDecision | 30 | per-call |
| endCallSession | 30 | per-call |
| getCallMediaToken | 30 | per-call; cost lever |
| onMessageCreated | 40 | chat fan-out |
| blockUser / unmatchUser / reportUser | 10 each | rare, rate-capped |
| activateBoost | 10 | rare |
| deleteAccount | 5 | rare, heavy |
| sendSystemNotification / resolveReport | 5 each | admin only |

These are enforced via a shared `runWith` default plus per-function overrides —
see the Phase 9 change in the repo.

## Definition of "launch-ready" (READY WITH CONDITIONS → READY)

All Stage 0 + Stage 1 done, Stage 2.1/2.2/2.4 done and **load-tested** to the 50k
targets in `LOAD_TEST_PLAN.md`, Stage 3.1 (moderation) staffed, and observability
live with alerts firing to an on-call owner.
