# Moomo backend

Cloud Functions + Firestore rules + indexes for the Moomo dating app
(`moomo-c7a37`). The social domains — matchmaking, call sessions, decisions,
matches, conversations, blocks, reports, boosts, notifications — are owned
here; the iOS client only reads its own slices and appends chat messages.

**Deployment state (2026-07-16): NOTHING in this directory is deployed yet.**
The live project still runs the initial ruleset from 2026-07-15
(`af223dd9-f244-472c-83d7-8b3ef62c0bba`) with no Functions and no indexes.
Until `firebase deploy` runs (below), the app's social tabs cannot work
against production: every callable is missing and every social read is denied
by the old rules.

## Layout

    functions/          Cloud Functions (TypeScript, Node 22, firebase-functions v2)
    functions/test/     emulator integration tests for the callables
    firestore.rules     deny-by-default security rules
    firestore.indexes.json  composite indexes the queries below require
    storage.rules       Storage rules (photos)
    rules-tests/        emulator tests for firestore.rules — 108 tests
    scripts/            operational scripts

## Firestore schema

Server-written means Admin SDK only — rules deny every client write.

| Path | Written by | Client may | Purpose |
|---|---|---|---|
| `users/{uid}` | client (owner) | read/write own | private account data; 18+/consent backstops |
| `users/{uid}/private/onboarding` | client (owner) | read/write own | resumable onboarding draft |
| `users/{uid}/callHistory/{sessionId}` | server | read own | this user's PRIVATE view of a finished call: `peer`, `mode`, `startedAt`, `durationSeconds`, `endReason`, `outcome`. Per-user so "blocked" is never visible to the blocked person and decisions never leak. |
| `users/{uid}/notifications/{id}` | server | read own; update `isRead`→true only | bell feed (`kind`, `title`, `body`, `isRead`, `createdAt`) |
| `publicProfiles/{uid}` | client (owner) + server flags | **get single doc** (any signed-in); **list denied** — browse via `getDiscoveryFeed`; write own | Discover projection: `displayName`, `age`, `city`, `gender`, `interestedIn`, `photoPaths`, `lastActiveAt` (client heartbeat, throttled to 1/4min) + `activityBucket` (10-min quantized ordering stamp — the anti-hotspot index key; rules verify alignment and nearness to now). Rules enforce the exact schema (whitelisted keys, valid age/gender/preferences, photo paths inside the owner's Storage folder, honest `lastActiveAt`/`activityBucket`). `wantsToTalk` and `boostedUntil` are **server-set** — client writes touching them are rejected. `lastActiveAt`/`updatedAt` single-field indexes are **disabled** (`firestore.indexes.json` fieldOverrides) — they were the monotonic write hotspot. |
| `matchmakingQueue/{uid}` | server | read own | queue entry: `mode`, `status` (`waiting`→`matched`), `sessionId` when paired. The waiting client listens to its own entry. |
| `callSessions/{id}` | server | read own (participants) | neutral call facts: `participantIds`, `participants` (denormalised summaries), `mode`, `status`, `startedAt`, `maxDurationSeconds`, `endedAt`, `endedBy`, `durationSeconds`. Nothing sensitive — both sides read it. |
| `callSessions/{id}/decisions/{uid}` | server | **nothing** | like/pass, closed to both participants ("they passed" must be indistinguishable from "they haven't decided") |
| `matches/{pairKey}` | server | read own (participants) | exists iff mutual like; keyed by sorted uids so repeat calls can't duplicate; `conversationId`, `participants`, `createdAt` |
| `conversations/{conv_pairKey}` | server (+trigger) | read own; update **own** per-user keys: `unreadCounts.{uid}`→0, `hiddenBy.{uid}` (bool), `metBy.{uid}` (bool) | one per match: `participants`, `lastMessage` preview, `lastMessageAt`, `unreadCounts`, per-user `hiddenBy` (one-sided hide) and `metBy` ("we met" answer) |
| `conversations/{id}/messages/{id}` | client (participants) | read; append as self | `senderId`, `text` (≤1000), `sentAt` (server time); exact shape enforced; no edits/deletes |
| `blocks/{uid}/blocked/{uid}` | server (blockUser) | read own; delete own (unblock) | direct client creates rejected — a block must always cascade |
| `reports/{id}` | server (reportUser) | **nothing** | write-only via callable; rate-limited; moderation reads with Admin SDK |
| `unmatches/{id}` | server (unmatchUser) | **nothing** | private unmatch reasons (`unmatchedBy`, `otherUserId`, `matchId`, `reason`, `createdAt`); moderation reads with Admin SDK |
| `boosts/{uid}` | server | read own | `remainingBoosts`, `activeUntil`, `grantedAt` (lazy daily refill) |
| `rateLimits/{uid}_{action}` | server | **nothing** | fixed-window abuse counters (`uid`, `action`, `windowStartMillis`, `count`) — see `src/ratelimit.ts` for every ceiling |
| `config/runtime` | operator (Admin SDK / console) | **nothing** | kill switches: `maintenanceMode`, `matchmakingEnabled`, `callsEnabled`, `discoveryEnabled`, `boostsEnabled`. Missing doc/flag = enabled; cached in-instance ~15s (`RUNTIME_CONFIG_CACHE_MS`). Safety callables, `leaveMatchmakingQueue`, `endCallSession`, and `deleteAccount` are deliberately never gated. |

## Cloud Functions (`functions/src`)

Callables (v2 `onCall`, region `us-central1`):

| Function | Does |
|---|---|
| `joinMatchmakingQueue({mode, preferredPeerId?})` | Transactionally pairs with a waiting user and creates the `callSessions` doc — `createCallSession` is internal, never callable. Ranking: the preferred person first (if genuinely waiting), then waiters with an **active boost**, then oldest-first within the scanned window. Only **mutually compatible** users pair (`gender` + `interestedIn` from `publicProfiles`, mirroring `MatchPreferences` in the app; missing preferences read as "everyone"); blocked pairs are refused both directions. Otherwise enqueues and the client listens to its queue entry. Sets `publicProfiles.wantsToTalk`. **Scale shape (P1-2):** the waiting pool is sharded (`shard` 0..N-1, `QUEUE_SHARD_COUNT`, default 8; tests pin 1) and scanned from a random shard, profile reads happen OUTSIDE the transaction (candidate heartbeats no longer abort pairing), retries are bounded (5), and a duplicate join returns the existing live session (idempotent). Rate-limited 12/min; gated by `matchmakingEnabled`. |
| `getDiscoveryFeed()` | **The only way to browse profiles** (P0-3): a bounded, cursor-free feed of ≤25 candidates — block-filtered both directions, compatibility-filtered with the matchmaking table, ordered by `activityBucket` with genuinely-waiting users reserved seats. Returns a render-minimal DTO (`isOnline` boolean instead of raw `lastActiveAt` — precise activity times never leave the server). Rate-limited 20/min; gated by `discoveryEnabled`. |
| `leaveMatchmakingQueue()` | Removes the waiting entry, clears `wantsToTalk`. Never rate-limited or kill-switched — nobody may be trapped in the queue. |
| `endCallSession({sessionId, reason})` | Participant-only, idempotent. Marks the session ended and writes BOTH users' private `callHistory` projections (the blocker sees `blocked`; the blocked person sees an ordinary `ended`). |
| `submitCallDecision({sessionId, decision})` | Participant-only, one-shot. Pass → `passed`. Like → `likeSent` unless the peer already liked, in which case `createMatchOnMutualLike` (internal) mints the match + conversation + both notifications in the same transaction and both histories say `matched`. "Peer passed" is deliberately indistinguishable from "peer undecided". |
| `getCallMediaToken({sessionId})` | Participant-only, live sessions only. Mints a LiveKit room token scoped to exactly that session's room (room name = session id, identity = caller uid), expiring with the call clock plus reconnect grace. Requires the LiveKit params/secrets below; refuses with `failed-precondition` when unconfigured — the client shows the call as failed, never fakes media. |
| `blockUser({blockedUserId, displayName?})` | One transaction: writes the block doc, deletes the pair's match **and their conversation document**, ends any live call between them. The conversation's messages are then swept with `recursiveDelete`; if that crashes, rules already refuse the orphaned thread (no parent + blocked pair) and a retried block finishes the sweep. |
| `reportUser({reportedUserId, reason, details?})` | Validates the reason whitelist, caps at 20 reports/day per account, writes the report with `status: 'open'`. |
| `unmatchUser({otherUserId, reason?})` | One transaction: records the private reason in `unmatches` and deletes the pair's match **and their conversation document**; messages are then swept with `recursiveDelete` (same crash-safety story as blockUser). Reason must be in `UNMATCH_REASONS` (defaults to `no_reason`). Deliberately **not** a block — the pair may re-match through a future call; the app offers a block on top. |
| | Abuse brakes: 20 reports/day, 50 blocks/day per account — brakes, not quotas; legitimate use never gets near them. |
| `activateBoost()` | Lazy daily allowance (3/24h, mirrored client-side), refuses `alreadyActive` / `noneRemaining`, stamps `boostedUntil` on the public profile. |
| `sendSystemNotification({userId, title, body})` | **Admin custom claim only** — operational announcements. |
| `deleteAccount()` | The app's ONLY complete account deletion. Removes everything the caller owns — user tree (private, callHistory, notifications), public profile, queue entry, boosts, block list, every match/conversation/message/session they're in, Storage photos — then the Auth user (last, so a crashed run can be retried). Keeps: reports (the safety record) and other users' own records that merely mention the account (their callHistory, their blocks). |
| `resolveReport({reportId, status, resolution?})` | **Admin custom claim only.** Moves a report `open` → `resolved`/`dismissed`, stamping `resolvedBy`/`resolvedAt`. The primitive the (future) review tool drives. |

Triggers & scheduled:

| Function | Does |
|---|---|
| `onMessageCreated` | Keeps `conversations/{id}` honest per message: `lastMessage` preview, `lastMessageAt`, increments the recipients' `unreadCounts`. |
| `sweepMatchmakingQueue` | Every minute: removes queue entries older than 2× TTL and withdraws their `wantsToTalk` flags. Replaced the per-join/leave sweep, which was a collection-scan transaction contending with every pairing (P1-2). |

## App Check (READ BEFORE DEPLOYING)

**Every callable now sets `enforceAppCheck: true`** (via the shared
`callable()` helper in `src/options.ts` — asserted by
`test/options.config.test.mjs`). Requests without a valid App Check token
are refused with UNAUTHENTICATED before any handler runs.

Deploy order is load-bearing. Before this code reaches production:

1. Enable the App Check API (`firebaseappcheck.googleapis.com`) for
   `moomo-c7a37` and register the iOS app with **App Attest** in Firebase
   console → App Check.
2. Register every developer simulator's **debug token** (the iOS app installs
   `AppCheckDebugProvider` in DEBUG builds — token prints on first run).
