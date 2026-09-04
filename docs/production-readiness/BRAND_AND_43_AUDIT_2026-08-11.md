# Brand-collision and 4.3(b) audit — 2026-08-11

_Scope: the whole repo plus every release-facing surface, looking for anything
that could read to App Review as a copy, a spam app, or a Chinese Momo/MoMo
clone. Follows `REJECTION_2026-08-05_ROOT_CAUSE.md`._

Every claim below is tagged **VERIFIED** (checked against the code at HEAD or a
command run this session), **UNVERIFIED**, or **NEEDS MANUAL ACTION** (outside
the repo — App Store Connect or the Firebase console).

---

## 0. Headline

**No evidence of clone or spam signalling was found.** No `陌陌`, no CJK
character anywhere in the repo, no standalone "Momo", no competitor branding
copied into product copy, no placeholder metadata. The name collision is
one-directional and internal: the project was built as "Moomo", renamed to
**Baybe** for the store, and the retired name survives only in identifiers that
cannot be renamed without breaking the shipped app.

**The 4.3(b) risk is not a naming problem and this audit does not reduce it.**
See §5.

---

## 1. Sweeps run

```sh
# every file except .git, node_modules, Xcode build output, .firebase
EXCL="--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=build \
      --exclude-dir=.firebase --exclude-dir=DerivedData"

grep -rniE 'moomo|momo' . $EXCL                    # see §2
grep -rnP  '[\x{4e00}-\x{9fff}]' . $EXCL           # 0 hits — no CJK at all
grep -rniE '(^|[^o])momo' . $EXCL                  # 0 hits — no standalone "Momo"
grep -rniE '(tinder|bumble|hinge|omegle|azar|badoo|grindr|happn|tantan|blued|
             filter off|blindlee|coffee meets bagel)' . $EXCL
grep -rniE '\bclone\b|knock-?off|rip-?off|inspired by|copy of' . $EXCL
grep -rniE 'lorem ipsum|example\.com|yourcompany|placeholder text|TBD|FIXME' \
     app/Moomo web docs backend/functions/src $EXCL
grep -rhoE 'displayName: *"[^"]*"' app/MoomoTests app/MoomoUITests \
     app/MoomoLiveUITests backend                  # test fixture names
```

**Clean results — VERIFIED:**

| Sweep | Result |
|---|---|
| `陌陌` / any CJK character | **0 hits repo-wide** |
| Standalone `Momo` (not inside `Moomo`) | **0 hits** |
| Chinese dating-app references of any kind | **0 hits** |
| Competitor branding in product copy | **0 hits in shipping copy.** 5 hits total, all internal: `Hinge` in README + 2 code/test comments (now removed from README, see §3); `Omegle/Azar/Filter Off/Blindlee` only inside the three internal analysis docs, which are named in §6 as **never to be pasted to Apple** |
| `clone` / `knock-off` / `inspired by` | **0 hits.** Two false positives on the English word "copy" in unrelated ownership comments (`Profile.swift:179`, `SessionStore.swift:7`) |
| Placeholder metadata / Lorem / example.com | **0 hits.** Only false positives on the `xxxl` spacing token |
| Test fixture display names | `Anaya`, `Kenji`, `Jane Q. User`, `Someone` — neutral, no seeded persona that reads as scraped or fake-populated |
| Old app names other than Moomo | **0 hits** |

---

## 2. Every `Moomo` reference, classified by who can see it

The grep returns ~100 files. What matters is which of them a **user** or a
**reviewer** can read. Four tiers:

### Tier A — reaches a user's or reviewer's eyes

| Item | Where | Disposition |
|---|---|---|
| `moomolab@gmail.com` | In-app: `WelcomeView.swift:53`, `SafetySettingsView.swift:169`, `PermissionAndSafetySteps.swift:114`, `AuthenticationService.swift:32`, `LegalDocumentView.swift:112,132`. Hosted: `web/index.html:25`, `web/privacy.html:89`, `web/terms.html:73`. Also the ASC support contact | **KEPT — your decision this session.** It is the only "moomo" string a user actually reads. Reads as a lab/company name rather than the Momo brand, and the mailbox is known-monitored (`LAUNCH_CHECKLIST.md:100-102`). Listed as an accepted residual risk in §7 |
| `moomo://legal/privacy`, `moomo://legal/terms` | `ConsentRow.swift:79-80` | **FIXED → `baybe://`.** A private sentinel matched by identity inside the same file — unregistered, never leaves the app — but iOS renders the raw URL in the link preview on a long press, so it was genuinely reachable. Zero behavioural change: both ends are in one file |

