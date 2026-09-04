# Baybe 1.0 — final resubmission package, 2026-08-12

**Verdict: NO-GO.** Prepared, not submitted, per instruction. Four of the five
gates you set are not met; one cannot be verified from here and needs your eyes
in the console.

Everything below was verified against live production, the live App Store
Connect record, and the code at working-tree HEAD on 2026-08-12. Where a claim
could not be verified, it says so rather than assuming.

---

## 1. Gate summary

| # | Gate | State |
|---|---|---|
| 1 | Build 4 uploaded **and** selected | ❌ **FAIL — build 4 does not exist.** ASC holds builds 1, 2, 3 only |
| 2 | Coarse Location privacy label published | ⚠️ **UNVERIFIABLE from here.** No ASC API exposes labels; must be read in the console |
| 3 | Demo video recorded / attached / link-ready | ❌ **FAIL — no video file exists** anywhere on this machine |
| 4 | Demo accounts verified immediately before submission | ✅ **PASS as of 2026-08-12** — must be re-run in the final minutes |
| 5 | Review notes match the actual UI | ❌ **FAIL** — live notes carry the 24-hour SLA, disclose no location, and predate the new Discover location bar |

---

## 2. Build 4 — the finding that drives the verdict

**Build 4 has never been built, archived, or uploaded.** This is not a
processing delay; there is no artifact.

| Evidence | Result |
|---|---|
| ASC `/v1/builds?filter[app]=6793496424` | Only **3** builds: 1, 2, 3 — all VALID, none expired. Build 3 uploaded 2026-07-29 |
| ASC version 1.0 (`a9f46f0b…`) | State **REJECTED**, attached build **3** |
| Latest reviewSubmission `9942a9c1…` | State **UNRESOLVED_ISSUES** |
| `app/build/` | `Baybe-1.0-2.xcarchive`, `Baybe-1.0-3.xcarchive` — **no 1.0-4** |
| `CURRENT_PROJECT_VERSION` in `project.pbxproj` | **3** — not yet bumped |

### Would a build 4, cut today, actually contain the proximity client?

Yes — the code is complete and wired, and I verified each link in the chain
rather than trusting the file's presence:

- `app/Moomo/Services/CoarseLocationReporter.swift` exists and snaps to a
  `0.01°` grid before any write, writing `users/{uid}/private/location`.
- It is **actually invoked**: `FirestoreDiscoveryService.swift:62` calls
  `CoarseLocationReporter.refreshIfAuthorized(uid:)` on every feed load. A file
  that compiled but was never called would have been the trap here; it is not
  the case.
- The Xcode target uses `PBXFileSystemSynchronizedRootGroup` over the whole
  `Moomo/` folder, so the new files compile into the target automatically
  without pbxproj entries.
- `Moomo/PrivacyInfo.xcprivacy` already declares
  `NSPrivacyCollectedDataTypeCoarseLocation`.
- `Info.plist` carries `NSLocationWhenInUseUsageDescription`.
- **BUILD SUCCEEDED** (iPhone 17 Pro simulator, 8.9 s).

**But it is all uncommitted.** Every proximity file is untracked or modified in
the working tree on branch `fix/appcheck-app-attest-team-id`. Nothing is on
`main`. An archive cut right now would capture it, but nothing in version
control records what shipped — commit before archiving, or build 4 becomes
unreproducible.

### The deployed backend it talks to — verified live

| Check | Result |
|---|---|
| Cloud Functions deployed | **17 / 17 ACTIVE**, incl. `acceptCallInvite` |
| `getDiscoveryFeed`, `joinMatchmakingQueue` | Updated **2026-08-12T18:25Z** — the proximity deploy |
| Firestore rules release | **2026-08-12T18:24Z**, ruleset `6680198e…` |
| Deployed ruleset vs `backend/firestore.rules` | **Byte-identical**; `isCoarseGridValue` present and enforcing the `0.001` tolerance |
| Legal pages | `baybe-dating.web.app/privacy` and `/terms` **match local exactly** — the location paragraph is live |