3. Watch App Check request metrics until verified traffic dominates.
4. Only then deploy these functions. Deploying first locks every real user
   out of every callable.

Local/dev/test behavior:

- **Emulator tests** invoke handlers directly (`firebase-functions-test`),
  which bypasses transport-level App Check — no tokens needed; the suites
  run unchanged.
- **iOS local dev** against production functions needs a registered debug
  token — and DEBUG builds attest with `AppCheckDebugProvider` on **devices
  as well as simulators** (see `MoomoAppCheckProviderFactory`), so every
  DEBUG install (each simulator, each phone) has its own token to register.
  The app prints it on **every** launch, framed with `[Moomo]`, and the
  Discover error card's DEBUG diagnostic repeats it when App Check is the
  blocker. Register it in Firebase console → moomo-c7a37 → App Check → Apps
  → Moomo (iOS) → ⋮ → Manage debug tokens, or over REST (needs
  `gcloud auth` with access to the project):

  ```sh
  curl -X POST \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "x-goog-user-project: moomo-c7a37" -H "Content-Type: application/json" \
    -d '{"displayName": "<who/where>", "token": "<TOKEN-FROM-APP-LOG>"}' \
    "https://firebaseappcheck.googleapis.com/v1/projects/moomo-c7a37/apps/1:998689337464:ios:ca57cd2d8363fae941fd8d/debugTokens"
  ```

  To pin a stable token instead, set the `FIRAAppCheckDebugToken`
  environment variable in the scheme (note the double A — the SDK also
  accepts plain `AppCheckDebugToken`) to a value you registered; the shared
  scheme is committed, so never commit a real token that way.
  `MOOMO_DISABLE_APP_CHECK=1` (env or `-MOOMO_DISABLE_APP_CHECK` launch arg)
  skips installing the client provider for work against a project with the
  App Check API off — the backend will refuse those calls once enforcement
  is deployed.
