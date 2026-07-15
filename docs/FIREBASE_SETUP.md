# Firebase setup

**Status: linked and live against `moomo-c7a37`.**

- Firebase SDK linked via SPM (FirebaseAuth, FirebaseFirestore,
  FirebaseStorage) plus GoogleSignIn-iOS.
- `GoogleService-Info.plist` present and gitignored, verified as project
  `moomo-c7a37` / number `998689337464`.
- Debug builds without a config still fall back to a labeled `LOCAL MOCK MODE`.
  **Release builds cannot** — `makeAuthService()` traps rather than silently
  authenticating nobody.

## Provider status (verified against the live project)

| Provider | Enabled | Works |
|---|---|---|
| Anonymous (guest) | ✅ yes | ✅ verified by live probe |
| Apple | ✅ yes | ⚠️ needs the Xcode capability — see below |
| Google | ✅ yes | ❌ **blocked** — no iOS OAuth client |
| Phone | enabled | not used; no UI, by request |

### ❌ Google is blocked: no iOS OAuth client

`GoogleService-Info.plist` has **no `CLIENT_ID` and no `REVERSED_CLIENT_ID`**.
Registering the iOS app through the *CLI* does not mint an iOS OAuth client;
only the console flow does. Without it, Google Sign-In cannot work, and no
amount of app code fixes it.

The app handles this honestly rather than crashing:
`FirebaseBootstrap.isGoogleSignInConfigured` is false, and a Google attempt
fails with a clear provider error.

To fix:

1. Google Cloud console → **APIs & Services → Credentials**
   → **Create credentials → OAuth client ID → iOS**
   → bundle ID `com.moomo.dating`.
2. Re-download the config:
   ```sh
   firebase apps:sdkconfig IOS 1:998689337464:ios:ca57cd2d8363fae941fd8d \
     --project moomo-c7a37 --out app/Moomo/GoogleService-Info.plist
   ```
3. Confirm `CLIENT_ID` and `REVERSED_CLIENT_ID` now exist:
   ```sh
   plutil -extract REVERSED_CLIENT_ID raw -o - app/Moomo/GoogleService-Info.plist
   ```
4. Add that `REVERSED_CLIENT_ID` as a URL scheme (`INFOPLIST_KEY_CFBundleURLTypes`).
   Without the scheme, Google returns to a blank screen instead of the app.

### ⚠️ Apple needs a capability

`apple.com` is enabled in Firebase, but Sign in with Apple also needs:

1. Apple Developer → your App ID → enable **Sign in with Apple**.
2. Xcode → target → Signing & Capabilities → **+ Sign in with Apple**.

The system sheet refuses without these, regardless of Firebase.

### ⚠️ The CLI was pointed at the wrong project

`firebase use` reported **`fitcheck-d3091`** — an unrelated project — from
inside this repo. A `firebase deploy` would have targeted it. Now pinned by
`.firebaserc` and `firebase use moomo-c7a37`. **Check `firebase use` before
every deploy.**

## Original setup notes

## 1. Create the project

**Do not reuse `moomoios-2026`.** That is the Moomo *AI* app's project —
different product, different users, different consent basis and retention
rules. `BackendConfiguration.assertNotAIProject` deliberately traps at launch
if that project ID appears, because silently writing dating data into the AI
app's project would be far worse than failing to start.

1. Firebase console → **Add project** → name it e.g. `moomo-dating-prod`.
2. **Build → Authentication → Get started**, enable:
   - Apple
   - Google
   - Anonymous  (required — this is guest access)
3. **Build → Firestore Database → Create database** → production mode.
4. **Build → Storage → Get started** (for profile photos).

## 2. Add the iOS app

1. Project settings → **Add app** → iOS.
2. Bundle ID: **`com.moomo.dating`** — must match exactly.
3. Download `GoogleService-Info.plist`.
4. Drop it at `app/Moomo/GoogleService-Info.plist`.

It is gitignored and must stay that way.

The target uses a synchronized folder group, so the file is picked up
automatically — no Xcode project changes needed.

## 3. Link the SDK

Xcode → File → Add Package Dependencies:

| Package | URL | Products |
|---|---|---|
| firebase-ios-sdk | `https://github.com/firebase/firebase-ios-sdk` | FirebaseAuth, FirebaseFirestore, FirebaseStorage, FirebaseFunctions, FirebaseMessaging, FirebaseAppCheck |
| GoogleSignIn-iOS | `https://github.com/google/GoogleSignIn-iOS` | GoogleSignIn |

Every Firebase call site is inside `#if canImport(FirebaseAuth)`, so the app
compiles either way and switches over automatically once the SDK resolves.

## 4. Google Sign-In URL scheme

Open `GoogleService-Info.plist`, copy `REVERSED_CLIENT_ID`, and add it as a URL
scheme. In build settings:

```
INFOPLIST_KEY_CFBundleURLTypes → add the reversed client ID
```

Without this, Google sign-in returns to a blank screen rather than the app.

## 5. Sign in with Apple

1. Apple Developer → Certificates, Identifiers & Profiles → your App ID →
   enable **Sign in with Apple**.
2. Xcode → target → Signing & Capabilities → **+ Capability** →
   Sign in with Apple.
3. Firebase console → Authentication → Apple → fill in Services ID, Team ID,
   Key ID, and the `.p8` private key.

Apple sign-in **cannot work without step 1 and 2** even in mock mode — the
system sheet itself refuses.

## Verifying which mode you're in

The banner is the source of truth:

- `LOCAL MOCK MODE — Firebase SDK not linked` → step 3 not done.
- `LOCAL MOCK MODE — GoogleService-Info.plist not found` → step 2 not done.
- No banner → real Firebase.

## What is deliberately not done

- **Nothing is deployed.** No functions, no rules, no indexes have been pushed
  to any project.
- `FirebaseAuthenticationService` is not yet written — the protocol and the
  boundary are in place, and it lands with the Firestore work.
- Firestore rules, indexes, and Cloud Functions are not written yet; they are
  Phase 4.
