# Million-User Readiness Audit

_Audit date 2026-07-20. Scope: full repo — iOS client, Cloud Functions, Firestore
rules/indexes, Storage rules, config, tests. Every finding cites file:line and a
confidence label (Confirmed / Highly likely / Possible / Not verifiable)._

## Remediation status — updated 2026-07-21

A remediation pass landed in the repo (nothing deployed). Status labels:
**Fixed-in-repo** = code + tests exist and pass locally; **Deploy-gated** =
fixed in code but requires console/deploy steps to take effect; **Unproven at
scale** = implemented but the claim needs the load test (`LOAD_TEST_PLAN.md`)
— emulator tests prove correctness, not throughput; **Open** = not addressed.

| ID | Title | Status |
|---|---|---|
| P0-1 | maxInstances / kill switch / budget | **Fixed-in-repo** (ceilings on all 15 functions + `config/runtime` kill switches, tested) EXCEPT the Cloud Billing budget + PITR — console-only, **Open** |
| P0-2 | App Check | **Deploy-gated**: `enforceAppCheck: true` on every callable (helper-level, guardrail-tested); iOS installs a provider by default. Console registration (App Attest + debug tokens + API enable) MUST precede deploy — see backend/README.md |
| P0-3 | publicProfiles scrape | **Fixed-in-repo**: client `list` denied at any size (rules-tested); browsing only via `getDiscoveryFeed` — bounded, cursor-free, block/compat-filtered, rate-limited, PII-minimal DTO (no raw lastActiveAt). Single-doc `get` remains for signed-in users (uids not enumerable). Firestore-product App Check enforcement (console) still **Open** |
| P1-1 | Presence-write hotspot | **Fixed-in-repo, unproven at scale**: heartbeat throttled client-side (≤1/4min), `activityBucket` (10-min quantized) is the only ordered activity index, `lastActiveAt`/`updatedAt` single-field indexes disabled via fieldOverrides. Scenario 8 load test still required |
| P1-2 | Matchmaking FIFO contention | **Fixed-in-repo, unproven at scale**: sharded waiting pool (default 8), profile reads moved outside the pairing transaction (candidate heartbeats no longer abort it), sweep moved to a 1-min scheduled function, bounded retries (5) + retry logging, idempotent duplicate joins. Scenario 9 load test still required |
| P1-3 | Global same-25 feed | **Partially improved** (server-composed, waiting users reserved, bucket ordering adds churn) — still no geo/pagination/seen-exclusion. **Open** as a product-scale item |
| P1-4 | Rate limits | **Fixed-in-repo**: per-user windows on join/feed/token/decision/boost/deleteAccount, fail-closed, tested |
| P1-5 | Observability | **Partially fixed**: structured ops events + kill switches in code (tested). Dashboards, alert policies, Crashlytics, runbooks, on-call — **Open** (console/process) |
| P1-6 | SMS toll fraud | **Open** (console: region allowlist, quotas); App Check code raises the bar once deployed |
| P2-1 | Unread idempotency | **Open** (unchanged, non-blocking) |
| P2-2 | Client-side block filtering | **Fixed-in-repo**: the feed filters blocks both directions server-side (tested); the client wrapper stays as defense in depth |
| P2-3..P2-6, P3-x | | **Open** (unchanged) |

Test evidence for this pass: 144/144 rules, 104/104 functions integration,
196/196 iOS unit, `tsc` clean. All counts grew (was 135/50/168) — every fix
above added focused tests.

## How to read severity

- **P0** — security incident, data loss, unauthorized access, widespread outage,
  or uncontrolled billing.
- **P1** — likely to fail or severely degrade under viral traffic.
- **P2** — important scalability/reliability/maintainability problem.
- **P3** — optimization / long-term.

## Evidence base

- 135/135 Firestore rules tests pass (emulator).
- 50/50 Cloud Functions integration tests pass (emulator).
- 168/168 iOS unit tests pass (simulator).
- `tsc` typecheck + build clean. `npm audit`: 9–11 moderate (transitive).
- No load test has been run — all scale claims below are analytical and flagged.

