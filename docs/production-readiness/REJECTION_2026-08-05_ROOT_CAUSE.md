# Rejection root-cause — iOS App 1.0 (3), reviewed 2026-08-05

_Audit run 2026-08-06. Submission `9942a9c1-3993-44dc-8e2e-7f48dcccdc5b`,
ASC app 6793496424, version id `a9f46f0b-4b99-4e2f-8bd4-836b1e72b9a5`.
Review devices: iPhone 17 Pro Max, iPad Air 11-inch (M3)._

Every line below is tagged **VERIFIED** (checked this session against ASC API,
the code at HEAD, or a run), **UNVERIFIED** (could not be checked here),
**NEEDS MANUAL ACTION**, or **BLOCKING RISK**.

---

## 0. Confirmed ASC state

| Fact | State |
|---|---|
| Version 1.0 `appStoreState` / `appVersionState` | **REJECTED** — VERIFIED |
| reviewSubmission `9942a9c1…` | `UNRESOLVED_ISSUES`, item **REJECTED** — VERIFIED |
| Attached build | 3 (`15c0f67c-d92e-44fa-97e1-b01e25b6a6cf`), `VALID`, not expired, uploaded 2026-07-29 — VERIFIED |
| Build 3 provenance | `CURRENT_PROJECT_VERSION = 3` at HEAD → the reviewed binary **is** this working tree, ring invites included — VERIFIED |
| Demo account in ASC | `+16505551234` / `123456`, `demoAccountRequired: true` — VERIFIED |
| Age rating | store `SEVENTEEN_PLUS`, `ageRatingOverrideV2: EIGHTEEN_PLUS`, UGC + messaging declared — VERIFIED, correct for 18+ dating |
| Categories | Lifestyle (primary) + Social Networking — VERIFIED |
| Screenshots | 10, `APP_IPHONE_67` set only — VERIFIED. Correct: the app is **iPhone-only** (`TARGETED_DEVICE_FAMILY = 1`), so no iPad set is required |
| Legal URLs | `https://baybe-dating.web.app` 200, `/privacy` 200, `/terms` 200 — VERIFIED (`/support` 404, but the support URL points at the root, which is fine) |
| App Privacy labels | **UNVERIFIED** — no public ASC API (`appDataUsages` 404s). Console check required |

---

## 1. Guideline 2.1 — root cause

**Apple asked two things. Both have the same single cause: the three demo
accounts in the review notes are mathematically incapable of matching each
other, so the reviewer could never reach the matched state at all.**

### The mechanism (code-verified)

Both pairing paths — the queue and the ring fan-out — apply the same three
gates:

- `backend/functions/src/matchmaking.ts:317-319` — `isMutuallyCompatible`,
  `isBlockedEitherWay`, `hasPassedEitherWay`
- `backend/functions/src/ring.ts:182,187,385-386` — the same three
- `backend/functions/src/compatibility.ts:37-39` — mutual gender preference:
  **both** users' stated `interestedIn` must accept the other's `gender`
- `backend/functions/src/shared.ts:216-226` — a pass tombstone in **either**
  direction permanently severs the pair (shipped in `8722bc2`)

Against the three live test accounts (recorded 2026-07-29 during the
screenshot pass, **UNVERIFIED against production today** — see §6):

| Account | Profile | Can pair with |
|---|---|---|
| `+16505551234` "Solan" — **the account given to Apple** | woman, wants women | — |
| `+16505555678` "Lily" | woman, wants **men** | ✗ Solan: Lily's preference rejects a woman |
| `+16505559876` | wants women | ✗ Solan: a **pass tombstone** already exists between them |

So the reviewer signing in as Solan has an empty candidate set, permanently.

### What the reviewer actually saw

1. Discover renders `DiscoverMessageCard("No one's around", …)`
   (`DiscoverView.swift:88-98`) — and in that state **there is no button
   anywhere in the app that sends a call request**, because all three call
   entry points live on Discover (`DiscoverView.swift:85,112,123`) and the
   "Talk to Her/Him" CTA only exists when a compatible candidate is present.
2. If they tapped a Chat Mode tile instead: "Finding someone…"
   (`CallSearchViews.swift:41`) → 30-second timeout
   (`FirestoreCallService.swift:24`) → **"No one's free to talk right now.
   Try again in a bit."** (`CallService.swift:65`).

**VERIFIED — the search does not hang forever.** It fails honestly at 30s.
That was worth ruling out, but it is not what Apple hit; they hit a dead end
that no amount of waiting resolves.

This maps exactly onto Apple's two requests:
- *"Clarify what information users see when they are ready to get matched"* —
  they never got to that screen, so they are asking us to describe it.
- *"Provide a demo video showing the app sending a video/call request"* — they
  could not send one, and no in-app affordance to send one was visible.

