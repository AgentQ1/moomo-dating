# Proximity-aware matching — implementation report, 2026-08-11

_Answers the GO on `BRAND_AND_43_AUDIT_2026-08-11.md` §9. Every claim here was
run or read at HEAD this session. Sections 5–7 are the paste-ready material;
sections 1–4 and 8 are internal._

---

## 0. Headline

> **UPDATE 2026-08-12 — deployed.** Rules, the three affected Cloud Functions,
> and the privacy page are live on `moomo-c7a37`; the Guideline 2.1 demo-account
> blocker has been diagnosed and repaired in production. See §9 for that run and
> for the revised verdict. §8 is the pre-deploy assessment, kept as written.

Proximity ranking is **implemented, tested, and not yet deployed.** Closer
compatible people now rank higher in Discover, in the pairing queue, and in the
ring fan-out. No coordinate is public, no distance is displayed, and nobody is
excluded for being far away or for not sharing a location.

"Nearby" and the Welcome line are therefore **truthful as written** and need no
copy change. Three other strings that promised *no* location storage were
inaccurate the moment this shipped and have been corrected (§3).

**This does not fix either rejection reason, and the resubmission verdict is
still NO-GO — see §8.** The 2.1 fix (demo accounts that can actually pair) and
the 4.3(b) problem are untouched by this work.

---

## 1. What existed before (audit)

| Area | State at HEAD before this session |
|---|---|
| CoreLocation | Present but city-only. `Features/Location/CityLocationResolver.swift` reverse-geocodes a map pin or a device fix to a **city name** and discards the coordinate; `LocationPickerView` is the only screen that asks for permission |
| Stored location | `CityLocation { city, region, countryCode }` → `users/{uid}.locationCity/Region/Country` and `publicProfiles/{uid}.city`. **No coordinate anywhere, in any document** |
| Permission string | `NSLocationWhenInUseUsageDescription` present, promising "Only the city is saved … never your exact location" |
| Privacy manifest | `PrivacyInfo.xcprivacy` **already declared** `NSPrivacyCollectedDataTypeCoarseLocation` / AppFunctionality |
| Discovery ranking | `discovery.ts` — bounded pools → mutual-compatibility filter → block/pass filter → sort by `lastActiveAt` desc, with reserved seats for `wantsToTalk`. **`city` read only as a display string** |
| Matchmaking ranking | `matchmaking.ts` — sharded FIFO window (10), tiered: explicit invite → boosted → oldest-first |
| Ring fan-out ranking | `ring.ts` — online + compatible pool (40), tiered: invite → boosted → bucket recency, capped at 8 |
| Rules, private docs | `users/{uid}/private/{document}` allowed **only** `onboarding` |
| Rules, public profile | `publicProfiles` — `allow get: if isSignedIn()`, `allow list: if false` |

The audit's conclusion held: **`publicProfiles` is readable by any signed-in
user who knows a uid, and a call, match or invite reveals one.** That single
fact dictates the whole design below.

---

## 2. What was built

### 2.1 The exact algorithm

One module owns it: `backend/functions/src/proximity.ts`.

**Storage.** The client rounds a reduced-accuracy fix to a **0.01° grid**
(`LOCATION_GRID_DEGREES`) and writes `{ lat, lng, updatedAt }` to
`users/{uid}/private/location`. 0.01° of latitude is ~1.11 km everywhere;
0.01° of longitude is ~1.11 km at the equator and shrinks toward the poles. So
a cell is **at most ~1.11 km on a side**, rounding displaces a real position by
up to ~0.8 km, and two people in the same cell produce byte-identical
documents.

**Distance.** Haversine, in memory, over the pools that already existed.

**Scores.** Both components map to `(0, 1]` with the same shape,
`1 / (1 + x/half)`:

```
proximityScore(d_km)   = 1 / (1 + d_km    / PROXIMITY_HALF_SCORE_KM)   half = 25 km
recencyScore(age_min)  = 1 / (1 + age_min / RECENCY_HALF_SCORE_MINUTES) half = 30 min

candidateScore = RECENCY_WEIGHT   * recencyScore(age)        RECENCY_WEIGHT   = 1.0
               + PROXIMITY_WEIGHT * proximityScore(distance) PROXIMITY_WEIGHT = 0.6
```

