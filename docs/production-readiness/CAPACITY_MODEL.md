# Capacity Model

_Audit date 2026-07-20. Numbers are engineering estimates from the code paths,
not measured production data. Each row states its confidence. Do not treat these
as validated throughput — they are inputs to the load-test plan (`LOAD_TEST_PLAN.md`)._

## Shared assumptions

| Symbol | Value | Basis |
|---|---|---|
| Registered users | 1,000,000 | target |
| DAU | 100,000 | target (10% of registered) |
| Concurrent (Normal / Viral / Extreme) | 10k / 50k / 100k | target |
| Sessions/DAU/day | 5 | assumption (dating apps skew high) |
| Discover opens/concurrent user/min | ~0.5 (once per 2 min) | assumption; each open = 1 presence write + 1 feed query |
| Speed calls started/concurrent user | 1 per ~4 min | assumption (3-min call + decide + requeue) |
| Chat msgs sent/active chatter/min | 2 | assumption; ~30% of concurrent users chatting |
| Firestore read | $0.06 / 100k | [pricing](https://cloud.google.com/firestore/pricing) |
| Firestore write | $0.18 / 100k | same |
| Firestore delete | $0.02 / 100k | same |

**Concurrency → actions/sec.** For a feature with per-user cadence `r` (actions/sec)
and `C` concurrent users, base rate = `C × r`. Peak applies a **5–10× spike**
multiplier per the brief; matchmaking and presence are bursty so I use 3× as the
realistic sub-spike and note the 10× ceiling.

---

## Per-feature load

### 1. Sign-ins / SMS (Phone Auth)

- **Assumptions:** sessions persist (Firebase restores auth), so steady sign-ins
  are new-user registrations + occasional re-auth. Viral day: 100k new sign-ups.
- **Formula:** `SMS/s = signups/day ÷ active_seconds`. If 100k sign-ups land in a
  6-hour viral window: `100,000 / 21,600 ≈ 4.6/s` average; bursty peak 5–10× →
  **25–50 SMS/s**. Each failed/ resent code adds more.
- **Bottleneck:** Firebase Phone Auth per-project SMS quota and per-number/IP
  limits; **SMS toll fraud** (see security review) because App Check is off.
- **Cost:** dominated by non-US numbers at $0.06 each — see `COST_AND_QUOTA_MODEL.md`.
- **Confidence:** Medium (sign-up curve is the biggest unknown).

### 2. Firestore presence writes — `publicProfiles.lastActiveAt`

- **Path:** `FirestoreDiscoveryService.loadDiscovery()` writes `lastActiveAt =
  serverTimestamp()` on **every Discover open** (`FirestoreDiscoveryService.swift:29`).
- **Formula:** `writes/s = C × 0.5/min ÷ 60 = C × 0.0083`.

| Scenario | Avg writes/s | Peak 3× |
|---|---|---|
| Normal 10k | ~83 | ~250 |
| Viral 50k | ~417 | **~1,250** |
| Extreme 100k | ~833 | **~2,500** |

- **Bottleneck — CONFIRMED:** `lastActiveAt` is a monotonically increasing
  server timestamp and is an **indexed** field (Discover orders by it). Firestore
  documents a soft limit of **~500 writes/sec to a single index with sequential
  values** before hotspotting (latency spikes, contention). Viral peak already
  exceeds this by 2.5×; Extreme by 5×. This is the **first thing that breaks**.
- **Confidence:** High. This is a documented Firestore anti-pattern, not a guess.

### 3. Firestore Discover feed reads — global `orderBy(lastActiveAt) limit 25`

- **Path:** `FirestoreDiscoveryService.swift:42-45` + a `users/{uid}` pref read +
  a `blocks` subcollection read per load (`BlockFilteringDiscoveryService`).
- **Formula:** reads/load ≈ 25 (feed) + 1 (self prefs) + N_blocked. `loads/s = C × 0.0083`.

| Scenario | Feed doc reads/s | Peak 3× |
|---|---|---|
| Normal 10k | ~2,150 | ~6,500 |
| Viral 50k | ~10,800 | ~32,000 |
| Extreme 100k | ~21,600 | ~65,000 |

- **Bottleneck:** all reads target the **leading edge of one index** (most-recent
  `lastActiveAt`), concentrating read load on a narrow key range (read
  hotspotting, less severe than write but real). Also a **product cliff**: every
  user in the world is served the same ~25 most-recently-active profiles — no
  geography, no pagination cursor, no already-seen exclusion.
- **Confidence:** High for the read volume; High for the "everyone sees the same
  people" behavior (direct from the query).

### 4. Matchmaking — `joinMatchmakingQueue`

- **Path:** each join runs (a) `sweepStaleQueueEntries()` — a transaction with a
  collection scan `where createdAt < X limit 50` (`matchmaking.ts:283`), then (b)
  the pairing transaction reading the 10 oldest waiting entries + up to 11
  `publicProfiles` + 2 block docs per candidate (`matchmaking.ts:143-224`).
- **Formula:** `joins/s = C × (1 per 240s) = C × 0.00417`.

| Scenario | Joins/s | Firestore reads/s (~35/join) | Peak 3× reads/s |
|---|---|---|---|
| Normal 10k | ~42 | ~1,460 | ~4,400 |
| Viral 50k | ~208 | ~7,300 | ~22,000 |
| Extreme 100k | ~417 | ~14,600 | ~44,000 |

- **Bottleneck — CONFIRMED (contention, not volume):** every joiner's pairing
  transaction reads and writes the **same head of the FIFO queue**. Under Viral
  load hundreds of transactions/sec contend on the same ~10 documents →
  Firestore serializes them → transaction retries/aborts → matchmaking latency
  climbs and effective throughput collapses well before the raw read numbers
  above. The per-join `sweepStaleQueueEntries()` transaction touches the same hot
  collection, doubling contention. Firestore transaction contention degrades
  super-linearly; this will not scale to 50k concurrent as written.
- **Confidence:** High that contention dominates; the exact break point needs the
  load test (Phase 5) to pin down — likely in the low thousands of concurrent
  active call-seekers.

### 5. Chat messages + `onMessageCreated` fan-out

- **Path:** client writes message (1 write) → trigger reads conversation (1 read)
  + updates preview/unread (1 write) → each participant's conversation listener
  re-reads the conversation doc.
- **Formula:** active chatters ≈ 30% of C, 2 msgs/min each. `msgs/s = 0.3C × 2/60 = 0.01C`.

| Scenario | Msgs/s | Writes/s (msg + trigger) | Reads/s (trigger + listeners) |
|---|---|---|---|
| Normal 10k | ~100 | ~200 | ~300 |
| Viral 50k | ~500 | ~1,000 | ~1,500 |
| Extreme 100k | ~1,000 | ~2,000 | ~3,000 |

- **Bottleneck:** none structural — writes are spread across many
  conversation documents (no hot doc). The trigger is fine. Cost scales linearly.
- **Confidence:** Medium (chat engagement rate is assumed).

### 6. Presence / listeners (steady-state)

- Each signed-in, foregrounded user holds: 1 conversations listener (limit 100),
  1 callHistory listener (limit 50), 1 blocks listener, plus per-open-thread
  message listeners and (during a search) a queue-doc listener.
- **Concurrent listener count ≈ 3–5 × C.** At Extreme that is 300k–500k live
  listeners. Firestore supports ~1M concurrent connections per database (soft),
  so connection count is OK, but **each write to a watched document bills a read
  per listener** — this is where realtime cost accrues.
- **Confidence:** Medium.

### 7. Video rooms (LiveKit)

- **Formula:** concurrent rooms ≈ (users in a call) / 2. If ~20% of concurrent
  users are in a 3-min call: Viral = 10,000 users → **5,000 concurrent rooms**,
  10,000 participants. Participant-minutes/day scale with call volume.
- **Bottleneck:** LiveKit Cloud capacity is their concern, but **bandwidth cost**
  is yours and it is the single largest variable cost at scale (see cost model).
  No participant cap beyond 2 (room=sessionId, 2 identities), call length bounded
  by token TTL (180s + 90s grace). Good containment; cost is the risk.
- **Confidence:** Medium; depends heavily on % of users who actually call.

### 8. Cloud Functions concurrency

- v2 callables default to **80 concurrent requests/instance** and **no explicit
  `maxInstances`** (falls to platform default). Total callable QPS at Viral peak
  (matchmaking + decisions + tokens + safety) is order **1,000–3,000 req/s**.
- **Bottleneck:** at 80/instance that is ~15–40 warm instances — fine on paper,
  BUT (a) matchmaking transaction latency (finding #4) inflates request duration,
  raising instance count and cost; (b) with no `maxInstances`, a retry storm or
  abuse loop scales instances (and bill) without a ceiling; (c) cold starts on a
  spike add latency to the first requests.
- **Confidence:** Medium.

---

## Verdict per scenario

| Scenario | Holds? | First failure |
|---|---|---|
| **Normal (10k)** | Likely, with caveats | Presence writes ~250/s peak approach the hotspot ceiling; matchmaking contention begins to show. Probably survivable. |
| **Viral (50k)** | **No, as written** | Presence-write hotspot (~1,250/s ≫ 500/s ceiling) and matchmaking FIFO-head contention both break. Discover already degraded (everyone sees same 25). |
| **Extreme (100k)** | **No** | Everything in Viral, worse; plus uncontrolled function/Firestore cost with no `maxInstances` ceiling. |

## Unknowns that block a precise answer

1. **% of concurrent users who actually start calls** — drives matchmaking
   contention and LiveKit bandwidth cost (the two biggest risks). Range 5–40%
   changes the break point by ~8×.
2. **Deployed function runtime config** — repo sets none; the actual
   `maxInstances`/`concurrency` on the deployed Cloud Run services is not
   verifiable from source. Confirm in the console.
3. **Sign-up curve shape** during virality — determines SMS burst and toll-fraud
   exposure.
4. **Geographic distribution** — single-region latency and SMS pricing both
   depend on it.
5. **Firestore PITR / backup config** — not in repo; verify in console.

These must be measured (Phase 5) before any "yes" at 50k is credible.
