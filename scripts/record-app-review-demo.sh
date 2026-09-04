#!/usr/bin/env bash
#
# Records the App Review demo video for Baybe, repeatably and safely.
#
# The video goes to Apple. Everything here exists to stop two failure modes:
#
#   1. Recording a run that cannot work. The 2026-08-05 rejection happened
#      because the demo accounts could not pair, so no call button ever
#      appeared. Preflight refuses to roll until production says they pair.
#   2. Filming something a reviewer should never see. DEBUG builds print
#      backend diagnostics into the Discover error card. This script refuses a
#      DEBUG build unless you insist with --allow-debug.
#
# Nothing sensitive is printed. Every subprocess is piped through redact(),
# which strips project identifiers, backend hostnames, app ids, API keys and
# UUID tokens — so the terminal is safe to have on screen while you film.
#
# Usage:
#   scripts/record-app-review-demo.sh --help
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.moomo.dating"
MIN_BUILD_DEFAULT=4
PRIVACY_PATH="/privacy"

# ---------------------------------------------------------------------------
# Redaction. Applied to EVERY line this script emits from a subprocess.
# ---------------------------------------------------------------------------

redact() {
  sed -E \
    -e 's#[A-Za-z0-9_-]*moomo[A-Za-z0-9_-]*-[a-z0-9]{5,}#<project>#g' \
    -e 's#https?://[A-Za-z0-9._-]+(/[^ ")]*)?#<url>#g' \
    -e 's#[A-Za-z0-9._-]+\.(googleapis\.com|web\.app|firebaseapp\.com|cloudfunctions\.net)#<host>#g' \
    -e 's#1:[0-9]+:(ios|android|web):[a-f0-9]+#<app-id>#g' \
    -e 's#AIza[0-9A-Za-z_-]{20,}#<api-key>#g' \
    -e 's#[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}#<token>#g' \
    -e 's#(^|[^A-Za-z0-9])[A-Za-z0-9]{26,34}($|[^A-Za-z0-9])#\1<uid>\2#g' \
    -e 's#(^|[^A-Za-z0-9])[A-Za-z0-9]{26,34}($|[^A-Za-z0-9])#\1<uid>\2#g' \
    -e 's#(Bearer|access_token|apiKey|key=)[[:space:]=]*[A-Za-z0-9._-]+#\1 <redacted>#g' \
    -e "s#$HOME#~#g" \
    -e 's#^[[:space:]]*at .*#  <trace omitted>#'
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

FAIL_COUNT=0
MANUAL_ITEMS=()

pass()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
fail()   { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn()   { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
manual() { printf '  %s→%s %s\n' "$BLUE" "$RESET" "$1"; MANUAL_ITEMS+=("$1"); }
info()   { printf '    %s%s%s\n' "$DIM" "$1" "$RESET"; }
head1()  { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }

die() { printf '\n%sError:%s %s\n\n' "$RED" "$RESET" "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

MODE=""
SIM_A=""
SIM_B=""
ALLOW_DEBUG=0
APPCHECK_TOKEN=""
SKIP_APPCHECK=0
MIN_BUILD="$MIN_BUILD_DEFAULT"
CONFIRM_BUILD=""
PREFLIGHT_ONLY=0

usage() {
  cat <<'USAGE_EOF'
Record the App Review demo video for Baybe.

USAGE
  scripts/record-app-review-demo.sh --device [options]
  scripts/record-app-review-demo.sh --simulator-a <name|udid> [--simulator-b <name|udid>] --allow-debug [options]
  scripts/record-app-review-demo.sh --preflight-only [--device | --simulator-a <n>]

MODES
  --device                  Physical two-device recording (RECOMMENDED).
                            Runs preflight, then prints exact manual steps.
                            Does not capture video itself — iOS screen
                            recording is driven from Control Center.

  --simulator-a <name|udid> Simulator recording via simctl. Requires
  --simulator-b <name|udid> --allow-debug, because a Release build cannot
                            attest on a simulator (see NOTES).

OPTIONS
  --allow-debug             Permit a DEBUG build. Off by default: DEBUG builds
                            render backend diagnostics into the Discover error
                            card, which must never reach a reviewer.
  --appcheck-token <uuid>   Verify this install can attest before recording.
  --skip-appcheck           Skip the attestation check (not recommended).
  --min-build <n>           Minimum acceptable build number (default 4).
  --confirm-build <n>       Device mode: assert the installed build number,
                            which cannot be read from a device automatically.
  --preflight-only          Run the checks and exit. Changes nothing.
  -h, --help                This text.

NOTES
  Release builds attest with App Attest, which is unavailable on the iOS
  simulator. A Release build on a simulator therefore fails App Check and
  cannot load Discover at all. Reviewer-faithful recording means a physical
  device running a TestFlight/Release build: use --device.

  Simulator capture is for rehearsal and for flows you do not intend to ship
  to Apple, which is why it demands --allow-debug.
USAGE_EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)         MODE="device"; shift ;;
    --simulator-a)    MODE="simulator"; SIM_A="${2:-}"; shift 2 ;;
    --simulator-b)    SIM_B="${2:-}"; shift 2 ;;
    --allow-debug)    ALLOW_DEBUG=1; shift ;;
    --appcheck-token) APPCHECK_TOKEN="${2:-}"; shift 2 ;;
    --skip-appcheck)  SKIP_APPCHECK=1; shift ;;
    --min-build)      MIN_BUILD="${2:-}"; shift 2 ;;
    --confirm-build)  CONFIRM_BUILD="${2:-}"; shift 2 ;;
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -z "$MODE" && "$PREFLIGHT_ONLY" -eq 1 ]] && MODE="device"
[[ -z "$MODE" ]] && { usage; exit 1; }