The three constants that must move together are aligned:
`LOCATION_GRID_DEGREES = 0.01` (proximity.ts:53), `CoarseLocation.gridDegrees =
0.01` (CoarseLocationReporter.swift:44), and `value * 100` within `0.001` in
the deployed rules.

**Net:** the backend is live and correct; the client is written, wired, and
building; the only missing artifact is the build itself.

---

## 3. Demo accounts — verified pairable on production

Ran `node backend/functions/scripts/demo-accounts.mjs` (read-only) against
`moomo-c7a37` on 2026-08-12. The repair held:

| Phone | uid | Name | Gender | interestedIn | Intention | Photos |
|---|---|---|---|---|---|---|
| +1 650 555 1234 | `vElHha37…` | Solan | man | `["everyone"]` | figuringItOut | 1 |
| +1 650 555 5678 | `NmDVKN99…` | Lily | woman | `["everyone"]` | figuringItOut | 1 |
| +1 650 555 9876 | `Ocafnj68…` | Lulu | woman | `["everyone"]` | figuringItOut | 1 |

All three pairs **CAN PAIR** against the four real server gates in order:
mutual gender preference, overlapping intention, no block either way, no pass
tombstone either way — plus a present `displayName` and ≥1 photo.

⚠️ **This is perishable.** Any test call that ends in a "pass" writes a
permanent tombstone and silently re-breaks the pair — exactly what caused the
2026-08-05 rejection. Re-run the script in the final minutes before you submit,
and **do not press "pass" while recording the demo video.**

---

## 4. The 24-hour moderation SLA — still live, must be struck

**The repo is clean.** Every `24`-hour hit in the source tree is an unrelated
product feature (the 24-hour chat window, the 3-per-24h boost allowance, report
and block rate-limit windows) or an internal note saying to strike the claim.

**App Store Connect is not clean.** The live `appStoreReviewDetail.notes`
still contains, verbatim:

> Moderation: reports go to our moderation queue and are reviewed by our team,
> with action (content removal, suspension, or permanent removal) **within 24
> hours**.

Nothing staffs a 24-hour queue. Replace that line with the §5 text below. The
replacement notes drop the SLA entirely rather than substituting a longer one,
because no interval is currently backed.

---

## 5. Review notes — paste-ready replacement

Paste into **App Store Connect → App Review Information → Notes**, replacing the
current text in full. This fixes the SLA, adds the location disclosure that
build 4 now requires, and describes the Discover location bar the reviewer will
actually see.