Neither term ever reaches 0 — **the far are demoted, never removed.**

**The neutral rule.** If either side has no usable location, `proximityScore`
returns `NEUTRAL_PROXIMITY_SCORE = 0.5`, which is *exactly* the score of
someone at the half-score distance. An unlocated person ranks as if they were
one metro away: behind the known-near, ahead of the known-far, never dropped.
"Usable" excludes missing, malformed, out-of-range, and older than
`LOCATION_MAX_AGE_MS` (30 days).

**Where the weights bite** (the trade-off, stated plainly):

| Candidate | Score |
|---|---|
| Active now, 500 km away | 1.00 + 0.6·0.05 = **1.03** |
| Active 30 min ago, same cell | 0.50 + 0.6·1.00 = **1.10** |

So a neighbour outranks a distant person who is online right now, while two
people in the same metro (proximity scores within a few hundredths) are
separated by recency. Recency keeps weight 1.0 because a live call needs
someone awake.

### 2.2 Where it is applied

| Path | Change | Fairness/priority preserved |
|---|---|---|
| `getDiscoveryFeed` | Sort key changed from `lastActiveAt` to `candidateScore` | Reserved `wantsToTalk` seats unchanged (they now go to the best-ranked waiters, so the hero card is the closest active waiter) |
| `joinMatchmakingQueue` | Candidate window reordered closest-first **within** the existing tiers | Explicit call request still first; boost tier still second; window is still the ~10 oldest waiters, so FIFO survives at the window boundary — proximity only reorders inside it |
| `fanOutRingInvites` | Eligible pool sorted closest-first **within** tiers before the 8-invite cap | Invite tier and boost tier unchanged. This is where proximity matters most: everyone eligible is already online and compatible, and only 8 of 40 get rung |

Sorting is **stable** (`sortByProximity`), so equal scores — which includes
every pair of unlocated people — keep their incoming FIFO/boost order. That is
what makes this a layer over the existing priorities rather than a replacement.

### 2.3 Quota and index safety

**No new index, no new query shape, no new collection scan.** Distance is
computed in memory over the *existing* bounded reads (`ACTIVE_POOL = 60`,
`WAITING_FETCH = 30`, `RING_POOL = 40`, `CANDIDATE_WINDOW = 10`). The only new
I/O is **one batched `getAll`** of private location documents per request,
issued *after* the compatibility and block/pass filters — so an excluded
person's location is never even fetched.

`getDiscoveryFeed`'s `maxInstances: 10` workaround for the us-central1 CPU
quota is untouched.

---

## 3. Privacy and security

### The design constraint

`publicProfiles` allows `get` to **any** signed-in user who knows a uid. A
coordinate there would be a position-polling endpoint for everyone you have
ever spoken to — the classic dating-app trilateration failure. So:

**Location lives at `users/{uid}/private/location`, which no client but its
owner can read.** Cloud Functions read it through the Admin SDK, which bypasses
rules. Verified by test, in both directions (§4).

### Defence in depth

| Layer | Guarantee |
|---|---|
| Device | Fix requested at `kCLLocationAccuracyReduced` — iOS's own coarsened location, not GPS-precise |
| Device | Snapped to the 0.01° grid before it leaves; the precise value is a local constant in one function and is never stored, logged, or sent |
| Rules | `isCoarseLocation` re-validates: exactly three keys, both coordinates in range **and on the grid** (tolerance 0.001 of a cell), `updatedAt == request.time`. A tampered client cannot store a precise position **even in its own private document** |
| Rules | Read is `isSelf(uid)` only. Not other users, not people you have called, not anonymous |
| Server | `parseCoarseLocation` treats the document as hostile: junk, out-of-range and stale values degrade to "no location" (neutral), never to an error |
| Server | Positions older than 30 days stop ranking |
| Wire | The feed DTO is unchanged — 10 fields, no coordinate, no distance. Asserted by a test that greps the serialized payload |
| UI | No distance is displayed anywhere. No radius control was added |
| Deletion | `deleteAccount`'s `recursiveDelete(users/{uid})` already takes `private/location` with it |
| Consent | `refreshIfAuthorized` **never** calls `requestWhenInUseAuthorization`. It no-ops unless permission was already granted through the pre-existing city picker. Declining is permanent and costs the user nothing |
| Cadence | Refresh throttled to once per 6 hours per uid — coarse enough that the stored points are not a movement trail |

