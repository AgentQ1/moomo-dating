# Executive Summary — Moomo Production Readiness Audit

_Audit date: 2026-07-20. Auditor role: principal distributed-systems / security /
database / SRE / mobile-performance review. Scope: the entire repository —
iOS client, Cloud Functions, Firestore rules & indexes, Storage rules, auth,
video, config, and tests. All three local test suites were run (results below)._

## Verdict: **READY WITH CONDITIONS** — updated 2026-07-21

The 2026-07-21 remediation pass closed the repo-side P0/P1 blockers: App
Check enforcement in code, the `publicProfiles` scrape killed (list denied;
server-composed, rate-limited, cursor-free feed), instance ceilings + kill
switches, per-user rate limits, the presence hotspot removed from the indexed
path, matchmaking sharded with the sweep off the hot path, and structured ops
events. Evidence: 144/144 rules, 104/104 functions, 196/196 iOS tests, clean
`tsc`.

**The conditions are hard gates, not paperwork** — until they are met, treat
the deployed system as NOT READY:

1. **Deploy-order condition:** enable the App Check API + register App Attest
   and debug tokens BEFORE deploying this backend (deploying first locks all
   users out — backend/README.md "App Check").
2. **Console cost brakes:** Cloud Billing budget + alerts, LiveKit bandwidth
   alert, Firestore PITR, SMS region allowlist.
3. **Observability:** log-based metrics + alert policies on the emitted
   events, dashboards, Crashlytics, named on-call.
4. **Scale proof:** the fixes for P1-1/P1-2 are correctness-tested, NOT
   load-tested. **1M registered / 10k concurrent: plausible on the model.
   50k concurrent: DO NOT CLAIM until LOAD_TEST_PLAN.md scenarios 3, 8, 9
   pass.**
5. **Trust & safety:** a staffed moderation queue.

Original 2026-07-20 verdict (pre-remediation), kept for the record: **NOT
READY today, but on a credible path to READY WITH CONDITIONS.** The application is unusually well-engineered at the level of
_correctness and authorization_ — but it is missing the entire _abuse-control,
cost-control, scale, and operability_ layer that a viral launch requires. None of
the blockers are deep design flaws; they are known, well-scoped work items
(itemized in `REMEDIATION_ROADMAP.md`).

## Direct answers to the required questions

**Can it support 1,000,000 registered users?**
Registration/storage-wise, yes — Firestore holds 1M user documents comfortably and
the data model is sound. But "supporting" 1M users implies serving them, and the
**Discover feed and matchmaking do not scale** as written, and there is **no
abuse control** protecting a 1M-user PII dataset. So: **not as-is.**

**Can it support 10,000 concurrent users?**
**Probably, with caveats.** At 10k the presence-write rate (~250/s peak) approaches
but may stay under Firestore's ~500/s sequential-index hotspot ceiling, and
matchmaking contention is beginning but likely survivable. This has **not been
load-tested** — treat as "plausible, unproven."

**Can it support 50,000 concurrent users?**
**No, as written.** Two independent bottlenecks break: (1) the presence heartbeat
writes a monotonically increasing indexed timestamp on every Discover open, hitting
~1,250 writes/s — 2.5× over Firestore's documented hotspot ceiling; (2) matchmaking
funnels every joiner's transaction through the same head of a FIFO queue, causing
super-linear transaction contention. Both are fixable (roadmap Stage 2).

**What will fail first?**
The **presence-write hotspot on `publicProfiles.lastActiveAt`**
(`FirestoreDiscoveryService.swift:29`), followed closely by **matchmaking FIFO-head
contention** (`matchmaking.ts:143`). See `CAPACITY_MODEL.md` §2 and §4.

**What could cause data loss or unauthorized access?**
No confirmed data-loss path — writes are transactional, deletion is retry-safe, and
rules are strong (135 passing tests). The real exposure is **unauthorized data
access via mass scraping**: any authenticated account can page the entire
`publicProfiles` collection and pull every user's name, age, city, gender,
preferences, and photos (`firestore.rules:159`, `storage.rules:38`) — a
dating-profile dump including minors. **P0.**