### Aggravating factor — the answer to Apple's question is genuinely thin

Even on a healthy account, the Discover hero shows **less than the review
notes claim**:

- `DiscoverHeroCard.swift:40` — the headline is
  `featured.wantsToTalk ? "\(displayName) is waiting" : "Someone is waiting"`.
  When the flag is false the peer is **anonymous**: a photo and the word
  "Someone". No name, and **age and city are never on this screen at all**.
- The shipped screenshot `01-discover.png` captures exactly that state —
  a stranger's face, "Someone is waiting", "Talk to Her", captioned
  *"One tap starts a live video chat."*

Name/age/city do appear later — pre-connect (`CallSearchViews.swift:83-89`),
during the call (`ActiveCallView.swift:196-220`), and on the decision screen
(`CallDecisionViews.swift:28-42`) — all VERIFIED. But the screen where the
user *decides to call* shows the least, and that is the screen Apple asked
about and the screenshot they looked at.

---

## 2. Guideline 4.3(b) — root cause

**BLOCKING RISK. This is not a paperwork problem and it is not guaranteed
fixable.** Apple has been rejecting new entrants to the dating category under
4.3(b) on the strength of the *listing impression* alone. What Apple saw:

| Signal | Reality |
|---|---|
| **Lead screenshot** reads as random-stranger video chat: anonymous face + "Someone is waiting" + "One tap starts a live video chat" | The differentiator (mutual compatibility, identity-forward) is invisible; it looks like Omegle/Azar with a dating skin |
| **5 of 10 screenshots are generic dating furniture** — matches list, conversation, chat list, profile, Boost | Only 01/02/06 show the speed-call product |
| **Half the screens are near-empty** — `03-matches.png` shows "1 match" over a blank screen, `10-boost.png` is mostly whitespace | Reads as a thin/incomplete app, which is itself a 4.3 signal |
| **"Boost — jump to the front of the queue"** is a canonical dating-app monetization trope | Even though it is free (3/day, no IAP), it makes the app look like the category template |
| **Keywords are the generic dating set**: `dating,video,date,call,chat,match,singles,meet,speed,voice,love,relationship,romance` | `singles`, `love`, `romance`, `relationship`, `chat`, `match` are exactly the terms 4.3 keyword-clustering looks for |
| **Review notes never mention the actual differentiator flow** | They describe safety policy at length but never say "the user picks a specific person and sends them a live call request" |