### Residual risks, stated honestly

1. **Coverage is opt-in and partial.** Only users who tapped "use my current
   location" in the city picker ever have a position. Everyone else ranks
   neutral. The feature is real for those who share; it is not universal.
2. **A same-cell pair is knowable to the server**, not to users. The server
   necessarily knows who is near whom — that is what ranking *is*.
3. **Inference from ordering.** A determined user with many accounts could, in
   principle, learn something coarse from feed order. The ~1 km grid, the
   absence of any displayed distance, the no-cursor feed, and the rate limit
   all bound this; it is not eliminated.

---

## 4. Verification run this session

| Suite | Command | Result |
|---|---|---|
| Cloud Functions | `cd backend/functions && npm test` | **178/178 pass, 0 fail** (was 131) |
| Firestore + Storage rules | `cd backend/rules-tests && npm test` | **166/166 pass, 0 fail** (was 153) |
| iOS unit | `xcodebuild test -scheme Moomo -only-testing:MoomoTests` | **258/258 pass, 0 fail** (was 243) |
| iOS build | `xcodebuild build -scheme Moomo -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` | **BUILD SUCCEEDED** (19.5 s) |
| TypeScript | `npx tsc --noEmit` | clean |

**Not run:** UI tests (`MoomoUITests`, `MoomoLiveUITests`) — they drive a
simulator against the live backend and this change is not deployed, so they
would exercise the old ranking. No deploy has been performed.

### Tests added (47 new)

**`backend/functions/test/proximity.test.mjs`** (new, 30 tests) — the grid is
~1.11 km and idempotent; two positions 400 m apart collapse to one point;
haversine matches known separations; proximity is monotonic in distance and
never reaches zero; **the half-score distance scores exactly the neutral
value**; an unlocated candidate outranks a far one and trails a near one; with
no viewer location every candidate scores identically (the denied-permission
fallback); `parseCoarseLocation` rejects junk, out-of-range, stale and
timestamp-less documents.

**`discovery.integration.test.mjs`** (9 new) — closer compatible users rank
higher with all else equal; the closest waiter gets the hero card; **denied
permission still returns a full feed in pure recency order**; **a candidate
with no location is never excluded and ranks between near and far**; a stale
position ranks neutral; proximity never overrides compatibility, a block, or a
pass, *even in the same cell*; a malformed location degrades to neutral;
**coordinates never appear in the payload.**

**`matchmaking.integration.test.mjs`** (5 new) — the nearer of two waiters is
paired though the far one waited longer; a joiner with no location falls back
to oldest-first; a waiter with no location is still paired; proximity never
pairs past a block; an explicit call request still outranks a closer waiter.

**`backend/rules-tests/firestore.rules.test.mjs`** (13 new) — the owner can
read/write/delete their own; **no other signed-in user can read it**; no
anonymous read; no cross-user write or delete; a precise latitude is refused; a
value 1/10 of a cell off-grid is refused; out-of-range refused; non-numeric
refused; extra or missing fields refused; a client-claimed timestamp refused.

**`app/MoomoTests/CoarseLocationTests.swift`** (new, 15 tests) — snapping
rounds to cell centres and is idempotent; **positions 400 m apart collapse to
one indistinguishable point**; the cell is ~1.11 km; the constant matches the
backend; precise and off-grid coordinates fail validation; every snapped value
round-trips; throttle allows the first refresh, refuses one inside the window,
allows one after, and is per-user; the cadence is hours, not minutes.

---

## 5. App Store Connect — App Privacy labels **(MANUAL ACTION REQUIRED)**

`PrivacyInfo.xcprivacy` already declares coarse location; the **console labels
are the thing that must match it.** Set, under App Privacy → Data Types:

