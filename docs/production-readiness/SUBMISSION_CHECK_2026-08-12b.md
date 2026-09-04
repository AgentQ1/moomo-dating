# Baybe 1.0 — final resubmission check, 2026-08-12 (second pass, with video)

**Verdict: NO-GO. Nothing was submitted to Apple.** The App Store Connect record
is untouched: version 1.0 is still `REJECTED` with build 3 attached, and the
latest reviewSubmission is still `UNRESOLVED_ISSUES`.

Two gates fail. The demo video is the new one, and it is the one that matters —
it cannot be sent to Apple as-is.

---

## 1. Gate summary

| # | Gate | State |
|---|---|---|
| 1 | Tests and build | ✅ PASS — 178 + 166 + 261, zero failures |
| 2 | Production (project, rules, functions, hosting) | ✅ PASS — all live and matching the repo |
| 3 | Demo accounts pairable | ✅ PASS — 3/3 CAN PAIR, re-verified today |
| 4 | Coarse-location client behaviour | ✅ PASS by code audit — cannot be exercised in a shipped build yet |
| 5 | **Build 4 exists and is selected** | ❌ **FAIL — build 4 still does not exist** |
| 6 | **Demo video usable** | ❌ **FAIL — recorded from a DEBUG build; leaks the Firebase project id; never shows the receiving side** |
| 7 | Review notes free of the 24-hour SLA | ❌ FAIL — still live in ASC, verbatim |
| 8 | Coarse Location privacy label published | ⚠️ UNVERIFIABLE from CLI — no API, console only |

---

## 2. The demo video — why it cannot be sent

File: `~/Desktop/ScreenRecording_08-12-2026 14-27-07_1.mov`
200.8 s, 1320×2868, 390 MB, recorded 2026-08-12 14:27 local.

### 2.1 It is a DEBUG build, and it predates build 4 by 1h45m

The decisive fact is a clock, not a judgement call:

