import Foundation

// MARK: - Identity

/// How an account was created. Guests can later link to a real provider,
/// which upgrades the account in place and keeps the uid.
enum AuthProvider: String, Codable, Sendable, CaseIterable {
    case apple
    case google
    case guest
}

/// Consent, recorded so we can prove what was agreed to and when.
///
/// Version is stored, not just a boolean: when the policy changes, we need to
/// know who agreed to which text, and re-prompt those who haven't seen the
/// current one.
struct ConsentRecord: Codable, Equatable, Sendable {
    var acceptedAt: Date
    var documentVersion: String

    /// Bump on every published change to the Privacy Policy or Terms.
    static let currentVersion = "2026-07-15"

    static func now() -> ConsentRecord {
        ConsentRecord(acceptedAt: Date(), documentVersion: currentVersion)
    }

    var isCurrent: Bool { documentVersion == Self.currentVersion }
}

// MARK: - Profile enums

enum Gender: String, Codable, Sendable, CaseIterable, Identifiable {
    case woman
    case man
    case nonBinary
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .woman: "Woman"
        case .man: "Man"
        case .nonBinary: "Non-binary"
        case .other: "Other"
        }
    }
}

/// Who a user wants to be matched with. Multi-select.
enum InterestedIn: String, Codable, Sendable, CaseIterable, Identifiable {
    case women
    case men
    case everyone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .women: "Women"
        case .men: "Men"
        case .everyone: "Everyone"
        }
    }
}

/// City-level location only.
///
/// There is deliberately no latitude/longitude anywhere in this model. Precise
/// coordinates are never collected, stored, or transmitted — a dating app that
/// leaks them puts people in physical danger, and the safest way to guarantee
/// that is to have nowhere to put them.
struct CityLocation: Codable, Equatable, Sendable {
    var city: String
    var region: String?
    var countryCode: String

    var display: String {
        [city, region, countryName].compactMap { $0 }.joined(separator: ", ")
    }

    /// Reference profile shows "New York, USA".
    var shortDisplay: String {
        [city, countryName].compactMap { $0 }.joined(separator: ", ")
    }

    private var countryName: String? {
        Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode
    }
}

/// A profile photo that has been uploaded.
struct ProfilePhoto: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// Remote path. Nil while the photo is still local-only (mock mode, or
    /// queued for upload).
    var remotePath: String?
    var order: Int
}

// MARK: - Profile

/// A user's dating profile. This is the single definition — view models hold a
/// reference to it, never their own copy of its fields.
struct Profile: Codable, Equatable, Sendable {
    var displayName: String = ""
    var dateOfBirth: Date?
    var gender: Gender?
    var interestedIn: Set<InterestedIn> = []
    var location: CityLocation?
    var photos: [ProfilePhoto] = []
    var bio: String = ""
    var interests: Set<String> = []
    var isVerified: Bool = false
    var school: String?

    /// Age in whole years. Nil if no date of birth.
    var age: Int? {
        guard let dateOfBirth else { return nil }
        return Calendar.current.dateComponents([.year], from: dateOfBirth, to: Date()).year
    }
}

// MARK: - Age

/// The 18+ gate.
///
/// Kept as a free function on the model rather than inside a view so it can be
/// unit-tested and reused by the server without dragging UI along.
enum AgeGate {
    static let minimumAge = 18

    /// The latest date of birth that still clears the gate, as of `now`.
    static func latestAllowedBirthDate(now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .year, value: -minimumAge, to: now) ?? now
    }

    /// The earliest date of birth we accept at all. Guards against typos and
    /// nonsense values rather than making a claim about longevity.
    static func earliestAllowedBirthDate(now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .year, value: -120, to: now) ?? now
    }

    static func age(for birthDate: Date, now: Date = Date()) -> Int {
        Calendar.current.dateComponents([.year], from: birthDate, to: now).year ?? 0
    }

    /// Whole-years-elapsed check. Someone whose 18th birthday is today passes;
    /// tomorrow's does not.
    static func isOldEnough(birthDate: Date, now: Date = Date()) -> Bool {
        age(for: birthDate, now: now) >= minimumAge
    }

    static func validate(birthDate: Date, now: Date = Date()) -> AgeGateResult {
        if birthDate > now { return .invalid(.inFuture) }
        if birthDate < earliestAllowedBirthDate(now: now) { return .invalid(.implausible) }
        if !isOldEnough(birthDate: birthDate, now: now) { return .invalid(.underage) }
        return .valid
    }
}

