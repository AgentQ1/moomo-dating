# Rejection 2026-08-24 — analysis and remediation plan

Submission `4b5c3242-40e3-454c-a540-2eb8bf9d7771`, version 1.0 (4), reviewed
2026-08-24 on iPad Air 11-inch (M3) + iPhone 17 Pro Max.

Two guidelines cited:

| Guideline | Status | Fixable? |
|---|---|---|
| **1.1 Safety — Objectionable Content** (screenshots + keywords) | **NEW** | **Yes, entirely in metadata. Zero UI change.** |
| **4.3(b) Design — Spam** (saturated category) | **REPEAT** (2nd time), now with escalation language | Not by metadata alone |

---

## 0. Headline finding

**These are not two independent problems. 1.1 is very likely a cause of 4.3(b).**

The listing's signal profile — a dating app named **Baybe**, whose hero call
screenshot is a close-up of a woman in a low-cut top, whose profile screenshot
is a woman in a cut-out swimsuit dress, with a generic dating keyword cluster —
is the exact fingerprint App Review uses to triage the low-quality dating
cluster that 4.3(b) exists to cull. A reviewer forms the "one more of these"
judgement from the screenshot strip before reading a single feature.

The 2026-08-11 audit concluded that screenshot/keyword rework "addresses the
soft variant of 4.3(b) only." **That conclusion should be revised.** At the time
it was written, nobody knew Apple had an objectionable-content read on the
marketing. Now they have said so explicitly. Cleaning the listing is no longer
cosmetic ASO work — it removes a documented, Apple-stated defect that was
present during both 4.3(b) rejections.

That does not make metadata a guaranteed 4.3 fix. It does mean the previous
"metadata cannot help" verdict was reached without this information.

---

## 1. Guideline 1.1 — exact defects

Apple cited "screenshots (woman in revealing clothing) **and keywords**" and
attached two files.

### 1.1a — The two attached screenshots

| Attachment | Screenshot | Verdict |
|---|---|---|
| `26cd08d2…png` | **02-call** — "A real date in three minutes" | **CONFIRMED DEFECT.** Full-bleed close-up of "Mila, 24" in a low-cut black top with visible cleavage, shot as a downward selfie. This is the cited image. |
| `d9d847dc…png` | **07-welcome** — "Every profile is phone-verified" | No revealing content found. The three avatars are head-and-shoulders shots (zoomed and checked). Most likely attached as the second-worst offender or as general listing context. |

### 1.1b — A second offender Apple did *not* cite

**`09-profile.png` shows "Solan, 23" in a white cut-out dress / swimsuit,
bare midriff, spaghetti straps, standing by water.** Full-body, not a portrait.
By the standard Apple applied to 02-call this is at least as exposed — arguably
more so, because it is a swimwear-style full body shot rather than a neckline.

**Implication: the problem is not one bad screenshot. It is the photo pool.**
The marketing images were built from a set of photos that read as "attractive
strangers" rather than "people having a conversation." Swapping only the cited
image leaves the same signal in the strip and invites the same finding again.

### 1.1c — The photos are also *inside the app*

The same photos are the demo accounts' profile photos in production
(Solan / Lily / Lulu — `+1650555 1234 / 5678 / 9876`). A reviewer signs in with
those accounts and sees them. Fixing the screenshots while leaving the in-app
photos means the next reviewer meets the same content one tap in, and a 1.1
finding on in-app content is worse than one on metadata.

### 1.1d — Keywords: UNVERIFIED, must be read before anything is written

Apple named `keywords` as a field carrying the violation. **The live keyword
string could not be read from this machine** — the ASC API key
(`~/FitCheckAI/private_keys/AuthKey_3TH447PNUA.p8`, key `3TH447PNUA`, issuer
`3678b63e-…`) is behind a permission block.

Last recorded value (2026-08-06, 84 chars):

```
dating,video,date,call,chat,match,singles,meet,speed,voice,love,relationship,romance
```

A rewrite was *proposed* on 2026-08-06 but there is no record it was *applied*.
Nothing in either string is obviously objectionable, which means one of:

1. the string was changed since, to something that is; or
2. Apple is reading `singles` / `love` / `romance` / `date` as the
   hookup-adjacent cluster in combination with the imagery; or
3. the field list in the letter is partly boilerplate.

**Do not rewrite keywords until the live value is read.** Guessing risks
"fixing" a field that was already fine while missing the actual term.

### 1.1e — Open question: the app name

**"Baybe" is a phonetic spelling of "babe."** In combination with a cleavage
screenshot and a dating keyword set, that is a plausible contributor to
"marketing includes terms … that reference objectionable content," and it is
independently a strong signal for the 4.3(b) cluster.

This is a **hypothesis, not a finding** — Apple did not name the app name. But
it is worth weighing, because the name was chosen in the 2026-08-11 rebrand to
escape a *different* collision (Momo), and this second-order effect was never
considered. The app name is editable in ASC while the version is in
`PREPARE_FOR_SUBMISSION`; matching the in-app wordmark
(`MoomoLogo.swift:39`) would be a small asset change, not a redesign.