| Time (2026-08-12) | Event |
|---|---|
| **14:01:36** | DEBUG build installed on the device (`Debug-iphoneos/.XCInstall`) |
| **14:27:07** | Screen recording starts (the .mov's creation date) |
| **16:12:29** | `project.pbxproj` edited — `CURRENT_PROJECT_VERSION` 3 → 4 |

The build number was raised to 4 **after** the video was already recorded. Nothing
that appears in this file can be build 4. It is the DEBUG build that was on the
device when the project still said 3.

The rest is on disk too.

| Evidence | Result |
|---|---|
| `DerivedData/…/Build/Products/` | Contains **only** `Debug-iphoneos` and `Debug-iphonesimulator`. There is **no `Release-iphoneos`** |
| `Debug-iphoneos/.XCInstall` mtime | **2026-08-12 14:01** — a DEBUG build was installed on the device 26 minutes before the recording started |
| `~/Library/Developer/Xcode/Archives` | No archive since 2026-08-01 |
| `app/build/` | `Baybe-1.0-2`, `Baybe-1.0-3` only |
| The video shows the Discover location bar | That view (`DiscoverLocationBar.swift`) is **uncommitted working-tree code**. TestFlight build 3 does not contain it, so the video cannot be from TestFlight either |

The checklist requirement — *"recorded from Build 4 or a Release/TestFlight
build, not DEBUG"* — fails on both halves.

Why it matters beyond bookkeeping: in DEBUG, `DiscoveryService.swift:96` appends
`"(Debug: \(code))"` to the Discover error card. The recording got lucky — the
feed never errored — but the build is one network hiccup away from putting a
backend error code on camera.

### 2.2 It puts the Firebase project id on screen

At **t ≈ 8–11 s**, phone verification opens a web view whose title bar reads:

> **moomo-c7a37.firebaseapp.com**

Held for about three seconds, legible, full width. This fails the explicit
requirement that the video expose no Firebase project ids or URLs — and it hands
a 4.3(b) reviewer the string "moomo" in Apple's own screenshot of your app.

This is the known Firebase Phone Auth reCAPTCHA leak (custom Auth domain not
configured). It cannot be fixed in the repo.

### 2.3 It does not use the reviewer demo accounts

The video signs up a **brand-new account on a real phone number, `+1 650 555
0109`** — which is why the reCAPTCHA appeared at all (Firebase test numbers skip
it) and why a real SMS code was typed rather than `123456`.

Apple asked what *they* will see with the accounts *they* were given. The video
answers a different question. The account it creates is "Franshika, 23" —
not Solan, Lily, or Lulu.

Note also: the throwaway account the video is driven from, `+1 650 555 0109`,
**was deleted from production** during the demo-account cleanup (§4). The video
now depicts an account that no longer exists.

### 2.4 It never shows the receiving side — the actual 2.1 ask

Verified exhaustively, not by spot-check: the whole file was sampled at
**1-second granularity (201 samples)** and reduced to **47 distinct scenes** by
a frame-signature diff, so a banner with the client's ~7-second lifetime could
not fall between samples. Every scene is a single device, signed in as
"Franshika, 23", start to finish. There is no incoming-call banner, no Answer
and no Decline anywhere in the file.

Beat by beat:

| Time | What is on screen |
|---|---|
| 0:00–0:20 | Sign-up: consent, phone number, reCAPTCHA, SMS code |
| 0:20–1:10 | 13-step onboarding (name, DOB, intention, photos, bio, interests) |
| 1:20–1:48 | Discover — "Franshila, 24 / Chicago · Online now", **"Nearby"** button; Chat and Calls empty states |
| 1:53–1:54 | Discover shows **Lulu, 21** with the "Wants to Talk to You" bubble |
| ~1:54.5 | **"Nearby" is tapped** — the request is sent |
| 1:56 | "Connecting… Lulu, 21" |
| 2:00 | In call — "3-Minute Speed Call, Time left 02:55", peer name/city overlay |
| 2:08 | "Call ended!", Pass / Like, Report / Block |
| 2:16–2:40 | Match with Lulu, chat opens, two messages sent |
| 2:56–3:20 | Discover, Matches (We Met / Report / Block / Unmatch), Profile with Delete account |

What is shown: a request being **sent**, and a call **connecting**.

What is never shown: **the recipient receiving anything.** There is no incoming
call banner, no Answer, no Decline, anywhere in 200 seconds. Only one device was
recorded. And because Lulu was already flagged "Wants to Talk to You", the tap
took the *instant-pair* path — so even the caller's "Finding someone…" state and
the whole ring/banner mechanism never ran.

The required beats "demo account B receiving the request" and "accept/decline"
are absent. Sending Apple a reply that describes a banner with Answer/Decline,
attached to a video that contains neither, invites the same 2.1 rejection.

### 2.5 It exposes your own private photo library

At **t ≈ 48 s** the photo picker fills the screen with the recording device's
real camera roll: screenshots of a messaging app's settings including a "Blocked"
list, a conversation with a named contact, and financial-app screens. This is
your personal data, and it would ship to Apple inside the attachment.

### 2.6 Size

390 MB for a 3:20 clip. It will need compressing or hosting before it can be
attached or linked, whatever else changes.

---

## 3. Build 4 — numbered, but never built or uploaded

**Update, 16:12:** `CURRENT_PROJECT_VERSION` has been bumped to **4** in
`project.pbxproj` (uncommitted). That is the version *number* only — there is
still no artifact:

- `app/build/` holds `Baybe-1.0-2.xcarchive` and `Baybe-1.0-3.xcarchive`. **No
  `Baybe-1.0-4.xcarchive`.**
- DerivedData holds only `Debug-iphoneos` and `Debug-iphonesimulator`. **No
  `Release-iphoneos`** — nothing has ever been built for release.
- ASC `/v1/builds` returns **1, 2, 3**. Nothing uploaded.

So build 4 can now be *cut*, but it has not been. The original finding stands:

Unchanged from this morning's finding, re-verified against the live API:

| Evidence | Result |
|---|---|
| `/v1/builds?filter[app]=6793496424` | Builds **1, 2, 3** only. Build 3 uploaded 2026-07-29, VALID, not expired |
| `/v1/apps/6793496424/appStoreVersions` | One version, `1.0`, `appStoreState: REJECTED` |
| `/v1/reviewSubmissions` | Latest `9942a9c1…` = **UNRESOLVED_ISSUES** (2026-07-29) |
| `CURRENT_PROJECT_VERSION` | **3** |
| Proximity client | Still entirely **uncommitted** on `fix/appcheck-app-attest-team-id` |

I did not cut build 4. Doing so now would produce a build that the current video
does not depict, and the video has to be re-recorded anyway — so the build must
come **first**, and the video must be recorded **from it**.

---

## 4. What passed

### Tests, run today

| Suite | Result |
|---|---|
| `backend/functions && npm test` | **178 / 178**, 0 fail |
| `backend/rules-tests && npm test` | **166 / 166**, 0 fail |
| `xcodebuild test -only-testing:MoomoTests` | **261 / 261**, 0 fail — `** TEST SUCCEEDED **` |
| App target compile | Succeeded (as part of the test build) |

Note: the first rules-tests run reported a Firestore emulator fatal error
because it was launched concurrently with the functions suite and the two
collided on emulator ports. Re-run alone, it passed 166/166. Do not run those
two suites in parallel.

### Production, verified live

| Check | Result |
|---|---|
| Active Firebase project | **moomo-c7a37** |
| Firestore rules release | ruleset `6680198e…`, released 2026-08-12T18:24Z |
| Deployed ruleset vs `backend/firestore.rules` | **byte-identical** (`cmp` clean, 28 562 bytes); `isCoarseGridValue` present ×3 |
| Cloud Functions | **17 / 17** deployed, incl. `getDiscoveryFeed`, `joinMatchmakingQueue`, `acceptCallInvite` |
| `baybe-dating.web.app/privacy` | **HTTP 200**, carries the "Approximate location… rounded to about a square kilometre" paragraph |

### Demo accounts, re-verified minutes ago

`node backend/functions/scripts/demo-accounts.mjs` (read-only) against
production:

| Phone | Name | Gender | interestedIn | Intention | Photos |
|---|---|---|---|---|---|
| +1 650 555 1234 | Solan | man | `["everyone"]` | figuringItOut | 1 |
| +1 650 555 5678 | Lily | woman | `["everyone"]` | figuringItOut | 1 |
| +1 650 555 9876 | Lulu | woman | `["everyone"]` | figuringItOut | 1 |

All three pairs **CAN PAIR** — no blocks, no pass tombstones, no preference
mismatch. Still perishable; re-run in the final minutes before submitting.

#### Reviewer-facing state, deep-checked and repaired

`demo-accounts.mjs` only answers "can these three pair". Two new scripts answer
"is this account actually fit to hand a reviewer":

- **`scripts/inspect-demo-account.mjs`** (read-only) — Auth enabled, every field
  `candidateFrom()` reads, Storage objects behind each `photoPath`, private/public
  preference divergence, leftover matches/threads/invites/notifications, blocks
  and pass tombstones against the other two, reports filed against the account,
  and a **feed preview** that replicates `getDiscoveryFeed`'s composition to
  answer the 2026-08-05 question directly: *would Discover have anything to show?*
- **`scripts/clean-demo-account.mjs`** (dry-run by default, `--apply` to commit) —
  clears inert invites and unread notifications, and does full account deletion
  mirroring `src/account.ts` document for document. It refuses to delete any of
  the three review accounts.

Applied to production on 2026-08-12:

| Change | Detail |
|---|---|
| Deleted the video throwaway | `+1 650 555 0109` "Franshika" (`cuuIsYoH…`) — profile, photos, 1 match, 1 conversation, 1 call session, queue/invite/boost docs, Auth user |
| Cleared Lulu's leftover invite | `callInvites/Ocafnj68…`, cancelled and 111 min expired |
| Marked notifications read | 2 on Lulu, 2 on Solan — they were putting an unclearable badge on the tab bar |

**Kept by decision:** Lulu's two remaining matches/threads (Franshika `Qz3kQ3dH…`,
Élodie) and Lily's two, so a reviewer who cannot stage a two-device call can still
see that chat exists and is gated behind a match. They are typo-laden test
chatter ("Ink", "I,m finr"), which is a 4.3(b) judgement call, not a defect —
the script marks them `!`, not `✗`.

