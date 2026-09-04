import Foundation

/// Date icebreakers — the three small prompts a pair can start from Go Play's
/// picker while they are already talking.
///
/// The shape of the feature is the point: nobody came to a video date to play
/// a game, so this never takes the screen, never pauses the video, and never
/// asks for more than one tap. Three prompts arrive on a schedule, both people
/// answer at the same time without seeing each other's answer, and the card
/// flips.
///
/// This file is the vocabulary only: prompt decks, submissions, outcomes, the
/// schedule. The privacy machinery lives in `DateIcebreakerWire`, the
/// choreography in `DateIcebreakerSessionModel`, and the pixels in
/// `DateIcebreakerOverlay`. Nothing here imports SwiftUI or LiveKit — the
/// model layer is testable with no simulator and no room.

// MARK: - Prompts

enum IcebreakerRoundKind: String, Codable, Sendable, CaseIterable {
    /// Two choices. The reveal says whether you picked the same one.
    case thisOrThat
    /// A scenario, answered red / yellow / green. The reveal shows both
    /// answers and something to talk about.
    case flag
    /// Two phases: guess what they will say, then say your own.
    case guessMyAnswer
}

/// One card's worth of content. `options` is a fixed order both devices
/// share, so an answer can travel as an index rather than as text — which is
/// also why nothing on this channel is ever user-authored.
struct IcebreakerPrompt: Equatable, Sendable, Identifiable {
    var id: String
    var kind: IcebreakerRoundKind
    /// The question, as it reads on the card.
    var title: String
    var options: [String]
    /// A line to leave under the reveal, to give the next minute of
    /// conversation somewhere to go.
    var discussion: String

    func option(_ index: Int) -> String {
        options.indices.contains(index) ? options[index] : "—"
    }

    func isValidChoice(_ index: Int) -> Bool { options.indices.contains(index) }
}

/// The three flag answers, in the order they appear on every flag card.
enum IcebreakerFlag: Int, CaseIterable, Sendable {
    case red
    case yellow
    case green

    var label: String {
        switch self {
        case .red: "Red flag"
        case .yellow: "Yellow flag"
        case .green: "Green flag"
        }
    }
}

/// What a phone sends once, in secret, and reveals once the other has locked
/// theirs in too.
struct IcebreakerSubmission: Equatable, Codable, Sendable {
    /// Index into the prompt's options — my own answer.
    var choice: Int
    /// Guess My Answer only: which option I think *they* picked.
    var guess: Int?

    init(choice: Int, guess: Int? = nil) {
        self.choice = choice
        self.guess = guess
    }

    /// The exact bytes a commitment is taken over. Written by hand rather
    /// than left to `JSONEncoder` because a digest is only worth anything if
    /// both devices agree, byte for byte, on what was hashed — and key order
    /// in encoded JSON is not a promise either side should be relying on.
    var canonicalForm: String {
        "\(choice)|\(guess.map(String.init) ?? "-")"
    }
}

// MARK: - Outcomes

/// What the card says once it flips.
struct IcebreakerOutcome: Equatable, Sendable {
    var headline: String
    var detail: String
    /// Whether the two answers landed in the same place. Drives the summary
    /// count, and nothing else — a difference is not a failure here.
    var isAgreement: Bool
    /// Guess My Answer only.
    var localGuessedRight: Bool?
    var peerGuessedRight: Bool?

    /// Reads two revealed submissions against the prompt they answered.
    static func make(
        prompt: IcebreakerPrompt,
        local: IcebreakerSubmission,
        peer: IcebreakerSubmission,
        peerName: String
    ) -> IcebreakerOutcome {
        let agreed = local.choice == peer.choice
        switch prompt.kind {
        case .thisOrThat:
            return IcebreakerOutcome(
                headline: agreed
                    ? "You both said \(prompt.option(local.choice))"
                    : "You said \(prompt.option(local.choice)) — \(peerName) said \(prompt.option(peer.choice))",
                detail: agreed ? prompt.discussion : "Different picks. \(prompt.discussion)",
                isAgreement: agreed
            )

        case .flag:
            return IcebreakerOutcome(
                headline: "You: \(prompt.option(local.choice)) · \(peerName): \(prompt.option(peer.choice))",
                detail: agreed
                    ? "You read that the same way. \(prompt.discussion)"
                    : "You read that differently — worth a minute on why. \(prompt.discussion)",
                isAgreement: agreed
            )

        case .guessMyAnswer:
            // Each guess is checked against the *other* person's own answer.
            let localRight = local.guess == peer.choice
            let peerRight = peer.guess == local.choice
            let headline: String
            switch (localRight, peerRight) {
            case (true, true): headline = "You both called it"
            case (true, false): headline = "You called it — \(peerName) didn't"
            case (false, true): headline = "\(peerName) called it — you didn't"
            case (false, false): headline = "Neither of you saw that coming"
            }
            return IcebreakerOutcome(
                headline: headline,
                detail: "You said \(prompt.option(local.choice)); "
                    + "\(peerName) said \(prompt.option(peer.choice)). \(prompt.discussion)",
                isAgreement: agreed,
                localGuessedRight: localRight,
                peerGuessedRight: peerRight
            )
        }
    }
}