**Location → Coarse Location — YES, collected.**

| Field | Value |
|---|---|
| Used for tracking? | **No** |
| Linked to the user's identity? | **Yes** (it is stored under the account's uid) |
| Purposes | **App Functionality** and **Product Personalization** |
| Third-party advertising / Developer's advertising / Analytics | **No** |

Do **not** declare **Precise Location** — the app never collects it, and
over-declaring invites a question it cannot answer well.

Everything else stays as already recorded: Contact Info → Phone Number; Contact
Info → Name; User Content → Photos or Videos, Other User Content; Identifiers →
User ID; Sensitive Info; Other Data (date of birth). All linked, none used for
tracking, **no email address**.

Also confirm the privacy policy URL is live and now carries the location
paragraph (`web/privacy.html`, updated this session — **must be redeployed to
`baybe-dating.web.app` before submitting**, or the policy the reviewer reads
will contradict the label).

---

## 6. App Review reply — paste-ready

> **What a user sees when they are ready to match**
>
> The Discover screen shows one person at a time, not a deck or a grid. For
> that person the user sees their photo, their first name and age together on
> one line, their city, whether they are online right now, and — when that
> person is actively waiting for a call — a "Wants to Talk to You" badge. The
> primary button directly beneath sends that person a video call request.
> There is no swiping and no card stack anywhere in Baybe.
>
> **What is shown before and after a match**
>
> Before any call, the caller sees the Discover card described above: photo,
> first name, age, city, and online state. Once the call connects, the peer's
> photo stays on screen with their name and age, their city, and their
> occupation if they have set one. Nothing else is revealed by calling
> someone — no phone number, no last name, no location beyond the city.
>
> After a call, each person privately chooses "like" or "pass" on a decision
> screen. Neither choice is ever shown to the other person. A text conversation
> is created **only** when both people independently choose "like" — that is
> the only way any message can be sent in Baybe. There is no inbox of
> strangers, no way to message someone before a call, and a "pass" is
> indistinguishable from not having decided yet.
>
> **How a video or voice call request works**
>
> 1. On Discover, the user taps the primary button under the featured person's
>    photo — labelled **"Nearby"**, with a video-camera icon.
> 2. This sends a live video call request **to that specific person**. Nothing
>    is simulated and no bot is ever involved.
>
>    (The two tiles lower on the same screen, "Video Match" and "Speed Talk",
>    are a different action: they ask to be paired with whoever is available
>    rather than with a named person. Only the button under the photo is a
>    directed request.)
> 3. If that person is already waiting for a call, the two are paired
>    immediately and the call connects.
> 4. If they are not, the app rings them: their phone shows an incoming-call
>    banner with **Answer** and **Decline**. Up to eight compatible people who
>    are online at that moment may be rung; the first to answer is connected,
>    atomically, and every other ring is withdrawn.
> 5. Declining, or letting the banner time out, ends it silently. The caller is
>    never told who declined.
> 6. Every call is ended by our server at 180 seconds. The media credential
>    expires with the call clock, so no client can extend a call, and calls are
>    never recorded.
>
> Either person can report or block the other during the call and on the
> decision screen afterwards. A block is server-side and mutual: the pair can
> never be paired again and any live call between them ends immediately.
>
> **How proximity affects ranking**
>
> Location in Baybe is **approximate and used only to decide the order** in
> which people are shown. If a user allows location access, their position is
> rounded on their device to a grid of about one kilometre and saved to a
> private document that only that user's own account can read. Our server uses
> it to rank people who are closer to them higher, among the people they are
> already compatible with.
>
> It is a ranking preference, never a filter. Nobody is excluded for being far
> away. A user who declines location access — or who has simply never granted
> it — sees exactly the same people, ordered by recent activity instead, and
> can use every feature of the app. No exact coordinate is ever stored, no
> location is ever shown to another user, and the app never displays a distance
> between two people.
>
> **Why Baybe is meaningfully different**
>
> The only way to meet someone in Baybe is a live, mutually agreed 3-minute
> video or voice call. There is no profile deck and no swiping — Discover shows
> one person at a time. There is no way to send a message to another user under
> any circumstance until two people have completed a live call together and
> then each independently and privately chose "like" afterwards. A user cannot
> accumulate matches, cannot maintain an inbox of strangers, and cannot
> initiate contact in text. Calls are terminated by our server at 180 seconds
> and the media credential expires with the call clock, so no client can extend
> one. Pairing requires both people's stated gender preferences and
> relationship intentions to accept each other; it is never random. Every
> account is SMS phone-verified — there is no anonymous, guest, or social
> login.