The description text is genuinely well differentiated ("No endless swiping…
know in three minutes"). **The description is the only place the
differentiation appears, and it is the part reviewers skim.**

### What is actually differentiated (all VERIFIED at HEAD)

- **No swipe deck exists anywhere in the app** — Discover is one hero card
  plus two mode tiles (`DiscoverView.swift`). VERIFIED.
- **Meeting *is* a 3-minute live call**; there is no text-first path to a
  stranger. Server-capped at 180s (`shared.ts:17`), media token dies with the
  clock (`media.ts:61-96`).
- **Chat cannot be opened before a call.** Conversations are minted only
  inside the mutual-like transaction (`decisions.ts:50-115`). VERIFIED.
- **Pairing is mutual-preference, never random** (`compatibility.ts:37-39`).
- **Peer identity is shown before media connects and stays on screen.**
- **Phone verification on every account, no anonymous/social login.**
- **A pass is private and permanent** (`shared.ts:216-226`).

That is a real product difference. It is simply not what the listing shows.

---

## 3. Guideline 1.2 — still open, and one claim is currently unsupported

- **No automated content filtering exists.** `backend/functions/src/index.ts`
  exports no moderation trigger; `moderation.ts` is only an admin-only
  `resolveReport` triage callable. No Storage trigger, no Vision SafeSearch,
  no text filter for profile free-text, chat, or photos. VERIFIED.
  Apple requires "a method for filtering objectionable material" for UGC apps
  and applies it hardest to dating.
- **BLOCKING RISK — the live ASC review notes claim an SLA that nothing backs:**
  > "reports go to our moderation queue and are reviewed by our team, with
  > action (content removal, suspension, or permanent removal) **within 24
  > hours**."

  `LAUNCH_CHECKLIST.md` lists "Human moderation queue live + staffed + SLA" as
  unchecked, and `APP_REVIEW_NOTES.md` explicitly says *do not* put a number in
  writing until it is staffed. **This must be removed or made true before
  resubmission** — telling App Review something untrue about safety staffing is
  a far worse failure mode than the rejection itself.

---

## 4. Other sweep results

**VERIFIED clean:**
- Builds: `xcodebuild build -scheme Moomo` succeeded for iPhone 17 Pro Max and
  for iPad Air 11-inch (M3).
- Tests: rules **150/150**, functions **128/128**, iOS unit **233/233**. Exact
  commands in §7.
- Backend live: 17 functions deployed to `moomo-c7a37` in us-central1,
  including `acceptCallInvite` / `declineCallInvite`.
- iPad Air 11-inch (M3): app installs, launches, and renders correctly in
  iPhone compatibility mode (screenshot captured). No crash, no broken layout.
- Permission strings present and accurate (camera / microphone / photo library),
  each naming Baybe and stating that nothing is recorded.
- `ITSAppUsesNonExemptEncryption=false` present.

**NEEDS MANUAL ACTION:**
- **App Privacy labels** — cannot be read via API. The label set recorded at
  submission includes **Coarse Location**, but the app contains **no
  CoreLocation usage at all** (VERIFIED: no `CLLocation`/`NSLocation` anywhere;
  city is picked from a static catalog in onboarding). That label is very
  likely inaccurate and should be removed.
- Welcome copy says *"Find the person nearby you'd most like to meet"* — there
  is no proximity feature. Minor, but it is a location claim the app cannot back.
- Apple's new social-media age-rating questions are due in ASC by **2026-09-07**.

**UNVERIFIED:**
- One real device-to-device call on the production LiveKit stack (still the
  open item from `LAUNCH_CHECKLIST.md`).
- The `isVerified` badge renders in call UI but nothing server-side ever grants
  it (`discovery.ts:103-104`) — never claim photo/ID verification.

---

## 5. Fixes required before any resubmission

### A. Demo accounts (fixes 2.1) — **blocked on Firestore access**
Make the accounts in the review notes able to actually meet:
1. Delete the pass tombstone(s) between the demo pair
   (`passes/{uid}/passed/{peer}` in both directions).
2. Set `interestedIn`/`gender` so the demo pair is mutually compatible.
3. Confirm both have a complete profile: `displayName`, `age` (18+), `city`,
   `photoPath`, and a recent `lastActiveAt`.
4. Confirm no block documents between them.
5. Add a **dedicated fourth account** reserved for review, never used for
   passing/blocking in testing.

### B. Review notes rewrite (fixes 2.1's "clarify")
Must explicitly state: two accounts are required, that they are pre-paired and
compatible, the exact tap path, what is shown at each step, and **drop the
24-hour SLA claim**. Draft in `ASC_REPLY_2026-08-06.md`.

### C. Metadata + screenshot rework (the only lever on 4.3(b))
- Replace `01-discover` so the lead screen shows a **named, aged, located**
  person with an explicit "send a call request" CTA — not "Someone is waiting".
- Drop or demote the Boost and near-empty Matches screens.
- Add a screen that shows the *invite being sent / received* — the mechanic no
  other dating app has.
- Rewrite keywords away from `singles/love/romance/relationship`.

### D. App UI change (recommended, needs build 4)
`DiscoverHeroCard.swift:40` should always show name, age and city, and the
fallback should never read "Someone is waiting". This directly answers Apple's
question in the binary itself rather than in prose, and it is the single
cheapest change that makes the app *look* identity-forward instead of random.

---

## 6. What could not be verified here

Production Firestore reads/writes via `firebase-admin` were **blocked by the
local permission classifier** in this session. Consequently:

- The demo accounts' current `gender` / `interestedIn` / pass tombstones /
  profile completeness are **UNVERIFIED against production today**. The table in
  §1 comes from a 2026-07-29 working note, which matches the code behaviour and
  matches Apple's symptoms exactly — but it has not been re-read from the
  database.
- **The 2.1 fix cannot be applied** without that access.
- **A real demo video cannot be recorded locally** until the accounts can pair.

---

## 7. Commands run this session

```sh
cd backend/rules-tests && npm test          # 150/150 pass
cd backend/functions   && npm test          # 128/128 pass

cd app && xcodebuild build -project Moomo.xcodeproj -scheme Moomo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -derivedDataPath build/DerivedData        # BUILD SUCCEEDED

cd app && xcodebuild test -project Moomo.xcodeproj -scheme Moomo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:MoomoTests \
  -derivedDataPath build/DerivedData        # 233 tests, 0 failures

# iPad Air 11-inch (M3) — the device Apple reviewed on
xcrun simctl boot 6F16B2C7-2844-4038-A718-53C987ADAB2E
cd app && xcodebuild build -project Moomo.xcodeproj -scheme Moomo \
  -destination 'platform=iOS Simulator,id=6F16B2C7-2844-4038-A718-53C987ADAB2E' \
  -derivedDataPath build/DerivedDataIPad    # BUILD SUCCEEDED
xcrun simctl install 6F16B2C7-… build/DerivedDataIPad/…/Moomo.app
xcrun simctl launch  6F16B2C7-… com.moomo.dating   # launches, renders correctly

firebase functions:list --project moomo-c7a37      # 17 functions, all deployed
```
