import Foundation

// MARK: - Identity

/// How an account was created. Phone OTP is the only sign-in method: every
/// account is backed by a verified phone number. Legacy provider strings in
/// old documents ("guest", "apple", "google") decode as `.phone` via
/// `FirestoreProfileStore`'s fallback; restored sessions without a verified
/// number are signed out by `FirebaseAuthenticationService`, never resumed.
enum AuthProvider: String, Codable, Sendable, CaseIterable {
    case phone
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

/// What someone is on Baybe for.
///
/// This is a *filter*, not decoration: `MatchPreferences` refuses to pair two
/// people whose intentions cannot overlap, and the server enforces the same
/// table (see `backend/functions/src/compatibility.ts`). Someone looking for a
/// life partner is never paired with someone looking for a short-term fling.
enum DatingIntention: String, Codable, Sendable, CaseIterable, Identifiable {
    case lifePartner
    case longTerm
    case longTermOpenToShort
    case shortTermOpenToLong
    case shortTerm
    case figuringItOut

    var id: String { rawValue }

    /// Full wording, for the picker and the profile.
    var label: String {
        switch self {
        case .lifePartner: "Life partner"
        case .longTerm: "Long-term relationship"
        case .longTermOpenToShort: "Long-term, open to short"
        case .shortTermOpenToLong: "Short-term, open to long"
        case .shortTerm: "Short-term fun"
        case .figuringItOut: "Still figuring it out"
        }
    }

    /// The short form the Discover bar can fit beside a city name.
    var compactLabel: String {
        switch self {
        case .lifePartner: "Life partner"
        case .longTerm: "Long-term"
        case .longTermOpenToShort: "Mostly long-term"
        case .shortTermOpenToLong: "Mostly short-term"
        case .shortTerm: "Short-term"
        case .figuringItOut: "Figuring it out"
        }
    }

    /// One line of "what this actually means", so the choice is informed
    /// rather than guessed at.
    var detail: String {
        switch self {
        case .lifePartner: "Looking for the one."
        case .longTerm: "Something serious, without naming the endpoint."
        case .longTermOpenToShort: "Serious first, but not ruling anything out."
        case .shortTermOpenToLong: "Casual first, but it could grow."
        case .shortTerm: "Something light, right now."
        case .figuringItOut: "Open to meeting people and seeing."
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

    /// "Chicago, IL" — the Discover location bar's form. Prefers the region
    /// code because that is what the reference shows; falls back to the
    /// country for places we hold no region for ("London, United Kingdom").
    var compactDisplay: String {
        [city, region ?? countryName].compactMap { $0 }.joined(separator: ", ")
    }

    private var countryName: String? {
        Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode
    }
}

/// A profile photo that has been uploaded.
///
/// `remotePath` is deliberately **not** optional. A `ProfilePhoto` may only
/// exist once its bytes are stored, so holding one is proof the upload
/// succeeded. In-flight and failed uploads are represented separately, by
/// `PhotoUploadQueue.Item`, and never enter the profile.
///
/// This is what stops the class of bug where onboarding completes with photos
/// the server has never seen: "has at least one photo" and "has at least one
/// uploaded photo" are now the same statement, and no validation rule has to
/// remember the difference.
struct ProfilePhoto: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// Storage path, e.g. `users/{uid}/photos/{id}.jpg`. Never a download URL:
    /// those carry a token that rotates, and a rotated token would silently
    /// break every photo already written to Firestore.
    var remotePath: String
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
    /// Nil on accounts from before intentions existed. Treated as "open to
    /// anything" by the matching table, never as a reason to pair with nobody.
    var datingIntention: DatingIntention?
    var location: CityLocation?
    var photos: [ProfilePhoto] = []
    var bio: String = ""
    var interests: Set<String> = []
    var isVerified: Bool = false

    /// Age in whole years. Nil if no date of birth.
    var age: Int? {
        guard let dateOfBirth else { return nil }
        return Calendar.current.dateComponents([.year], from: dateOfBirth, to: Date()).year
    }

    /// Storage path of the main photo — the lowest `order`, matching what the
    /// public projection publishes as `photoPaths[0]`.
    var primaryPhotoPath: String? {
        photos.min(by: { $0.order < $1.order })?.remotePath
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
        case .underage: "You must be 18 or older to use Baybe."
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
    /// The verified phone number in E.164, straight from the auth backend —
    /// never persisted to the profile document. Every live session has one:
    /// phone OTP is the only sign-in method.
    var phoneNumber: String?

    /// Whether consent is recorded and current.
    ///
    /// Split out from `hasValidProfileState` because the two failures need
    /// different destinations: a missing field means "resume onboarding", but
    /// missing consent means "go back to welcome and consent". Onboarding
    /// cannot fix consent — it has no step for it — so conflating them is what
    /// soft-locked accounts whose document was created without consent.
    var hasRecordedCurrentConsent: Bool {
        consent?.isCurrent == true
    }

    /// Whether this account may enter the main app.
    ///
    /// Onboarding completion alone isn't enough: consent must exist and be
    /// current, and the profile must still satisfy the required fields. An
    /// account that completed onboarding under an older policy is sent back to
    /// re-consent rather than waved through.
    var hasValidProfileState: Bool {
        guard hasRecordedCurrentConsent else { return false }
        guard onboardingCompletedAt != nil else { return false }
        return ProfileRequirements.missingFields(in: profile).isEmpty
    }
}

// MARK: - Completion

/// What a profile needs, and how complete it is.
enum ProfileRequirements {

    /// Fields required before entering the app.
    static func missingFields(in profile: Profile) -> [ProfileField] {
        var missing: [ProfileField] = []

        if profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(.name)
        }
        if profile.dateOfBirth.map({ !AgeGate.isOldEnough(birthDate: $0) }) ?? true {
            missing.append(.dateOfBirth)
        }
        if profile.gender == nil { missing.append(.gender) }
        if profile.interestedIn.isEmpty { missing.append(.interestedIn) }
        if profile.location == nil { missing.append(.location) }
        if profile.photos.isEmpty { missing.append(.photos) }

        return missing
    }

    /// Weighted completion, as shown on the profile screen ("85% Profile
    /// Complete"). Required fields carry more weight than embellishments.
    static func completionPercentage(for profile: Profile) -> Int {
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
