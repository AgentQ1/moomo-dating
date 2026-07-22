# Security and Abuse Review

_Audit date 2026-07-20. Based on reading `firestore.rules`, `storage.rules`, all
Cloud Functions, and the iOS auth/service layer, plus 135 passing rules tests and
50 passing function tests._

## Remediation status — 2026-07-21

The abuse-control layer this review found missing now exists in the repo
(144/144 rules + 104/104 function tests pass; nothing deployed):

- **App Check (P0):** `enforceAppCheck: true` on every callable via the shared
  options helper, with guardrail tests (helper output + source scan). The iOS
  provider now installs BY DEFAULT (`FirebaseBootstrap.swift`; opt out locally
  with `MOOMO_DISABLE_APP_CHECK=1` — the old `MOOMO_ENABLE_APP_CHECK` opt-in is
  gone). Remaining exposure: console registration must precede deploy, and
  Firestore/Storage product-level enforcement is still off.
- **Scrape (P0/P1):** client `list` on `publicProfiles` is denied at any page
  size; browsing is only the `getDiscoveryFeed` callable — bounded (≤25),
  cursor-free (no enumeration handle), block-filtered both directions,
  compatibility-filtered, rate-limited (20/min), and PII-minimal (`isOnline`
  boolean instead of raw `lastActiveAt`). Single-doc `get` by unguessable uid
  remains for legitimate profile cards.
- **Rate limits (P1):** per-user fixed windows, fail-closed —
  join 12/min, feed 20/min, media token 10/min, decision 20/min, boost 5/min,
  deleteAccount 3/h (`src/ratelimit.ts`), counters in server-only `rateLimits/`.
- **Cost ceilings (P0):** maxInstances on all 15 functions + `config/runtime`
  kill switches (safety/leave/end/delete never gated). Billing budget = console,
  still open.
- **Still open:** SMS region allowlist (P1), moderation staffing (P2),
  Firestore-product App Check, transitive npm advisories (P3).

## Headline

The **authorization model is genuinely strong** and well-tested: deny-by-default
rules, server-owned collections, per-user projections that keep like/pass and
block state secret, participant-gated reads, whitelist schemas, an 18+ backstop,
and consent-version enforcement. The rules test suite (135 cases) exercises the
negative paths directly.

The weakness is **not** authorization logic. It is that **the entire abuse-control
layer is missing**: App Check is off, most callables have no rate limit, and the
public profile projection is readable (and paginable) by any authenticated
account. For a dating app — PII, photos, minors, location-adjacent data — this is
the dominant risk category.

---

## What is done well (keep it)

- **Server-owned social data.** `matches`, `callSessions`, `conversations`,
  `blocks`, `reports`, `unmatches`, `boosts`, queue, history, notifications all
  deny client writes (`firestore.rules`); only Cloud Functions (Admin SDK) write
  them. Forged matches/sessions/boosts are rejected — proven by tests.
- **Secret-keeping projections.** Like/pass lives in `callSessions/{id}/decisions`
  which is closed to **both** clients (`firestore.rules:288`). "They passed" is
  indistinguishable from "they haven't decided". Block state is per-user; the
  blocked person is never told (`calls.ts`, `decisions.ts`).
- **Block cascade integrity.** `blockUser` deletes the conversation _inside_ the
  same transaction as the block, so a crash mid-cascade can't leave an open chat;
  message rules also require an un-blocked pair (`firestore.rules:373`). Tested
  including the crash scenario.
- **Media tokens are server-minted and scoped.** `getCallMediaToken` verifies
  participant + live session + within the call clock, mints a JWT scoped to
  `room = sessionId`, TTL = remaining time + 90s, `canPublishData:false`
  (`media.ts`). No client-generated tokens; no cross-room replay; no unmoderated
  data side-channel. Non-participants get `not-found` (existence not leaked).
- **Storage rules** cap size (5 MB) and enforce `image/jpe?g` content type; paths
  are owner-scoped; leaked paths give unauthenticated readers nothing.
- **18+ backstop** in rules (`hasValidAgeIfPresent`) independent of the client.
- **Consent version** pinned in rules; can't be backdated.
- **No secrets in the repo.** `GoogleService-Info.plist`, `.env*`, keys,
  service-account JSON all gitignored; LiveKit secrets live in Secret Manager.
- **Complete server-side account deletion** (`deleteAccount`) — no orphaned
  social data, Auth user removed last for retry-safety.

