import SwiftUI

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

    /// A short, explicit list. Coarse location via CoreLocation is wired in
    /// later — and even then it will only ever resolve to a city, never
    /// coordinates.
    private let cities: [CityLocation] = [
        CityLocation(city: "New York", region: "NY", countryCode: "US"),
        CityLocation(city: "Chicago", region: "IL", countryCode: "US"),
        CityLocation(city: "San Francisco", region: "CA", countryCode: "US"),
        CityLocation(city: "Los Angeles", region: "CA", countryCode: "US"),
        CityLocation(city: "London", region: nil, countryCode: "GB"),
        CityLocation(city: "Toronto", region: "ON", countryCode: "CA")
    ]

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

// MARK: - Photos

struct PhotosStep: View {
    @ObservedObject var model: OnboardingModel

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: Space.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            LazyVGrid(columns: columns, spacing: Space.sm) {
                ForEach(model.draft.profile.photos) { photo in
                    PhotoSlot(photo: photo) {
                        model.update { profile in
                            profile.photos.removeAll { $0.id == photo.id }
                            for index in profile.photos.indices {
                                profile.photos[index].order = index
                            }
                        }
                    }
                }

                if model.draft.profile.photos.count < 6 {
                    AddPhotoSlot {
                        // The picker and downsampling pipeline land with the
                        // Storage work. This records a slot so the step's
                        // validation and reordering are exercisable now.
                        model.update { profile in
                            profile.photos.append(ProfilePhoto(
                                id: UUID().uuidString,
                                remotePath: nil,
                                order: profile.photos.count
                            ))
                        }
                    }
                }
            }

            Text("Your first photo is your main one. Drag to reorder once you've added a few.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

private struct PhotoSlot: View {
    var photo: ProfilePhoto
    var onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .fill(Palette.blueTint)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Palette.blue.opacity(0.35))
                }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, Palette.ink.opacity(0.5))
                    .padding(6)
            }
            .accessibilityLabel("Remove photo")
        }
        .overlay(alignment: .bottomLeading) {
            if photo.order == 0 {
                Text("MAIN")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.blue))
                    .padding(8)
            }
        }
    }
}

private struct AddPhotoSlot: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .strokeBorder(
                    Palette.checkboxBorder,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Palette.blue)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add photo")
    }
}

// MARK: - Bio

struct BioStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        MoomoTextEditor(
            placeholder: "I'm into photography, long coffees, and terrible puns…",
            text: Binding(
                get: { model.draft.profile.bio },
                set: { bio in model.update { $0.bio = bio } }
            ),
            characterLimit: 300
        )
        .accessibilityLabel("Bio")
    }
}

// MARK: - Interests

struct InterestsStep: View {
    @ObservedObject var model: OnboardingModel

    private let options = [
        "Coffee", "Photography", "Hiking", "Cooking", "Live music", "Films",
        "Reading", "Travel", "Gaming", "Fitness", "Art", "Football",
        "Dogs", "Cats", "Dancing", "Comedy", "Tech", "Fashion"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            FlowLayout(spacing: Space.xs) {
                ForEach(options, id: \.self) { option in
                    InterestChip(
                        label: option,
                        isSelected: model.draft.profile.interests.contains(option)
                    ) {
                        model.update { profile in
                            if profile.interests.contains(option) {
                                profile.interests.remove(option)
                            } else {
                                profile.interests.insert(option)
                            }
                        }
                    }
                }
            }

            Text("\(model.draft.profile.interests.count) selected")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

// MARK: - Permissions

struct CameraMicStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ExplainerRow(
                icon: "video.fill",
                title: "Camera",
                detail: "For video speed calls. Nothing is ever recorded or stored."
            )
            ExplainerRow(
                icon: "mic.fill",
                title: "Microphone",
                detail: "For voice and video calls. Audio is peer-to-peer and never saved."
            )
            ExplainerRow(
                icon: "hand.raised.fill",
                title: "You're in control",
                detail: "Mute or leave any call at any time. We'll ask for access when your first call starts — not now."
            )
        }
        .onAppear {
            // Marks the explainer as seen. The system prompt is deliberately
            // not triggered here: iOS gives one chance to ask, and asking
            // before the reason is understood is how apps get denied forever.
            model.markPermissionExplainerSeen()
        }
    }
}

