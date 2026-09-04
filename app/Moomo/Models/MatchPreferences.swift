import Foundation

/// Who may be paired with whom, from `gender` + `interestedIn` +
/// `datingIntention`.
///
/// One definition, used by Discover's feed filter; the backend mirrors the
/// same table in `backend/functions/src/compatibility.ts` (`wantsGender`,
/// `seeks`), so the people Discover shows are the people matchmaking would
/// actually pair.
///
/// The gender rules:
///  - Empty or missing preferences read as "everyone" — accounts from before
///    preferences were enforced must keep working, and refusing to pair them
///    with anybody would be a soft-lock, not safety.
///  - `.everyone` accepts any gender, including non-binary/other/unknown.
///  - `.women` accepts exactly `.woman`; `.men` exactly `.man`. Non-binary,
///    other, and unknown genders are matched only by "everyone" — guessing a
///    binary bucket for them would misgender people structurally.
///
/// The intention rules: each intention seeks some subset of
/// {long-term, short-term}, and two people are compatible when those subsets
/// overlap. A missing intention seeks both, for the same
/// don't-soft-lock-old-accounts reason as above.
enum MatchPreferences {

    static func wants(_ preferences: Set<InterestedIn>, gender: Gender?) -> Bool {
        if preferences.isEmpty || preferences.contains(.everyone) { return true }
        switch gender {
        case .woman: return preferences.contains(.women)
        case .man: return preferences.contains(.men)
        case .nonBinary, .other, .none: return false
        }
    }

    /// The two horizons an intention can be aimed at.
    enum Horizon: Hashable {
        case longTerm
        case shortTerm
    }

    /// What an intention is willing to end up in. Nil — an account that never
    /// picked one — seeks both, so it stays matchable with everybody.
    static func seeks(_ intention: DatingIntention?) -> Set<Horizon> {
        switch intention {
        case .lifePartner, .longTerm: [.longTerm]
        case .shortTerm: [.shortTerm]
        // "Open to" and "figuring it out" are the bridges: they are what let a
        // long-term seeker and a short-term seeker ever meet in the middle.
        case .longTermOpenToShort, .shortTermOpenToLong, .figuringItOut, .none:
            [.longTerm, .shortTerm]
        }
    }

    /// Whether two intentions could lead to the same kind of relationship.
    /// Someone set on a life partner is never shown someone set on a fling.
    static func areIntentionsCompatible(
        _ a: DatingIntention?,
        _ b: DatingIntention?
    ) -> Bool {
        !seeks(a).isDisjoint(with: seeks(b))
    }

    /// True only when BOTH people would choose to meet the other, on gender
    /// preference AND on what they are each here for.
    static func areMutuallyCompatible(
        _ a: (gender: Gender?, interestedIn: Set<InterestedIn>, intention: DatingIntention?),
        _ b: (gender: Gender?, interestedIn: Set<InterestedIn>, intention: DatingIntention?)
    ) -> Bool {
        wants(a.interestedIn, gender: b.gender)
        && wants(b.interestedIn, gender: a.gender)
        && areIntentionsCompatible(a.intention, b.intention)
    }
}