if [[ "$MODE" == "simulator" ]]; then
  [[ -z "$SIM_A" ]] && die "--simulator-a requires a simulator name or udid"
  if [[ "$ALLOW_DEBUG" -ne 1 ]]; then
    cat >&2 <<EOF

${RED}Refusing to record on a simulator without --allow-debug.${RESET}

A Release build attests with App Attest, which does not exist on the iOS
simulator — the app would fail App Check and Discover would never load. So a
simulator recording is necessarily a DEBUG build, and DEBUG builds print
backend diagnostics into the Discover error card if anything goes wrong.

  For the video you send Apple:  use --device on a TestFlight build.
  For rehearsal only:            re-run with --allow-debug.

EOF
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

head1 "Preflight"

# --- 1. Demo accounts can pair, per production -----------------------------
check_demo_accounts() {
  local out
  if ! command -v node >/dev/null 2>&1; then
    fail "demo accounts: node not found, cannot verify pairing"
    return
  fi
  out="$(cd "$REPO_ROOT/backend/functions" && node scripts/demo-accounts.mjs 2>&1)"
  if printf '%s' "$out" | grep -q "All demo pairs can pair"; then
    local n
    n="$(printf '%s' "$out" | grep -c "CAN PAIR")"
    pass "demo accounts: all pairs pairable in production ($n/3 pairs)"
  else
    fail "demo accounts: NOT all pairs can pair — recording would dead-end"
    printf '%s' "$out" | grep -E "CANNOT PAIR|      - " | redact | sed 's/^/      /'
    info "repair with: (cd backend/functions && node scripts/demo-accounts.mjs --fix)"
  fi
}