enum AgeGateResult: Equatable {
    case valid
    case invalid(AgeGateFailure)
}

enum AgeGateFailure: Equatable {
    case underage
    case inFuture
    case implausible

    var message: String {
        switch self {
        case .underage: "You must be 18 or older to use Moomo."
        case .inFuture: "That date is in the future."
        case .implausible: "Please enter a valid date of birth."
        }
    }
}

// MARK: - User

/// An authenticated account plus its profile.
struct User: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var authProvider: AuthProvider
    var consent: ConsentRecord?
    var profile: Profile
    var createdAt: Date
    /// Set when onboarding has been completed end to end.
    var onboardingCompletedAt: Date?

    var isGuest: Bool { authProvider == .guest }

    /// Whether this account may enter the main app.
    ///
    /// Onboarding completion alone isn't enough: consent must exist and be
    /// current, and the profile must still satisfy the required fields. An
    /// account that completed onboarding under an older policy is sent back to
    /// re-consent rather than waved through.
    var hasValidProfileState: Bool {
        guard let consent, consent.isCurrent else { return false }
        guard onboardingCompletedAt != nil else { return false }
        return ProfileRequirements.missingFields(in: profile, isGuest: isGuest).isEmpty
    }
}

// MARK: - Completion

/// What a profile needs, and how complete it is.
enum ProfileRequirements {

    /// Fields required before entering the app. Guests are held to a smaller
    /// bar — they get a minimal temporary profile — but the age gate and a
    /// name are never optional for anyone.
    static func missingFields(in profile: Profile, isGuest: Bool) -> [ProfileField] {
        var missing: [ProfileField] = []

        if profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(.name)
        }
        if profile.dateOfBirth.map({ !AgeGate.isOldEnough(birthDate: $0) }) ?? true {
            missing.append(.dateOfBirth)
        }
        if profile.gender == nil { missing.append(.gender) }
        if profile.interestedIn.isEmpty { missing.append(.interestedIn) }

        if !isGuest {
            if profile.location == nil { missing.append(.location) }
            if profile.photos.isEmpty { missing.append(.photos) }
        }

        return missing
    }

    /// Weighted completion, as shown on the profile screen ("85% Profile
    /// Complete"). Required fields carry more weight than embellishments.
    static func completionPercentage(for profile: Profile, isGuest: Bool) -> Int {
        let checks: [(done: Bool, weight: Double)] = [
            (!profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, 15),
            (profile.dateOfBirth != nil, 15),
            (profile.gender != nil, 10),
            (!profile.interestedIn.isEmpty, 10),
            (profile.location != nil, 10),
            (!profile.photos.isEmpty, 20),
            (profile.photos.count >= 3, 5),
            (!profile.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, 10),
            (profile.interests.count >= 3, 5)
        ]

        let earned = checks.filter(\.done).map(\.weight).reduce(0, +)
        let total = checks.map(\.weight).reduce(0, +)
        guard total > 0 else { return 0 }
        return Int((earned / total * 100).rounded())
    }
}

enum ProfileField: String, CaseIterable {
    case name
    case dateOfBirth
    case gender
    case interestedIn
    case location
    case photos

    var label: String {
        switch self {
        case .name: "Name"
        case .dateOfBirth: "Date of birth"
        case .gender: "Gender"
        case .interestedIn: "Who you want to meet"
        case .location: "Location"
        case .photos: "Photos"
        }
    }
}
