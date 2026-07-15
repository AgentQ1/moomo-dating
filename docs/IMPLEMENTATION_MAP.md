# Moomo — Implementation Map

Phase 1 deliverable. Written 2026-07-15.

## Audit result

No speed-dating codebase existed. Every "Moomo" project on the machine
(`~/moomo-ios`, `~/moomoios`, `~/moomoios2`, `~/moomo-web`,
`~/Desktop/MoomoAI`, `~/Desktop/MoomoWebApp`) is the same product lineage: a
Gemini-powered AI chat / presentation / image-generation app. Searched every
repo, every branch, and the whole disk for `RTCPeerConnection`,
`matchmakingQueue`, `callSessions`, `Video Match`, `Wants to Talk` — zero hits.
The only keyword matches were false positives (`syncAllSessions` matching
"callsession"; `appStoreUnmatchedEvents`, an App Store webhook, matching
"unmatch").

`~/Desktop/MoomoAI` is a live product (release prep for 1.0(3), App Store
Connect, Firebase `moomoios-2026`, StoreKit). It is **not** touched by this
work.

Decision: greenfield build at `~/moomo-dating`, new Firebase project.
Every screen below is therefore **new**. There is no existing implementation
to diff against.

## Reference coverage

Six reference screens were supplied for thirteen required screens.

| # | Screen | Reference? | Status |
|---|--------|-----------|--------|
| 1 | Welcome / auth | ✅ supplied | Built, visually iterated |
| 2 | Onboarding | ❌ none | Not started — extrapolate |
| 3 | Discover home | ✅ supplied | Not started |
| 4 | Matching queue | ❌ none | Not started — extrapolate |
| 5 | 3-minute speed call | ✅ supplied | Not started |
| 6 | Call-ended decision | ✅ supplied | Not started |
| 7 | Match creation | ✅ supplied | Not started |
| 8 | Chat | ✅ supplied (same shot as 7) | Not started |
| 9 | Calls tab | ❌ none | Not started — extrapolate |
| 10 | Matches tab | ❌ none | Not started — extrapolate |
| 11 | Chat list | ❌ none | Not started — extrapolate |
| 12 | Profile | ✅ supplied | Not started |
| 13 | Premium | ❌ none | Not started — extrapolate |

Plus settings and safety screens (no reference).

## Screen 1 — Welcome / auth

**Files.** `Features/Auth/WelcomeView.swift`,
`Features/Auth/LegalDocumentView.swift`, `Components/MoomoLogo.swift`,
`Components/AuthButton.swift`, `Components/ConsentRow.swift`,
`Components/Sparkle.swift`.

**Visual deltas resolved during iteration** (each caught by screenshotting the
running app, not by inspection):

| Delta | Fix |
|---|---|
| Logo collided with the Dynamic Island | Flexible spacers replaced with measured offsets |
| Arc gap at 12 o'clock | Gap moved to the reference's -78°→-13° opening |
| Wordmark too heavy and too wide | System serif → Didot at 0.13 × diameter |
| Figures too small, then too tall | Frame grossed up per-axis to the reference's 0.46 × 0.468 |
| Heads rendered as ellipses | Head diameter keyed off width on both axes |
| Auth buttons 80pt tall | 60pt, per the reference's ~0.063 × screen height |
| Divider 2× too wide | 110pt (~0.27 × screen width) |
| **Consent sentence truncated to one line** | `.fixedSize(horizontal:false, vertical:true)` |

**Known remaining delta.** The two figures are a hand-traced bezier
approximation. They read correctly as the mark but are not pixel-identical —
the clasp sits slightly low and the negative-space wedge between the heads is
wider than the reference. **This cannot be closed by tracing.** It needs the
source vector (Illustrator/SVG/PDF) exported and dropped into the asset
catalog, at which point `MFigures` collapses to an `Image`.

**Reference/spec conflict, and how it was resolved.** The reference shows the
consent checkbox *unchecked* with the three sign-in buttons at full strength.
The spec requires sign-in "disabled until consent is checked". Dimming
contradicts the reference; signing in contradicts the spec. Resolution: the
rows stay visually identical to the reference and remain tappable, but a gated
tap refuses sign-in, bounces the checkbox, fires a warning haptic, and posts a
VoiceOver announcement. Consent is strictly enforced and never inferred.
Flip to literal dimming by driving `.opacity` from `isGated` in
`AuthButton.swift`.

**Backend behaviour required.** Record consent (timestamp + document version)
against the account at creation; Google/Apple/anonymous sign-in via Firebase
Auth; App Check attestation before any callable.

**Navigation.** Consent → provider → new user goes to onboarding, returning
user with a complete profile goes to Discover.

**Data model.** `users/{uid}` with `consentedAt`, `consentDocumentVersion`,
`authProvider`, `createdAt`.

**Acceptance criteria.**
- Sign-in impossible without consent (enforced client *and* server side).
- No intermediate consent screen, no duplicate consent prompt.
- Legal links open in-app and work offline.
- Cold launch to interactive under 400ms.

## Screens 2–13

Not yet implemented. Each needs the same treatment as screen 1: build, run,
screenshot, compare, correct, repeat.

## Blockers

1. **Reference screens are not on disk.** They were supplied in conversation
   only. Programmatic diffing (Phase 8) needs them saved as PNGs — ideally at
   a known device size — under `tools/visual/reference/`. Until then, visual
   comparison is by eye, which caught real bugs but cannot certify
   pixel-parity.
2. **Source logo vector** — see above.
3. **Firebase project** must be created; config dropped at
   `app/Moomo/GoogleService-Info.plist`.
4. **TURN/STUN provider** must be chosen before WebRTC. Peer-to-peer calls fail
   for a large share of real users without TURN relay.
5. **Legal copy** in `LegalDocumentView` is placeholder and must be replaced by
   counsel-reviewed text before any submission.

---

## Firebase integration (2026-07-15, later)

Linked: `firebase-ios-sdk` (FirebaseAuth, FirebaseFirestore, FirebaseStorage)
and `GoogleSignIn-iOS`, via SPM.

**Deliberately not linked:**
- `FirebaseMessaging` — no push in the current spine. Linking it now would
  require notification entitlements for a feature that doesn't exist.
- `FirebaseAppCheck` — cannot be configured safely for local development
  without a per-machine debug provider token. Enabling it now would break the
  simulator for anyone who hasn't registered their debug token. It goes in
  alongside the first Cloud Function, which is when it starts protecting
  anything.

**Collections introduced:**

    users/{uid}                      private account data — owner-only
    users/{uid}/private/onboarding   resumable draft — owner-only
    publicProfiles/{uid}             public projection — owner-only for now

`publicProfiles` is intentionally *not* readable by other signed-in users yet.
Discover runs on mock data, so nothing needs it, and opening it before blocks
and rate limiting exist would expose every profile to any account.

**Blockers found:**

1. **Google sign-in cannot work** — no iOS OAuth client exists, so the plist
   carries no `CLIENT_ID`/`REVERSED_CLIENT_ID`. Registering the app via the CLI
   does not mint one. Console action required.
2. **Anonymous was disabled** despite being reported as enabled. Caught by
   probing the live API rather than trusting the description; the user enabled
   it, and it is now verified working.
3. **The Firebase CLI was pointed at `fitcheck-d3091`** — an unrelated project —
   from inside this repo. A deploy would have hit the wrong project. Now pinned.
