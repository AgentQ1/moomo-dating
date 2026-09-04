# Remediation deliverables — rejection 2026-08-24

Companion to `REJECTION_2026-08-24_PLAN.md` (analysis). This file is the
paste-ready output. **Nothing here has been submitted to Apple.**

**Scope: metadata only. No app code is changed.** The `"Nearby"` CTA was
briefly changed to `"Start Call"` and then **reverted on your instruction** —
see §1. Nothing in `app/` differs from where it started, so this remediation
ships against the **existing build 4** and no new build is required.

---

## 1. Files changed

**None. No app code was changed.**

The one code lever considered was the Discover hero CTA — `"Nearby"` →
`"Start Call"` (`DiscoverHeroCard.swift:58-68`), on the reasoning that the
button starting the product's only way of meeting someone should name the
action rather than describe proximity. **You decided to keep `"Nearby"`, and it
has been reverted.** `grep -rn "Start Call" app/Moomo/` returns nothing;
`build-for-testing` re-verified green after the revert (§7).

Reverted with it: the three comments in `Palette.swift:40`,
`CallModels.swift:6` and `DiscoveryService.swift:31` that name the button
label. All four files are byte-identical to their pre-session state.

### Two consequences of keeping "Nearby"

1. **No build 5 is required.** This remediation is metadata-only and ships
   against build 4, which is already uploaded, VALID and attached. That removes
   the archive → export → upload → attach → processing cycle, and it removes
   the risk of an unreproducible archive (the proximity and ring work is still
   uncommitted on `fix/appcheck-app-attest-team-id`).
2. **Screenshot 01 stays accurate.** It shows `"Nearby"`, which is what build 4
   renders. Had the CTA changed without a new build, that screenshot would have
   been a 2.3.3 accuracy violation. It still needs a **1.1 audit** — it was
   replaced on 2026-08-13 and has never been checked — but it does not need
   recapturing.

### One correction to carry forward

`BRAND_AND_43_AUDIT_2026-08-11.md` §7 risk #3 records `"Nearby"` as *"an
unsupported proximity claim — no proximity feature exists."* **That is no
longer true.** Real proximity ranking was deployed on 2026-08-12: a coarse
`0.01°` grid in `users/{uid}/private/location`, read server-side by
`discovery.ts` and `ring.ts`. `"Nearby"` is now truthful.

It is a **soft boost with a neutral fallback**, not a hard radius filter —
closer candidates sort earlier, and a user with no stored location ranks
neutral rather than being excluded. So the word is accurate as a description of
how the feed is ordered. Do not re-open this as a truthfulness problem; it was
one, and the proximity work fixed it.

## 2. Keywords

**Live (rejected):**
```
dating,video,date,call,chat,match,singles,meet,speed,voice,love,relationship,romance
```

**Recommended replacement — 96 chars, zero banned terms:**
```
video,voice,call,chat,talk,speed,minute,live,intro,first,verified,phone,meet,people,conversation
```

Single unique tokens, because the App Store search index auto-combines keyword
terms into phrases. This set generates `video call`, `voice call`, `speed call`,
`talk first`, `call first`, `live intro`, `phone verified`, `meet people`,
`3 minute conversation` and so on, without spending characters repeating
`call` three times.

**Alternative — your phrasing, 94 chars, also compliant:**
```
video call,voice call,3 minute chat,talk first,call first,no swiping,phone verified,live intro
```
Costs ~20 characters to duplicate `call` (×3) and `first` (×2). Functionally
equivalent on compliance; weaker on index coverage.

**Removed and why:** `dating`, `date`, `singles`, `love`, `romance`,
`relationship`, `match`. Apple named `keywords` as carrying the 1.1 violation,
and this cluster is also what 4.3(b) keyword-clustering triage looks for.

**`no swiping` / `swipe` deliberately omitted from the recommendation.** The
field is reviewer-visible; a keyword targeting swipe-app searches contradicts
the exact positioning message the rest of the listing is making. Say it in the
description, where it is an argument, not a search bid.

**ASO cost, stated plainly:** dropping `dating` gives up the category's highest
volume term. Discovery will lean on the Dating category browse, the app name,
and the subtitle. That is the trade Apple's letter forces.

---

## 3. Promotional text (170 char limit — 137 used)

```
Meet through one live 3-minute call. No swipe deck, no messaging strangers — you talk first, and chat opens only if you both choose Like.
```