### Tier B — reviewer-visible but structural, deliberately unchanged

| Item | Why it stays |
|---|---|
| Bundle ID `com.moomo.dating` | Immutable after the app record exists. Visible to a reviewer in ASC, in crash logs, in `simctl` commands. Already explained in the review notes: *"the bundle ID com.moomo.dating and the internal project name Moomo are historical and not user-visible."* Keep that sentence |
| Firebase project `moomo-c7a37` | Renaming a Firebase project ID is impossible; migrating means a new project, new App Check registration, new App Attest Team ID setup, and a full data migration. Not reviewer-visible in normal use |

### Tier C — developer-only, cosmetically aligned

| Item | Disposition |
|---|---|
| `[Moomo]` App Check debug-token banner, `FirebaseBootstrap.swift:94-98` | **Changed to `[Baybe]`.** Inside `#if DEBUG` — never present in a Release build, so it was never shipping. Cosmetic only. The Firebase console path in the same block still says `moomo-c7a37` / `Moomo (iOS)` because those are the literal labels a developer must find in the console |
| `README.md` title and framing | **Rewritten** to lead with Baybe and to state explicitly which "Moomo" identifiers are load-bearing and must not be "fixed" |

### Tier D — internal, not user-visible, no action

Xcode target/scheme/product name `Moomo`; the `app/Moomo/` source directory;
type names `MoomoApp`, `MoomoAppDelegate`, `MoomoLogo`, `MoomoTabBar`,
`MoomoTextField`, `MoomoTextEditor`, `MoomoAppCheckProviderFactory`; test
targets `MoomoTests` / `MoomoUITests` / `MoomoLiveUITests` /
`MoomoIntegrationTests`; `os.Logger` subsystems `com.moomo.dating`;
`BackendConfiguration.forbiddenProjectID = "moomoios-2026"` (a guard that
*prevents* pointing at the unrelated Moomo AI project — keep); `MOOMO_DISABLE_APP_CHECK`
launch flag; doc-comment prose.

**Renaming any of Tier D would be pure churn with real breakage risk** (the
Xcode target is folder-synchronized) and buys nothing: App Review never sees
source.

### What the app actually shows a user — VERIFIED clean

| Surface | Value |
|---|---|
| Home-screen name (`CFBundleDisplayName`) | **Baybe** |
| App Store name | **Baybe** |
| On-screen wordmark inside the logo | **`baybe`** (`MoomoLogo.swift:39`) |
| Logo accessibility label | **"Baybe"** (`LogoMark.swift:50`, `MoomoLogo.swift:45`) |
| Camera / microphone / photo / location permission strings | All four name **Baybe** (`Info.plist`) |
| Hosted legal pages, titles, wordmark, footer | **Baybe** throughout |
| Backend strings that reach the user | No brand name at all — VERIFIED across `backend/functions/src/*.ts` |

---

## 3. Files changed this session

| File | Change | Reason |
|---|---|---|
| `app/Moomo/Components/ConsentRow.swift` | `moomo://legal/*` → `baybe://legal/*` (+ comment explaining why the scheme carries the store name) | The one remaining place the retired name could surface to a user, via the iOS link-preview on long press. No UI, layout, or behaviour change |
| `app/Moomo/Services/FirebaseBootstrap.swift` | Debug log tag `[Moomo]` → `[Baybe]` | Consistency. `#if DEBUG` only — not in any shipped build |
| `README.md` | Title → "Baybe"; added a paragraph pinning which Moomo identifiers are load-bearing; "organised Hinge-style" → "organised by whose turn it is" | Removes competitor-derived phrasing from the repo's front door and stops a future session from "cleaning up" the bundle ID |
| `backend/functions/test/options.config.test.mjs` | `getDiscoveryFeed` expected `maxInstances` 20 → 10, with the quota reasoning | **Pre-existing red test, unrelated to this audit.** `src/discovery.ts:155-160` deliberately dropped the ceiling to 10 to get past the us-central1 CPU quota; the expectation table was never updated. Suite is green again — see §8 |