```
Baybe is an 18+ dating app built around short (3-minute, server-capped) video and voice calls between mutually compatible, phone-verified users. (Bundle ID com.moomo.dating and the internal project name "Moomo" are historical and not user-visible.) It is not anonymous or random video chat:

- Every account requires SMS phone verification - there is no anonymous, guest, or social login. Restored sessions without a verified phone number are signed out.
- Users are 18+: date of birth is required during onboarding and the server's security rules reject any under-18 date of birth.
- Calls are never random-with-strangers: pairing requires both users' stated gender preferences and relationship intentions to accept each other, and the peer's profile (photo, name, age, city) is shown before video connects and stays on screen during the call.
- Community-guideline acceptance (no harassment, hate, or nudity - violations end in removal) is a mandatory onboarding step; users must agree before completing sign-up.

SAFETY / UGC (Guideline 1.2):
- Report: every participant can be reported during the call, on the post-call decision screen, from chat, and from the matches list. Reports include a reason and are stored server-side with the reported content reference.
- Block: available everywhere reporting is. Blocking is server-side and mutual: the pair can never be matched or paired again, any live call between them is ended immediately, and their conversation is hidden.
- Filtering: the Discover feed and matchmaking are server-composed and exclude blocked users in both directions; a pass/skip means the other user is never shown again.
- Moderation: reports are delivered to a server-side moderation queue and triaged by our team, which can remove content, suspend an account, or remove it permanently. Blocking takes effect immediately and does not wait on that review.
- Account deletion: in-app at Profile > Delete account (confirmation required). Deletion removes profile, photos, matches, conversations, and the auth user server-side.
- Calls are length-capped at 180 seconds by the server (the media token expires with the call clock) and are never recorded.
- Chat opens only after both users independently choose "like" after a call; a "pass" is never revealed to the other person.

LOCATION (new in this build):
- Baybe collects approximate location only, and only to decide the ORDER in which already-compatible people are shown. It is never a filter - nobody is excluded for being far away, and no distance is ever displayed.
- The app never prompts for location on its own. The only prompt comes from the "use my current location" control inside the city picker, which the user opens deliberately from the location bar at the top of Discover.
- If permission is granted, the position is requested at reduced accuracy and rounded ON THE DEVICE to a grid of about one kilometre before it is sent. No exact coordinate is ever stored, logged, or transmitted.
- The rounded value is written to a private per-account document that only that account can read; our security rules re-validate the rounding server-side and reject anything finer. It is never published to other users.
- Declining location costs nothing: the feed is ordered by recent activity instead and every feature still works.

DEMO ACCOUNT: sign in with phone number +1 (650) 555-1234 and SMS code 123456. This is a Firebase test number - no real SMS is sent; tick the consent box, enter the number on the welcome screen, then enter code 123456 on the code screen. Two additional test accounts exist if you need to test matching: +1 (650) 555-5678 (code 222222) and +1 (650) 555-9876 (code 333333).

IMPORTANT - Baybe needs two people, exactly like a phone call. With only one account signed in, the app correctly reports that nobody is available. Please sign in on two devices or simulators to see a call connect. Exact steps are in the attached demo video.

Privacy policy: https://baybe-dating.web.app/privacy
Terms: https://baybe-dating.web.app/terms
Support: https://baybe-dating.web.app (email moomolab@gmail.com)

Thank you for your review.
```

---

## 6. Resolution Center reply — paste-ready

Every visual claim below was read off the views at HEAD today. The
`DiscoverHeroCard` and `DiscoverView` changed with the proximity work, so the
earlier drafts were re-verified rather than reused.

```
Thank you for the detailed feedback, and apologies for the time it cost you. The fault was ours, not the app's.

WHY YOU COULD NOT REACH A MATCH

Baybe pairs two people only when both people's stated preferences accept each other, and a "pass" permanently separates a pair. The demo accounts we supplied had been used in our own testing until they no longer satisfied those rules, so the account you signed into had no eligible partner and could never reach a match — which is why no call-request button was reachable. We have reset the accounts and verified against production that all three pair with each other.

Baybe also needs two people, exactly like a phone call. With one account signed in, the app correctly reports that nobody is available. We have attached a demo video showing the full flow end to end.

1. WHAT A USER SEES WHEN THEY ARE READY TO GET MATCHED

The Discover tab shows one specific person, not a queue and not a deck: their photo, their first name and age on one line, their city, and whether they are online now. When that person is actively waiting for a call, a "Wants to Talk to You" bubble appears beside their photo. Smaller photos of other people available right now orbit the card. There is no swiping and no card stack anywhere in Baybe.

At the top of the screen is a bar showing the user's own city and their relationship intention; each opens a picker for changing it.

2. WHAT IS SHOWN BEFORE A MATCH

Before any call: photo, first name, age, city, online status. Nothing else about a person is available to another user anywhere in Baybe — there is no profile browser and no message field. Once connected, the peer's name, age, city and occupation are shown full-screen while the call establishes and stay on screen for the whole call, alongside a visible countdown.

3. WHAT IS SHOWN AFTER A MATCH

A match exists only after two people have completed a live call together and then each independently and privately chose "Like" on the post-call screen. Only then does a text conversation open. A "Pass" is never revealed to the other person. Until that point there is no way for any user to send any message to any other user.

4. HOW A USER SENDS A VIDEO/CALL REQUEST

On the Discover tab, the button directly under the person's name and city — labelled "Nearby", with a video-camera icon — sends a live video call request.

It reaches the person on the card first. If that person is already waiting for a call, the two pair immediately and the call connects. Otherwise Baybe rings them: their app raises an incoming-call banner showing the caller's photo, their first name, whether it is a video or voice call, and Answer / Decline. Up to eight mutually compatible people who are online at that moment may be rung; the first to answer is connected atomically and every other ring is withdrawn. The banner is live for about 7 seconds. Declining, or letting it time out, ends it silently — the caller is never told who declined. If nobody answers within about 30 seconds, the caller is told nobody is free to talk right now.

The two tiles lower on the same screen, "Video Match" and "Speed Talk", are a different action: they ask to be paired with whoever is available, rather than with a named person. Only the button under the photo is a directed request.

Every call is ended by our server at 180 seconds; the media credential expires with the call clock, so no client can extend a call, and calls are never recorded. Either person can report or block the other during the call, on the decision screen afterwards, from chat, and from the matches list. A block is server-side and mutual: the pair can never be paired again and any live call between them ends immediately.

5. LOCATION

This build adds approximate-location ranking. If a user grants location access — only ever from the "use my current location" control inside the city picker, which they open deliberately — their position is taken at reduced accuracy and rounded on the device to a grid of about one kilometre before it leaves the phone. That rounded value is stored in a private document only their own account can read, and our security rules reject anything finer.

It affects the ORDER of people the user is already compatible with. It is never a filter: nobody is excluded for being far away, no distance is ever displayed, and a user who declines location sees the same people ordered by recent activity instead, with every feature working.

DEMO ACCOUNTS (Firebase test numbers, no real SMS is sent):
- Account A: +1 650 555 1234, code 123456
- Account B: +1 650 555 5678, code 222222

Please sign in on two devices or simulators. Tick the consent box on the welcome screen, enter the number, then enter the code on the next screen.

Thank you again for your time.
```

