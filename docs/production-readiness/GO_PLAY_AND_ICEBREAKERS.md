# Go Play and the date icebreakers

_Written 2026-08-28. Replaces `GO_PLAY_GLOW_TRAIL.md`, which described a
SpriteKit trail game that has been removed from the app in full._

Discover offers two chat modes, and they are two different products on top of
one transport. Both are tiles in the chat-modes row, and both start an
ordinary video call on the one matchmaking pool.

| | Video Match | Go Play |
|---|---|---|
| What it is | A plain 3-minute video date | The same call, with a game the pair choose together |
| Who starts the extra thing | Nobody — there is no extra thing | The two of them, from a picker |
| What's on screen | Video, the clock, the controls | Video, plus the picker or the chosen game |
| `CallExperience` | `.videoMatch` | `.goPlay` |

Neither collapses into the other. Video Match never shows the game picker and
nothing ever arrives over its video; Go Play never opens anything on its own
either — the pair ask for it.

> **Changed 2026-08-28 (later).** Video Match used to run the three date
> icebreakers by itself, on a schedule from the top of the call. It no longer
> does: `ActiveCallView.onAppear` schedules nothing, so the session never gets
> an origin and the overlay never draws. The prompts survive as a *game behind
> Go Play's picker* — one door, chosen by the pair. `scheduleFromCallStart()`
> is left on `DateIcebreakerSessionModel` (still unit-tested) but has no
> caller in the app.

## What was removed

Glow Trail — the SpriteKit board, the trail engine, the host simulation loop,
snapshots, lives, scores, rematch, the `baybe.glowtrail.v1` topic, and every
`GlowTrail*` type — is gone, along with its three test files and the
`-ui-testing-short-game` launch argument. What survived is the part that was
never about that game:

- `CallDataTransport` — the four-member send-bytes/receive-bytes view onto the
  room the call already has. Unchanged.
- `LiveKitGameTransport` — the implementation, now filtering on
  `CallGameWire.topic`.
- The backend's `canPublishData` grant in `media.ts`, scoped per room and
  dying with the call's token.

## The channel

One LiveKit data topic carries everything: **`baybe.callgames.v1`**.

Features are told apart by a required `channel` field inside each message
(`lobby` | `icebreakers`), not by a topic each. A decoder that sees another
channel's message drops it rather than half-reading it — `CallGameCodec` and
`DateIcebreakerCodec` each refuse the other's traffic, and a test asserts it in
both directions. Adding a game means adding a channel value, not a topic and
not a server change.

Nothing on this channel is ever rendered as user-authored text. Answers travel
as indices into fixed decks; the lobby carries lifecycle flags. Chat stays in
Firestore, where rules and moderation apply.

## The icebreakers (a Go Play game)

Three prompts, on a schedule once the pair start them from Go Play's picker,
in `app/Moomo/Features/DateIcebreakers/`. The cue times below are offsets from
the moment the run starts, not from the top of the call:

| Cue | Round |
|---|---|
| 0:25 | This or That — two choices, reveal says whether you matched |
| 1:05 | Red / Yellow / Green Flag — a scenario, reveal shows both answers plus something to talk about |
| 1:45 | Guess My Answer — phase one guesses theirs, phase two gives your own, then both reveal |
| 2:30 | "You two discovered…" — a short summary of what was actually answered |

**The clock is the call's.** `advance(to:)` is fed the seconds elapsed in the
call, which are recomputed from the server-set session start on both devices
(`CallFlowModel.elapsedSeconds`). Two phones reach round two together without
exchanging a word about it, and a phone that was suspended catches up rather
than drifting a round behind. There is no second timer anywhere in the feature.

**The deck is derived, not negotiated.** `IcebreakerDeck.prompts(forSessionID:)`
picks one card of each kind from the shared call session id, using a hand-written
FNV-1a — Swift's own `hashValue` is seeded per process and would give two
devices different prompts. The test pins the published FNV-1a vectors so a
"cleanup" cannot quietly reintroduce that bug.

### Commit then reveal

Both people answer at the same time and neither may see the other's answer
first. There is no server in the loop, so the guarantee is built into the
protocol:

1. A phone that has answered sends a **commit**: `SHA-256(roundID | answer | salt)`.
   It says "I have decided" and nothing about what was decided. The round id is
   inside the digest, so a commitment cannot be replayed onto another round;
   the salt is there because a three-option answer would otherwise be
   brute-forced from its digest in no time.
2. Only once the *other* side's commitment has arrived does a phone send its
   **reveal** — the answer plus the salt.
3. The receiver checks the reveal against the commitment it was promised
   earlier. A mismatch is dropped and never displayed.

The consequence: an answer's plaintext never leaves a device until the other
device has already locked its own answer in. A tampered client can send
garbage or nothing, but it cannot peek. A reveal that arrives before this side
has answered is parked, not applied — and if the clock runs the round out
first, it is never looked at at all.

### What it may not do

The overlay is a band across the bottom of the video card. It is never a
sheet, never full screen, and never pauses or shrinks the video. Mute, camera,
the safety menu, minimise, and End Call all stay exactly where they were —
asserted in the UI test, because a call you cannot leave without first
dismissing a card would be a safety problem, not a UI compromise.

