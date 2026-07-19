import SwiftUI

// The identity steps: name, date of birth, gender, interested-in, location.
// Each binds into `OnboardingModel` and holds no profile state of its own.

// MARK: - Name

struct NameStep: View {
    @ObservedObject var model: OnboardingModel
    @FocusState private var focused: Bool

    var body: some View {
        MoomoTextField(
            placeholder: "First name",
            text: Binding(
                get: { model.draft.profile.displayName },
                set: { name in model.update { $0.displayName = name } }
            ),
            characterLimit: 30
        )
        .focused($focused)
        .textContentType(.givenName)
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
        .submitLabel(.next)
        .onSubmit { model.advance() }
        .task {
            // Delay avoids racing the step transition, which drops focus.
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
        .accessibilityLabel("First name")
    }
}

// MARK: - Date of birth

struct DateOfBirthStep: View {
    @ObservedObject var model: OnboardingModel

    /// Where the wheel sits before the user has chosen: the youngest allowed
    /// age, so the common case is a short scroll and the wheel never opens on
    /// a value the gate would reject.
    ///
    /// This is deliberately *not* written into the profile on appear. The wheel
    /// showing a date is not the user stating their date of birth, and the age
    /// gate is a legal attestation — defaulting it would put a claim in their
    /// mouth that they never made. So `dateOfBirth` stays nil until they
    /// actually pick, and the step can't be passed until they do.
    private var wheelDate: Date {
        model.draft.profile.dateOfBirth ?? AgeGate.latestAllowedBirthDate()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            DatePicker(
                "Date of birth",
                selection: Binding(
                    get: { wheelDate },
                    set: { date in model.update { $0.dateOfBirth = date } }
                ),
                in: AgeGate.earliestAllowedBirthDate()...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface)
            )
            .shadow(Shadows.card)
            .accessibilityLabel("Date of birth")

            if model.draft.profile.dateOfBirth == nil {
                Text("Scroll to your date of birth to continue.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
            }

            if let dob = model.draft.profile.dateOfBirth {
                let age = AgeGate.age(for: dob)
                let ok = AgeGate.isOldEnough(birthDate: dob)
                HStack(spacing: Space.xs) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    Text(ok ? "You're \(age)." : AgeGateFailure.underage.message)
                        .font(Typography.body)
                }
                .foregroundStyle(ok ? Palette.verifiedGreenFG : Palette.coral)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Gender

struct GenderStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: Space.sm) {
            ForEach(Gender.allCases) { gender in
                SelectableCard(
                    title: gender.label,
                    isSelected: model.draft.profile.gender == gender
                ) {
                    model.update { $0.gender = gender }
                }
            }
        }
    }
}

// MARK: - Interested in

struct InterestedInStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: Space.sm) {
            ForEach(InterestedIn.allCases) { option in
                SelectableCard(
                    title: option.label,
                    isSelected: model.draft.profile.interestedIn.contains(option)
                ) {
                    model.update { profile in
                        if option == .everyone {
                            // "Everyone" is the whole set; mixing it with the
                            // narrower options is contradictory.
                            profile.interestedIn = profile.interestedIn.contains(.everyone)
                                ? []
                                : [.everyone]
                        } else {
                            profile.interestedIn.remove(.everyone)
                            if profile.interestedIn.contains(option) {
                                profile.interestedIn.remove(option)
                            } else {
                                profile.interestedIn.insert(option)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Location

struct LocationStep: View {
    @ObservedObject var model: OnboardingModel

    private let cities = CityCatalog.cities

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(cities, id: \.display) { city in
                SelectableCard(
                    title: city.shortDisplay,
                    isSelected: model.draft.profile.location == city
                ) {
                    model.update { $0.location = city }
                }
            }

            Label(
                "Moomo shows your city, never your exact location.",
                systemImage: "lock.shield.fill"
            )
            .font(Typography.body)
            .foregroundStyle(Palette.textSecondary)
            .padding(.top, Space.xs)
        }
    }
}
