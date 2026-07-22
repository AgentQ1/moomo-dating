import Foundation

/// Who may be paired with whom, from `gender` + `interestedIn`.
///
/// One definition, used by Discover's feed filter; the backend mirrors the
/// same table in `backend/functions/src/compatibility.ts` (`wantsGender`), so
/// the people Discover shows are the people matchmaking would actually pair.
///
/// The rules:
///  - Empty or missing preferences read as "everyone" — accounts from before
///    preferences were enforced must keep working, and refusing to pair them
///    with anybody would be a soft-lock, not safety.
///  - `.everyone` accepts any gender, including non-binary/other/unknown.
///  - `.women` accepts exactly `.woman`; `.men` exactly `.man`. Non-binary,
///    other, and unknown genders are matched only by "everyone" — guessing a
///    binary bucket for them would misgender people structurally.
enum MatchPreferences {

    static func wants(_ preferences: Set<InterestedIn>, gender: Gender?) -> Bool {
        if preferences.isEmpty || preferences.contains(.everyone) { return true }
        switch gender {
        case .woman: return preferences.contains(.women)
        case .man: return preferences.contains(.men)
        case .nonBinary, .other, .none: return false
        }
    }

    /// True only when BOTH people would choose to meet the other.
    static func areMutuallyCompatible(
        _ a: (gender: Gender?, interestedIn: Set<InterestedIn>),
        _ b: (gender: Gender?, interestedIn: Set<InterestedIn>)
    ) -> Bool {
        wants(a.interestedIn, gender: b.gender) && wants(b.interestedIn, gender: a.gender)
    }
}