### Screen claims verified against the code, 2026-08-12

Every visual claim in the reply above was read off the views at HEAD, because
the last submission was rejected partly for describing a screen that did not
match the build. Two drafting errors were caught and corrected here:

| Draft said | Reality | Source |
|---|---|---|
| Occupation is visible on Discover | It is **not**. Occupation appears only in the in-call identity overlay | `DiscoverHeroCard.swift:41-56` vs `ActiveCallView.swift:215-216` |
| The "Speed Talk" tile sends a request to that specific person | It does **not**. Both mode tiles call `coordinator.start(mode:)` with **no peer** — an undirected queue join. Only the hero button passes `with: featured` | `DiscoverView.swift:102,130,141` |

Confirmed accurate: the hero shows `"\(displayName), \(age)"` plus a city ·
"Online now" line and a "Wants to Talk to You" badge when the peer is waiting
(`DiscoverHeroCard.swift:41,49,26-29`) — the anonymous "Someone is waiting"
fallback that App Review hit on 2026-08-05 is gone; the in-call overlay shows
name, age, occupation, city (`ActiveCallView.swift:196-220`); the fan-out cap
is 8 (`shared.ts` `RING_FANOUT_LIMIT`); the call cap is 180 s (`shared.ts:17`).

**Do not paste the reply without re-checking this table if the Discover or
call UI changes again.**

### Guardrails on the above

- Say **approximate**. Never claim a distance filter, a radius setting, a
  "within X km" search, or a displayed distance — none exist.
- Do **not** claim photo or ID verification (`isVerified` is never granted
  server-side).
- Do **not** claim automated content filtering (still none — Guideline 1.2
  exposure is unchanged by this work).
- Do **not** restore the "reviewed within 24 hours" moderation SLA. Nothing
  backs it. It is still live in ASC and must be struck.

---

## 7. Demo video — script and checklist

Complements `DEMO_VIDEO_CAPTURE.md`, which has the capture mechanics. Two
devices (or two simulators), screen-recorded side by side or cut together.
Target 60–90 seconds, no narration required; on-screen text captions are
enough.

**Before recording — the 2.1 prerequisite.** Apple rejected build 3 because the
demo accounts *could never pair*, so no call-request button ever appeared. This
must be fixed and verified first or the video will show the same dead end:

- [ ] Both demo accounts' gender + "interested in" preferences **mutually
      accept** each other.
- [ ] Both accounts' **dating intentions overlap** on at least one horizon.
- [ ] **No pass tombstone exists between them** — `passes/{A}/passed/{B}` and
      `passes/{B}/passed/{A}` must both be absent. A pass from any earlier test
      call is permanent and silently severs the pair.
- [ ] No block either way.
- [ ] Both accounts have a photo and a completed profile, or they will not be
      shown at all.
- [ ] Verify by opening Discover on A and confirming **B is actually on
      screen** before you start recording.

**Optional, for the proximity segment.** Set both simulators to nearby
coordinates (Xcode → Debug → Simulate Location, or Features → Location →
Custom) and grant location on both, so the ordering claim is demonstrable.