# --- 2. App Check can actually mint for this install -----------------------
check_appcheck() {
  if [[ "$SKIP_APPCHECK" -eq 1 ]]; then
    warn "App Check: skipped by request"
    return
  fi
  if [[ "$MODE" == "device" && -z "$APPCHECK_TOKEN" ]]; then
    manual "App Check: Release builds attest per-device via App Attest — confirm by opening the app and seeing Discover load (no error card)"
    return
  fi
  if [[ -z "$APPCHECK_TOKEN" ]]; then
    fail "App Check: no --appcheck-token given; a DEBUG install whose token is unregistered is refused every backend call"
    info "the app prints its token at launch; register it with tools/register-appcheck-debug-token.sh"
    return
  fi

  local api_key api app_id project response
  project="$(sed -n 's/.*"projectId": *"\([^"]*\)".*/\1/p' "$REPO_ROOT/app/Moomo/GoogleService-Info.plist" 2>/dev/null || true)"
  if [[ -z "$project" ]]; then
    project="$(plutil -extract PROJECT_ID raw "$REPO_ROOT/app/Moomo/GoogleService-Info.plist" 2>/dev/null || true)"
  fi
  app_id="$(plutil -extract GOOGLE_APP_ID raw "$REPO_ROOT/app/Moomo/GoogleService-Info.plist" 2>/dev/null || true)"
  api_key="$(plutil -extract API_KEY raw "$REPO_ROOT/app/Moomo/GoogleService-Info.plist" 2>/dev/null || true)"
  if [[ -z "$project" || -z "$app_id" || -z "$api_key" ]]; then
    fail "App Check: could not read the app's Firebase config"
    return
  fi

  api="https://firebaseappcheck.googleapis.com/v1/projects/$project/apps/$app_id"
  response="$(curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"debugToken\": \"$APPCHECK_TOKEN\"}" \
    "$api:exchangeDebugToken?key=$api_key" 2>/dev/null)"
  if printf '%s' "$response" | grep -q '"token"'; then
    pass "App Check: this install can mint tokens"
  else
    fail "App Check: this install CANNOT mint tokens — every backend call will be refused"
    info "register it once: tools/register-appcheck-debug-token.sh <token-printed-at-launch>"
  fi
}

# --- 3. Installed build is new enough --------------------------------------
check_build_version() {
  if [[ "$MODE" == "simulator" ]]; then
    local udid plist version
    udid="$(resolve_sim "$SIM_A")"
    if [[ -z "$udid" ]]; then
      fail "installed build: simulator '$SIM_A' not found"
      return
    fi
    plist="$(xcrun simctl listapps "$udid" 2>/dev/null || true)"
    if ! printf '%s' "$plist" | grep -q "$BUNDLE_ID"; then
      fail "installed build: the app is not installed on simulator A"
      return
    fi
    version="$(printf '%s' "$plist" \
      | awk -v b="$BUNDLE_ID" 'index($0,b){f=1} f&&/CFBundleVersion/{print;exit}' \
      | sed -E 's/.*= *"?([0-9]+)"?.*/\1/')"
    if [[ -z "$version" ]]; then
      manual "installed build: could not read the build number — confirm it is $MIN_BUILD or newer"
      return
    fi
    if [[ "$version" -ge "$MIN_BUILD" ]]; then
      pass "installed build: $version (>= $MIN_BUILD)"
    else
      fail "installed build: $version — older than $MIN_BUILD, so it predates approximate-location ranking"
    fi
    return
  fi

  if [[ -n "$CONFIRM_BUILD" ]]; then
    if [[ "$CONFIRM_BUILD" -ge "$MIN_BUILD" ]]; then
      pass "installed build: $CONFIRM_BUILD asserted via --confirm-build (>= $MIN_BUILD)"
    else
      fail "installed build: $CONFIRM_BUILD asserted — older than $MIN_BUILD"
    fi
  else
    manual "installed build: read Settings > General > iPhone Storage > Baybe, or the TestFlight build number — it must be $MIN_BUILD or newer; re-run with --confirm-build <n> to record it"
  fi
}

# --- 4. Privacy policy reachable -------------------------------------------
check_privacy_policy() {
  local url code
  url="$(sed -n 's/.*\(https:\/\/[a-z0-9.-]*\)\/privacy.*/\1/p' \
        "$REPO_ROOT/docs/production-readiness/RESUBMISSION_PACKAGE_2026-08-12.md" 2>/dev/null | head -1)"
  [[ -z "$url" ]] && url="https://baybe-dating.web.app"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url$PRIVACY_PATH" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    pass "privacy policy: reachable (HTTP 200)"
  else
    fail "privacy policy: HTTP $code — the reviewer follows this link from the listing"
  fi
}

# --- 5. Proximity backend deployed -----------------------------------------
check_proximity_backend() {
  if ! command -v gcloud >/dev/null 2>&1; then
    manual "proximity backend: gcloud not available — confirm the ranking functions are deployed"
    return
  fi
  local project fns
  project="$(plutil -extract PROJECT_ID raw "$REPO_ROOT/app/Moomo/GoogleService-Info.plist" 2>/dev/null || true)"
  [[ -z "$project" ]] && { manual "proximity backend: could not resolve the backend project"; return; }

  fns="$(gcloud functions list --project="$project" --format="value(name)" 2>/dev/null || true)"
  if [[ -z "$fns" ]]; then
    manual "proximity backend: could not list backend functions (credentials?) — confirm deployment manually"
    return
  fi
  local missing=""
  for f in getDiscoveryFeed joinMatchmakingQueue acceptCallInvite declineCallInvite; do
    printf '%s\n' "$fns" | grep -qx "$f" || missing="$missing $f"
  done
  if [[ -z "$missing" ]]; then
    pass "proximity backend: ranking and call-invite functions are deployed"
  else
    fail "proximity backend: missing —$missing"
  fi
}

resolve_sim() {
  local q="$1"
  if [[ "$q" =~ ^[0-9A-Fa-f-]{36}$ ]]; then printf '%s' "$q"; return; fi
  xcrun simctl list devices available 2>/dev/null \
    | grep -F "$q" | head -1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/'
}

check_demo_accounts
check_appcheck
check_build_version
check_privacy_policy
check_proximity_backend

# --- build configuration gate ----------------------------------------------
head1 "Build configuration"
if [[ "$ALLOW_DEBUG" -eq 1 ]]; then
  warn "DEBUG build permitted (--allow-debug)"
  info "the Discover error card renders backend diagnostics in DEBUG."
  info "if any error appears on screen, STOP and discard the take."
else
  pass "Release behaviour required — reviewer-visible diagnostics are compiled out"
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

head1 "Verdict"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf '  %sNO-GO%s — %d blocking check(s) failed. Nothing was recorded.\n\n' \
    "$RED" "$RESET" "$FAIL_COUNT"
  exit 1
fi

if [[ ${#MANUAL_ITEMS[@]} -gt 0 ]]; then
  printf '  %sGO, once you confirm %d item(s) above by hand.%s\n' \
    "$YELLOW" "${#MANUAL_ITEMS[@]}" "$RESET"
else
  printf '  %sGO — every automated check passed.%s\n' "$GREEN" "$RESET"
fi

[[ "$PREFLIGHT_ONLY" -eq 1 ]] && { printf '\n  Preflight only; exiting.\n\n'; exit 0; }

# ---------------------------------------------------------------------------
# The shot list — printed in both modes
# ---------------------------------------------------------------------------

STAMP="$(date +%Y-%m-%d_%H%M%S)"
OUT_DIR="$REPO_ROOT/artifacts/app-review-demo/$STAMP"
mkdir -p "$OUT_DIR"

print_shot_list() {
  cat <<'SHOTS'

  ── Shot list ────────────────────────────────────────────────────────────
   Target 60-90 seconds. Captions optional; narration not required.

   Device A
    1. Open Baybe from the home screen.
    2. Sign in as demo User A: tick the consent box, enter the phone number,
       then the SMS code on the next screen.
    3. Discover: hold ~3 seconds on the featured person. Show the photo,
       "Name, age", the city line, and the "Wants to Talk to You" bubble if
       it is present.
       Caption: "Everything you see before a call."
    4. Tap the city in the top bar, show the picker, dismiss it.
       Caption: "Approximate location only - it decides the ORDER people are
                 shown, never who you can meet. No distance is ever shown."
    5. Tap the "Nearby" button under the photo (video-camera icon).
       Caption: "A live video call request goes to that specific person."
    6. Hold on the "Finding someone..." state.

   Device B
    7. Show the incoming-call banner: caller photo, first name, call type,
       Answer and Decline. It is live for about 7 seconds - be ready.
    8. Tap Decline. Cut to A still waiting.
       Caption: "Declining is silent. The caller is never told who declined."
    9. On A, start the request again. On B, tap Answer.

   Both
   10. The call connecting: peer name/age/city overlay and the countdown.
       Caption: "Calls are capped at 180 seconds by the server, and are
                 never recorded."
   11. Open the in-call report/block control, then close it.
       Caption: "Either person can report or block during the call."
   12. End the call. Show the private like/pass decision screen.
   13. BOTH tap Like. Show the match and the conversation opening.
       Caption: "Chat opens only when both choose like. This is the only way
                 a message can be sent."

  ── Do not ──────────────────────────────────────────────────────────────
   * Do NOT tap "Pass" at any point. A pass writes a permanent tombstone and
     re-breaks the demo accounts for the reviewer.
   * Do NOT film an error card on a DEBUG build.
   * Do NOT imply a distance readout, a radius, or a "within X km" filter.
     None exist. Say "approximate" and say "ordering".
   * Do NOT film notification banners from other apps, or your own contacts.

SHOTS
}

# ---------------------------------------------------------------------------
# Device mode — manual capture
# ---------------------------------------------------------------------------

if [[ "$MODE" == "device" ]]; then
  head1 "Two-device recording (manual capture)"
  cat <<EOF

  iOS screen recording cannot be started from a Mac, so capture runs from the
  device. This is the reviewer-faithful path: a Release build attesting with
  App Attest, exactly as the reviewer's install will.

  On EACH device, once:
    1. Settings > Control Center > add "Screen Recording".
    2. Settings > Focus > Do Not Disturb ON  (keeps other apps out of frame).
    3. Install the build from TestFlight and open it once to confirm Discover
       loads with no error card.

  To record:
    4. Swipe into Control Center, long-press the record button, choose
       "Screen Recording", and turn the microphone OFF unless you are
       narrating. Start on BOTH devices.
    5. Perform the shot list below.
    6. Stop from the status bar. The clips land in Photos.
    7. AirDrop both clips into:
         artifacts/app-review-demo/$STAMP/
    8. Cut them together side by side, or sequence A then B with captions.

EOF
  print_shot_list
  cat <<EOF
  ── Output ──────────────────────────────────────────────────────────────
   Put the finished cut here, then attach it to the review submission:
     artifacts/app-review-demo/$STAMP/

EOF
  exit 0
fi

# ---------------------------------------------------------------------------
# Simulator mode — automated capture
# ---------------------------------------------------------------------------

UDID_A="$(resolve_sim "$SIM_A")"
[[ -z "$UDID_A" ]] && die "simulator not found: $SIM_A"
UDID_B=""
if [[ -n "$SIM_B" ]]; then
  UDID_B="$(resolve_sim "$SIM_B")"
  [[ -z "$UDID_B" ]] && die "simulator not found: $SIM_B"
fi

VIDEO_A="$OUT_DIR/device-a.mp4"
VIDEO_B="$OUT_DIR/device-b.mp4"
PID_A=""; PID_B=""

stop_recording() {
  printf '\n  Stopping recording...\n'
  [[ -n "$PID_A" ]] && kill -INT "$PID_A" 2>/dev/null
  [[ -n "$PID_B" ]] && kill -INT "$PID_B" 2>/dev/null
  [[ -n "$PID_A" ]] && wait "$PID_A" 2>/dev/null
  [[ -n "$PID_B" ]] && wait "$PID_B" 2>/dev/null
  sleep 1
  head1 "Recorded"
  for v in "$VIDEO_A" "$VIDEO_B"; do
    [[ -f "$v" ]] && printf '  %s  (%s)\n' "$v" "$(du -h "$v" | cut -f1)"
  done
  printf '\n  Review both clips before sending. Discard the take if any error\n'
  printf '  card, diagnostic text, or unrelated notification appears.\n\n'
  exit 0
}
trap stop_recording INT TERM

head1 "Recording (simulator)"
xcrun simctl bootstatus "$UDID_A" -b >/dev/null 2>&1 || true
xcrun simctl io "$UDID_A" recordVideo --codec h264 --force "$VIDEO_A" >/dev/null 2>&1 &
PID_A=$!
pass "recording device A"
if [[ -n "$UDID_B" ]]; then
  xcrun simctl bootstatus "$UDID_B" -b >/dev/null 2>&1 || true
  xcrun simctl io "$UDID_B" recordVideo --codec h264 --force "$VIDEO_B" >/dev/null 2>&1 &
  PID_B=$!
  pass "recording device B"
fi

print_shot_list

printf '  %sRecording. Press Enter (or Ctrl-C) when the shot list is done.%s\n' "$BOLD" "$RESET"
read -r _ || true
stop_recording
