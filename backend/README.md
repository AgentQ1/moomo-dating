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
| `publicProfiles/{uid}` | client (owner) + server flags | read (any signed-in); write own | Discover projection: `displayName`, `age`, `city`, `gender`, `interestedIn`, `photoPaths`, `lastActiveAt` (client heartbeat). Rules enforce the exact schema (whitelisted keys, valid age/gender/preferences, photo paths inside the owner's Storage folder, honest `lastActiveAt`). `wantsToTalk` and `boostedUntil` are **server-set** — client writes touching them are rejected. |
| `matchmakingQueue/{uid}` | server | read own | queue entry: `mode`, `status` (`waiting`→`matched`), `sessionId` when paired. The waiting client listens to its own entry. |
| `callSessions/{id}` | server | read own (participants) | neutral call facts: `participantIds`, `participants` (denormalised summaries), `mode`, `status`, `startedAt`, `maxDurationSeconds`, `endedAt`, `endedBy`, `durationSeconds`. Nothing sensitive — both sides read it. |
| `callSessions/{id}/decisions/{uid}` | server | **nothing** | like/pass, closed to both participants ("they passed" must be indistinguishable from "they haven't decided") |
| `matches/{pairKey}` | server | read own (participants) | exists iff mutual like; keyed by sorted uids so repeat calls can't duplicate; `conversationId`, `participants`, `createdAt` |
| `conversations/{conv_pairKey}` | server (+trigger) | read own; update **own** `unreadCounts` to 0 | one per match: `participants`, `lastMessage` preview, `lastMessageAt`, `unreadCounts` |
| `conversations/{id}/messages/{id}` | client (participants) | read; append as self | `senderId`, `text` (≤1000), `sentAt` (server time); exact shape enforced; no edits/deletes |
| `blocks/{uid}/blocked/{uid}` | server (blockUser) | read own; delete own (unblock) | direct client creates rejected — a block must always cascade |
| `reports/{id}` | server (reportUser) | **nothing** | write-only via callable; rate-limited; moderation reads with Admin SDK |
| `boosts/{uid}` | server | read own | `remainingBoosts`, `activeUntil`, `grantedAt` (lazy daily refill) |

## Cloud Functions (`functions/src`)

Callables (v2 `onCall`, region `us-central1`):

| Function | Does |
|---|---|
| `joinMatchmakingQueue({mode, preferredPeerId?})` | Transactionally pairs with a waiting user and creates the `callSessions` doc — `createCallSession` is internal, never callable. Ranking: the preferred person first (if genuinely waiting), then waiters with an **active boost**, then oldest-first. Only **mutually compatible** users pair (`gender` + `interestedIn` from `publicProfiles`, mirroring `MatchPreferences` in the app; missing preferences read as "everyone"); blocked pairs are refused both directions. Otherwise enqueues and the client listens to its queue entry. Sets `publicProfiles.wantsToTalk`. |
| `leaveMatchmakingQueue()` | Removes the waiting entry, clears `wantsToTalk`, sweeps stale entries. |
| `endCallSession({sessionId, reason})` | Participant-only, idempotent. Marks the session ended and writes BOTH users' private `callHistory` projections (the blocker sees `blocked`; the blocked person sees an ordinary `ended`). |
| `submitCallDecision({sessionId, decision})` | Participant-only, one-shot. Pass → `passed`. Like → `likeSent` unless the peer already liked, in which case `createMatchOnMutualLike` (internal) mints the match + conversation + both notifications in the same transaction and both histories say `matched`. "Peer passed" is deliberately indistinguishable from "peer undecided". |
| `getCallMediaToken({sessionId})` | Participant-only, live sessions only. Mints a LiveKit room token scoped to exactly that session's room (room name = session id, identity = caller uid), expiring with the call clock plus reconnect grace. Requires the LiveKit params/secrets below; refuses with `failed-precondition` when unconfigured — the client shows the call as failed, never fakes media. |
| `blockUser({blockedUserId, displayName?})` | One transaction: writes the block doc, deletes the pair's match **and their conversation document**, ends any live call between them. The conversation's messages are then swept with `recursiveDelete`; if that crashes, rules already refuse the orphaned thread (no parent + blocked pair) and a retried block finishes the sweep. |
| `reportUser({reportedUserId, reason, details?})` | Validates the reason whitelist, caps at 20 reports/day per account, writes the report with `status: 'open'`. |
| | Abuse brakes: 20 reports/day, 50 blocks/day per account — brakes, not quotas; legitimate use never gets near them. |
| `activateBoost()` | Lazy daily allowance (3/24h, mirrored client-side), refuses `alreadyActive` / `noneRemaining`, stamps `boostedUntil` on the public profile. |
| `sendSystemNotification({userId, title, body})` | **Admin custom claim only** — operational announcements. |
| `deleteAccount()` | The app's ONLY complete account deletion. Removes everything the caller owns — user tree (private, callHistory, notifications), public profile, queue entry, boosts, block list, every match/conversation/message/session they're in, Storage photos — then the Auth user (last, so a crashed run can be retried). Keeps: reports (the safety record) and other users' own records that merely mention the account (their callHistory, their blocks). |
| `resolveReport({reportId, status, resolution?})` | **Admin custom claim only.** Moves a report `open` → `resolved`/`dismissed`, stamping `resolvedBy`/`resolvedAt`. The primitive the (future) review tool drives. |

Triggers:

| Function | Does |
|---|---|
| `onMessageCreated` | Keeps `conversations/{id}` honest per message: `lastMessage` preview, `lastMessageAt`, increments the recipients' `unreadCounts`. |

App Check is **not enforced yet** (Phase 5): callables accept any valid
Firebase Auth token. Flip `enforceAppCheck: true` per callable once the iOS
app registers App Attest.

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
cd rules-tests && npm install && npm test     # 108 rules tests, emulator only
cd functions && npm install && npm test       # build + 45 emulator integration tests (incl. preference pairing + boost priority) (matchmaking e2e, block-vs-decision race, blockUser cascade, media tokens, deleteAccount, moderation, boost, chat trigger)
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
firebase functions:list --project moomo-c7a37   # 11 callables + 1 trigger
```

## Operational notes

- **Account deletion is complete (Phase 5).** The in-app flow calls the
  `deleteAccount` callable; rules now deny client deletes of `users/{uid}`
  and `publicProfiles` so no partial client-side path exists. Reports are
  retained by design (safety record).
- **Moderation** has a workflow primitive (`resolveReport`, admin claim) and
  a model (`status`/`resolution`/`resolvedBy`/`resolvedAt`); a human review
  tool and a staffed queue still need to exist before launch.
- **App Check**: the iOS app now registers a provider (App Attest on device,
  debug provider in DEBUG). Enforcement is still OFF per callable
  (`enforceAppCheck`); before flipping it, register the app in Firebase
  console → App Check, add each developer simulator's debug token, and
  verify token metrics show real traffic. Flipping first locks users out.
- **Scrape brake**: `publicProfiles` lists must carry `limit <= 50`; Discover
  asks for 25.
- Stale queue entries are filtered by pairing and swept opportunistically on
  every `leaveMatchmakingQueue`.

## Scripts

`scripts/cleanup-integration-data.sh` — removes residue left by the live
integration suite. Dry-run by default; `--confirm` to delete.
