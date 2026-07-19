import SwiftUI

/// A circular avatar.
///
/// Shows the person's photo when `photoPath` names one in Storage, loading it
/// through the same `RemotePhotoView`/`PhotoImageCache` pipeline as every
/// other profile photo. Without a path — older profiles, blocked-user
/// rows — it falls back to a deterministic initial-and-tint placeholder: the
/// same person always gets the same colour, so a set of avatars still reads
/// as distinct people.
struct AvatarView: View {
    var name: String
    var photoPath: String?
    var size: CGFloat

    var body: some View {
        ZStack {
            if let photoPath {
                RemotePhotoView(
                    remotePath: photoPath,
                    service: PhotoServiceFactory.make()
                ) {
                    initialsPlaceholder
                }
            } else {
                initialsPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initialsPlaceholder: some View {
        ZStack {
            Circle().fill(tint)

            Text(initial)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
        }
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespaces).first.map(String.init)?.uppercased() ?? "?"
    }

    /// Stable per-name colour. Hashed by content rather than `hashValue`,
    /// which is seeded per-process and would give the same person a different
    /// colour on every launch.
    private var tint: LinearGradient {
        let palette: [(UInt32, UInt32)] = [
            (0xF0A6B4, 0xD4818C),
            (0x8FA6E8, 0x4F6BC4),
            (0xF2C078, 0xD79A46),
            (0x9BD3B4, 0x5FA37C),
            (0xC3A6E8, 0x8B6BC4)
        ]
        let index = Int(stableHash(name) % UInt64(palette.count))
        let (light, dark) = palette[index]
        return LinearGradient(
            colors: [Color(hex: light), Color(hex: dark)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func stableHash(_ string: String) -> UInt64 {
        // FNV-1a. Deterministic across launches, unlike Swift's `hashValue`.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

#Preview {
    HStack {
        AvatarView(name: "Anaya", size: 64)
        AvatarView(name: "Kenji", size: 96)
        AvatarView(name: "Mei", size: 44)
    }
    .padding()
    .background(Palette.canvas)
}