### UI claims re-verified today

| Claim in the reply | Source at HEAD |
|---|---|
| Button reads **"Nearby"** with a video-camera icon | `DiscoverHeroCard.swift:58-63` — `PrimaryButton(title: "Nearby", icon: "video.fill")` |
| Hero shows "Name, age" + city/online line | `DiscoverHeroCard.swift:41,49` |
| "Wants to Talk to You" bubble when waiting | `DiscoverHeroCard.swift:26-29` — renders as two lines |
| Location + intention bar at top of Discover | `DiscoverView.swift:15-22`, `DiscoverLocationBar.swift` |
| "Video Match" / "Speed Talk" are undirected | `DiscoverView.swift:130,141` — `start(mode:)` with no peer |
| Banner shows photo, first name, video/voice, Answer/Decline — **no age, no city** | `IncomingCallBanner.swift:25,29,38` |
| Banner ~7 s client, 10 s server | `CallModels.swift:50`, `shared.ts:36` |
| Ring fan-out cap of 8 | `shared.ts:39` `RING_FANOUT_LIMIT` |
| 180-second server cap | `shared.ts:17` `SPEED_CALL_SECONDS` |
| Report + block on all four surfaces | `ActiveCallView`, `CallDecisionViews`, `ChatDetailView`, `MatchesView` |
| Profile → Delete account | `ProfileView.swift:58` |

### Never claim these — unchanged

- **No photo or ID verification.** `isVerified` renders but is never granted
  server-side.
- **No automated content filtering.** Guideline 1.2 exposure is unchanged.
- **No moderation SLA in hours.**
- **No distance filter, radius setting, or displayed distance.** Say
  *approximate* and say *ordering*.

---

## 7. Demo video — final script

Two devices or simulators, screen-recorded and cut together. Target 60–90 s.
On-screen captions; narration optional. **Attach to the reviewSubmission or
host it and put the link in the review notes.**

### Before you record

- [ ] Re-run `node scripts/demo-accounts.mjs` from `backend/functions` — all
      three pairs must read **CAN PAIR**.
- [ ] Open Discover on A and confirm **B is actually on screen** before rolling.
- [ ] Register the simulator's App Check debug token
      (`tools/register-appcheck-debug-token.sh`), or every callable fails
      `unauthenticated`.
- [ ] **Do not tap "Pass" at any point.** A pass writes a permanent tombstone
      and re-breaks the demo accounts for the reviewer.
