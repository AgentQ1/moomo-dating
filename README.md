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

Screen 1 (welcome/auth) built and visually iterated against its reference.
Screens 2–13 not started. Backend not started.
