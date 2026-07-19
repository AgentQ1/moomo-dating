# Moomo — speed dating

Native SwiftUI iOS app. Three-minute video and voice speed calls, mutual-match
gating, and 24-hour chat windows.

Greenfield as of 2026-07-15. Unrelated to the Moomo AI app in `~/moomo-ios` and
`~/Desktop/MoomoAI`, which is a different product and is not touched by this
repo. See `docs/IMPLEMENTATION_MAP.md`.

## Layout

```
app/       SwiftUI app (Xcode project; folder-synchronized target)
backend/   Firebase Cloud Functions, Firestore/Storage rules, indexes
tools/     Visual-validation reference and capture
docs/      Implementation map
```

## Build

```sh
cd app
xcodebuild -project Moomo.xcodeproj -scheme Moomo \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Design system

`app/Moomo/DesignSystem/` is the single source of truth for colour, type,
spacing, radii, shadow, size, and motion. Every value is sampled from the
supplied reference screens.

**Do not use a raw `Color`, font size, or padding literal in a view.** If a
screen needs a value that isn't a token, it is either a token that needs naming
or a mistake.

## Status

Live app against Firebase project `moomo-c7a37`: phone OTP sign-in (the only
auth method), onboarding, all five tabs (Discover, Calls, Matches, Chat,
Profile), speed calls over LiveKit with server matchmaking, mutual-match
gating, chat, blocking/reporting, boosts, and account deletion.

Matchmaking pairs only mutually compatible users (gender + who they want to
meet) and ranks actively boosted waiters first; Discover applies the same
compatibility filter. See `backend/README.md` for the callable surface and
`docs/IMPLEMENTATION_MAP.md` for the screen-by-screen map.

App Check is wired client-side but not enforced (`docs/FIREBASE_SETUP.md`).
Light mode is locked in `app/Info.plist` until a real dark palette ships.