---

## Findings

### P0 — App Check not enforced (abuse / billing / scraping enabler)

- **Evidence:** `index.ts:9-10` and `backend/README.md:73` — `enforceAppCheck` is
  false on every callable. `FirebaseBootstrap.swift:63-84` — the provider only
  installs when `MOOMO_ENABLE_APP_CHECK=1`, and the App Check API is disabled for
  the project. **Net: zero attestation today.**
- **Why it's a problem:** the Firebase API key ships in every app bundle. Anyone
  can drive the Phone Auth REST flow to mint a real Auth token, then call **every
  callable** and issue **every publicProfiles query** as a "legitimate" user, from
  a script, at scale. There is no app-integrity gate.
- **Impact:** enables the scrape (below), the billing attacks
  (`COST_AND_QUOTA_MODEL.md`), matchmaking spam, and bot registration.
- **Fix:** enable the App Check API, register App Attest + debug tokens, verify
  token metrics show real traffic, then flip `enforceAppCheck: true` per callable
  and require App Check on `publicProfiles` reads. **Staged rollout** (monitor
  before enforce) to avoid locking out real users. Must-fix before launch.
- **Confidence:** Confirmed (config verified).

### P0/P1 — `publicProfiles` is mass-scrapable PII

- **Evidence:** `firestore.rules:159-163` — `allow get: if isSignedIn()` and
  `allow list: if isSignedIn() && request.query.limit <= 50`. The rule comment
  itself concedes "any authenticated account can read public projections."
- **Why:** an authenticated script can page the entire collection by issuing
  `orderBy(lastActiveAt)`/`orderBy(updatedAt)` queries of 50 with cursors,
  harvesting every user's `displayName`, `age`, `city`, `gender`, `interestedIn`,
  `photoPaths`, and (via Storage `read: if isSignedIn()`) **the photos
  themselves**. At 1M users that is a complete dating-profile dump — a stalking,
  doxxing, and catfishing dataset, including minors.
- **Impact:** privacy incident, regulatory exposure (GDPR/CCPA), safety harm.
- **Fix:** (1) enforce App Check on reads; (2) move Discover behind a
  **server-composed feed** callable that returns a bounded, block-filtered,
  rate-limited page and never exposes raw `orderBy` over the whole collection;
  (3) rate-limit per user. The repo already names this as "Phase 5" — it must
  land before a public launch. Mark **P0** given the data sensitivity and the
  absence of _any_ current brake beyond `limit<=50`.
- **Confidence:** Confirmed.

### P0 — No `maxInstances` / cost ceiling on any function

- **Evidence:** every `onCall` is bare (verified). No `maxInstances`,
  `concurrency`, or billing cap in code.
- **Why:** combined with no App Check and no rate limits, a retry storm or a
  scripted loop scales function instances, Firestore ops, and the bill without a
  ceiling. There is no kill switch.
- **Impact:** uncontrolled billing; possible Firestore/Cloud Run quota exhaustion
  taking down real users.
- **Fix:** set explicit `maxInstances` per function, a Cloud Billing budget with
  alerts, and a maintenance/kill-switch flag. Must-fix before launch.
- **Confidence:** Confirmed (in code). Exact deployed defaults: verify in console.

### P1 — No per-user rate limiting on expensive callables

- **Evidence:** `joinMatchmakingQueue`, `submitCallDecision`, `getCallMediaToken`,
  `activateBoost`, `endCallSession`, `unmatchUser`, `deleteAccount` have **no**
  rate limiting. Only `reportUser` (20/day) and `blockUser` (50/day) do.
- **Why:** each is a lever an attacker (or a buggy client retry loop) can pull
  thousands of times/minute — matchmaking is the worst (heaviest Firestore work).
- **Impact:** cost, contention amplification, matchmaking degradation for real
  users, boost/decision griefing.
- **Fix:** per-uid token-bucket (e.g. a `rateLimits/{uid}` doc or Firestore
  increment with a window, or the Firebase Extensions rate-limiter). Start with
  the heaviest: `joinMatchmakingQueue`, `getCallMediaToken`, `activateBoost`.
- **Confidence:** Confirmed.

### P1 — SMS / phone-auth toll-fraud exposure

- **Evidence:** `sendCode` (`FirebaseAuthenticationService.swift:222`) → Firebase
  Phone Auth. No App Check gate; no visible SMS region allowlist.