**No UI, layout, colour, typography, flow, onboarding, matching or call-screen
changes were made.** The hero CTA still reads "Nearby" and the Welcome line
still reads "Find the person nearby you'd most like to meet", per your
instruction to hold both pending the GO/NO-GO in §7.

---

## 4. Features verified in code (the only material safe to claim to Apple)

Everything here was read at HEAD this session. Nothing is inferred from docs.

| Feature | Evidence |
|---|---|
| **No swipe deck exists** | `DiscoverView.swift` is a location bar + one hero card + two mode tiles. There is no card-stack, no swipe gesture, no deck anywhere in the app |
| **Meeting is a live 3-minute call; there is no text-first path** | `shared.ts:17` `SPEED_CALL_SECONDS = 180`, server-enforced; the media token dies with the call clock (`media.ts:56,69` — "This call has ended.") |
| **Chat cannot be opened before a call** | Conversations are minted *only* inside the mutual-like transaction (`decisions.ts:50-115`, `createConversation` is "Internal only") |
| **Pairing is mutual-preference, never random** | `compatibility.ts:76-80` `isMutuallyCompatible` = `wantsGender(a,b) && wantsGender(b,a)` — both directions must accept. Applied identically by matchmaking, discovery and the ring fan-out |
| **Dating-intention filter** | `compatibility.ts:44-74` — six intentions mapped to `longTerm`/`shortTerm` horizons; pairs need an overlapping horizon; a missing intention overlaps everything (so old accounts stay matchable) |
| **A pass is private and permanent** | `shared.ts:216-226` tombstone; enforced in matchmaking, ring and discovery, both directions |
| **Blocking is mutual, server-side, and kills a live call** | `safety.ts` `blockUser`; block checks sit *inside* the accept transaction (`ring.ts` header) so a block landing after a ring still refuses the accept |
| **Silent-block invariant** | A block, a pass, an expired ring, a lost race and a busy callee all return the *same* "unavailable" — being blocked is indistinguishable from bad timing (`ring.ts:24-29`) |
| **Directed call request → incoming banner → accept/decline** | Hero CTA → `CallCoordinator.start(mode:with:)` → `preferredPeerId` (`FirestoreCallService.swift:74-75`) → `joinMatchmakingQueue` → either immediate pairing if that person is already waiting (`matchmaking.ts:256-267`) or `fanOutRingInvites` (`matchmaking.ts:383`). Callee side: `callInvites/{uid}` listener → `IncomingCallBanner.swift` with Answer/Decline → `acceptCallInvite` / `declineCallInvite` (`index.ts:23`) |
| **Ring invites are server-written only** | `callInvites/{uid}` is one doc per callee, server-written; a client that could write invites could ring anyone or forge an acceptance (`ring.ts:12-17`) |
| **Feed is server-composed and structurally un-scrapeable** | `discovery.ts:1-33` — no cursor, bounded pools, minimal DTO, raw `lastActiveAt` never leaves the server; `firestore.rules:167` `allow list: if false` on `publicProfiles` |
| **Phone verification only** | Single `phone` AuthProvider; no anonymous, Apple, Google or social login anywhere |
| **18+, server-backstopped** | `Profile.swift:214` `minimumAge = 18`; `firestore.rules:58-63` rejects an under-18 DOB server-side |
| **App Check enforced on every callable** | `options.ts` `callable()` helper; guard test "per-function extras cannot silently drop enforcement" |
| **Account deletion in-app** | `deleteAccount` callable (`index.ts:32`) |
| **Rate limiting + kill switches** | `ratelimit.ts`, `runtime.ts` `requireEnabled` |

### Claims that are NOT supported — do not put these in front of Apple

