import Foundation

#if canImport(FirebaseFirestore)
import FirebaseFirestore

/// Firestore-backed profile storage.
struct FirestoreProfileStore: ProfileStore {

    private var db: Firestore { Firestore.firestore() }

    // MARK: - Bootstrap

    /// Idempotent by construction: a transaction reads the document and only
    /// writes the fields that are actually absent or stale. Running it twice —
    /// which happens routinely, since the auth listener fires on every launch —
    /// produces the same result as running it once.
    func bootstrap(
        uid: String,
        provider: AuthProvider,
        providerDisplayName: String?,
        consent: ConsentRecord?
    ) async throws -> User {
        let userRef = db.collection(FirestorePath.users).document(uid)

        _ = try await db.runTransaction { transaction, errorPointer -> Any? in
            let snapshot: DocumentSnapshot
            do {
                snapshot = try transaction.getDocument(userRef)
            } catch let error as NSError {
                errorPointer?.pointee = error
                return nil
            }

            if snapshot.exists {
                // Existing account. Only ever touch provider metadata and
                // updatedAt. Everything the user has entered is left alone —
                // this path runs on every relaunch, and writing profile fields
                // here would let stale provider data clobber real answers.
                var patch: [String: Any] = [
                    "authProvider": provider.rawValue,
                    "updatedAt": FieldValue.serverTimestamp()
                ]

                // Fill a blank display name from the provider, never replace a
                // real one. Apple gives the name exactly once, so if the first
                // write missed it this is the only chance to recover it.
                let existingName = (snapshot.data()?["displayName"] as? String) ?? ""
                if existingName.isEmpty, let providerDisplayName, !providerDisplayName.isEmpty {
                    patch["displayName"] = providerDisplayName
                }

                // Re-record consent only when it is missing or superseded.
                if let consent {
                    let storedVersion = snapshot.data()?["consentDocumentVersion"] as? String
                    if storedVersion != consent.documentVersion {
                        patch["consentAcceptedAt"] = Timestamp(date: consent.acceptedAt)
                        patch["consentDocumentVersion"] = consent.documentVersion
                    }
                }

                transaction.updateData(patch, forDocument: userRef)
                return nil
            }

            // First sight of this uid.
            var document: [String: Any] = [
                "uid": uid,
                "authProvider": provider.rawValue,
                "displayName": providerDisplayName ?? "",
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let consent {
                document["consentAcceptedAt"] = Timestamp(date: consent.acceptedAt)
                document["consentDocumentVersion"] = consent.documentVersion
            }
            transaction.setData(document, forDocument: userRef)
            return nil
        }

        return try await load(uid: uid)
    }

    // MARK: - Update

    func update(uid: String, profile: Profile) async throws -> User {
        let userRef = db.collection(FirestorePath.users).document(uid)

        var document: [String: Any] = [
            "displayName": profile.displayName,
            "bio": profile.bio,
            "interests": Array(profile.interests),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let dob = profile.dateOfBirth { document["dateOfBirth"] = Timestamp(date: dob) }
        if let gender = profile.gender { document["gender"] = gender.rawValue }
        if !profile.interestedIn.isEmpty {
            document["interestedIn"] = profile.interestedIn.map(\.rawValue)
        }
        if let location = profile.location {
            // City-level only. There is no coordinate field to write.
            document["locationCity"] = location.city
            document["locationRegion"] = location.region as Any
            document["locationCountry"] = location.countryCode
        }
        document["photoCount"] = profile.photos.count

        try await userRef.setData(document, merge: true)

        // The public projection carries only what Discover shows. Date of birth
        // and consent are pointedly absent — the rules reject them, and this is
        // the write that would otherwise leak them.
        var publicDocument: [String: Any] = [
            "uid": uid,
            "displayName": profile.displayName,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let age = profile.age { publicDocument["age"] = age }
        if let city = profile.location?.city { publicDocument["city"] = city }
        if let gender = profile.gender { publicDocument["gender"] = gender.rawValue }

        try await db.collection(FirestorePath.publicProfiles)
            .document(uid)
            .setData(publicDocument, merge: true)

        return try await load(uid: uid)
    }

    func markOnboardingComplete(uid: String) async throws -> User {
        try await db.collection(FirestorePath.users).document(uid).setData([
            "onboardingCompletedAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)

        return try await load(uid: uid)
    }

    // MARK: - Load

    private func load(uid: String) async throws -> User {
        let snapshot = try await db.collection(FirestorePath.users).document(uid).getDocument()
        guard let data = snapshot.data() else {
            throw AuthError.unknown("Profile not found.")
        }
        return Self.decode(uid: uid, data: data)
    }

    /// Hand-decoded rather than via Codable: the stored shape is flat (so rules
    /// can reason about individual fields) while `Profile` is nested, and the
    /// two should be free to diverge without a migration.
    static func decode(uid: String, data: [String: Any]) -> User {
        var profile = Profile()
        profile.displayName = data["displayName"] as? String ?? ""
        profile.bio = data["bio"] as? String ?? ""
        profile.dateOfBirth = (data["dateOfBirth"] as? Timestamp)?.dateValue()
        profile.gender = (data["gender"] as? String).flatMap(Gender.init(rawValue:))
        profile.interests = Set(data["interests"] as? [String] ?? [])
        profile.interestedIn = Set(
            (data["interestedIn"] as? [String] ?? []).compactMap(InterestedIn.init(rawValue:))
        )
        if let city = data["locationCity"] as? String,
           let country = data["locationCountry"] as? String {
            profile.location = CityLocation(
                city: city,
                region: data["locationRegion"] as? String,
                countryCode: country
            )
        }
        // Photo bytes live in Storage; this is enough for completeness checks
        // until the upload pipeline lands.
        let photoCount = data["photoCount"] as? Int ?? 0
        profile.photos = (0..<photoCount).map {
            ProfilePhoto(id: "\(uid)-\($0)", remotePath: nil, order: $0)
        }
        profile.isVerified = data["isVerified"] as? Bool ?? false

        var consent: ConsentRecord?
        if let acceptedAt = (data["consentAcceptedAt"] as? Timestamp)?.dateValue(),
           let version = data["consentDocumentVersion"] as? String {
            consent = ConsentRecord(acceptedAt: acceptedAt, documentVersion: version)
        }

        return User(
            id: uid,
            authProvider: (data["authProvider"] as? String)
                .flatMap(AuthProvider.init(rawValue:)) ?? .guest,
            consent: consent,
            profile: profile,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            onboardingCompletedAt: (data["onboardingCompletedAt"] as? Timestamp)?.dateValue()
        )
    }
}
#endif