// MARK: - Rounds

/// One prompt's life, from the moment it appears to the moment it flips.
struct IcebreakerRound: Equatable, Sendable, Identifiable {

    enum Phase: Equatable, Sendable {
        /// Guess My Answer, part one: what will *they* say?
        case guessingPeer
        /// Pick your own answer.
        case answering
        /// Locked in; theirs hasn't arrived yet.
        case waitingForPeer
        /// Both answers are on the table.
        case revealed
        /// The clock moved on before both sides answered. Honest, and never
        /// blamed on anybody.
        case unanswered
    }

    let id: String
    let index: Int
    let prompt: IcebreakerPrompt
    var phase: Phase
    /// Our own submission, once made. Never leaves the device before their
    /// commitment arrives — see `DateIcebreakerWire`.
    var local: IcebreakerSubmission?
    /// Theirs, once revealed and verified against their commitment. Nil until
    /// then, which is the entire privacy guarantee stated as a type.
    var peer: IcebreakerSubmission?
    /// Guess My Answer: the part-one answer, held while part two is picked.
    var stagedGuess: Int?
    var outcome: IcebreakerOutcome?

    init(id: String, index: Int, prompt: IcebreakerPrompt) {
        self.id = id
        self.index = index
        self.prompt = prompt
        self.phase = prompt.kind == .guessMyAnswer ? .guessingPeer : .answering
    }

    /// Whether a tap on an option means anything right now.
    var isAcceptingInput: Bool {
        phase == .guessingPeer || phase == .answering
    }

    /// The question as currently posed — Guess My Answer asks two different
    /// things off one prompt.
    func headline(peerName: String) -> String {
        switch phase {
        case .guessingPeer:
            return "What will \(peerName) say?"
        case .answering where prompt.kind == .guessMyAnswer:
            return "Now your answer"
        default:
            return prompt.title
        }
    }
}

// MARK: - Summary

/// The small "You two discovered…" card at the end of the run.
struct IcebreakerSummary: Equatable, Sendable {
    var lines: [String]
    /// How many of the answered rounds landed in the same place.
    var agreements: Int
    var answeredRounds: Int

    var isEmpty: Bool { lines.isEmpty }

    /// Built from whatever actually got answered. Rounds nobody completed are
    /// left out rather than reported as a miss.
    static func make(from rounds: [IcebreakerRound], peerName: String) -> IcebreakerSummary {
        let revealed = rounds.filter { $0.phase == .revealed }
        let lines = revealed.compactMap { round -> String? in
            guard let local = round.local, let peer = round.peer else { return nil }
            switch round.prompt.kind {
            case .thisOrThat:
                return local.choice == peer.choice
                    ? "You both chose \(round.prompt.option(local.choice))"
                    : "\(round.prompt.option(local.choice)) vs \(round.prompt.option(peer.choice))"
            case .flag:
                return local.choice == peer.choice
                    ? "Same read on \(round.prompt.option(local.choice).lowercased())"
                    : "You saw that one differently"
            case .guessMyAnswer:
                return local.guess == peer.choice
                    ? "You already read \(peerName) well"
                    : "\(peerName) still has some surprises"
            }
        }
        return IcebreakerSummary(
            lines: lines,
            agreements: revealed.filter { $0.outcome?.isAgreement == true }.count,
            answeredRounds: revealed.count
        )
    }
}

// MARK: - Schedule

/// When the three prompts arrive, and when the summary does.
///
/// The numbers are minutes-into-a-three-minute-call, chosen so the first
/// prompt lands after the opening hellos rather than on top of them, and the
/// last one is finished with time left to talk about it.
struct IcebreakerSchedule: Equatable, Sendable {
    /// Seconds into the call at which each round opens.
    var cues: [TimeInterval]
    /// Seconds into the call at which the summary card appears.
    var summaryAt: TimeInterval
    /// How long the summary stays before the screen goes back to being just
    /// a call.
    var summaryDuration: TimeInterval = 20

    static let standard = IcebreakerSchedule(
        cues: [25, 65, 105],
        summaryAt: 150
    )

    /// A compressed run so a UI test can watch all three rounds and the
    /// summary without sitting through most of a call.
    static let uiTesting = IcebreakerSchedule(
        cues: [3, 11, 19],
        summaryAt: 27,
        summaryDuration: 20
    )

    static var current: IcebreakerSchedule {
        ProcessInfo.processInfo.arguments.contains("-ui-testing-fast-icebreakers")
            ? .uiTesting
            : .standard
    }
}

// MARK: - Decks

/// The prompt decks, and the rule that picks one card from each.
///
/// Selection is deterministic from the call session id: both phones run the
/// same arithmetic over the same string and land on the same three prompts,
/// with no negotiation to lose and no round trip to wait for. The hash is
/// written out by hand because Swift's own `hashValue` is seeded per process
/// — two devices would disagree, which is exactly the bug that would only
/// ever show up on real hardware.
enum IcebreakerDeck {