---

## Findings

### P0-1 · No `maxInstances` / cost ceiling / kill switch on any function
- **Confidence:** Confirmed.
- **Where:** all of `backend/functions/src/*.ts` — every `onCall`/`onDocumentCreated`
  is bare (e.g. `matchmaking.ts:125`, `media.ts:35`, `account.ts:23`). No runtime
  options anywhere.
- **Problem:** no upper bound on instances/cost; no maintenance mode; no kill
  switch.
- **Failure scenario:** a viral spike or an abuse/retry loop scales Cloud Run
  instances and Firestore ops without limit → surprise bill and/or quota
  exhaustion that takes real users down.
- **User/cost impact:** uncontrolled billing (P0 by definition); potential outage.
- **Fix:** set `maxInstances` (and sensible `concurrency`, `memory`,
  `timeoutSeconds`) per function; add a Cloud Billing budget with alerts; add a
  `killSwitch`/`maintenance` flag checked at the top of each callable.
- **Difficulty:** Low (config). **Before launch:** Yes.

### P0-2 · App Check not enforced — no app-integrity gate
- **Confidence:** Confirmed.
- **Where:** `index.ts:9`, `backend/README.md:73`, `FirebaseBootstrap.swift:63-84`.
- **Problem:** every callable and every `publicProfiles` query accepts any valid
  Auth token; tokens are trivially minted (API key is in the bundle).
- **Failure scenario:** scripted bots register, scrape, and hammer callables as
  "legitimate" users.
- **Security/cost impact:** enables P0-3, P1-4, and the billing attacks.
- **Fix:** enable App Check API, register App Attest + debug tokens, verify
  metrics, then flip `enforceAppCheck` per callable (staged: monitor → enforce).
- **Difficulty:** Medium (rollout care). **Before launch:** Yes.

### P0-3 · `publicProfiles` is mass-scrapable PII (incl. photos, minors)
- **Confidence:** Confirmed.
- **Where:** `firestore.rules:159-163`; photos `storage.rules:38`.
- **Problem:** `allow get: if isSignedIn()` and `list` with only `limit<=50`; an
  authenticated script pages the whole base and pulls names, ages, cities,
  genders, preferences, and photos.
- **Failure scenario:** full profile+photo dump of 1M users → doxxing/catfishing
  dataset; privacy/regulatory incident.
- **Fix:** App Check on reads + a server-composed, block-filtered, rate-limited
  feed callable; stop exposing raw `orderBy` over the collection.
- **Difficulty:** Medium-High (new feed path). **Before launch:** Yes.

### P1-1 · Presence-write hotspot on monotonic `lastActiveAt`
- **Confidence:** High (documented Firestore anti-pattern).
- **Where:** `FirestoreDiscoveryService.swift:29-33` (write) + `:42-45` (indexed
  orderBy).
- **Problem:** every Discover open writes a monotonically increasing indexed
  timestamp; Firestore soft-limits ~500 writes/s to a sequential index before
  hotspotting.
- **Failure scenario:** Viral peak ≈1,250 writes/s and Extreme ≈2,500/s (see
  `CAPACITY_MODEL.md` §2) — 2.5–5× over the ceiling → write latency spikes,
  contention, Discover stalls. **This breaks first.**
- **Fix:** decouple presence from the ordering index — e.g. quantize
  `lastActiveAt` to a coarse bucket (5-min), write presence to a separate
  sharded/`onlineStatus` structure, or throttle heartbeats client-side (write at
  most once/N minutes). Reduce write frequency and remove monotonicity from the
  hot index.
- **Difficulty:** Medium. **Before launch:** Yes for 50k target.

### P1-2 · Matchmaking FIFO-head transaction contention
- **Confidence:** High (mechanism); break point needs load test.
- **Where:** `matchmaking.ts:143-224` (pairing txn on 10 oldest waiting) +
  `:283-309` (`sweepStaleQueueEntries` txn per join/leave).