| Claim | Reality |
|---|---|
| Photo / ID verification | `isVerified` renders in call UI but **nothing server-side ever grants it** (`discovery.ts:103-104`, "Server-set when photo verification ships") |
| Proximity / "nearby" matching | **There is no location filtering or ranking anywhere.** `discovery.ts` reads `city` only as a display string (`:70,:98`); `compatibility.ts` never mentions location. See §7 |
| Automated content filtering | Still none. `moderation.ts` is an admin-only `resolveReport` triage callable. No Storage trigger, no image or text scanning. Guideline 1.2 exposure is unchanged |
| A moderation SLA in hours | Nothing backs it. The live ASC notes still carry "within 24 hours" — **must be struck before resubmission** (Gate 3) |

---

## 5. Guideline 4.3(b) — positioning assessment

### Uniqueness summary for App Review (short form, all code-backed)

> Baybe's only way to meet someone is a live, mutually agreed 3-minute video or
> voice call. There is no profile deck and no swiping — Discover shows one
> person at a time. There is no way to send a message to another user under any
> circumstance until two people have completed a live call together and then
> each independently and privately chose "like" afterwards. A user cannot
> accumulate matches, cannot maintain an inbox of strangers, and cannot
> initiate contact in text. Calls are terminated by our server at 180 seconds
> and the media credential expires with the call clock, so no client can extend
> one. Pairing requires both people's stated gender preferences and relationship
> intentions to accept each other; it is never random. Every account is SMS
> phone-verified — no anonymous, guest, or social login exists.

### Remaining 4.3 risk that cannot be fixed without product changes

**This is the honest part, and it has not improved since 2026-08-06.**

1. **Apple's rejection text pre-rejects the differentiation argument.** *"may
   include features or characteristics that distinguish it. **However, there
   are already enough of these apps**"* — a feature list is answering a
   question they closed. Nothing in this audit changes that.
2. **"Reconsider the app concept and submit a new app"** points at a different
   app record, not a fixed submission.
3. **The differentiator is invisible in the listing.** The lead screenshot shows
   an anonymous face and "One tap starts a live video chat"; 5 of 10 screens are
   generic dating furniture; two are near-empty. Screenshot and keyword rework
   (Gate 4) addresses the *soft* variant of 4.3(b) and will not move a
   concept-level one.
4. **"Video speed dating" has genuine prior art.** Apple's saturation claim is
   not baseless.
5. **The one honest lever is an App Review Board appeal** with the structural
   argument — *remove live calling from Baybe and no product remains; remove it
   from a conventional dating app and it is essentially unchanged*. Drafted in
   `ASC_REPLY_2026-08-06.md` Part 2. It may still fail.

**Nothing in this audit is a 4.3(b) fix.** It removes a risk that, on the
evidence, was not what got the app rejected.

---

## 6. Documents that must never be pasted to Apple

`REJECTION_2026-08-05_ROOT_CAUSE.md`, `RESUBMISSION_CHECKLIST_2026-08-06.md`
and this file are internal. They name competitors, state odds of approval,
enumerate unsupported claims, and discuss taking the app off iOS. Only the
prepared blocks in `ASC_REPLY_2026-08-11.md` go to App Store Connect.

---

## 7. Open risks accepted or pending decision

| # | Risk | State |
|---|---|---|
| 1 | `moomolab@gmail.com` visible in-app and on the legal pages | **Accepted by you, 2026-08-11.** Low: an email, not branding, and a 4.3 triage pass will not open it |
| 2 | Firebase Phone Auth's SMS body and the reCAPTCHA fallback page carry `moomo-c7a37.firebaseapp.com` | **NOT FIXED — needs your approval, infra change.** This is the highest-reach surviving "moomo" string: it is in the verification SMS every real user receives. Fixing it means a custom Auth domain in the Firebase console — **NEEDS MANUAL ACTION**, cannot be done from the repo. **UNVERIFIED** against a real SMS this session; it is the documented default Firebase behaviour, not something I observed |
| 3 | Hero CTA reads "Nearby"; Welcome reads "…the person nearby…"; **no proximity feature exists** | **Pending your GO/NO-GO** — you asked for real location matching rather than a copy fix. Scoped in §9 |
| 4 | App Privacy labels | **REVERSED since 2026-08-06.** That report told you to remove Coarse Location because the app had no CoreLocation. The working tree now *does* use CoreLocation (`Features/Location/CityLocationResolver.swift`, `NSLocationWhenInUseUsageDescription` in `Info.plist`), and city is stored on the profile and shown to other users. **Coarse Location must now be DECLARED, not removed.** NEEDS MANUAL ACTION in the console |
| 5 | Guideline 1.2 — no automated content filtering | Unchanged and still open |
| 6 | Live ASC review notes still claim a 24-hour moderation SLA | Must be struck before resubmission |
| 7 | `isVerified` badge with no server-side grant | Never claim verification |

