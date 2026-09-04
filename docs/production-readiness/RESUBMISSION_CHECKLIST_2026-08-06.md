# Resubmission checklist — Baybe 1.0, after the 2026-08-05 rejection

_Written 2026-08-06. **Current decision: NO-GO.** Nothing in this file may be
actioned into a resubmission until Chandan approves._

## Live ASC state (VERIFIED 2026-08-06 via ASC API)

| Item | Value |
|---|---|
| App | Baybe, 6793496424, `com.moomo.dating` |
| Version | 1.0, id `a9f46f0b-4b99-4e2f-8bd4-836b1e72b9a5` — **REJECTED** |
| Submission | `9942a9c1-3993-44dc-8e2e-7f48dcccdc5b` — **UNRESOLVED_ISSUES**, item REJECTED |
| Build attached | 3 (`15c0f67c-d92e-44fa-97e1-b01e25b6a6cf`) — VALID, not expired |
| Other builds | 1 and 2, both VALID, not expired |
| Age rating | 17+ store / `EIGHTEEN_PLUS` override — correct, no change needed |
| Categories | Lifestyle + Social Networking — no change needed |
| Legal URLs | privacy/terms/support all 200 — no change needed |
| Screenshots | 10 in `APP_IPHONE_67`; **editable now** (version is REJECTED, not in review) |

Screenshots and metadata are only locked while a submission is
`WAITING_FOR_REVIEW`. In `REJECTED` they are editable — no cancellation needed
this time.

---

## Gate 1 — BLOCKING: demo accounts must actually pair

- [ ] Read production `publicProfiles` for the three test accounts; record
      `gender`, `interestedIn`, `photoPath`, `age`, `city`, `lastActiveAt`.
- [ ] Delete `passes/{A}/passed/{B}` and `passes/{B}/passed/{A}` for the demo pair.
- [ ] Delete any `blocks/{A}/blocked/{B}` (either direction).
- [ ] Set `interestedIn`/`gender` so the pair is mutually compatible.
- [ ] Create a **fourth** account reserved for App Review only — never used in
      internal testing, so it can never accumulate a pass tombstone again.
- [ ] Re-test end to end on a **Release** build on two devices: sign in on both,
      send the call request, answer it, complete the call, both Like, chat opens.
- [ ] Add a repo script (`tools/reset-review-accounts.*`) so this is one command
      before every future submission, not tribal knowledge.

**Requires production Firestore access, which was blocked in this session.**

## Gate 2 — BLOCKING: demo video

- [ ] Record per `DEMO_VIDEO_CAPTURE.md`, beats 1–9. Beat 4 (the incoming call
      banner) is the shot Apple explicitly asked for.
- [ ] Host it and confirm the URL returns 200 signed-out.
- [ ] Paste the link into the Resolution Center reply.

## Gate 3 — BLOCKING: remove the unsupported moderation SLA

- [ ] Strike *"within 24 hours"* from the ASC review notes — or staff the queue
      and keep it. It is currently live in ASC and nothing backs it.

## Gate 4 — 4.3(b) evidence (the real risk; see Gate 7)

- [ ] Replace `01-discover.png` — must show a **named, aged, located** person
      with an explicit call-request CTA. (App-side fix already landed, below.)
- [ ] Add a screenshot of the **incoming call request banner** — the mechanic
      no other dating app in the category has.
- [ ] Drop `10-boost.png` and `03-matches.png` (near-empty screens that read as
      an unfinished app).
- [ ] Rewrite keywords. Current (84 chars):
      `dating,video,date,call,chat,match,singles,meet,speed,voice,love,relationship,romance`
      Proposed (92 chars):
      `video call,speed dating,voice call,3 minute date,talk first,video date,call first,no swiping`
- [ ] Move the differentiator into the **first two lines** of the description —
      that is all a 4.3 triage pass reads.
- [ ] Paste the new review notes from `ASC_REPLY_2026-08-06.md` Part 3.