- **Symptom map**: once enforcement is deployed, a client without a valid
  token gets `unauthenticated` from EVERY callable — the same code
  `requireAuth` uses, which is why the client refines it: Discover retries
  once on a fresh ID token, then probes both credentials and renders either
  "Signed out" (no Firebase session) or, in DEBUG, an `App Check:`
  diagnostic naming the unregistered token (2026-07-22 incident; the
  probes live in `DiscoveryDiagnostics`, the policy in
  `AuthGatedDiscoveryService`, both `app/Moomo/Services/`). It is never the
  offline card. If Discover instead logs `not-found`, the deployed backend
  predates `getDiscoveryFeed` — deploy functions.
- **Admin tooling caveat**: `sendSystemNotification` / `resolveReport` also
  enforce App Check, so ops scripts can no longer call them over the wire
  without a debug token; prefer Admin-SDK direct writes for tooling, or
  register a debug token for the ops environment.

## Abuse & operational controls

- **Rate limits** (`src/ratelimit.ts`, per-user fixed windows, fail-closed):
  join 12/min · feed 20/min · media token 10/min · decision 20/min · boost
  5/min · deleteAccount 3/hour — plus the existing 20 reports/day and 50
  blocks/day. Counters live in server-only `rateLimits/`.
- **Kill switches** (`src/runtime.ts`): flip booleans on `config/runtime`
  (see schema table) from the console — no deploy. Safety and leave/end
  paths are never gated.
