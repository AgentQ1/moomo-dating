# App Review notes — paste-ready material

_Written 2026-07-22 during the release-readiness audit. Everything below is
code-verified (file:line cited) except the two items marked CONSOLE. Paste the
"Review notes" section into App Store Connect → App Review Information, filling
in the demo phone number._

## Review notes (paste into ASC)

> Baybe is an 18+ dating app built around short (3-minute, server-capped)
> video and voice calls between mutually compatible, phone-verified users.
> (Store name: Baybe, ASC app 6793496424; bundle ID com.moomo.dating and the
> internal project name "Moomo" are historical and not user-visible.)
> It is not anonymous or random video chat:
>
> - Every account requires SMS phone verification — there is no anonymous,
>   guest, or social login. Restored sessions without a verified phone number
>   are signed out.
> - Users are 18+: date of birth is required during onboarding and the
>   server's security rules reject any under-18 date of birth.
> - Calls are never random-with-strangers: pairing requires both users'
>   stated gender preferences to accept each other, and the peer's profile
>   (photo, name, age, city) is shown before video connects and stays
>   on screen during the call.
> - Every participant can be reported or blocked during the call and on the
>   decision screen afterwards. Blocking is server-side and mutual: the pair
>   can never be matched or paired again, and any live call between them is
>   ended immediately.
> - Call length is set by the server at 180 seconds and the media token
>   expires with the call clock, so no client can extend a call. Calls are
>   never recorded.
> - Chat opens only after both users independently choose "like" after a
>   call; a "pass" is never revealed to the other person.
> - Community-guideline acceptance (no harassment, hate, or nudity —
>   violations end in removal) is a mandatory onboarding step.
>
> DEMO ACCOUNT: sign in with phone number +1 (650) 555-1234 and SMS code
> 123456. This is a Firebase test number — no real SMS is sent. Spares:
> +1 (650) 555-5678 / 222222 and +1 (650) 555-9876 / 333333.
>
> _2026-07-22: the notes above (with live legal URLs and the 1.2 safety
> summary) were entered into ASC App Review Information via the API, and the
> demo sign-in was exercised end-to-end on a simulator with a registered App
> Check debug token._

## Evidence map (for whoever fields reviewer questions)

| Claim | Evidence |
|---|---|
| Phone-only auth, no social login | `app/Moomo/Models/Profile.swift:5-12` (single `phone` AuthProvider); `FirebaseAuthenticationService.swift:147-151` (anonymous/no-phone sessions force-signed-out); regression guard `MoomoLiveUITests/LiveWelcomeUITests.swift:79-80` asserts no Google/Apple buttons |
| 18+ gate, server-backstopped | `app/Moomo/Models/Profile.swift:149-178` (AgeGate min 18); `backend/firestore.rules:58-63` (under-18 DOB rejected server-side); `firestore.rules:206-207` (public age must be 18–120 int) |
| Mutual-compatibility pairing | `backend/functions/src/compatibility.ts:37-39`; blocked pairs refused both directions `matchmaking.ts:296-302` |
| Peer identity before/during call | `CallSearchViews.swift:70-97` (pre-media profile); `ActiveCallView.swift:196-220` (persistent overlay) |
| 3-minute server cap | `backend/functions/src/shared.ts:17` (180s); `media.ts:61-96` (token dies with clock + 90s grace) |
| Report + block everywhere | In-call `ActiveCallView.swift:99-103`; post-call `CallDecisionViews.swift:64-84`; chat `ChatDetailView.swift:212-223`; matches `MatchesView.swift:163-188`; blocked-list management `SafetySettingsView.swift:64-124` |
| Private decisions | `backend/functions/src/decisions.ts:8-9,170-205`; rules close decisions to both participants `firestore.rules:307-313` |
| Community guidelines gate | `PermissionAndSafetySteps.swift:96-135`; enforced `OnboardingModel.swift:354-355` |
| Account deletion (5.1.1(v)) | In-app: `ProfileView.swift:180-187` + confirmation `:53-64`; server deletes everything incl. Auth user `backend/functions/src/account.ts:25-80` |

## Do NOT claim in review notes or store copy

- **Photo/ID verification** — the `isVerified` badge exists in UI but nothing
  server-side ever grants it (`discovery.ts:103-104`); phone verification is
  the honest claim.
- **"Reports are reviewed within X hours"** — until the moderation queue is
  actually staffed with an SLA, don't put a number in writing.
- **"Published on the App Store" / user counts** — no load-test evidence for
  50k concurrent (LOAD_TEST_PLAN.md gate still open).

## CONSOLE items to complete before submitting

1. Read the test phone numbers from Firebase Console → Authentication →
   Sign-in method → Phone → Phone numbers for testing (3 exist; one uses
   OTP 123456) and put one in the review notes. Verify it signs in on a
   TestFlight build (App Check enforced — the 2026-07-22 debug-token incident
   showed unregistered installs fail).
2. App Store Connect: age rating 18+ (dating), App Privacy labels from
   PrivacyInfo.xcprivacy (phone, name, photos, sensitive info, other user
   content, user ID, coarse location, other data types (DOB); linked, no
   tracking, NO email), privacy policy URL (must be live), support URL.
