import SwiftUI

/// The two legal documents the consent gate links to.
enum LegalDocument: String, Identifiable {
    case privacy
    case terms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: "Privacy Policy"
        case .terms: "Terms of Service"
        }
    }

    /// Hosted copies. These must be live and reachable before submission —
    /// App Review rejects dating apps whose policy links 404.
    var url: URL {
        switch self {
        case .privacy: URL(string: "https://moomo.app/privacy")!
        case .terms: URL(string: "https://moomo.app/terms")!
        }
    }
}

/// Presents a legal document in-app.
///
/// Currently renders the offline fallback copy. Loading the hosted document
/// over the network is wired up alongside the rest of the networking layer;
/// the fallback exists so the consent gate is never a dead end offline, which
/// would otherwise block sign-in entirely.
struct LegalDocumentView: View {
    var document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(document.fallbackBody)
                    .font(Typography.body)
                    .lineSpacing(Typography.bodyLineSpacing)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.gutter)
            }
            .background(Palette.canvas)
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Palette.blue)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Link("Open in browser", destination: document.url)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.blue)
                }
            }
        }
    }
}

private extension LegalDocument {
    /// Offline fallback copy, shown until the hosted documents load in-app.
    ///
    /// Engineering constraint, not legal advice: this text describes only what
    /// the app actually does today. It must never promise a feature, retention
    /// behaviour, or control that is not implemented — features and their
    /// legal copy ship together. Counsel review of this text is still required
    /// before App Store submission; that requirement lives here, in a comment,
    /// not in the text users are asked to agree to.
    var fallbackBody: String {
        switch self {
        case .privacy:
            """
            Moomo is a dating app built around short video and voice calls.

            What we collect
            • Account details you give us: name, date of birth, gender, who \
            you'd like to meet, photos, bio, and interests.
            • Your phone number. Every account verifies one — it keeps the \
            community real. It is used for verification only and is never \
            shown to other users.
            • Approximate location — city level only. Moomo never collects, \
            stores, or shares your precise location.
            • Sign-in information (including your email address) from Apple \
            or Google when you use them to create your account.
            • Messages you send to your matches, and reports you file.

            What other users can see
            Your name, age, city, gender, who you'd like to meet, and your \
            photos — what your profile card shows.

            What we never do
            • We never record your calls.
            • We never sell your personal data.
            • We never share your date of birth — only your age is shown.

            Your controls
            You can delete your account at any time from the Profile tab. \
            Deletion permanently removes your profile, photos, matches, \
            conversations, and sign-in details. Safety reports filed by or \
            about an account are retained after deletion so that reported \
            behaviour cannot be erased by deleting the account.
            """
        case .terms:
            """
            By using Moomo you agree to the following.

            Eligibility
            You must be 18 or older. Accounts found to belong to minors are \
            removed immediately and permanently.

            Conduct
            Be real, be kind. Harassment, nudity, hate speech, solicitation, \
            impersonation, and recording other users without consent are \
            prohibited and result in removal.

            Your account
            You are responsible for what you post to your profile. Moomo may \
            remove content or accounts that break these rules.

            Contact
            Questions about these terms: support@moomo.app.
            """
        }
    }
}

#Preview {
    LegalDocumentView(document: .privacy)
}