---

## 8. Verification run this session

| Command | Result |
|---|---|
| `cd backend/rules-tests && npm test` | **153/153 pass**, 0 fail |
| `cd backend/functions && npm test` (before fix) | **130/131**, 1 fail — `getDiscoveryFeed maxInstances should be 20` (actual 10). Pre-existing, unrelated to this audit |
| `cd backend/functions && npm test` (after fix) | see §3; re-run recorded in the session report |
| `cd app && xcodebuild build -scheme Moomo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData` | **BUILD SUCCEEDED** (24.4 s) |
| `cd app && xcodebuild test -scheme Moomo -only-testing:MoomoTests …` | recorded in the session report |

There is no lint or format target in this repo — no SwiftLint config, no
`npm run lint` script. `tsc` runs as the functions build step inside `npm test`.

---

## 9. Proximity matching — scoping for the GO/NO-GO

You asked for real location/proximity matching so "nearby" becomes truthful.
Here is what that actually costs, so the decision is informed.

### The safety constraint that shapes the whole design

`firestore.rules:164` — `allow get: if isSignedIn()` on `publicProfiles`. Any
signed-in user can read **any** profile document by uid, and uids are learnable
(a call session, a match, an invite all reveal one). **Coordinates must
therefore never go in `publicProfiles`** — that would hand every user who has
ever called you a polling endpoint for your position, which is the classic
dating-app trilateration failure.

Correct home: `users/{uid}/private/location`, which is already `isSelf(uid)`-only
(`firestore.rules:120-122`) and needs one rule edit to allow the new document
name plus schema validation. The Admin SDK bypasses rules, so `discovery.ts`
and `ring.ts` can read it while no client ever can.

### Work required

1. **Rules** — allow `private/location`, validate it holds only a snapped
   lat/lng (≈1 km grid) and a timestamp; reject anything finer. Plus rules
   tests.
2. **Client write path** — `CityLocationResolver` already has the
   `CLLocationManager` plumbing and the permission string; add a snapped write
   on city resolve. No new UI, no new prompt.
3. **Backend ranking** — distance computed in-memory over the *existing*
   bounded scans (`ACTIVE_POOL = 60`, `RING_POOL = 40`). No geohash, no new
   composite index, no new query shape. Closer users sort earlier;
   **missing location must rank neutral, never exclude** — the alternative
   silently unmatches every pre-existing account and recreates the exact 2.1
   failure that caused this rejection.
4. **Tests** — both sides.
5. **Deploy** — functions + rules, then build 4.

Roughly a day of careful work, most of it in tests and rules rather than the
distance maths.

### Why I recommend **NO-GO for this resubmission** (GO as the next piece of work)

- It adds a **new data-collection surface** to a submission whose privacy
  labels are already wrong (risk #4) — a mis-declared location label is its own
  rejection under 5.1.
- It requires a **functions + rules deploy**. The last one hit the us-central1
  CPU quota ceiling and had to be worked around; that is the same quota that is
  still at ~236/250 and is why §3's test fix exists.
- **It does not address either rejection.** 2.1 is demo accounts that cannot
  pair. 4.3(b) is concept-level. Proximity ranking moves neither.
- The truthfulness problem it solves is **also solved by deleting one word**,
  at zero deploy risk.
- Shipping it means the reviewer meets a location prompt and a location claim
  on a resubmission that is already fighting a saturation argument.

**Recommendation: fix the copy now, ship proximity deliberately afterwards** —
with its own privacy-label update and its own build, not bundled into a
rejection response.

If you would rather ship it now, say so and I will build it as scoped above;
the design is sound, the objection is timing.