---

## 2. Guideline 4.3(b) — what changed since last time

The text is nearly identical to 2026-08-05, with one addition:

> Resubmitting this app without making the appropriate changes, or submitting a
> new app with similar marketing and concept, will result in the same or
> additional App Review Guideline violations.

That sentence is the material change. It closes the "quietly resubmit and hope
for a different reviewer" path, and it explicitly extends to a **new app
record** — so the "submit as a fresh app" workaround is pre-refused.

Everything the 2026-08-11 audit established still holds:

- The differentiation argument is pre-rejected in the letter's own text
  ("may include features … **However, there are already enough**").
- "Reconsider the app concept and submit a new app" points at a rebuild.
- The web-app suggestion is the boilerplate for "we do not want this here."

What is genuinely different this time: **Apple has now told us one concrete,
fixable thing that was wrong with the listing during both rejections.** That is
the first actionable foothold on 4.3(b) this project has had.

---

## 3. The verified differentiators (unchanged, all code-backed)

Re-confirmed at HEAD. This is the only material safe to put in front of Apple:

| Claim | Evidence |
|---|---|
| No swipe deck exists anywhere | `DiscoverView.swift` — location bar + one hero card + two mode tiles. No card stack, no swipe gesture |
| Meeting *is* a live 3-minute call; no text-first path | `shared.ts:17` `SPEED_CALL_SECONDS = 180`, server-enforced; media token dies with the call clock (`media.ts:56,69`) |
| No message can be sent to anyone, ever, before a completed call + mutual like | Conversations minted only inside the mutual-like transaction (`decisions.ts:50-115`) |
| Pairing is mutual-preference, never random | `compatibility.ts:76-80` — both directions must accept |
| A pass is private and permanent | `shared.ts:216-226` tombstone, enforced in matchmaking, ring and discovery |
| Phone-verified only; no anonymous or social login | Single `phone` AuthProvider |
| 18+ enforced server-side | `firestore.rules:58-63` rejects an under-18 DOB |

Still **not** claimable: photo/ID verification (`isVerified` is never granted
server-side), automated content filtering (none exists — Guideline 1.2 remains
open), any moderation SLA in hours.

---

## 4. Plan

Ordered. Phases 1–2 are required regardless of the 4.3 strategy chosen in
Phase 3, and involve **no UI change at all**.

### Phase 0 — Recon (blocking, ~30 min)

Nothing precise can be written until the live listing is read.

- [ ] Read live **keywords**, **subtitle**, **description**, **promotional
      text**, and **app name** for en-US.
- [ ] Download all **10 live 6.7" screenshots** (set `856d0de5-…`). Two of them
      (`01-discover`, `10-boost`) were replaced on 2026-08-13 and have never
      been audited for 1.1 — the local copies are stale.
- [ ] Confirm the version state. Attaching a build previously flipped
      `REJECTED` → `PREPARE_FOR_SUBMISSION`; screenshots and metadata are only
      editable outside `WAITING_FOR_REVIEW`.

**Requires either** a Bash permission rule allowing the ASC key read, **or**
the values pasted from the console.

### Phase 1 — Eliminate 1.1 at the source (metadata + production data; no UI change)

The fix is the **photo standard**, applied everywhere at once, not a swap of the
one cited image.

**Photo standard** — every photo that appears in a screenshot or on a demo
account must satisfy all of:

- neckline at or above the collarbone; shoulders covered
- head-and-shoulders or chest-up framing — no full-body, no swimwear
- no bed, bedroom, bathroom, or mirror-selfie backgrounds
- neutral expression or a natural smile; no pouting or posed selfie angles
- unambiguously adult-looking

- [ ] Re-shoot / re-source photos to that standard.
- [ ] Rebuild **02-call** (the cited image) — this is mandatory.
- [ ] Rebuild **09-profile** (the uncited swimsuit shot) — treat as mandatory.
- [ ] Re-audit **01-discover**, **03-matches**, **06-calls**, and the two
      unaudited live images against the standard; rebuild any that fail.
- [ ] Replace the **production demo-account photos** for all three reviewer
      accounts so the in-app experience matches the listing.
- [ ] Re-read the whole strip end to end as a reviewer would, before upload.

**Framing pipeline note:** there is no framing pipeline in the repo. The framed
marketing images were produced ad hoc. The raw capture harness exists
(`app/MoomoLiveUITests/ScreenshotCaptureUITests.swift`); the composite step must
be rebuilt or the existing frames re-composited with new photos. Budget for
this — it is the largest single piece of work in Phase 1.

**Upload constraint:** the set caps at 10, so **delete before upload**, and the
whole replacement must happen while the version is out of `WAITING_FOR_REVIEW`.

### Phase 2 — Rewrite the listing away from the culled cluster (metadata only)

- [ ] **Keywords** — after Phase 0. Remove anything appearance-, hookup- or
      adult-adjacent, and remove the saturation cluster
      (`singles`, `love`, `romance`, `relationship`). Keep the mechanic:
      `video call`, `voice call`, `3 minute`, `talk first`, `live conversation`.