| # | Device | What to show | Caption |
|---|---|---|---|
| 1 | A | Phone-number sign-in with the SMS code | "Every account is phone-verified. No anonymous or social login." |
| 2 | A | Discover, holding on the profile card for ~3 s: photo, "Name, age", city, online state, and the "Wants to Talk to You" badge if present | "This is everything you see before a call." |
| 3 | A | Tap the location bar, show the city picker, dismiss it | "Location is approximate — city only, plus a private ~1 km area used to rank closer people higher." |
| 4 | A | Tap the **"Nearby"** button (video-camera icon) under the profile | "User A sends a live video call request to that specific person." |
| 5 | A | The searching / connecting state | — |
| 6 | B | The incoming-call banner appearing, with **Answer** and **Decline** visible | "User B receives it, and can answer or decline." |
| 7 | B | Tap **Decline**; show A returning to the waiting state | "Declining is silent — the caller is never told who declined." |
| 8 | A | Start the request again | — |
| 9 | B | Tap **Answer** | — |
| 10 | Both | The live call connecting, peer name/photo overlay, the countdown | "Calls are capped at 180 seconds by the server and are never recorded." |
| 11 | Either | The in-call report/block control | "Either person can report or block during the call." |
| 12 | Both | End the call; the private like/pass decision screen | "Each person decides privately. Chat opens only if both choose like." |
| 13 | Both | Both choose like; the match and the new conversation | "This is the only way a message can ever be sent in Baybe." |

**If proximity must be shown rather than explained:** with both accounts
located, seed a third compatible account at a far coordinate and show that the
near one is ordered first on Discover. If that is not practical, say plainly in
the reply that proximity affects ordering only and is not visible as a number —
do not stage anything that implies a distance readout exists.

---

## 8. GO / NO-GO for resubmission

**NO-GO.** Not because of this work — the proximity feature is complete,
tested, and safe — but because the two things that actually caused the
rejection are still open.

| Gate | State |
|---|---|
| **Deploy** | **BLOCKING.** Nothing here is live. `firebase deploy --only functions,firestore:rules --project moomo-c7a37` must run and be verified. The us-central1 Cloud Run CPU quota (~236/250) is the same one that forced `getDiscoveryFeed` to `maxInstances: 10`; a 3-function deploy may hit it again |
| **Privacy policy redeploy** | **BLOCKING.** `web/privacy.html` was edited this session and must be republished to `baybe-dating.web.app` before submission, or the live policy contradicts the new label |
| **App Privacy labels** | **BLOCKING.** Coarse Location must be declared in ASC (§5). A mis-declared location label is its own rejection under 5.1.1 |
| **Guideline 2.1 — demo accounts cannot pair** | **STILL OPEN.** This is the actual rejection reason and this work does not touch it. See `REJECTION_2026-08-05_ROOT_CAUSE.md` and the §7 checklist |
| **24-hour moderation SLA in live ASC notes** | **STILL OPEN.** Must be struck |
| **Guideline 4.3(b)** | **STILL OPEN and unaddressed.** Concept-level. Apple's text pre-rejects a differentiation argument; the only instrument is an App Review Board appeal |
| **Guideline 1.2 — no automated content filtering** | Unchanged, still open |
| Proximity implementation | **DONE** — §2, §4 |
| "Nearby" copy truthfulness | **RESOLVED** — the claim is now supported; no copy change needed |

**Recommendation.** Ship proximity in build 4 *after* the 2.1 pairing fix is
verified, the rules and functions are deployed, the privacy policy is
republished, and the Coarse Location label is set. Shipping it before those
adds a new data-collection surface to a submission that is already fighting a
saturation argument.

**No claim is made that any of this results in approval.** 4.3(b) is a
concept-level objection and proximity ranking does not answer it.

---

## 9. Deploy and 2.1 repair — 2026-08-12

### 9.1 Deployed to `moomo-c7a37`

| Step | Command | Result |
|---|---|---|
| Firestore rules | `firebase deploy --only firestore:rules` | **Released.** Compiled clean. Backward-compatible — it only ADDS `users/{uid}/private/location`; no existing path changed |
| Cloud Functions | `firebase deploy --only functions:getDiscoveryFeed,functions:joinMatchmakingQueue,functions:acceptCallInvite` | **All three updated successfully.** The us-central1 CPU quota did **not** bite this time |
| Privacy page | `firebase deploy --only hosting` | **Released.** `https://baybe-dating.web.app/privacy` returns 200 and serves the new location paragraph (verified by `curl`); `/terms` still 200 |