- **Problem:** all concurrent joiners' transactions read/write the same head of
  the queue → serialization, retries, aborts. The per-call sweep transaction
  contends on the same collection.
- **Failure scenario:** at Viral, hundreds of pairing txns/sec on ~10 hot docs →
  matchmaking latency climbs, throughput collapses, users see "no one available"
  while people are actually waiting.
- **Fix:** shard the waiting pool (e.g. by mode+bucket), pop candidates with less
  contention, move `sweepStaleQueueEntries` to a scheduled function (not
  per-request), and consider a queue design that doesn't force every joiner
  through one ordered head.
- **Difficulty:** High (core algorithm). **Before launch:** Yes for 50k target;
  a scheduled sweep + guarding the sweep is a partial mitigation shippable now.

### P1-3 · Global Discover feed — everyone sees the same 25; no pagination/geo
- **Confidence:** Confirmed (direct from query).
- **Where:** `FirestoreDiscoveryService.swift:42-45`.
- **Problem:** `orderBy(lastActiveAt desc).limit(25)` globally. No geography, no
  cursor, no already-seen exclusion, and read load concentrates on the index's
  leading edge.
- **Failure scenario:** at scale the same handful of most-recently-active people
  are shown to the entire user base — product-breaking — and read hotspotting.
- **Fix:** server-composed feed with geo/pref sharding, pagination, and diversity;
  same path that fixes P0-3.
- **Difficulty:** High. **Before launch:** Yes (product + scale).

### P1-4 · No per-user rate limiting on heavy callables
- **Confidence:** Confirmed.
- **Where:** `matchmaking.ts`, `media.ts`, `boost.ts`, `decisions.ts`,
  `calls.ts`, `account.ts` — no limits (only `safety.ts` has 20/day, 50/day).
- **Problem/scenario:** scripted or buggy-retry hammering drives cost, contention,
  and griefing.
- **Fix:** per-uid token bucket on the heaviest first (`joinMatchmakingQueue`,
  `getCallMediaToken`, `activateBoost`).
- **Difficulty:** Medium. **Before launch:** Yes.

### P1-5 · No observability, alerting, or incident tooling
- **Confidence:** Confirmed (nothing in repo; no Crashlytics in SPM; no dashboards/runbooks).
- **Where:** repo-wide absence; `MoomoAppDelegate` has only `os.Logger`.
- **Problem:** you cannot see error rates, latency, function concurrency,
  Firestore hotspots, crash-free rate, or billing in real time; no alerts; no
  runbooks; no rollback plan.
- **Failure scenario:** a viral-day incident is invisible until users complain or
  the bill arrives; MTTR is unbounded.
- **Fix:** see `OBSERVABILITY_AND_INCIDENT_PLAN.md` — Crashlytics, Cloud
  Monitoring dashboards + alerts, correlation IDs, billing budget, runbooks.
- **Difficulty:** Medium. **Before launch:** Yes.

### P1-6 · SMS toll-fraud / bot-registration exposure
- **Confidence:** Highly likely.
- **Where:** `FirebaseAuthenticationService.swift:222`; no App Check / region
  allowlist.
- **Fix:** App Check for phone auth, SMS region allowlist, per-IP/number alerts.
- **Difficulty:** Low-Medium. **Before launch:** Yes.

### P2-1 · `onMessageCreated` unread increment not idempotent
- **Confidence:** Highly likely. **Where:** `chat.ts:40`.
- **Impact:** cosmetic wrong unread count on duplicate trigger delivery; self-heals.
- **Fix:** dedupe by message id or recompute. **Before launch:** No.

### P2-2 · Client-side-only block filtering in Discover
- **Confidence:** Confirmed. **Where:** `AppServices.swift:185`.
- **Impact:** blocked profiles retrievable outside UI (no interaction possible).
- **Fix:** server-side filtering via the composed feed. **Before launch:** With P0-3.

