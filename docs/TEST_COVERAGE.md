# Test coverage — what is and isn't actually verified

Written so nothing here is mistaken for more assurance than it carries.

## Verified by automated tests

| Area | Where | Notes |
|---|---|---|
| 18+ age gate boundaries | `AgeGateTests` | Exactly-18-today passes, one day short fails, future and implausible dates rejected |
| Consent gate | `AuthenticationTests` | Refused below the UI layer, not just by disabling buttons |
| Consent version + timestamp | `AuthenticationTests`, `ProfileBootstrapTests` | Stale version invalidates profile state |
| Auth failure → retryable / terminal | `AuthenticationTests` | Cancellation never raises an alert |
| Retry after failure | `AuthenticationTests` | |
| Returning-user routing | `AuthenticationTests` | Bypasses welcome only when profile state is valid |
| Guest→provider linking keeps uid | `AuthenticationTests`, `ProfileBootstrapTests` | |
| Duplicate credential conflict | `AuthenticationTests` | Guest left intact on failure |
| Onboarding validation, every step | `OnboardingTests` | |
| Onboarding resume after relaunch | `OnboardingTests`, `OnboardingUITests` | Drafts keyed per user, no cross-account leak |
| Guest short flow keeps the age gate | `OnboardingTests` | |
| Completion clears draft; failure keeps it | `OnboardingTests` | |
| Bootstrap idempotency | `ProfileBootstrapTests` | Twice ≠ duplicate; never resets a finished profile |
| Provider name fills blanks only | `ProfileBootstrapTests` | Apple's one-shot name backfills but never overwrites |
| Public projection excludes private fields | `ProfileBootstrapTests` | No DOB, consent, or coordinates |
| Consent gate in the real UI | `OnboardingUITests` | Buttons genuinely disabled; tapping does nothing |
| Untouched date picker blocks | `OnboardingUITests` | Prevents recording an age nobody stated |
| Full guest flow → Discover | `OnboardingUITests` | |

## NOT executable in this environment — not claimed to pass

These are **not** written as passing tests. Do not treat them as covered.

| Area | Why not | How to verify |
|---|---|---|
| **Google sign-in, end to end** | No iOS OAuth client exists — `CLIENT_ID` absent from the plist. The flow cannot run at all. | Create the OAuth client (see `FIREBASE_SETUP.md`), then sign in on a simulator |
| **Google cancellation path** | Same — the sheet never opens | Manual, once the OAuth client exists |
| **Apple sign-in, end to end** | Needs the Sign in with Apple capability and a signed-in Apple ID; the system sheet cannot be driven headlessly | Manual on a device or a simulator with an Apple ID |
| **Apple first-time name capture** | Apple returns the name only on the *first* authorization, ever. Re-testing needs the app revoked in Apple ID settings first. | Manual, once |
| **Real anonymous sign-in through the app** | Verified against the live API by probe, but not driven through the UI with the SDK linked | Run the app; tap Continue as Guest |
| **Firestore bootstrap against real Firestore** | `ProfileBootstrapTests` covers the *contract* via an in-memory store. Firestore's transaction semantics are not exercised. | `firebase emulators:start --only firestore` and re-point the store |
| **Firestore rules** | No emulator run; rules are written but unverified | `firebase emulators:exec --only firestore` with rules tests |
| **Session restoration with real Firebase** | The auth-state listener path is not covered by tests | Manual: sign in, force-quit, relaunch |
| **Sign-out against real Firebase** | Same | Manual |

## ⚠️ Current regression — 5 UI tests fail

Before Firebase was linked: 9/9 UI tests passed.
After: **4/9 pass, 5 fail.** Not flakiness — a real, diagnosed break.

**Root cause: the Firestore database does not exist in `moomo-c7a37`.**
Probed directly against the live API:

    PERMISSION_DENIED — Cloud Firestore API has not been used in project
    moomo-c7a37 before or it is disabled

The chain: guest sign-in succeeds (anonymous auth works) → `bootstrap()` tries
to write `users/{uid}` → Firestore rejects it → bootstrap throws → the user is
never published → routing stays on Welcome → every UI test that expects to
reach onboarding fails.

The app is behaving correctly. It refuses to present a signed-in user whose
profile could not be loaded, because publishing a hollow user would bounce a
fully-onboarded person back through onboarding. The backend is simply not there
yet.

**Fix (console, one time):** Firebase console → Build → Firestore Database →
Create database → production mode. Then deploy the rules in
`backend/firestore.rules`, which are written but **not deployed**.

Until then the real backend cannot complete a sign-in, and the UI suite cannot
pass against it.

## The honest summary

Everything above the Firebase boundary is well covered, because it was built
against a protocol and a mock that behaves like the real thing.

**The Firebase implementations themselves have not been executed once.**
`FirebaseAuthenticationService` and `FirestoreProfileStore` compile and are
wired in, but no test drives them, and no provider flow has been run by a human
in this environment. They should be treated as unproven until someone runs the
app and signs in.