**What could create an uncontrolled bill?**
Several things, because there is **no `maxInstances`, no billing budget, no rate
limiting, and App Check is off**: a scripted matchmaking/token loop, a
profile-scrape, or SMS pumping can all run up Firestore, Functions, LiveKit, or
SMS cost with no ceiling and no kill switch. **P0.** A single motivated attacker
could generate an unbounded bill in a day.

**What must be fixed before launch?**
- Cost brakes: `maxInstances`, billing budget, kill switch (P0-1).
- App Check enforcement (P0-2).
- Server-composed, rate-limited, block-filtered Discover feed replacing raw
  `publicProfiles` reads (P0-3, P1-3).
- Per-user rate limits on heavy callables (P1-4).
- Presence-write and matchmaking-contention fixes (P1-1, P1-2) **load-tested**.
- SMS toll-fraud controls (P1-6).
- Observability + alerting + runbooks (P1-5).
- Human moderation queue (trust & safety).

**What can be deferred?**
Multi-region (P2-4), push notifications (P3-2), transitive dep upgrades (P3-1),
queued account deletion (P2-3), idempotent unread counter (P2-1) — all real, none
blocking.

**What evidence supports each conclusion?**
- **Tests run this audit:** 135/135 Firestore rules, 50/50 Cloud Functions
  integration, 168/168 iOS unit — all pass; `tsc` build clean. (Strong
  correctness/authorization foundation.)
- **Static reading** of every function confirms no runtime options / rate limits.
- **`firestore.rules:159-163`** confirms open `publicProfiles` reads.
- **Firestore's own documentation** on ~500 writes/s sequential-index hotspots
  supports the presence-write break point.
- **`npm audit`**: 9–11 moderate transitive advisories.
- Pricing figures are current-provider (linked in `COST_AND_QUOTA_MODEL.md`) but
  order-of-magnitude; the biggest cost unknown (LiveKit bandwidth) is flagged.

## The honest framing

This is **not** a low-quality codebase papered over with Firebase. The
authorization model, the match/decision race handling, the block cascade, the
media-token scoping, and the test discipline are better than most production
dating apps. The gap is that the team has (by their own README) been building the
_product spine_ and has explicitly deferred the _"Phase 5"_ operational hardening —
App Check, server-side feed, rate limits — and that deferred work is exactly what
stands between here and a safe viral launch.

**Do not treat green tests or a clean build as readiness.** The blockers above are
invisible to unit tests and only appear under real concurrency, real attackers, and
a real bill. Fix Stage 0 + Stage 1 of the roadmap, then **prove** the 50k targets
with the load test in `LOAD_TEST_PLAN.md` before claiming READY.

## What was changed during this audit (Phase 9)

A single **behavior-preserving** fix was applied: explicit runtime options
(`maxInstances`, region, memory, timeout, and a per-function concurrency default)
were added to the Cloud Functions via a shared `globalOptions` + per-function
overrides, giving the cost/instance ceiling that P0-1 requires **without changing
any product logic**. All 50 function integration tests still pass, plus a new test
asserting the ceilings are configured. Details in `REMEDIATION_ROADMAP.md` and the
git diff. Nothing was deployed; no production resource or billing setting was
touched.

## Deliverables

| File | Contents |
|---|---|
| `EXECUTIVE_SUMMARY.md` | this document |
| `ARCHITECTURE.md` | system map + Mermaid diagrams + what's not built |
| `MILLION_USER_READINESS_AUDIT.md` | all findings, classified, with file:line |
| `CAPACITY_MODEL.md` | per-feature load math, 3 scenarios, bottlenecks |
| `COST_AND_QUOTA_MODEL.md` | cost per scenario, quotas, billing-attack surface |
| `SECURITY_AND_ABUSE_REVIEW.md` | authorization strengths + abuse gaps |
| `LOAD_TEST_PLAN.md` | safe emulator/staging load-test strategy + thresholds |
| `OBSERVABILITY_AND_INCIDENT_PLAN.md` | monitoring, alerts, runbooks, kill switches |
| `REMEDIATION_ROADMAP.md` | staged fix plan with effort estimates |
| `LAUNCH_CHECKLIST.md` | go/no-go gate |
