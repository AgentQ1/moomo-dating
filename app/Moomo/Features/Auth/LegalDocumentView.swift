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
    /// Placeholder copy. This is not legal text and must be replaced with the
    /// reviewed policy before any submission.
    var fallbackBody: String {
        switch self {
        case .privacy:
            """
            Moomo connects people through short video and voice calls.

            What we collect
            • Account details you give us: name, date of birth, gender, photos, \
            bio, and interests.
            • Approximate location — city level only. Moomo never shares or \
            displays your precise location.
            • Call metadata: who you called and for how long. Calls themselves \
            are peer-to-peer and are never recorded or stored.
            • Messages you send to matches, retained for the life of the match.

            What we never do
            • We never record your calls.
            • We never sell your personal data.
            • We never reveal that you declined someone.

            Your controls
            You can export your data or delete your account at any time from \
            Profile → Safety & Privacy. Deletion removes your profile, photos, \
            messages, and call history within 30 days.

            This placeholder must be replaced by counsel-reviewed text before \
            release.
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

            Calls
            Speed calls last three minutes. The timer is enforced by our \
            servers and cannot be extended.

            Matches and chat
            A match is created only when both people express interest. Chats \
            stay open for 24 hours.

            Subscriptions
            Premium is billed through your Apple ID. Subscriptions renew \
            automatically until cancelled in your Apple ID settings.

            This placeholder must be replaced by counsel-reviewed text before \
            release.
            """
        }
    }
}

#Preview {
    LegalDocumentView(document: .privacy)
}
