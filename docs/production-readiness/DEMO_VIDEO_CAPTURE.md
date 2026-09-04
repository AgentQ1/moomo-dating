# Demo video for App Review — capture script

_What Apple asked for: "a demo video showing the app sending a video/call
request to a user." Written 2026-08-06._

**Status: NOT CAPTURED.** It cannot be recorded until the demo accounts can
actually pair — see `REJECTION_2026-08-05_ROOT_CAUSE.md` §5A. Recording a
video is the *last* step, not the first: there is nothing to film until two
accounts are mutually compatible with no pass tombstone between them.

---

## Step 0 — prerequisites (must all be true before filming)

- [ ] Two accounts, mutually compatible (`gender` / `interestedIn` accept each
      other in both directions — `backend/functions/src/compatibility.ts:37-39`).
- [ ] **No pass tombstone** between them: `passes/{A}/passed/{B}` and
      `passes/{B}/passed/{A}` must both be absent (`shared.ts:216-226`).
- [ ] No block documents between them.
- [ ] Both profiles complete: `displayName`, `age` ≥ 18, `city`, `photoPath`.
- [ ] Both simulators' App Check debug tokens registered
      (`tools/register-appcheck-debug-token.sh`) — App Check is enforced on
      every callable, and an unregistered install fails with "unauthenticated".
- [ ] Camera + microphone pre-granted on both, or the first frames of the video
      are a permission alert.

## Step 1 — boot two simulators

```sh
# Device 1 — the caller
xcrun simctl boot "iPhone 17 Pro Max"           # 782FD13C-6499-40C9-9A2B-8E83630C1568
# Device 2 — the callee
xcrun simctl boot "iPhone 17 Pro"               # 5EB35472-7DD5-46C4-A179-CC28DC0308C7

for D in 782FD13C-6499-40C9-9A2B-8E83630C1568 5EB35472-7DD5-46C4-A179-CC28DC0308C7; do
  xcrun simctl privacy "$D" grant microphone com.moomo.dating
  xcrun simctl privacy "$D" grant camera     com.moomo.dating
done
```

## Step 2 — install a Release-style build on both

Do **not** film a Debug build: Debug uses App Check debug tokens, Release uses
App Attest, and the 2026-07-23 incident was a Release-only outage that no debug
run ever reproduced.

```sh
cd app
xcodebuild build -project Moomo.xcodeproj -scheme Moomo -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -derivedDataPath build/DerivedDataRelease

for D in 782FD13C-… 5EB35472-…; do
  xcrun simctl install "$D" \
    build/DerivedDataRelease/Build/Products/Release-iphonesimulator/Moomo.app
done
```

## Step 3 — record

Record **device 1 (the caller)** as the primary video. Film device 2 separately
or place the two simulator windows side by side and capture the screen region —
side by side is far more convincing to a reviewer, because it shows the request
leaving one device and arriving on the other.

```sh
# Per-simulator recording (Ctrl-C to stop)
xcrun simctl io 782FD13C-… recordVideo --codec h264 ~/Baybe_Screenshots/demo-caller.mp4
xcrun simctl io 5EB35472-… recordVideo --codec h264 ~/Baybe_Screenshots/demo-callee.mp4
```

For the side-by-side single file, arrange both simulator windows and use
QuickTime → File → New Screen Recording, or:

```sh
# list screen-capture devices, then record the display
ffmpeg -f avfoundation -list_devices true -i ""
ffmpeg -f avfoundation -i "<screen-index>" -r 30 -pix_fmt yuv420p \
  ~/Baybe_Screenshots/demo-sidebyside.mp4
```

## Step 4 — the exact beats to film (≈60–90 s)

Keep it silent or add a short caption track. Apple wants to see the mechanic,
not production values.

> **Corrected 2026-08-11** against the code at HEAD. Beats 2, 3 and 4 named a
> button and a banner layout that do not exist in the binary — see
> `ASC_REPLY_2026-08-11.md` §0. Film what is actually on screen; if the video
> and the written notes disagree, the video is what Apple believes.

| # | Device | What must be on screen |
|---|---|---|
| 1 | Both | Sign-in: phone number entered, code entered. Shows there is no anonymous/social login. Can be sped up. |
| 2 | 1 | **Discover showing the peer's photo, first name, age and city.** This is the answer to "what information users see when they are ready to get matched" — hold it for ~3 seconds. The primary button under it reads **"Nearby"** with a video-camera icon; there is **no** "Talk to \<name\>" button in this build. |
| 3 | 1 | Tap the **"Nearby"** button. |
| 4 | 2 | **The incoming-call banner appears** — caller's photo, first name, "Incoming Video Call", and the Decline (✗) / Answer (video) buttons. **No age or city on the banner.** **This is the shot Apple explicitly asked for — do not cut it short.** It is only up for **7 seconds** (`CallModels.swift:50`), so device 2 must already be on camera before beat 3. |
| 4b | 1 | Optional but valuable: on a first take, tap **Decline** on device 2 to film the decline path, then re-run for the accept. Apple asked to see the request mechanic; showing both answers proves it is a real two-way negotiation. |
| 5 | 2 | Tap Answer. |
| 6 | Both | Video connects. Device 1 passes through "Finding someone…" then the peer's name, age and city while connecting. Hold on the in-call screen showing the peer's name/age/city overlay **and the visible countdown** — this proves the 3-minute cap. |
| 7 | 1 | Open the in-call menu to show **Report** and **Block** exist during the call. |
| 8 | Both | End the call → the private **Like / Pass** screen with the peer's name, age, city. |
| 9 | Both | Both tap Like → match → chat opens. Shows chat is gated on mutual like. |

### What the video cannot prove, and must not be edited to imply

- **That the request went only to the person on the card.** It also rings up to
  seven other compatible online people simultaneously (`RING_FANOUT_LIMIT = 8`),
  and the first to answer wins. With only two accounts online this is invisible
  — which is fine, but do not narrate it as a private one-to-one invitation.
- **That the two accounts pair at all.** Unverified until Gate 1 is closed.
- **That media negotiates on real hardware.** Still the open
  `LAUNCH_CHECKLIST.md` item. A simulator capture does not close it.

## Step 5 — attach

Apple accepts a video URL in Resolution Center, not a file upload. Host it
unlisted (YouTube unlisted, or Firebase Hosting on the existing `baybe-dating`
site) and paste the link into the reply. If hosting on Firebase:

```sh
cp demo-sidebyside.mp4 web/demo/baybe-call-request.mp4
firebase deploy --only hosting:baybe-dating --project moomo-c7a37
# → https://baybe-dating.web.app/demo/baybe-call-request.mp4
```

Confirm the URL returns 200 from a signed-out browser before sending.

---

## If simulators cannot carry real media

The simulator's camera is synthetic and LiveKit media may not negotiate the way
it does on hardware. If step 6 fails on simulators, film **two real devices**
instead — that also satisfies the still-open `LAUNCH_CHECKLIST.md` item "one
real device-to-device speed call on the production stack", killing two birds.

## Existing harness (partial help only)

`MoomoLiveUITests/ScreenshotCaptureUITests` has `testActAsCallPeer`, which
parks a second simulator in the matchmaking queue. It can hold the callee side
while a human drives the caller — but it answers a *queue* pairing, not a ring
invite, so it does not by itself produce the banner shot in beat 4. Env vars
reach the runner only through xcodebuild's own environment
(`export TEST_RUNNER_SCREENSHOT_PHONE=…`).