- **Structured ops events** (`src/observability.ts`): `rate_limit_blocked`,
  `kill_switch_blocked`, `matchmaking_paired/waiting/txn_retry/sweep`,
  `discovery_feed_served/suspicious`, `block_cascade_completed` — one JSON
  log entry each, for log-based metrics and alerts (see
  docs/production-readiness/OBSERVABILITY_AND_INCIDENT_PLAN.md).
- **Queue sharding**: `QUEUE_SHARD_COUNT` (deploy-time env; default 8).
  Entries written before sharding lack `shard` and simply age out within
  ~80s (queue TTL) — no migration needed.

Build: `cd functions && npm install && npm run build` (strict TypeScript;
the predeploy hook runs it automatically).

## Call media (LiveKit)

Voice/video transport is LiveKit; the backend mints room tokens
(`getCallMediaToken`), the iOS client holds no credentials. Configuration:

| Name | Kind | Example |
|---|---|---|
| `LIVEKIT_URL` | string param (`functions/.env.moomo-c7a37`) | `wss://moomo-xxxxxxxx.livekit.cloud` |
| `LIVEKIT_API_KEY` | Cloud Secret Manager secret | `APIxxxxxxx` |
| `LIVEKIT_API_SECRET` | Cloud Secret Manager secret | from the LiveKit project |

Setup, exactly once per environment:

```sh
# 1. Create a LiveKit Cloud project (https://cloud.livekit.io) and copy the
#    websocket URL + API key/secret.
# 2. Point the functions at it:
echo 'LIVEKIT_URL=wss://<your-project>.livekit.cloud' > functions/.env.moomo-c7a37
firebase functions:secrets:set LIVEKIT_API_KEY --project moomo-c7a37
firebase functions:secrets:set LIVEKIT_API_SECRET --project moomo-c7a37
# 3. Redeploy functions.
```

Until these exist, `getCallMediaToken` refuses every call and the app reports
calls as unavailable — honestly, with no simulated fallback.

## Testing

```sh
cd rules-tests && npm install && npm test     # 144 rules tests, emulator only
cd functions && npm install && npm test       # build + 104 emulator tests (matchmaking e2e incl. sharding/idempotency/concurrency, discovery feed, rate limits + kill switch, option ceilings + App Check guardrails, block-vs-decision race, blockUser cascade, media tokens, deleteAccount, moderation, boost, chat trigger)
```

The rules tests cover the app spine (bootstrap, 18+/consent backstops,
owner-only privacy, deletion) plus every social collection above: participant
gating, server-ownership (forged matches/sessions/queue entries/boosts all
rejected), message shape and sender integrity, markRead's narrow update, the
decisions subcollection staying closed to both participants, per-user call
history privacy, notification mark-read-only, block-list privacy with
callable-only creation, and write-only reports. Blocked pairs are silenced in
depth: message creation requires an open parent conversation AND no block in
either direction — proven even for a conversation document that outlives a
crashed cascade.