- [ ] Optional, for the location beat: set both simulators to nearby
      coordinates (Features → Location → Custom) and grant location on both.

| # | Device | What to show | Caption |
|---|---|---|---|
| 1 | A | Phone-number sign-in: tick consent, enter number, enter SMS code | "Every account is phone-verified. No anonymous or social login." |
| 2 | A | Discover, holding on the card ~3 s: photo, "Name, age", city, online state, "Wants to Talk to You" bubble | "This is everything you see before a call." |
| 3 | A | Tap the city in the top bar, show the picker and its location control, dismiss | "Location is approximate — a city, plus a private ~1 km area used only to rank closer people higher." |
| 4 | A | Tap the **"Nearby"** button under the photo | "A live video call request goes to that specific person." |
| 5 | A | The "Finding someone…" state | — |
| 6 | B | The incoming-call banner with **Answer** and **Decline** | "The other person can answer or decline." |
| 7 | B | Tap **Decline**; cut to A still waiting | "Declining is silent — the caller is never told who declined." |
| 8 | A | Start the request again | — |
| 9 | B | Tap **Answer** | — |
| 10 | Both | The call connecting: peer name/age/city overlay and the countdown | "Calls are capped at 180 seconds by the server and are never recorded." |
| 11 | Either | Open the in-call report/block control | "Either person can report or block during the call." |
| 12 | Both | End the call; the private like/pass decision screen | "Each person decides privately." |
| 13 | Both | **Both tap Like**; the match and the new conversation | "Chat opens only when both choose like. This is the only way a message can be sent in Baybe." |

**On proximity:** do not stage anything implying a distance readout — none
exists. If you want it on camera, seed a third compatible account at a far
coordinate and show the near one ordered first. Otherwise let the reply explain
it in words.

**Use the script:** `scripts/record-app-review-demo.sh --device --confirm-build 4`
runs this preflight for you, refuses a DEBUG build, and prints the shot list.
Full documentation in `DEMO_VIDEO_RECORDING.md`; capture mechanics for the
screenshot harness remain in `DEMO_VIDEO_CAPTURE.md`.

⚠️ **The video must come from a physical device.** Release builds attest with
App Attest, which does not exist on the simulator — a Release build on a
simulator fails App Check and never loads Discover. Simulator capture is
therefore always a DEBUG build, and DEBUG renders backend diagnostics into the
Discover error card.

---

## 8. App Privacy labels — exact console checklist

**App Store Connect → your app → App Privacy → Data Types → Edit.** There is no
API for this; it must be done in the console, and **the top-of-page Publish
button must be clicked** — entering answers alone does not take effect. This is
the step that silently blocked the first submission.

### Add — Location → Coarse Location

| Field | Set to |
|---|---|
| Collected? | **Yes** |
| Used for tracking? | **No** |
| Linked to the user's identity? | **Yes** (stored under the account uid) |
| Purposes | **App Functionality** and **Product Personalization** |
| Third-party advertising | **No** |
| Developer's advertising or marketing | **No** |
| Analytics | **No** |

**Do NOT declare Precise Location.** The app never collects it — the fix is
taken at `kCLLocationAccuracyReduced` and rounded to two decimal places before
it leaves the device, which is squarely inside Apple's definition of coarse.
Over-declaring invites a question with no good answer.

### Keep exactly as already recorded

| Data type | Linked | Tracking | Purpose |
|---|---|---|---|
| Contact Info → Name | Yes | No | App Functionality |
| Contact Info → Phone Number | Yes | No | App Functionality |
| User Content → Photos or Videos | Yes | No | App Functionality |
| User Content → Other User Content | Yes | No | App Functionality |
| Identifiers → User ID | Yes | No | App Functionality |
| Sensitive Info | Yes | No | App Functionality |
| Other Data Types (date of birth) | Yes | No | App Functionality |

**No email address. No tracking on anything.**

### Verify after publishing

- [ ] The App Privacy section shows **Coarse Location** on the public-facing
      summary.