struct NotificationsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ExplainerRow(
                icon: "bell.badge.fill",
                title: "Someone wants to talk",
                detail: "We'll let you know when a match is waiting for you."
            )
            ExplainerRow(
                icon: "heart.fill",
                title: "It's a match",
                detail: "When you both say yes, you get 24 hours to chat."
            )
            ExplainerRow(
                icon: "hourglass",
                title: "Chat expiring",
                detail: "A nudge before a conversation runs out."
            )
            Text("You'll only be asked once. You can change this any time in Settings.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, Space.xs)
        }
    }
}

struct ExplainerRow: View {
    var icon: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            ZStack {
                Circle()
                    .fill(Palette.blueTint)
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: Size.iconMedium))
                    .foregroundStyle(Palette.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.rowTitleSmall)
                    .foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Safety

struct SafetyStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ExplainerRow(
                icon: "person.fill.checkmark",
                title: "Be yourself",
                detail: "Real name, real photos, real you. Impersonation gets removed."
            )
            ExplainerRow(
                icon: "hand.thumbsup.fill",
                title: "Be kind",
                detail: "Harassment, hate, and nudity are never OK and end in removal."
            )
            ExplainerRow(
                icon: "flag.fill",
                title: "Report anything off",
                detail: "You can report or block from any call, match, or chat. We read every report."
            )
            ExplainerRow(
                icon: "eye.slash.fill",
                title: "Never record",
                detail: "Recording someone without consent is against the rules and often the law."
            )

            Toggle(isOn: Binding(
                get: { model.draft.acknowledgedSafety },
                set: { model.setSafetyAcknowledged($0) }
            )) {
                Text("I understand and agree to the community guidelines.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tint(Palette.blue)
            .padding(.top, Space.xs)
        }
    }
}

// MARK: - Review

struct ReviewStep: View {
    @ObservedObject var model: OnboardingModel

    private var profile: Profile { model.draft.profile }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            CompletionCard(
                percentage: ProfileRequirements.completionPercentage(
                    for: profile, isGuest: model.isGuest
                )
            )

            VStack(spacing: 0) {
                ReviewRow(label: "Name", value: profile.displayName)
                if let age = profile.age {
                    Divider().background(Palette.separator)
                    ReviewRow(label: "Age", value: "\(age)")
                }
                if let gender = profile.gender {
                    Divider().background(Palette.separator)
                    ReviewRow(label: "Gender", value: gender.label)
                }
                if !profile.interestedIn.isEmpty {
                    Divider().background(Palette.separator)
                    ReviewRow(
                        label: "Wants to meet",
                        value: profile.interestedIn.map(\.label).sorted().joined(separator: ", ")
                    )
                }
                if let location = profile.location {
                    Divider().background(Palette.separator)
                    ReviewRow(label: "Location", value: location.shortDisplay)
                }
                if !profile.photos.isEmpty {
                    Divider().background(Palette.separator)
                    ReviewRow(label: "Photos", value: "\(profile.photos.count)")
                }
                if !profile.interests.isEmpty {
                    Divider().background(Palette.separator)
                    ReviewRow(
                        label: "Interests",
                        value: profile.interests.sorted().joined(separator: ", ")
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface)
            )
            .shadow(Shadows.card)

            if model.isGuest {
                Label(
                    "You're browsing as a guest. Your profile is temporary — link an account any time from Profile to keep it.",
                    systemImage: "info.circle.fill"
                )
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ReviewRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Space.md)
            Text(value)
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Space.md)
        .frame(minHeight: Size.menuRowHeight)
        .accessibilityElement(children: .combine)
    }
}

private struct CompletionCard: View {
    var percentage: Int

    var body: some View {
        HStack(spacing: Space.md) {
            ZStack {
                Circle()
                    .stroke(Palette.blue.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(percentage) / 100)
                    .stroke(Palette.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(percentage)%")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.blue)
            }
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 2) {
                Text("Profile complete")
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.textPrimary)
                Text(percentage >= 100
                     ? "You're all set."
                     : "You can finish the rest later from your profile.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.cardLarge, style: .continuous)
                .fill(Palette.blueTint)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Profile \(percentage) percent complete")
    }
}