**Result — all three accounts now report zero defects, all three pairs CAN PAIR**,
and each account's feed preview returns **12 people** with the hero card and its
"Nearby" call button. The 2.1 failure mode is provably absent.

⚠️ Correction to an earlier claim in this file: a leftover `callInvites` document
is **not** a banner risk. `CallInviteLogic.invite()`
(`app/Moomo/Services/CallInviteLogic.swift:29-32`) requires `status == "ringing"`
**and** `expiresAt > now` and rejects cache replays, so terminal or expired
invites are inert. The script now tests those same two conditions rather than
mere existence.

### Coarse location client — code audit

Cannot be exercised in a shipped build (there isn't one), so verified by reading:

- `CoarseLocationReporter.swift:44` — `gridDegrees = 0.01`; `:56` snaps before
  any write; `:141` re-asserts `isSnapped` and refuses to write otherwise.
- Writes to `users/{uid}/private/location` — owner-read-only.
- **Denied location is safe**: `:124-125` reads `authorizationStatus` and
  returns early unless `authorizedWhenInUse`/`authorizedAlways`. No write, no
  throw, no prompt. Discovery falls through to activity ordering.
- Grid constants aligned across the three places that must move together:
  client `0.01`, `proximity.ts` `LOCATION_GRID_DEGREES = 0.01`, deployed rules
  `value * 100` within `0.001`.

---

## 5. App Store Connect metadata

### Review notes — the 24-hour SLA is still live

`/v1/appStoreVersions/a9f46f0b…/appStoreReviewDetail` still contains, verbatim:

> Moderation: reports go to our moderation queue and are reviewed by our team,
> with action (content removal, suspension, or permanent removal) **within 24
> hours**.

Nothing staffs that. It must be replaced with the user-supplied sentence:

> Users can report or block profiles and calls in the app. Reports are reviewed
> by the Baybe team and action is taken when content or behavior violates our
> policies.

I did not edit it. Editing the notes without submitting would leave the record
in a half-changed state; the notes should be replaced in the same pass that
attaches build 4.

### Privacy labels — no API, console only

`/v1/apps/6793496424/dataUsages` → **404**. `/v1/appDataUsages?filter[app]=…` →
**404**. Consistent with every previous attempt: App Privacy answers are not
exposed by the App Store Connect API in either direction. Whether Coarse
Location is declared, and whether it is (correctly) marked *not* used for
tracking, can only be read in the web console.

`Moomo/PrivacyInfo.xcprivacy` does declare
`NSPrivacyCollectedDataTypeCoarseLocation` — but the manifest and the store
label are separate systems, and only the label is what Apple's reviewer reads.

---

## 6. Ordered path to GO

1. ~~Delete the `+1 650 555 0109` throwaway account~~ — **done**, see §4.
2. **Commit the proximity work** and the two new scripts. Nothing on `main`
   records what would ship.
3. **Bump `CURRENT_PROJECT_VERSION` to 4**, archive, export with
   `manageAppVersionAndBuildNumber=false`, upload with `altool`. Wait for VALID
   (~5 min for build 3).
4. **Install that Release build on the physical device** — via TestFlight once
   processing completes, which is also what makes the video honestly "build 4".
5. **Re-record the video** against §7 of `RESUBMISSION_PACKAGE_2026-08-12.md`,
   fixing all five faults:
   - Release/TestFlight build, not DEBUG.
   - Sign in as **Solan** (`+1 650 555 1234` / `123456`) — a Firebase test
     number, which also means **no reCAPTCHA web view and no project id on
     screen**. Skip sign-up entirely; the reviewer does not need onboarding.
   - **Two devices.** Show B's incoming banner and both Decline and Answer.
     Make sure the callee is **not** already in "Wants to Talk to You", or the
     ring path is skipped again.
   - Do not open the photo picker on a device holding personal photos.
   - Do not tap **Pass**.
6. **Compress or host** the result.
7. **Publish the Coarse Location privacy label** in the console (§8 of the
   package doc) and click the top-of-page **Publish**.
8. **Replace the review notes** — this is what strikes the 24-hour SLA.
9. **Attach build 4** to version 1.0. If it 409s, cancel the pending
   submission first, let the version settle to `DEVELOPER_REJECTED`, retry.
10. **Post the Resolution Center reply** and attach/link the video.
11. **Re-run `demo-accounts.mjs`**; all three pairs must read CAN PAIR.
12. Submit.

## 7. Still unaddressed

- **Guideline 4.3(b)** is untouched and concept-level. Apple's wording
  (*"reconsider the app concept and submit a new app"*) pre-empts a
  differentiation argument. Resubmitting a perfect 2.1 answer can still be
  rejected on 4.3(b). The structural appeal is drafted in
  `ASC_REPLY_2026-08-06.md` Part 2.
- **Guideline 1.2** — still no automated content filtering.
- **Firebase Phone Auth still serves `moomo-c7a37.firebaseapp.com`** in the
  reCAPTCHA fallback and SMS body. Needs a custom Auth domain in the Firebase
  console. Using test numbers in the video sidesteps it; a real reviewer typing
  a real number would still see it.

---

*Internal. Nothing in this file has been sent to Apple.*
