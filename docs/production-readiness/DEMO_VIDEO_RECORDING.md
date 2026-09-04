# Recording the App Review demo video

`scripts/record-app-review-demo.sh` makes the demo video repeatable. It runs
the preflight that would otherwise be forgotten, refuses to record a run that
cannot succeed, and prints the shot list so two takes a month apart show Apple
the same thing.

This supersedes the ad-hoc checklist in `PROXIMITY_2026-08-11.md` §7. Capture
mechanics for the screenshot harness stay in `DEMO_VIDEO_CAPTURE.md`.

---

## Why the script refuses things

**It will not record a DEBUG build unless you pass `--allow-debug`.** In DEBUG,
`DiscoveryService.errorDescription` appends the backend diagnostic to the
Discover error card — the failure code, the attestation URL, the project, the
debug token. A Release build compiles that branch out
(`DiscoveryService.swift:95-100`). Filming a DEBUG build risks handing Apple a
video of your infrastructure inside a submission that is already contested.

**Simulator recording is rehearsal only, and the script says so.** Release
builds attest with `AppAttestProvider` (`FirebaseBootstrap.swift:154-162`), and
App Attest does not exist on the iOS simulator. A Release build on a simulator
fails App Check outright and never loads Discover. So a simulator recording is
necessarily a DEBUG build — which is exactly why simulator mode demands
`--allow-debug`. **The video you send Apple must come from a physical device
running a TestFlight build.**

**It will not record if the demo accounts cannot pair.** That is the 2026-08-05
rejection reproduced exactly: the reviewer signed in, no partner was eligible,
no call button ever appeared. Preflight asks production the same four questions
the server asks — mutual gender preference, overlapping intention, no block, no
pass tombstone — and stops if any pair is broken.

---

## Running it

```bash
# The real thing: two physical devices on a TestFlight build.
scripts/record-app-review-demo.sh --device --confirm-build 4

# Check readiness without touching anything.
scripts/record-app-review-demo.sh --device --preflight-only

# Rehearsal on simulators (DEBUG, not for Apple).
scripts/record-app-review-demo.sh \
  --simulator-a "iPhone 17 Pro" \
  --simulator-b "iPhone 17 Pro Max" \
  --allow-debug --appcheck-token <token-the-app-prints-at-launch>
```

| Flag | Effect |
|---|---|
| `--device` | Physical two-device mode. Preflight, then manual capture steps. |
| `--simulator-a` / `--simulator-b` | Simulator capture via `simctl io … recordVideo`. Records both at once. |
| `--allow-debug` | Permit a DEBUG build. Required for simulator mode. |
| `--appcheck-token <uuid>` | Prove this install can attest before you start. |
| `--skip-appcheck` | Skip that check. Not recommended. |
| `--min-build <n>` | Minimum acceptable build (default **4**). |
| `--confirm-build <n>` | Device mode: assert the installed build, which cannot be read remotely. |
| `--preflight-only` | Run checks and exit. |

Exit codes: `0` GO · `1` NO-GO, a check failed · `2` refused (DEBUG without
`--allow-debug`).

---

## What preflight checks

| Check | How | Blocking |
|---|---|---|
| Demo accounts pair in production | `demo-accounts.mjs`, **read-only** — never `--fix` | yes |
| App Check can mint for this install | performs the real token exchange | yes, if a token is given |
| Installed build ≥ 4 | `simctl listapps` on simulator; `--confirm-build` on device | yes |
| Privacy policy reachable | HTTP status only | yes |
| Proximity backend deployed | ranking + call-invite functions present | yes |

Results are `✓` pass, `✗` fail (blocks recording), `→` manual (you confirm by
hand). Device mode always leaves two manual items: App Attest can only be
confirmed by opening the app, and a device's installed build number cannot be
read from the Mac.

---

## Nothing sensitive is printed

Every subprocess is piped through `redact()`, so the terminal is safe to have
on screen while filming. It strips backend hostnames and URLs, the Firebase
project id, the app id, API keys, bearer tokens, UUID debug tokens, Firebase
uids, `$HOME`, and stack-trace frames.

Verified against the real failure text:

```
- URL: https://firebaseappcheck.googleapis.com/v1/projects/…  →  - URL: <url>
register this install's debug token: EE027910-…-82B79942672C  →  … <token>
passes/vElHha376tfCiSQI…/passed/NmDVKN99LLTaG…                →  passes/<uid>/passed/<uid>
```

Demo phone numbers and SMS codes are *not* redacted — you have to type them,
and they are already published to Apple in the review notes. They are safe to
show on camera.

---

## The shot list

Printed by the script so it cannot drift from the reply text. Target 60–90 s.

**Device A** — open Baybe · sign in as demo User A (consent box, number, code)
· hold on Discover showing photo, "Name, age", city, and the "Wants to Talk to
You" bubble · tap the city to show the location picker, dismiss · tap
**"Nearby"** under the photo · hold on "Finding someone…".

**Device B** — the incoming-call banner with **Answer** / **Decline** (live for
~7 seconds, be ready) · tap **Decline**, cut to A still waiting · A requests
again, B taps **Answer**.

**Both** — the call connecting with the peer overlay and countdown · open the
in-call report/block control · end the call, show the private like/pass screen ·
**both tap Like**, show the match and the conversation opening.

### Hard rules

- **Never tap "Pass".** It writes a permanent tombstone and re-breaks the demo
  accounts for the reviewer — the original rejection, recreated.
- **Never film an error card on a DEBUG build.**
- **Never imply a distance readout, radius, or "within X km" filter.** None
  exist. Say *approximate*, and say it affects *ordering*.
- Turn on Do Not Disturb so other apps stay out of frame.

On the location beat, the caption should say approximate location decides the
**order** compatible people appear in, never who you can meet, and that no
distance is ever shown.

---

## Two-device capture

iOS screen recording cannot be started from a Mac, so device mode prints the
steps rather than driving them. Per device, once: add **Screen Recording** to
Control Center, turn on **Do Not Disturb**, install from TestFlight, and open
the app once to confirm Discover loads with no error card.

Then start recording on both, run the shot list, stop from the status bar,
AirDrop both clips into the timestamped folder the script created, and cut them
together side by side (or A then B with captions).

---

## Output

```
artifacts/app-review-demo/<YYYY-MM-DD_HHMMSS>/
    device-a.mp4      # simulator mode, written directly
    device-b.mp4
```

`artifacts/` is gitignored — these are large regenerable binaries. Keep the
take you send Apple somewhere durable and note which submission used it.

Review both clips before sending. Discard the take if any error card,
diagnostic text, or unrelated notification appears.
