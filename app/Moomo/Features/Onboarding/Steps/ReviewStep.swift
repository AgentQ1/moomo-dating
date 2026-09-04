import SwiftUI

// MARK: - Review

struct ReviewStep: View {
    @ObservedObject var model: OnboardingModel

    private var profile: Profile { model.draft.profile }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            CompletionCard(
                percentage: ProfileRequirements.completionPercentage(for: profile)
            )

            // The step's subtitle promises "here's what others will see", so
            // show the photos rather than a count of them.
            if !profile.photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.sm) {
                        ForEach(profile.photos) { photo in
                            RemotePhotoView(
                                remotePath: photo.remotePath,
                                service: model.photoDisplayService
                            )
                            .frame(width: 96, height: 128)
                            .clipShape(
                                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                            )
                            .overlay(alignment: .bottomLeading) {
                                if photo.order == 0 {
                                    Text("MAIN")
                                        .font(.system(size: 9, weight: .bold))
                                        .tracking(0.6)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Palette.blue))
                                        .padding(6)
                                }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("review.photos")
            }

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
                if let intention = profile.datingIntention {
                    Divider().background(Palette.separator)
                    ReviewRow(label: "Looking for", value: intention.label)
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