## Gate 5 — privacy label accuracy

- [ ] In ASC → App Privacy, **remove Coarse Location**. The app has no
      CoreLocation usage; city is chosen from a static catalog in onboarding.
- [ ] Re-publish labels (the top-of-page Publish button, not just Save).
- [ ] Fix the welcome-screen copy *"Find the person nearby you'd most like to
      meet"* — there is no proximity feature. (Needs build 4.)

## Gate 6 — build

The app-side fix below is **in the working tree, not in any uploaded build**.
If it ships, it needs build 4:
- [ ] Bump `CURRENT_PROJECT_VERSION` to 4.
- [ ] Archive → export → `altool --upload-app` off the ASC API key.
- [ ] Wait for `VALID`, attach to version 1.0.

## Gate 7 — the 4.3(b) judgement call (revised 2026-08-06 on the full text)

The full rejection text is the **hard, concept-level** variant of 4.3(b), not
the soft "your listing looks generic" one. Three markers:

1. *"may include features or characteristics that distinguish it. **However,
   there are already enough of these apps**"* — the differentiation argument is
   pre-rejected.
2. *"reconsider the app concept and **submit a new app**"* — Apple is talking
   about a different app record, not a fixed submission.
3. The **web-app suggestion** — boilerplate reserved for "we do not want this
   on the App Store."

**Consequence: Gate 4 does not fix this.** Screenshots, keywords and
description rework address the soft variant. They will not move a concept-level
rejection, and doing them alone then resubmitting is near-certain to fail again.

Realistic odds of getting *this app record* approved as a dating app: **low.**
"Video speed dating" has prior art (Filter Off, Blindlee, and others), so
Apple's saturation claim is not baseless. Ranked options:

| Option | Cost | Honest odds |
|---|---|---|
| **App Review Board appeal** with the structural argument in `ASC_REPLY_2026-08-06.md` Part 2 | Low — preserves the record | Low, but it is the only lever that targets the actual rejection |
| **Genuine concept change** — e.g. real community/campus scoping. Note: `community` is currently **UI-only and `nil` in production** (`FirestoreDiscoveryService.swift:95`); there is no server-side scoping. This is a build, not a repositioning | High | Moderate, if the resulting product is honestly not "a dating app" |
| **Web app** (Apple's own suggestion) — the Firebase + LiveKit stack already runs on web | Medium | Certain to work, but off the App Store |
| Resubmit with reworked metadata only | Low | Near zero. Repeated resubmission is itself a 4.3 signal |

Do not resubmit repeatedly without changing the substance.

---

## Changes already made in this session (in repo, NOT submitted)

| Change | File | Status |
|---|---|---|
| Discover hero always shows name, age, city — no more "Someone is waiting" | `app/Moomo/Features/Discover/DiscoverHeroCard.swift` | Built + 233/233 tests pass. **Needs build 4 to reach Apple.** Survived the Discover redesign below by explicit decision — the design reference showed the anonymous wording and was overridden. |
| Discover redesign: white city bar + map picker replace the "Hey there" header; bell and Boost entry points removed; hero CTA is a magenta "Nearby"; "Real Talk" → "Speed Talk" | `DiscoverView.swift`, `DiscoverLocationBar.swift`, `Features/Location/`, `DiscoverHeroCard.swift` | Built. Note the CTA no longer reads "Talk to Her/Him" — if the "explicit call-request CTA" point in the root-cause report is being answered through copy, re-check this wording before build 4. |
| Root-cause report | `docs/production-readiness/REJECTION_2026-08-05_ROOT_CAUSE.md` | Written |
| Reviewer reply + replacement review notes | `docs/production-readiness/ASC_REPLY_2026-08-06.md` | Draft, not sent |
| Demo video capture script | `docs/production-readiness/DEMO_VIDEO_CAPTURE.md` | Written, video not captured |

**No ASC record was modified in this session.** All ASC calls were reads.
