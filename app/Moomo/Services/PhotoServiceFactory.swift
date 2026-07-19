import Foundation

/// Picks the photo backend, using the same rule as `MoomoApp.makeAuthService()`:
/// real Firebase when configured, the local one otherwise, and never a silent
/// downgrade in a release build.
enum PhotoServiceFactory {
    static func make() -> PhotoUploadService {
        switch BackendConfiguration.current {
        case .firebase:
            #if canImport(FirebaseStorage)
            return FirebaseStorageService()
            #else
            fatalError(
                "GoogleService-Info.plist is present but FirebaseStorage is not linked."
            )
            #endif

        case .localMock(let reason):
            #if !DEBUG
            // A release build writing profile photos to the caches directory
            // would lose every one of them on the next sweep, while the UI
            // reported success.
            fatalError("Release builds require Firebase Storage. Mock reason: \(reason).")
            #else
            return LocalPhotoUploadService()
            #endif
        }
    }
}