    static let thisOrThat: [IcebreakerPrompt] = [
        .init(
            id: "tot-morning-night", kind: .thisOrThat,
            title: "Pick one", options: ["Early mornings", "Late nights"],
            discussion: "Ask what their best one looked like."
        ),
        .init(
            id: "tot-beach-mountains", kind: .thisOrThat,
            title: "Where are we going?", options: ["Beach", "Mountains"],
            discussion: "Find out what they'd actually do all day there."
        ),
        .init(
            id: "tot-plan-wing", kind: .thisOrThat,
            title: "A free weekend", options: ["Planned to the hour", "Wing it"],
            discussion: "Whichever one you're not, ask how that goes for them."
        ),
        .init(
            id: "tot-cook-out", kind: .thisOrThat,
            title: "Saturday dinner", options: ["Cook together", "Go out"],
            discussion: "There's a signature dish story in here somewhere."
        ),
        .init(
            id: "tot-cat-dog", kind: .thisOrThat,
            title: "Be honest", options: ["Cat person", "Dog person"],
            discussion: "Ask for the photo. There is always a photo."
        ),
        .init(
            id: "tot-text-call", kind: .thisOrThat,
            title: "Getting to know someone", options: ["Text all day", "One long call"],
            discussion: "Useful to know before tomorrow, really."
        ),
    ]

    static let flags: [IcebreakerPrompt] = [
        .init(
            id: "flag-phone-dinner", kind: .flag,
            title: "They check their phone through most of dinner.",
            options: IcebreakerFlag.allCases.map(\.label),
            discussion: "Say where your own line is."
        ),
        .init(
            id: "flag-ex-story", kind: .flag,
            title: "Their ex comes up three times in the first hour.",
            options: IcebreakerFlag.allCases.map(\.label),
            discussion: "Context changes this one a lot — compare notes."
        ),
        .init(
            id: "flag-friends-early", kind: .flag,
            title: "They want you to meet their friends in week one.",
            options: IcebreakerFlag.allCases.map(\.label),
            discussion: "Fast for one person is normal for another."
        ),
        .init(
            id: "flag-splits-bill", kind: .flag,
            title: "They quietly sort the bill before you notice.",
            options: IcebreakerFlag.allCases.map(\.label),
            discussion: "Worth saying how you'd rather handle it."
        ),
        .init(
            id: "flag-late-reply", kind: .flag,
            title: "They take a day to reply, every time.",
            options: IcebreakerFlag.allCases.map(\.label),
            discussion: "Talk about what a good pace actually feels like."
        ),
        .init(
            id: "flag-cancels-late", kind: .flag,
            title: "They cancel an hour before, twice.",
            options: IcebreakerFlag.allCases.map(\.label),
            discussion: "Ask what a good apology looks like to them."
        ),
    ]

    static let guessMyAnswer: [IcebreakerPrompt] = [
        .init(
            id: "gma-perfect-sunday", kind: .guessMyAnswer,
            title: "My perfect Sunday is mostly…",
            options: ["Outside", "On the sofa", "Out with people"],
            discussion: "Then argue about which one is objectively correct."
        ),
        .init(
            id: "gma-first-date", kind: .guessMyAnswer,
            title: "My ideal first date is…",
            options: ["Coffee and a walk", "Dinner somewhere good", "Something with a plan"],
            discussion: "You've now both said it out loud, so."
        ),
        .init(
            id: "gma-travel", kind: .guessMyAnswer,
            title: "Given a free ticket, I'd go…",
            options: ["Somewhere warm", "Somewhere far", "Somewhere I know"],
            discussion: "Ask for the last trip that actually surprised them."
        ),
        .init(
            id: "gma-energy", kind: .guessMyAnswer,
            title: "After a long week I…",
            options: ["Go quiet", "See everyone", "Get moving"],
            discussion: "Handy to know for a Friday."
        ),
        .init(
            id: "gma-fear", kind: .guessMyAnswer,
            title: "The thing I'd never do…",
            options: ["Skydive", "Karaoke", "Eat anything spicy"],
            discussion: "Somebody is bluffing here."
        ),
    ]

    /// The three prompts for one call, in the order they will be played:
    /// This or That, then a flag, then Guess My Answer.
    static func prompts(forSessionID sessionID: String) -> [IcebreakerPrompt] {
        let seed = fnv1a(sessionID)
        return [
            pick(from: thisOrThat, seed: seed &+ 1),
            pick(from: flags, seed: seed &+ 2),
            pick(from: guessMyAnswer, seed: seed &+ 3),
        ]
    }

    private static func pick(from deck: [IcebreakerPrompt], seed: UInt64) -> IcebreakerPrompt {
        deck[Int(seed % UInt64(deck.count))]
    }

    /// FNV-1a, 64-bit. Stable across processes, devices, and OS versions —
    /// which is the only property being asked of it.
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