The functions integration tests run the real compiled callables against the
Firestore emulator: the blockUser cascade end-to-end (including the
recursiveDelete-crash scenario — the conversation must die inside the block's
transaction), getCallMediaToken's scoping (participant-only, live-session
only, clock-bound expiry, room = session id), and the block-vs-decision race
(a like landing after a block must never mint or resurrect a match or
conversation).

Each functions test file uses its own emulator project id
(`moomo-functions-test-<area>`) so one file's `clearFirestore` cannot wipe
another's documents when Node runs them concurrently. This is deliberate;
`singleProjectMode: false` in the root `firebase.json` tells the emulator hub
so, instead of it warning "multiple projectIds" on every run. All ids are
throwaways — nothing here can reach a live project (the tests refuse to run
without `FIRESTORE_EMULATOR_HOST`).

## Deploying

The active project **must** be `moomo-c7a37`. `moomoios-2026` is the Moomo AI
app and must never receive any of this. `gcloud`'s default project on this
machine *is* `moomoios-2026` — the Firebase CLI is pinned by `.firebaserc`,
but raw `gcloud` needs `--project moomo-c7a37`.

```sh
cd backend/rules-tests && npm test                  # must pass first
cd ../functions && npm install && npm run build     # must compile clean
firebase use                                        # MUST print moomo-c7a37
firebase deploy --only firestore:rules,firestore:indexes,storage,functions --project moomo-c7a37
```

Functions require the **Blaze plan** (Cloud Functions v2 deploys through
Cloud Run). Secrets: `getCallMediaToken` reads `LIVEKIT_API_KEY` /
`LIVEKIT_API_SECRET` from Cloud Secret Manager and `LIVEKIT_URL` from
`functions/.env.moomo-c7a37` (see "Call media" above); everything else uses
only Application Default Credentials.

After deploy, verify:

```sh
firebase functions:list --project moomo-c7a37   # 13 callables + 1 trigger + 1 scheduled
```

## Operational notes

- **Account deletion is complete (Phase 5).** The in-app flow calls the
  `deleteAccount` callable; rules now deny client deletes of `users/{uid}`
  and `publicProfiles` so no partial client-side path exists. Reports are
  retained by design (safety record).
- **Moderation** has a workflow primitive (`resolveReport`, admin claim) and
  a model (`status`/`resolution`/`resolvedBy`/`resolvedAt`); a human review
  tool and a staffed queue still need to exist before launch.
- **App Check**: ENFORCED in code on every callable; the iOS app installs a
  provider by default (App Attest on device, debug provider in DEBUG;
  `MOOMO_DISABLE_APP_CHECK=1` to skip locally). See "App Check" above for
  the mandatory console steps BEFORE deploying.
- **Scrape brake**: `publicProfiles` client lists are DENIED at any size;
  browsing is the `getDiscoveryFeed` callable only (bounded, cursor-free,
  block/compat-filtered, rate-limited).
- Stale queue entries are filtered by pairing (TTL) and swept by the
  scheduled `sweepMatchmakingQueue` every minute.
- **Index migration note**: the old `matchmakingQueue (status, mode,
  createdAt)` composite is kept in `firestore.indexes.json` for rollback;
  drop it once the sharded queue has been live for a release. The
  `publicProfiles.lastActiveAt`/`updatedAt` fieldOverrides (index disabled)
  are the P1-1 hotspot fix.
- **`activityBucket` backfill (deploy checklist step)**: the feed's pool
  queries order by `activityBucket`, and Firestore orderBy EXCLUDES
  documents missing the field — so pre-existing profiles are invisible to
  the bucketed queries until stamped. Run
  `scripts/backfill-activity-buckets.mjs --project moomo-c7a37 --confirm`
  at deploy time (idempotent, dry-run by default). Until it runs, the feed
  detects thin pools and tops up from an unordered fallback scan (degraded
  ordering, one extra query per request) and flags it via
  `discovery_feed_served.fallbackUsed` — sustained `true` in production
  means the backfill hasn't run. Queue joins also stamp the bucket
  server-side, so genuinely waiting users are always visible to the hero
  card regardless of app version.

## Scripts

`scripts/cleanup-integration-data.sh` — removes residue left by the live
integration suite. Dry-run by default; `--confirm` to delete.