Only the three functions that changed were deployed. The rest of the codebase
is untouched code and was deliberately left on its current revision to avoid
spending regional CPU headroom for no behavioural gain.

**Ranking behaviour at the moment of deploy was identical to before it**, and
this is worth stating: no account has a location document yet, so every
candidate scores `NEUTRAL_PROXIMITY_SCORE` and the blend collapses to pure
recency. Proximity begins to take effect only as the iOS build that writes
positions reaches users — i.e. the backend change is inert until build 4 ships.

Function logs after the deploy show no errors (the only entries are an
unrelated 2026-08-10 `GET` probe against the callable endpoint).

### 9.2 Guideline 2.1 — demo accounts, diagnosed and repaired

New tool: `backend/functions/scripts/demo-accounts.mjs` — read-only by default,
`--fix` to repair. It checks the same four gates the server applies, in order,
plus the two reasons a profile is invisible even when compatible.

**Live state found (this is the actual rejection cause, still present):**

| Account | Profile as found | Could pair with |
|---|---|---|
| `+16505551234` "Solan" — **the account given to Apple** | man, wants women, no intention | **nobody** |
| `+16505555678` "Lily" | woman, wants men, no intention | — |
| `+16505559876` "Lulu" | woman, wants **women**, shortTerm | — |

| Pair | Verdict | Blocking reason |
|---|---|---|
| Solan ↔ Lily | CANNOT PAIR | **A pass tombstone** `passes/vElHha…/passed/NmDVKN…`. Gender preferences actually accepted each other — the tombstone alone was the blocker |
| Solan ↔ Lulu | CANNOT PAIR | Lulu's preferences reject a man |
| Lily ↔ Lulu | CANNOT PAIR | Lily's preferences reject a woman |

**Note the drift from the root-cause doc.** `REJECTION_2026-08-05_ROOT_CAUSE.md`
recorded Solan as *"woman, wants women"* on 2026-07-29; production today has him
as a **man wanting women**. That record was stale, which is precisely why this
check now exists as a script rather than a paragraph.

**Repair applied** (relaxes constraints between the three demo accounts only —
never a real user, never a deletion of profile data):

- deleted the `Solan → Lily` pass tombstone;
- set all three to `interestedIn: ['everyone']` and
  `datingIntention: 'figuringItOut'` — the most permissive catalog-valid
  combination — on both `publicProfiles` and the private `users/{uid}` document,
  so the next client-side profile save cannot re-publish the old values.

**Verified by re-running read-only:** all three pairs now report **CAN PAIR**.

Re-run `node scripts/demo-accounts.mjs` from `backend/functions` before every
submission. A single test call that ends in "pass" re-creates a permanent
tombstone and silently reinstates the exact rejection.

### 9.3 Revised gate status

| Gate | State |
|---|---|
| Deploy — rules, functions, hosting | **DONE** (§9.1) |
| Privacy policy live and consistent | **DONE** — verified over HTTP |
| Guideline 2.1 — demo accounts can pair | **DONE** — repaired and verified (§9.2) |
| **App Privacy labels — Coarse Location** | **STILL OPEN. MANUAL, BLOCKING.** Console only; §5 has the exact settings |
| **Build 4** | **STILL OPEN.** The iOS client that writes positions is not built or uploaded. Until it ships, proximity is inert in production |
| **24-hour moderation SLA in live ASC notes** | **STILL OPEN.** Must be struck |
| **Guideline 4.3(b)** | **STILL OPEN and unaddressed.** Concept-level; nothing here answers it |
| Guideline 1.2 — no automated content filtering | Unchanged, still open |
| Demo video | **NOT RECORDED.** Script in §7; Apple explicitly asked for it |

### 9.4 Verdict

**Still NO-GO for resubmission**, but the blocker set has changed shape: the
infrastructure work is finished and the 2.1 dead end — the thing that actually
caused the rejection — is fixed and verified. What remains is not engineering:
set the Coarse Location privacy label, strike the 24-hour SLA, build and upload
build 4, record the demo video, and decide how to handle 4.3(b).

4.3(b) remains the one that cannot be closed from this repo, and no claim is
made that resolving everything above results in approval.