## 4. Description opening

First two lines are all a 4.3 triage pass reads. Every clause is code-backed.

```
Baybe is call-first. You meet one person at a time through a single live
3-minute voice or video conversation — and chat opens only if you both choose
Like once the call has ended.

There is no swipe deck and no profile feed to browse. There is no way to send a
message to anyone you have not already talked to live. Calls end automatically
at three minutes; the app does not let either side extend one.

Every account is verified by phone number — there are no anonymous, guest or
social sign-ins. Baybe is 18+ only. You can block or report anyone at any time,
and a block is immediate, silent and permanent.
```

**Claim audit** — each sentence against the code:

| Sentence | Evidence |
|---|---|
| single live 3-minute conversation | `backend/functions/src/shared.ts` `SPEED_CALL_SECONDS = 180`, server-enforced |
| chat opens only after mutual Like | `decisions.ts:50-115` — conversations minted only inside the mutual-like transaction |
| no swipe deck, no feed to browse | `DiscoverView.swift` — location bar, one hero card, two mode tiles. No card stack, no swipe gesture |
| no message before a live call | same transaction; `createConversation` is internal-only |
| app cannot extend a call | media token dies with the call clock (`media.ts:56,69`) |
| verified by phone number | single `phone` AuthProvider. **Worded as phone verification only** — never identity or photo |
| 18+ | `firestore.rules:58-63` rejects an under-18 DOB server-side |
| block is immediate, silent, permanent | `safety.ts` `blockUser`; block checks inside the accept transaction; silent-block invariant `ring.ts:24-29` |

**Not claimed anywhere:** photo/ID verification (`isVerified` is never granted
server-side), automated content filtering (none exists), any moderation SLA.

---

## 5. Screenshot replacement list

### The finding that drives this

**It is not one bad screenshot — it is the photo pool.** The demo accounts'
photos read as "attractive strangers," and they are reused across the set:

| Screenshot | Photo content | Verdict |
|---|---|---|
| **02-call** | "Mila, 24", low-cut black top, visible cleavage, full-bleed downward selfie | **REPLACE — this is the image Apple cited** |
| **09-profile** | "Solan, 23", white cut-out dress / swimsuit, bare midriff, spaghetti straps, full body | **REPLACE — uncited, but at least as exposed. Fails the same test** |
| **03-matches** | Lily's avatar — reclining in a chair, white outfit | **REPLACE photo + caption** |
| **06-calls** | Lily's reclining photo ×3 + Lulu in a black spaghetti-strap top | **REPLACE photos** |
| **07-welcome** | Three head-and-shoulders avatars — zoomed and checked, nothing revealing | **KEEP.** Apple attached it, but no violation is present |
| 04-conversation, 05-chat, 08-safety | Text-only screens | No 1.1 exposure |
| **01-discover, 10-decision** | Replaced 2026-08-13; **never audited for 1.1** | **MUST AUDIT** — download from ASC first |

Replacing only the cited image leaves the same signal in the strip.

### Photo standard — apply to marketing **and** the production demo accounts

- neckline at or above the collarbone; shoulders covered
- head-and-shoulders or chest-up framing — no full body, no swimwear
- no bed, bedroom, bathroom or mirror-selfie backgrounds
- neutral expression or natural smile; no pouting or posed selfie angles
- unambiguously adult-looking

**The demo accounts must be fixed too.** Solan / Lily / Lulu
(`+1650555 1234 / 5678 / 9876`) carry these same photos in production. A
reviewer signs in and sees them one tap past the listing. A 1.1 finding on
in-app content is worse than one on metadata.

### Proposed final set of 10, ordered to tell the call-first story

| # | Screen | Caption | Action |
|---|---|---|---|
| 1 | Discover — named person + **Nearby** | Talk first. One person at a time. | **AUDIT live image for 1.1** — no recapture needed |
| 2 | Incoming call banner — Answer / Decline | Someone wants to talk right now | **NEW — needs harness work** |
| 3 | Active call + countdown | Three minutes, then it ends by itself | **REBUILD** — modest photo |
| 4 | Decision — Like / Pass after the call | You decide after you've talked, not before | **AUDIT live 10-decision** |
| 5 | Chat thread | Chat opens only when you both say yes | Keep (04), re-caption |
| 6 | Calls history | Every call, in one place | **REBUILD** — modest photos |
| 7 | Welcome | Every profile is phone-verified | **KEEP as-is** |
| 8 | Safety | Block or report any time | **KEEP as-is** |
| 9 | Profile | Your profile, your control | **REBUILD** — modest photo |
| 10 | Matches | Matches come from conversations | **REBUILD** photo + caption |

