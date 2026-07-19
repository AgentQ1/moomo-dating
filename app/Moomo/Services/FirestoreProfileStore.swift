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
    ///
    /// The transaction already read the document, so the resulting `User` is
    /// decoded from that read merged with what was just written — a follow-up
    /// `load` here cost an extra network round trip on every launch and
    /// sign-in. Unresolved server timestamps are the only difference, and
    /// `decode` falls back sensibly for those.
    func bootstrap(uid: String, consent: ConsentRecord?) async throws -> User {
        let userRef = db.collection(FirestorePath.users).document(uid)

        let result = try await db.runTransaction { transaction, errorPointer -> Any? in
            let snapshot: DocumentSnapshot
            do {
                snapshot = try transaction.getDocument(userRef)
            } catch let error as NSError {
                errorPointer?.pointee = error
                return nil
            }

            if snapshot.exists {
                // Existing account. Only ever touch consent and updatedAt.
                // Everything the user has entered is left alone — this path
                // runs on every relaunch, and writing profile fields here
                // would let stale data clobber real answers.
                var patch: [String: Any] = [
                    "updatedAt": FieldValue.serverTimestamp()
                ]

                // Re-record consent only when it is missing or superseded.
                if let consent {
                    let storedVersion = snapshot.data()?["consentDocumentVersion"] as? String
                    if storedVersion != consent.documentVersion {
                        patch["consentAcceptedAt"] = Timestamp(date: consent.acceptedAt)
                        patch["consentDocumentVersion"] = consent.documentVersion
                    }
                }

                transaction.updateData(patch, forDocument: userRef)

                // What the document now holds: the read state plus the patch.
                // Server timestamps are unresolved locally; skip them and let
                // the stored value (or decode's fallback) stand.
                var merged = snapshot.data() ?? [:]
                for (key, value) in patch where !(value is FieldValue) {
                    merged[key] = value
                }
                return merged
            }

            // First sight of this uid.
            var document: [String: Any] = [
                "uid": uid,
                "authProvider": AuthProvider.phone.rawValue,
                "displayName": "",
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let consent {
                document["consentAcceptedAt"] = Timestamp(date: consent.acceptedAt)
                document["consentDocumentVersion"] = consent.documentVersion
            }
            transaction.setData(document, forDocument: userRef)
            return document
        }

        guard let data = result as? [String: Any] else {
            throw AuthError.unknown("Profile not found.")
        }
        return Self.decode(uid: uid, data: data)
    }

    // MARK: - Update

    func update(uid: String, profile: Profile) async throws -> User {
        let userRef = db.collection(FirestorePath.users).document(uid)

        // These are merge writes, so every optional the profile has CLEARED
        // must write `FieldValue.delete()` — leaving the key out would let the
        // stale value survive the save and resurface on the next load.
        var document: [String: Any] = [
            "displayName": profile.displayName,
            "bio": profile.bio,
            "interests": Array(profile.interests),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        document["dateOfBirth"] = profile.dateOfBirth.map { Timestamp(date: $0) as Any }
            ?? FieldValue.delete()
        document["gender"] = profile.gender.map { $0.rawValue as Any } ?? FieldValue.delete()
        document["interestedIn"] = profile.interestedIn.isEmpty
            ? FieldValue.delete()
            : profile.interestedIn.map(\.rawValue).sorted()
        if let location = profile.location {
            // City-level only. There is no coordinate field to write.
            document["locationCity"] = location.city
            document["locationCountry"] = location.countryCode
            // Never insert a nil optional as `Any` — Firestore rejects it.
            // Cities without a region (London) delete any stale value instead,
            // since this is a merge write.
            document["locationRegion"] = location.region ?? FieldValue.delete()
        } else {
            document["locationCity"] = FieldValue.delete()
            document["locationCountry"] = FieldValue.delete()
            document["locationRegion"] = FieldValue.delete()
        }
        // The real photo records, ordered. Previously this wrote only a count,
        // which meant a reload could not tell which photos existed — it
        // reconstructed placeholders from the number. Storing the paths is what
        // makes photos survive a relaunch.
        document["photos"] = profile.photos
            .sorted { $0.order < $1.order }
            .map { ["id": $0.id, "remotePath": $0.remotePath, "order": $0.order] }

        // The public projection carries only what Discover shows. Date of birth
        // and consent are pointedly absent — the rules reject them, and this is
        // the write that would otherwise leak them.
        var publicDocument: [String: Any] = [
            "uid": uid,
            "displayName": profile.displayName,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        // Cleared optionals delete here too — a stale public age or city is
        // shown to strangers long after the user removed it.
        publicDocument["age"] = profile.age.map { $0 as Any } ?? FieldValue.delete()
        publicDocument["city"] = profile.location.map { $0.city as Any } ?? FieldValue.delete()
        publicDocument["gender"] = profile.gender.map { $0.rawValue as Any } ?? FieldValue.delete()
        // Who they want to meet, so Discover and matchmaking can pair only
        // mutually compatible people. This is the projection Discover renders
        // its feed from; matchmaking reads the same field server-side.
        publicDocument["interestedIn"] = profile.interestedIn.isEmpty
            ? FieldValue.delete()
            : profile.interestedIn.map(\.rawValue).sorted()

        // Photo paths, so Discover can render a face without reading the
        // private document. Paths only — the bytes stay behind Storage rules,
        // and age is already derived here rather than exposing date of birth.
        publicDocument["photoPaths"] = profile.photos
            .sorted { $0.order < $1.order }
            .map(\.remotePath)

        // One atomic batch, not two sequential writes: the private profile and
        // its public projection must never diverge because the second write
        // failed — and one round trip is faster than two.
        let batch = db.batch()
        batch.setData(document, forDocument: userRef, merge: true)
        batch.setData(
            publicDocument,
            forDocument: db.collection(FirestorePath.publicProfiles).document(uid),
            merge: true
        )
        try await batch.commit()

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

    /// The offline-launch fallback: the user document from the local cache
    /// only. Never hits the network — an offline cold launch must not sit on
    /// the splash screen forever when the profile is already on disk.
    func loadCached(uid: String) async -> User? {
        guard let snapshot = try? await db.collection(FirestorePath.users)
            .document(uid).getDocument(source: .cache),
            let data = snapshot.data()
        else { return nil }
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
        // Photo bytes live in Storage; these are the pointers to them.
        //
        // A record without a `remotePath` is dropped rather than defaulted: it
        // would be a photo whose bytes we cannot fetch, and admitting one would
        // reintroduce exactly the "profile claims a photo the server never
        // received" bug the non-optional `remotePath` exists to prevent.
        profile.photos = (data["photos"] as? [[String: Any]] ?? [])
            .compactMap { entry in
                guard let id = entry["id"] as? String,
                      let remotePath = entry["remotePath"] as? String,
                      !remotePath.isEmpty else { return nil }
                return ProfilePhoto(
                    id: id,
                    remotePath: remotePath,
                    order: entry["order"] as? Int ?? 0
                )
            }
            .sorted { $0.order < $1.order }
        profile.isVerified = data["isVerified"] as? Bool ?? false

        var consent: ConsentRecord?
        if let acceptedAt = (data["consentAcceptedAt"] as? Timestamp)?.dateValue(),
           let version = data["consentDocumentVersion"] as? String {
            consent = ConsentRecord(acceptedAt: acceptedAt, documentVersion: version)
        }

        return User(
            id: uid,
            // Unknown/legacy provider strings (old "guest" docs) fall back to
            // phone — every live account has a verified number.
            authProvider: (data["authProvider"] as? String)
                .flatMap(AuthProvider.init(rawValue:)) ?? .phone,
            consent: consent,
            profile: profile,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            onboardingCompletedAt: (data["onboardingCompletedAt"] as? Timestamp)?.dateValue()
        )
    }
}
#endif