- [ ] `Moomo/PrivacyInfo.xcprivacy` declares
      `NSPrivacyCollectedDataTypeCoarseLocation` — ✅ already true.
- [ ] `https://baybe-dating.web.app/privacy` carries the approximate-location
      paragraph — ✅ verified live today, matches the repo.

⚠️ A mis-declared location label is its own rejection under 5.1.1, independent
of everything else here.

---

## 9. Also worth fixing while you are in there

**The store description under-describes location.** It currently reads:

> • City-level location only. Baybe never uses your precise location.

The second sentence is true. The first is now slightly narrower than what the
app does — it stores a ~1 km cell, not just a city — and it will sit next to a
Coarse Location label. Suggested replacement, which stays honest and still
reassures:

> • Approximate location only — never your precise location, and never shown
>   to anyone else.

This is a nicety, not a gate.

---

## 10. What has to happen before this can become a GO

In order. Steps 1–3 are the ones that do not exist yet.

1. **Commit the proximity work.** It is entirely uncommitted on
   `fix/appcheck-app-attest-team-id`. Nothing on `main` records what would ship.
2. **Bump `CURRENT_PROJECT_VERSION` to 4**, archive, export, upload:
   - `xcodebuild archive -authenticationKeyPath/-KeyID/-KeyIssuerID`
   - `-exportArchive` with **`manageAppVersionAndBuildNumber=false`** — with it
     true the build number gets re-picked
   - `altool --upload-app --apiKey/--apiIssuer`
   - Processing to VALID took under 5 minutes for build 3.
3. **Record the demo video** (§7) and attach it or host it link-ready.
4. **Publish the Coarse Location privacy label** (§8) — console, and click
   **Publish**.
5. **Replace the review notes** (§5) — this is what strikes the 24-hour SLA.
6. **Paste the Resolution Center reply** (§6).
7. **Attach build 4 to version 1.0.** If the version is still in a submitted
   state, cancel first — the attach 409s until the version settles into
   `DEVELOPER_REJECTED`, then succeeds on retry.
8. **Re-run the demo-account check in the final minutes** (§3) and confirm all
   three pairs still read CAN PAIR.
9. Submit.

### Still open, and not fixed by any of the above

- **Guideline 4.3(b).** Untouched and concept-level. Apple's text
  (*"there are already enough of these apps"*) pre-rejects a differentiation
  argument, and *"reconsider the app concept and submit a new app"* points at a
  different app record. The only instrument is an App Review Board appeal — the
  structural argument is drafted in `ASC_REPLY_2026-08-06.md` Part 2. It may
  still fail. **Resubmitting without addressing 4.3(b) risks the same
  rejection even if 2.1 is now perfect.**
- **Guideline 1.2 — no automated content filtering.** Unchanged. `moderation.ts`
  is an admin-only triage callable; there is no Storage trigger and no image or
  text scanning.
- **Firebase Phone Auth SMS body and the reCAPTCHA fallback page still carry
  `moomo-c7a37.firebaseapp.com`.** Needs a custom Auth domain in the Firebase
  console; cannot be fixed from the repo.
- **Social-media age-rating questions** are due in ASC → App Information by
  **2026-09-07**.

---

## 11. Verification run, 2026-08-12

| Suite | Result |
|---|---|
| `backend/functions && npm test` | **178 / 178 pass**, 0 fail |
| `backend/rules-tests && npm test` | **166 / 166 pass**, 0 fail |
| `xcodebuild test -only-testing:MoomoTests` | **258 / 258 pass**, 0 fail |
| `xcodebuild build -scheme Moomo` | **BUILD SUCCEEDED** (8.9 s) |
| `demo-accounts.mjs` (production, read-only) | **3 / 3 pairs CAN PAIR** |
| Deployed rules vs local | **identical** |
| Deployed functions | **17 / 17 ACTIVE** |
| Live legal pages vs local | **identical** |

**Not run:** `MoomoUITests` / `MoomoLiveUITests`. They drive a simulator against
the live backend and need a registered App Check debug token per install.

---

*Internal. Do not paste this file to Apple — only the fenced blocks in §5 and
§6 are reviewer-facing.*