### Known limitation: minimise mid-round

The sessions are `@StateObject`s on `ActiveCallView`, which lives inside a
`fullScreenCover`. Minimising the call destroys them, and returning builds
fresh ones. Because both the deck and the schedule are *derived* rather than
negotiated, the rebuilt session lands on the right prompt for the point the
call has reached — but a commitment the other side sent while we were away is
not replayed, so a round that was mid-handshake sits on "waiting for…" until
the next cue retires it as unanswered. The call is unaffected, and it
self-heals within one cue. Fixing it properly means hoisting the session above
the cover, which is a bigger change than the symptom is worth today.

## Go Play: the picker and the shared game architecture

`CallGame` (`Features/GoPlay/CallGameCatalog.swift`) is the list, and the only
place that knows which entries are real:

| Game | State |
|---|---|
| Icebreakers | Playable — started on demand, the only way in |
| Snake Clash | Listed, "Soon" |
| Ludo | Listed, "Soon" |
| Chase | Listed, "Soon" |
| Cards | Listed, "Soon" |

Unbuilt games stay on the list, dimmed and marked: a picker that hides its
roadmap tells the user nothing, and one that lets them pick an empty screen
wastes a call. `isPlayable` is enforced twice — the row is disabled, *and*
`propose(_:)` and the inbound invite handler both refuse — because a peer on a
newer build must not be able to open a screen this one cannot draw.

**Cards is not gambling.** No wager, no balance, no purchase, nothing with cash
value, and no copy that suggests any. A test greps the strings.

The handshake in `GoPlaySessionModel` is invite → accept/decline → exit, all
reliable, all deduplicated by `(sessionID, kind, sequence)`. Opening the picker
sends nothing — browsing is not an offer. Simultaneous proposals resolve by the
lower participant identity, a rule both devices evaluate from the same two
strings with no extra round trip. An unanswered proposal is withdrawn after 30
seconds rather than spinning forever.

Adding Snake Clash later means: flip `isPlayable`, add a view, and render it
off `activeGame`. The invite/accept/decline handshake, the duplicate handling,
the timeouts, the leaving, and the peer-left handling are already here and
already tested.

## Media is never touched

The guarantee both features rest on: **starting, playing, and leaving anything
drawn over a call performs no media operation.** No join, no leave, no
republish, no renegotiation. Nothing above `CallMediaService` ever holds a
LiveKit `Room` — that is structural, not a matter of discipline.

`CallGameLobbyTests.testNothingInTheLobbyOrTheGamesEverJoinsOrLeavesTheRoom`
drives a whole game's life against `MockCallMediaService` and asserts
`joinCount == 1, leaveCount == 0` at the end. A companion test asserts the
transport is subscribed once, not per state change — a feature that
re-subscribes on every transition is one refactor away from doing the same to
the room.

## Matchmaking: one pool, deliberately

**Go Play and Video Match share a single matchmaking pool.** `CallExperience`
is a client-side distinction; `joinMatchmakingQueue` still pairs on `mode`
alone, so a Go Play caller can be matched with a Video Match one. Both then get
a working call — the Go Play side simply sees the picker.

This was a decision, not an oversight. Splitting the pool means an extra
dimension on the queue query (a composite index change) inside a deployed,
transactional pairing path that also fans out ring invites — and it halves an
already-thin pool for a product that is waiting on App Store review. A thin
pool split in two matches nobody.

If the pool is ever split, the changes are: carry `experience` on the queue
entry in `matchmaking.ts`, add it to the `.where("mode", "==", mode)` query and
the preferred-peer check, add the composite index, thread it through
`CallService.findCandidate`, and update `matchmaking.integration.test.mjs`. The
client already carries the value end to end.

## Where things live

```
app/Moomo/Features/GoPlay/
  CallGameCatalog.swift          the list, and CallGameSeat
  CallGameWire.swift             topic, channel tag, lobby messages, codec
  GoPlaySessionModel.swift       the lobby: propose / accept / decline / leave
  GoPlayPickerView.swift         the picker card and the invitation card
  SimulatedCallGamePartner.swift DEBUG stand-in, both channels

app/Moomo/Features/DateIcebreakers/
  DateIcebreakerModels.swift     decks, submissions, outcomes, schedule
  DateIcebreakerWire.swift       commit/reveal protocol and the digest
  DateIcebreakerSessionModel.swift  the choreography
  DateIcebreakerOverlay.swift    the bottom card

app/MoomoTests/
  DateIcebreakerWireTests.swift     25 — codec, channels, commitments, decks
  DateIcebreakerSessionTests.swift  26 — privacy, reveal, auto-advance, summary
  CallGameLobbyTests.swift          19 — experiences, catalogue, handshake, media
```

## Suites at the time of writing

- iOS unit: **322 passed, 0 failed**
- iOS UI (the four rewritten call tests): **4 passed**
- Backend: **185 passed**, `tsc --noEmit` clean

No backend deploy is required by this change: `media.ts` was touched for
comments only, and the `canPublishData` grant it describes is already live.
