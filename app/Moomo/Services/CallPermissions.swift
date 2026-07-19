import AVFoundation

/// Microphone/camera authorization, behind a protocol so call flows are
/// testable without hardware or system prompts.
protocol CallPermissionsChecking: Sendable {
    /// Ensures everything `mode` needs to capture, prompting the system
    /// dialogs where authorization is undetermined. False when anything
    /// required is denied or restricted — the flow must not put a silent
    /// participant into a real call.
    func ensurePermissions(for mode: CallMode) async -> Bool
}

struct SystemCallPermissions: CallPermissionsChecking {
    func ensurePermissions(for mode: CallMode) async -> Bool {
        guard await ensureAccess(to: .audio) else { return false }
        if mode == .video {
            guard await ensureAccess(to: .video) else { return false }
        }
        return true
    }

    private func ensureAccess(to mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

#if DEBUG
/// For tests and the DEBUG no-backend world. The mock media service captures
/// nothing, so prompting for capture permission there would itself be a lie.
struct StubCallPermissions: CallPermissionsChecking {
    var granted = true
    func ensurePermissions(for mode: CallMode) async -> Bool { granted }
}
#endif
