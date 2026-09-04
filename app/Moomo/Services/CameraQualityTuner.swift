import AVFoundation
import Foundation
import os

/// Natural-capture tuning for the camera on a live video call.
///
/// LiveKit owns the capture session: it chooses the device, resolves the
/// format, sets the frame rate, and starts and stops capturing
/// (`CameraCapturer.startCapture`). This type only ever adjusts the *device's*
/// metering behaviour around that — exposure, white balance, low-light boost,
/// HDR availability — and never `activeFormat` or `activeVideoMinFrameDuration`,
/// which would fight the SDK mid-call and drop frames while it re-negotiated.
///
/// There is deliberately no image processing here. No blur, no sharpening, no
/// smoothing, no reshaping, no background replacement. A dating call has to
/// show the person who is actually on it, and skin texture and skin tone are
/// the first two things a beauty filter destroys. Everything below is a camera
/// control that a physical camera would have had anyway.
///
/// ## Backlighting
/// The one thing a video call reliably gets wrong is a person sitting in front
/// of a window: whole-frame metering exposes for the window and leaves the
/// face in silhouette. The fix used here is the cheap one — centre-weighted
/// metering (`exposurePointOfInterest` at the middle of the frame, where the
/// person on a phone call is) plus continuous re-convergence. No Vision, no
/// CoreImage, no per-frame work of any kind: the exposure engine is already
/// running, and this only tells it where to look.
final class CameraQualityTuner: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.moomo.dating", category: "camera")

    /// Where the exposure engine is told to meter. Dead centre: on a handheld
    /// video call the face is in the middle of the frame, and a bright window
    /// behind it is at the edges.
    private static let meteringPoint = CGPoint(x: 0.5, y: 0.5)

    private let lock = NSLock()
    /// Unowned-ish on purpose: the capture device belongs to AVFoundation and
    /// outlives us, but holding it strongly past `detach` would keep a stale
    /// device around after the call.
    private weak var device: AVCaptureDevice?
    private var subjectAreaObserver: NSObjectProtocol?

    /// Applies the tuning to the device LiveKit is currently capturing from,
    /// and re-applies it whenever the subject moves enough for the exposure
    /// engine to say so. Safe to call repeatedly — a flip lands here again
    /// with the other camera.
    ///
    /// A nil device (capture not started, or no camera on this build) is not
    /// an error: the call is still a call, it just runs on whatever defaults
    /// AVFoundation picked.
    func attach(to device: AVCaptureDevice?) {
        detach()
        guard let device else { return }

        lock.withLock { self.device = device }
        configure(device)

        // Subject-area monitoring is the device telling us the scene moved
        // (the person leaned out of frame, the light changed). Re-arming
        // continuous metering on that notification is what keeps a face from
        // staying dark after someone shifts in their chair.
        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: device,
            queue: .main
        ) { [weak self] _ in
            guard let self, let device = self.currentDevice else { return }
            self.configure(device)
        }
        lock.withLock { self.subjectAreaObserver = observer }
    }

    /// Stops observing. The device's own settings are left where they are —
    /// LiveKit is about to stop the session, and reverting them first would
    /// only be extra configuration churn on a camera that is going away.
    func detach() {
        let observer = lock.withLock { () -> NSObjectProtocol? in
            let value = subjectAreaObserver
            subjectAreaObserver = nil
            device = nil
            return value
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    deinit { detach() }

    private var currentDevice: AVCaptureDevice? {
        lock.lock(); defer { lock.unlock() }
        return device
    }

    /// One locked configuration pass. Every setting is asked for only where
    /// the hardware says it is supported, so this is a no-op on a device (or
    /// a simulator) that has none of them rather than a throw.
    private func configure(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
        } catch {
            // Another subsystem holds the device. Not worth failing a call
            // over: the camera keeps running on its defaults.
            Self.log.notice("Camera tuning skipped, device busy: \(error.localizedDescription, privacy: .public)")
            return
        }
        defer { device.unlockForConfiguration() }

        // Exposure: keep converging for the whole call, metered on the middle
        // of the frame rather than the whole of it. This is the backlight fix.
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = Self.meteringPoint
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }

        // White balance: continuous, never locked. Accurate skin tones across
        // a room lamp, a window, and a laptop screen depend on this being
        // allowed to keep moving.
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }

        // Ask the device to tell us when the scene changes, so the two
        // continuous modes above get re-armed above rather than drifting.
        if !device.isSubjectAreaChangeMonitoringEnabled {
            device.isSubjectAreaChangeMonitoringEnabled = true
        }

        #if os(iOS)
        // Low-light boost, where the hardware has it. "WhenAvailable" is the
        // point: the device decides, so a well-lit call is untouched.
        if device.isLowLightBoostSupported, !device.automaticallyEnablesLowLightBoostWhenAvailable {
            device.automaticallyEnablesLowLightBoostWhenAvailable = true
        }

        // HDR, when the format supports it and the scene wants it. Left under
        // the device's own control rather than pinned on: forcing HDR costs
        // motion clarity in dim rooms, which is the wrong trade for a call
        // where the subject is a moving face. Asserted rather than assumed,
        // because the capturer resets this whenever it re-selects a format.
        if device.activeFormat.isVideoHDRSupported, !device.automaticallyAdjustsVideoHDREnabled {
            device.automaticallyAdjustsVideoHDREnabled = true
        }
        #endif
    }
}
