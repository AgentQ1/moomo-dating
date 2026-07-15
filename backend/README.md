# Moomo backend

**Nothing here has been deployed.**

## Firestore rules

`firestore.rules` — initial, deny-by-default. Covers only what the current app
spine needs:

- `users/{uid}` — private account data, owner-only read/write.
- `users/{uid}/private/onboarding` — the resumable draft, owner-only.
- `publicProfiles/{uid}` — currently owner-only too. **Not opened to other
  signed-in users yet**: Discover runs on local mock data, so nothing needs it,
  and opening it before blocks and rate limiting exist would expose every
  profile to any account.

Everything else falls through to `allow read, write: if false`.

## Before deploying

The active project **must** be `moomo-c7a37`. `moomoios-2026` is the Moomo AI
app and must never receive these rules.

```sh
firebase use --project moomo-c7a37
firebase deploy --only firestore:rules --project moomo-c7a37
```

Test them first — deploying rules unverified is how a dating app leaks profiles:

```sh
firebase emulators:start --only firestore
```

## Cloud Functions

None written. Not deployed.