- [ ] **Description first two lines** — a 4.3 triage pass reads little else.
      Lead with the mechanic, not the category: you cannot message anyone until
      you have talked to them live for three minutes.
- [ ] **Screenshot captions** — carry the differentiator in order. Two specific
      edits:
      - Drop **"Chemistry beats swiping"** (03-matches). Never name a
        competitor's mechanic in your own listing; it invites exactly the
        comparison 4.3(b) is about.
      - Reconsider **"A real date in three minutes"** (02-call). "Date" is the
        category word; "conversation" is the product.
- [ ] **Subtitle / promotional text** — same sweep.
- [ ] Decide the **app-name question** (§1.1e).

### Phase 3 — 4.3(b) strategy — DECISION REQUIRED

Three paths. They are not mutually exclusive; the ordering below matters.

| Path | Cost | UI change | Honest odds |
|---|---|---|---|
| **A. Appeal first, no resubmission** — fix 1.1, then take the structural argument to the App Review Board without spending a submission | Low. ~1–2 weeks elapsed | **None** | Low–moderate, and it is the only lever aimed at the actual rejection. An appeal cannot itself be a rejection |
| **B. Fix + reposition, resubmit** — Phases 1–2 only, then resubmit | Low | **None** | Materially better than the 2026-08-11 estimate now that 1.1 is known and fixed, but still a coin-flip at best against an escalated repeat |
| **C. Fix + one structural change, then resubmit** | Medium — one component + a build | **Small, one screen** | Best odds, because it gives the reviewer something visible in five seconds that the category does not already have |

**Recommended sequence: A, then C if A fails.** Rationale:

- Phase 1 is mandatory under every path, so it is never wasted.
- An appeal spends no submission and cannot produce a third rejection.
- The appeal's outcome tells you Apple's real position, which is the only
  honest input to deciding whether the product change in C is worth building.
- Going straight to B risks a third rejection on a record that has now been
  warned, for very little upside over A.

**If C is chosen, the recommended structural change is photo-blind-until-call:**
Discover shows name, age and city but not the photo; the photo reveals when the
call connects.

- Code cost is small and contained: the avatar in `HeroCard`
  (`DiscoverHeroCard.swift:119,145`) plus a reveal at call start. No backend
  change, no new data, no new permission.
- It is a one-sentence pitch that the saturated cluster does not have: *you talk
  before you look.*
- It makes a 1.1 finding structurally impossible in the pre-call marketing,
  because there is no photo to be revealing.
- It is consistent with everything already true of the product (no deck, no
  browsing, no text before a call) — it is the honest end state of that design,
  not a bolt-on.
- Caveat: prior art exists (Blindlee), and it is a real product bet. It should
  be the user's call, not an assumption.

Alternatives if that bet is unwanted: hard-scope the feed to a real proximity
radius (proximity is already deployed as a soft boost — a constant and a rules
change), or a nightly event window. Both are weaker 4.3 arguments.

### Phase 4 — Resubmission mechanics (only after Phase 3 resolves)

Carried forward from the build-4 submission; all still apply.

- [ ] **Cancel any bound submission first.** A version bound to an old
      submission 409s with `STATE_ERROR.ITEM_PART_OF_ANOTHER_SUBMISSION`;
      `PATCH /v1/reviewSubmissions/{old} {"canceled":true}` clears it in ~15 s.
- [ ] **Re-run `backend/functions/scripts/demo-accounts.mjs`** in the final
      minutes. One test call ending in a pass recreates a permanent tombstone
      and silently reinstates the 2.1 rejection.
- [ ] Review notes cap at **4000 chars**; no moderation SLA in writing.
- [ ] **App Privacy — Coarse Location must be declared and Published.** Console
      only, no API. Still open. The app does now use CoreLocation.
- [ ] Resolution Center has **no API** — any reply is pasted in the console.
- [ ] If a new build is cut (path C), bump `CURRENT_PROJECT_VERSION` and
      **commit the working tree first** — the proximity work is still
      uncommitted on `fix/appcheck-app-attest-team-id`.

---

## 5. What is verified vs. assumed in this document

**Verified this session:** the two attached rejection images and their content;
the cleavage in 02-call; the cut-out swimsuit dress in 09-profile; the avatars
in 07-welcome are innocuous; app-facing copy contains no objectionable terms
(swept `app/Moomo/**.swift`); the differentiator table.

**Not verified — needs Phase 0:** the live keyword string, subtitle,
description, promotional text; the content of the two screenshots replaced on
2026-08-13; the current version state.

**Hypothesis, explicitly flagged:** that the name "Baybe" contributes to the
1.1 and 4.3 reads. Apple did not say this.

**Internal only — never paste to Apple:** this file,
`REJECTION_2026-08-05_ROOT_CAUSE.md`, `RESUBMISSION_CHECKLIST_2026-08-06.md`,
`BRAND_AND_43_AUDIT_2026-08-11.md`. They name competitors and state odds.