**Two caption edits regardless of photos:**

- **Drop "Chemistry beats swiping"** (03-matches). Never name a competitor's
  mechanic in your own listing — it invites exactly the comparison 4.3(b) is
  about.
- **Change "A real date in three minutes"** (02-call) → *"Three minutes, live,
  then it ends by itself."* `date` is the category word; the conversation is
  the product.

**Dropped from the set:** the near-empty chat list (05). It is generic dating
furniture and reads as an unfinished app.

### Known blockers on the screenshot work

- **No framing pipeline exists in the repo.** The framed images (coloured
  background, white headline, device bezel) were produced ad hoc in an earlier
  session. Only the raw capture harness exists
  (`app/MoomoLiveUITests/ScreenshotCaptureUITests.swift`, driven by
  `TEST_RUNNER_SCREENSHOT_DIR`). The composite step must be rebuilt or the
  existing frames re-composited. **This is the largest piece of work here.**
- **Screenshot 2 (incoming call banner) has no capture path today.** The
  harness covers welcome, location picker, search, conversation, safety, live
  call and peer-acting; it does not drive the ring-invite banner.
- Live set is 1320×2868 (6.9"). The set **caps at 10 — delete before upload.**
- Screenshots are only editable while the version is **out of
  `WAITING_FOR_REVIEW`**.

---

## 6. Paste-ready Apple reply

Resolution Center. Respectful, factual, no SLA claim, no ID-verification claim.
Trim to fit if the field rejects it.

```
Thank you for the detailed feedback — both points were clear and we have acted
on them.

Guideline 1.1 — Objectionable content in metadata

You identified a screenshot showing a woman in revealing clothing. We have
replaced it. We also re-reviewed the entire screenshot set rather than only the
image you flagged, and replaced every photo that did not meet a conservative
standard: head-and-shoulders framing, necklines at or above the collarbone, no
swimwear, no suggestive poses. We applied the same standard to the demo
accounts inside the app, so the experience a reviewer sees matches the listing.

We have also rewritten the keyword field. The previous keywords led with
generic romantic terms; the new set describes only the mechanic — video and
voice calling, a three-minute conversation, phone verification.

Guideline 4.3(b) — Design

We understand the concern about a saturated category, and we would like to
describe what the app actually does, because we do not think the previous
listing communicated it.

Baybe has no swipe deck and no profile feed to browse. The required first
interaction between two people is a single live voice or video conversation
that our server ends automatically at three minutes — neither side can extend
it. There is no way to send a message to another user under any circumstance
until two people have completed that live call and each then independently
chose Like. A user cannot accumulate an inbox of strangers, cannot open a chat
with someone they have not spoken to, and cannot initiate contact in text.
Pairing requires both people's stated preferences to accept each other; it is
never random. Every account is verified by phone number, and there is no
anonymous, guest or social sign-in.

We have rewritten the screenshots, keywords and description so that this is
what the listing leads with, rather than the generic dating framing we
previously used.

On safety: users can block or report anyone at any time. A block is immediate,
silent and permanent, and it takes effect inside the call-accept transaction so
it cannot be raced. We want to be precise and not overstate this — we do not
claim identity or photo verification, and we are not claiming a review time we
cannot guarantee.

We would be grateful if you would take another look at the updated metadata and
at the call-first flow. If there is a specific part of the experience you would
like us to demonstrate, please tell us and we will provide it.

Thank you for your time.
```

---

## 7. Verification results — commands and output

Run 2026-08-24, all three green.

| Command | Result |
|---|---|
| `cd backend/functions && npm test` | **178 pass, 0 fail, 0 skipped** — 8.3 s, exit 0 |
| `cd backend/rules-tests && npm test` | **166 tests, 166 pass, 0 fail** — exit 0 |
| `xcodebuild build-for-testing -project app/Moomo.xcodeproj -scheme Moomo -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath app/build/DerivedDataAudit CODE_SIGNING_ALLOWED=NO` | **TEST BUILD SUCCEEDED** — 20.9 s, exit 0 |

**Warnings:** exactly one in the build log —
`appintentsmetadataprocessor … Metadata extraction skipped. No AppIntents.framework dependency found.`
Benign and pre-existing.

**On the `CallService.swift` NSLock warning you noted:** it did **not** appear
in this build. `CallService.swift` is not named anywhere in the log and the log
carries only the one warning above. The `NSLock` usage is still there
(`CallService.swift:93,96,166-216`) and unchanged by this work — the warning is
simply not surfacing in this configuration. Not investigated further; out of
scope and non-blocking, as you said.

**Re-verified after the `"Start Call"` revert:** `build-for-testing`
**SUCCEEDED** again, same single benign warning. The tree is back to its
pre-session state, so the functions and rules suites are unaffected by the
revert — their results above stand.

**Screenshots were not regenerated**, so the visual inspection step is not yet
runnable. The audit above was performed against the existing images.

---

## 8. Manual App Store Connect steps still required

None of this is done. Nothing has been submitted.

### Blocked on you — cannot be done from here

1. **Download the two unaudited live screenshots** (`01-discover`,
   `10-decision`, set `856d0de5-…`) so they can be checked for 1.1. The ASC API
   key read is blocked by a local permission rule — either add a Bash
   permission rule for `~/FitCheckAI/private_keys/`, or export the images from
   the console.
2. **Confirm the live subtitle and description** so the keyword set does not
   duplicate terms already indexed by the app name/subtitle.
3. **New photos.** The photo standard cannot be applied without source images
   that meet it. This is the gating input for every screenshot rebuild and for
   the demo accounts.

### Console-only (no API exists)

4. **App Privacy — Coarse Location must be declared and Published.** Still
   open from the last submission. The app does now use CoreLocation.
5. **Resolution Center reply** — `/v1/resolutionCenterMessages` and
   `/v1/resolutionCenterThreads` both 404. §6 must be pasted by hand.

### Submission mechanics, when you approve

6. **Cancel any bound submission first.** A version bound to an old submission
   409s with `STATE_ERROR.ITEM_PART_OF_ANOTHER_SUBMISSION`;
   `PATCH /v1/reviewSubmissions/{old} {"canceled":true}` clears it in ~15 s.
7. **Screenshots: delete before upload** (set caps at 10), and only while the
   version is out of `WAITING_FOR_REVIEW`.
8. **Re-run `backend/functions/scripts/demo-accounts.mjs` in the final
   minutes.** One test call ending in a pass recreates a permanent tombstone
   and silently reinstates the 2.1 rejection.
9. **Review notes cap at 4000 characters.** No moderation SLA in writing.
10. **No new build is needed.** Build 4 is uploaded, VALID and attached, and
    with `"Nearby"` kept there is no app-side change to ship. Should a build 5
    ever be cut for another reason: bump `CURRENT_PROJECT_VERSION` and **commit
    the working tree first** — the proximity and ring work is still uncommitted
    on `fix/appcheck-app-attest-team-id`, so an archive cut now would be
    unreproducible.

---

## 9. What this does and does not fix

**Fixes, with high confidence:** Guideline 1.1. It is a metadata and demo-data
problem with a concrete, verifiable standard, and Apple named the defect.

**Improves, without guaranteeing:** Guideline 4.3(b). The listing no longer
carries the signal profile — a name-plus-cleavage-plus-`singles,love,romance`
fingerprint — that App Review triages into the culled dating cluster. That is a
real improvement on a real defect Apple identified, and it was present during
*both* 4.3(b) rejections.

**Note what this now rests on entirely.** With `"Nearby"` kept, the whole
4.3(b) argument is carried by metadata: the screenshots, the keywords, the
description and the Resolution Center reply. There is no in-app change telling
a reviewer the app is call-first — they have to open it and start a call to
find out. That raises the weight on screenshots 1-4 doing the explaining, and
it is the strongest reason to prefer the appeal route in §9 of the plan over
spending a submission.

**Does not resolve:** the concept-level part of 4.3(b). The letter's own text
pre-rejects a feature list ("However, there are already enough of these apps"),
points at a new app record, and now adds that resubmitting without appropriate
changes will draw the same or additional violations. A metadata-and-copy
remediation is not what that sentence is asking for.

**Still open, unchanged:** Guideline 1.2 — no automated content filtering
exists anywhere (`moderation.ts` is an admin-only `resolveReport`).
