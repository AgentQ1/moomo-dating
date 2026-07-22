# Launch Checklist

_Audit date 2026-07-20. Gate for a public launch targeting 1M registered / 50k
concurrent. Check every box or accept the documented risk with a named owner._

## Blockers (must be done — do not launch without these)

_Updated 2026-07-21: [x] = done in-repo with passing tests. Checked boxes with
a "verify deployed" note are code-complete but count only after the deploy +
console state is confirmed. Nothing here has been load-tested._

### Cost & runaway protection
- [ ] Cloud Billing budget + alerts at 50/80/100% (P0-1) — _console only_
- [x] `maxInstances` set on every function (P0-1) — _all 15 functions, ceiling-tested; verify deployed state_
- [x] Kill-switch / maintenance-mode flag wired into callables (P0-1, P1-5) —
      _`config/runtime` flags, tested; safety/leave/end/delete never gated_
- [ ] LiveKit bandwidth cap + alert (cost)

### Abuse & security
- [ ] App Check API enabled, App Attest + debug tokens registered (P0-2) —
      _console; MUST precede the next functions deploy (see backend/README.md)_
- [x] `enforceAppCheck: true` on all callables (P0-2) — _in code via shared
      helper, guardrail-tested; "verified after monitoring" happens at rollout_
- [x] Server-composed, block-filtered Discover feed replacing raw
      `publicProfiles` reads (P0-3, P2-2) — _`getDiscoveryFeed`, tested;
      client `list` denied by rules; NOT paginated (P1-3 still open)_
- [ ] App Check enforced on `publicProfiles` reads (P0-3) — _Firestore-product
      enforcement in console; rules-level list-deny already landed_
- [x] Per-user rate limits on matchmaking / feed / media-token / boost /
      decision / deleteAccount (P1-4) — _fail-closed, tested_
- [ ] SMS region allowlist + auth-abuse alerts; Firebase built-in abuse
      protection confirmed on (P1-6)

### Scale (the hot paths)
- [x] Presence heartbeat throttled + off the monotonic ordering index (P1-1) —
      _client throttle + quantized `activityBucket` + index overrides;
      correctness tested, throughput NOT proven_
- [x] `sweepStaleQueueEntries` moved to a scheduled function (P1-2)
- [x] Matchmaking waiting pool sharded (P1-2) — _shard scan + out-of-txn
      profile reads + idempotent joins, tested at emulator scale only_
- [ ] Cloud Run CPU **quota increase** for us-central1 — the project's 20 vCPU
      allocation caps every function at `maxInstances ≤ 20` (hit on the
      2026-07-22 deploy; hot-path ceilings were lowered from 40/30 to 20 to
      fit). Request the increase before the load test, which is where the hot
      paths may genuinely need more
- [ ] **Load test passed** to 50k targets in `LOAD_TEST_PLAN.md` (scenarios 3, 8,
      9 especially) — **still the gate for any 50k claim**

### Trust & safety
- [ ] Human moderation queue live + staffed + SLA (P2 safety)
- [ ] Auto-suspend policy on N distinct reporters
- [ ] Underage-report fast path

### Observability & incident readiness
- [x] Structured ops events emitted by the backend (P1-5) — _see
      OBSERVABILITY_AND_INCIDENT_PLAN.md "Implemented"; log-based metrics and
      alert policies still need to be created in the console_
- [ ] Crashlytics + Performance Monitoring live (P1-5)
- [ ] Cloud Monitoring dashboards (functions, Firestore per-collection writes,
      auth, billing) (P1-5)
- [ ] Alerts wired to an on-call owner (see thresholds in observability plan)
- [ ] Runbooks written (billing spike, matchmaking degraded, hotspot, LiveKit
      outage, bad release, data-loss)
- [ ] Firestore PITR enabled + a restore tested (P2-6)
- [ ] Named incident owner + escalation path

### Release hygiene
- [ ] CI runs all three test suites + `npm audit` + build, gates deploy (P2-5)
- [ ] Documented rollback procedure for rules + functions
- [ ] `firebase use` confirmed `moomo-c7a37` in the deploy runbook (never
      `moomoios-2026`)
- [ ] LiveKit `LIVEKIT_URL` + secrets set in `moomo-c7a37` (calls fail honestly
      until then)

## Strongly recommended (do before, or accept documented risk)
- [ ] `deleteAccount` moved to a queued job (P2-3)
- [ ] Data-retention / TTL policies (P2-6)
- [ ] Idempotent `onMessageCreated` (P2-1)
- [ ] Single-region risk documented with an RTO (P2-4)

## Deferrable (post-launch)
- [ ] Multi-region strategy (P2-4)
- [ ] Push notifications / FCM (P3-2)
- [ ] Transitive dependency upgrades (P3-1)

## Pre-launch verification commands

```sh
# Backend tests must pass
cd backend/rules-tests && npm test          # expect 144/144
cd ../functions && npm test                 # expect 104/104

# iOS unit tests must pass
cd app && xcodebuild test -project Moomo.xcodeproj -scheme Moomo \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MoomoTests

# Confirm deploy target and function config
firebase use                                # MUST print moomo-c7a37
firebase functions:list --project moomo-c7a37
# After deploy, confirm maxInstances/enforceAppCheck are actually set on each
# Cloud Run service (repo config is necessary but verify the deployed state).
```

## Sign-off

| Area | Owner | Status |
|---|---|---|
| Cost controls | | |
| App Check / abuse | | |
| Matchmaking scale | | |
| Discover feed | | |
| Moderation | | |
| Observability | | |
| Load test evidence | | |

**Do not sign off "READY" until the load test in `LOAD_TEST_PLAN.md` produces
evidence for the 50k targets. Successful compilation and green unit tests are
necessary but not sufficient.**