### P2-3 · `deleteAccount` is unbounded sequential work in a 60s callable
- **Confidence:** Highly likely. **Where:** `account.ts:31-59`.
- **Problem:** loops `recursiveDelete` over every match/conversation/session
  sequentially; a heavy account (or one inflated by abuse) can exceed the callable
  timeout. It is retry-safe (Auth user deleted last), so data isn't lost, but the
  UX is a failed deletion that must be retried, and GDPR "delete" should be
  reliable.
- **Fix:** move to a background/queued job (Tasks/Pub-Sub) with progress; or batch
  and continue. **Before launch:** Recommended, not strictly blocking.

### P2-4 · Single region, no failover / regional strategy
- **Confidence:** Confirmed. **Where:** default `us-central1`; no config.
- **Impact:** non-US latency; a region incident is a total outage.
- **Fix:** accept for launch with a documented RTO; plan multi-region for global
  scale. **Before launch:** No (document the risk).

### P2-5 · No CI/CD; manual, ungated deploys
- **Confidence:** Confirmed (no `.github/workflows`).
- **Impact:** deploys can ship untested rules/functions; no automated rollback.
- **Fix:** CI running the three test suites + `npm audit` + build on every PR;
  gated deploy; documented rollback. **Before launch:** Strongly recommended.

### P2-6 · No backup / PITR verification; no data-retention policy
- **Confidence:** Not verifiable from repo.
- **Impact:** unclear recovery from corruption/bad deploy; messages/reports grow
  unbounded.
- **Fix:** enable Firestore PITR + scheduled exports; define retention/TTL for
  messages, callHistory, reports; test a restore.
- **Before launch:** Enable PITR (Yes); retention (soon after).

### P3-1 · Transitive npm vulnerabilities (moderate)
- **Confidence:** Confirmed. **Fix:** track upstream, `npm audit` in CI.

### P3-2 · No push notifications (re-engagement gap)
- **Confidence:** Confirmed. Product, not scale. **Fix:** FCM when ready (adds its
  own fan-out cost to model later).

---

## Summary table

| ID | Sev | Confidence | Title | Before launch |
|---|---|---|---|---|
| P0-1 | P0 | Confirmed | No maxInstances/budget/kill switch | Yes |
| P0-2 | P0 | Confirmed | App Check not enforced | Yes |
| P0-3 | P0 | Confirmed | publicProfiles mass-scrapable PII | Yes |
| P1-1 | P1 | High | Presence-write hotspot (lastActiveAt) | Yes |
| P1-2 | P1 | High | Matchmaking FIFO-head contention | Yes (for 50k) |
| P1-3 | P1 | Confirmed | Global Discover feed / no pagination | Yes |
| P1-4 | P1 | Confirmed | No rate limits on heavy callables | Yes |
| P1-5 | P1 | Confirmed | No observability/alerting/runbooks | Yes |
| P1-6 | P1 | Highly likely | SMS toll-fraud exposure | Yes |
| P2-1 | P2 | Highly likely | Non-idempotent unread increment | No |
| P2-2 | P2 | Confirmed | Client-side block filtering | With P0-3 |
| P2-3 | P2 | Highly likely | deleteAccount unbounded in callable | Recommended |
| P2-4 | P2 | Confirmed | Single region, no failover | No (document) |
| P2-5 | P2 | Confirmed | No CI/CD | Recommended |
| P2-6 | P2 | Not verifiable | No PITR/retention verified | Enable PITR |
| P3-1 | P3 | Confirmed | Transitive npm vulns | No |
| P3-2 | P3 | Confirmed | No push notifications | No |

## What is explicitly NOT a problem

- Authorization/rules logic (135 tests; deny-by-default; server-owned data).
- Match/decision race safety (block-vs-like serialized in transactions; tested).
- Media token security (scoped, clock-bound, server-minted; tested).
- Image handling (client downsample via ImageIO; 5 MB + MIME cap in rules).
- Listener lifecycle (services remove listeners on deinit; AppServices caches one
  graph per uid to avoid per-render listener churn — `AppServices.swift:51`).
- Idempotent profile bootstrap (transactional, only-absent writes —
  `FirestoreProfileStore.swift:23`).