- **Why:** phone verification is the one paid, externally-triggerable action.
  Without App Check and region controls, attackers use it for SMS pumping
  (verifications to numbers/regions they profit from) and bot registration.
- **Impact:** direct cost + Auth quota exhaustion locking out real sign-ups.
- **Fix:** App Check for phone auth, SMS region allowlist in the console, per-IP
  and per-number monitoring/alerts. Confirm Firebase's built-in abuse protection
  is enabled.
- **Confidence:** Highly likely (standard Firebase phone-auth exposure; the
  mitigations are simply not present in the repo).

### P2 — `onMessageCreated` unread increment is not idempotent

- **Evidence:** `chat.ts:40` uses `FieldValue.increment(1)`; Firestore triggers
  are **at-least-once**, and the function sets no `retry`/idempotency guard.
- **Why:** a duplicate event delivery double-counts a recipient's unread badge.
- **Impact:** cosmetic (wrong unread count); self-heals on `markRead`. Low.
- **Fix:** guard with the message id (e.g. record processed message ids, or make
  the counter a recomputation). Low priority.
- **Confidence:** Highly likely (mechanism is real; effect is minor).

### P2 — Block filtering in Discover is client-side only

- **Evidence:** `AppServices.swift:185` `BlockFilteringDiscoveryService` filters
  after the raw feed returns; server returns blocked users, client hides them.
- **Why:** a tampered/scripted client sees blocked users; also wastes reads.
- **Impact:** a blocked user's profile is retrievable by the person they blocked
  (and vice-versa) outside the UI. Safety-relevant but bounded (no interaction is
  possible — messaging/matching are blocked server-side).
- **Fix:** server-composed feed (same fix as the scrape finding) filters blocks
  server-side.
- **Confidence:** Confirmed.

### P2 — Report system has no human review / SLA

- **Evidence:** `resolveReport` is an admin-claim callable primitive; README
  concedes "a human review tool and a staffed queue still need to exist before
  launch."
- **Why:** reports accumulate unactioned; abusive/underage accounts stay live.
- **Impact:** trust-and-safety failure; legal/reputational risk for a dating app.
- **Fix:** a moderation queue UI + staffing + SLA + auto-actions (e.g.
  auto-suspend on N distinct reporters). Must exist before a real launch.
- **Confidence:** Confirmed.

### P3 — Dependency vulnerabilities (transitive)

- **Evidence:** `npm audit` in `backend/functions` reports 9–11 **moderate**
  advisories, all transitive via `firebase-admin`/`@google-cloud/*` (`uuid`,
  `teeny-request`, `retry-request`).
- **Fix:** track upstream fixes; `npm audit` in CI; upgrade when clean versions
  ship. No known exploit path in this usage. Low.
- **Confidence:** Confirmed.

---

## Abuse scenarios vs. current defenses

| Attack | Defended today? (updated 2026-07-21, repo state) | Gap |
|---|---|---|
| Forge a match / read peer's like | ✅ Yes | rules + closed decisions |
| Message someone who blocked you | ✅ Yes | cascade + rule check |
| Join an unauthorized video room | ✅ Yes | server-minted scoped token |
| Underage DOB write | ✅ Yes | rules backstop |
| Impersonate another user's photo | ✅ Yes | owner-scoped photo paths |
| **Scrape all profiles + photos** | ✅ In repo | list denied; feed bounded/cursor-free/rate-limited. Deploy + Firestore-product App Check finish it |
| **Bot registration at scale** | ⚠️ Deploy-gated | enforceAppCheck in code; console registration + rollout pending |
| **Matchmaking / boost / token spam** | ✅ In repo | per-user rate limits, fail-closed, tested |
| **SMS pumping** | ⚠️ Partial | Firebase built-ins; App Check coded; region allowlist still missing |
| **Uncontrolled billing** | ⚠️ Mostly | maxInstances + kill switches + rate limits in repo; billing budget/alerts = console, still missing |
| Report brigading | ⚠️ Partial | 20/day cap, but no dedup by distinct reporter for auto-action |

## Priorities

1. Enforce App Check (unblocks several rows at once). **P0.**
2. Server-composed, rate-limited Discover feed (kills the scrape + client-side
   block gap). **P0/P1.**
3. `maxInstances` + billing budget + kill switch. **P0.**
4. Per-user rate limits on heavy callables. **P1.**
5. SMS region allowlist + monitoring. **P1.**
6. Moderation queue + staffing. **P1.**
