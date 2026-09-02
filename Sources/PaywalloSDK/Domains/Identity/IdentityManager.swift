import Foundation

public struct IdentityState {
    public let deviceId: String
    public let email: String?
    public let properties: [String: AnyCodable]
    public let phone: String?
    public let firstName: String?
    public let lastName: String?
    public let dateOfBirth: String?
    public let gender: String?
    public let zipCode: String?
    /// True when the IDFV read this session differs from the last persisted one — the
    /// device key changed under us, which breaks the stitch and shows up in
    /// `installSignals.idfvChanged`.
    public let idfvChanged: Bool
}

public final class IdentityManager {
    private var deviceId: String?
    private var anonId: String?
    private var email: String?
    private var properties: [String: AnyCodable] = [:]
    private var phone: String?
    private var firstName: String?
    private var lastName: String?
    private var dateOfBirth: String?
    private var gender: String?
    private var zipCode: String?
    private var previousIdfv: String?
    private var idfvChanged = false
    private var distinctId: String?

    private var secureStorage: SecureStorage
    private var debug = false
    private var initialized = false
    private var initTask: Task<String, Error>?

    private let emailRegex = try! NSRegularExpression(pattern: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#)

    public init(secureStorage: SecureStorage = .shared) {
        self.secureStorage = secureStorage
    }

    // MARK: - Initialize

    /// Idempotent. Concurrent callers share the same in-flight task.
    @discardableResult
    public func initialize(debug: Bool = false) async throws -> String {
        if initialized {
            return deviceId ?? ""
        }

        if let existing = initTask {
            return try await existing.value
        }

        let task = Task<String, Error> { [weak self] in
            guard let self = self else { return "" }
            return try await self.doInitialize(debug: debug)
        }

        initTask = task
        defer { initTask = nil }
        return try await task.value
    }

    private func doInitialize(debug: Bool) async throws -> String {
        self.debug = debug

        // 1. Run storage migration
        await StorageMigration.runIfNeeded()

        // 2. Load persisted state
        await loadPersistedState()

        // 3. Ensure deviceId
        let deviceData = await MainActor.run { DeviceInfo.shared.getDeviceInfo() }
        if deviceId == nil {
            let id = deviceData.deviceId
            deviceId = (id == "unknown" || id.isEmpty) ? UUID().uuidString : id

            let stored = await secureStorage.set(PaywalloConstants.deviceIdKey, value: deviceId!)
            if !stored {
                await secureStorage.set(PaywalloConstants.deviceIdFallbackKey, value: deviceId!)
            }
        }

        // 4. IDFV drift detection — runs on every boot, not only the first.
        await detectIdfvChange(deviceData)

        // 5. Ensure anonId
        if anonId == nil {
            let newAnonId = UUID().uuidString
            anonId = newAnonId
            // Durable write: retries plus a regular-storage fallback (anti-inflation).
            await IdentityStorage.persistAnonIdDurably(storage: secureStorage, anonId: newAnonId)
        }

        initialized = true
        return deviceId ?? ""
    }

    /// The IDFV is the device's #1 key; a silent swap (restore to a new device, all the
    /// vendor's apps uninstalled) breaks the stitch. Detect it, record the new value, and
    /// let the install payload carry the fact.
    private func detectIdfvChange(_ deviceData: DeviceData) async {
        let idfv = deviceData.idfv
        guard !idfv.isEmpty, idfv != "unknown" else { return }

        let stored = await secureStorage.get(PaywalloConstants.previousIdfvKey)
        idfvChanged = stored != nil && stored != idfv
        previousIdfv = idfv

        if stored != idfv {
            await secureStorage.set(PaywalloConstants.previousIdfvKey, value: idfv)
        }
    }

    // MARK: - Identify

    public func identify(_ options: IdentifyOptions) async {
        guard initialized else { return }

        if let email = options.email {
            if isValidEmail(email) {
                self.email = email
                await secureStorage.set(PaywalloConstants.userEmailKey, value: email)
            } else if debug {
                print("[Paywallo:Identity] Invalid email format, skipping email field")
            }
        }

        if let props = options.properties {
            // Merge, don't replace
            for (key, value) in props {
                properties[key] = value
            }
            if let jsonData = try? JSONEncoder().encode(properties),
               let json = String(data: jsonData, encoding: .utf8) {
                await secureStorage.set(PaywalloConstants.userPropertiesKey, value: json)
            }
        }

        if let phone = options.phone {
            self.phone = phone
            await secureStorage.set(PaywalloConstants.userPhoneKey, value: phone)
        }
        if let firstName = options.firstName {
            self.firstName = firstName
            await secureStorage.set(PaywalloConstants.userFirstNameKey, value: firstName)
        }
        if let lastName = options.lastName {
            self.lastName = lastName
            await secureStorage.set(PaywalloConstants.userLastNameKey, value: lastName)
        }
        if let dob = options.dateOfBirth {
            self.dateOfBirth = dob
            await secureStorage.set(PaywalloConstants.userDobKey, value: dob)
        }
        if let gender = options.gender {
            self.gender = gender.rawValue
            await secureStorage.set(PaywalloConstants.userGenderKey, value: gender.rawValue)
        }
        if let zipCode = options.zipCode {
            self.zipCode = zipCode
            await secureStorage.set(PaywalloConstants.userZipKey, value: zipCode)
        }
    }

    /// Merges properties into the persisted set. Unlike `identify`, it never touches PII.
    public func updateProperties(_ properties: [String: AnyCodable]) async {
        guard initialized else { return }

        for (key, value) in properties {
            self.properties[key] = value
        }
        if let jsonData = try? JSONEncoder().encode(self.properties),
           let json = String(data: jsonData, encoding: .utf8) {
            await secureStorage.set(PaywalloConstants.userPropertiesKey, value: json)
        }
    }

    // MARK: - Reset

    /// Generates a fresh anonId and clears all PII. Does NOT clear deviceId.
    public func reset() async {
        let newAnonId = UUID().uuidString
        anonId = newAnonId
        distinctId = nil
        email = nil
        properties = [:]
        phone = nil
        firstName = nil
        lastName = nil
        dateOfBirth = nil
        gender = nil
        zipCode = nil

        await secureStorage.set(PaywalloConstants.anonIdKey, value: newAnonId)
        await secureStorage.remove(PaywalloConstants.userEmailKey)
        await secureStorage.remove(PaywalloConstants.userPropertiesKey)
        await secureStorage.remove(PaywalloConstants.userPhoneKey)
        await secureStorage.remove(PaywalloConstants.userFirstNameKey)
        await secureStorage.remove(PaywalloConstants.userLastNameKey)
        await secureStorage.remove(PaywalloConstants.userDobKey)
        await secureStorage.remove(PaywalloConstants.userGenderKey)
        await secureStorage.remove(PaywalloConstants.userZipKey)
    }

    /// DEV only: erases the install markers and issues a new anonId, so the next cold
    /// start is a genuinely new user. Needed because those keys live in the Keychain and
    /// survive uninstalling the app — without this there is no way to test acquisition on
    /// a device that already ran it. Neither `reset()` nor `fullReset()` touch them.
    public func clearInstallStateForDev() async {
        await InstallIdempotency.clearInstallState(storage: secureStorage)
        await reset()
    }

    /// LGPD/GDPR erase: wipes local PII plus distinctId and clears pending critical
    /// retries (their bodies may carry PII).
    ///
    /// Does NOT touch deviceId or SDK config — those are not user data, and deviceId
    /// feeds install idempotency. A fresh anonId is issued IMMEDIATELY so a still-running
    /// app never tracks under an empty distinctId.
    public func deleteUserData() async {
        guard initialized else { return }

        await PendingRetry.shared.clear()

        let newAnonId = UUID().uuidString
        anonId = newAnonId
        distinctId = nil
        email = nil
        properties = [:]
        phone = nil
        firstName = nil
        lastName = nil
        dateOfBirth = nil
        gender = nil
        zipCode = nil

        await IdentityStorage.persistAnonIdDurably(storage: secureStorage, anonId: newAnonId)
        await secureStorage.remove(PaywalloConstants.distinctIdKey)
        await secureStorage.remove(PaywalloConstants.userEmailKey)
        await secureStorage.remove(PaywalloConstants.userPropertiesKey)
        await secureStorage.remove(PaywalloConstants.userPhoneKey)
        await secureStorage.remove(PaywalloConstants.userFirstNameKey)
        await secureStorage.remove(PaywalloConstants.userLastNameKey)
        await secureStorage.remove(PaywalloConstants.userDobKey)
        await secureStorage.remove(PaywalloConstants.userGenderKey)
        await secureStorage.remove(PaywalloConstants.userZipKey)
    }

    // MARK: - Getters

    /// Fallback chain: distinctId ?? anonId ?? ""
    public func getDistinctId() -> String {
        guard initialized else { return "" }
        return distinctId ?? anonId ?? ""
    }

    public func getDeviceId() -> String? { deviceId }
    public func getEmail() -> String? { email }
    public func getAnonId() -> String? { anonId }

    public func getProperties() -> [String: AnyCodable] { properties }

    /// True when the IDFV read this session differs from the last persisted one.
    public func hasIdfvChanged() -> Bool { idfvChanged }

    public func getPreviousIdfv() -> String? { previousIdfv }

    public func getState() -> IdentityState {
        IdentityState(
            deviceId: deviceId ?? "",
            email: email,
            properties: properties,
            phone: phone,
            firstName: firstName,
            lastName: lastName,
            dateOfBirth: dateOfBirth,
            gender: gender,
            zipCode: zipCode,
            idfvChanged: idfvChanged
        )
    }

    public var isInitialized: Bool { initialized }

    // MARK: - Private

    private func loadPersistedState() async {
        let state = await IdentityStorage.loadPersistedIdentity(storage: secureStorage)
        var resolvedDeviceId = state.deviceId
        if resolvedDeviceId == nil {
            resolvedDeviceId = await IdentityStorage.readDeviceIdWithFallback(storage: secureStorage)
        }

        if let id = resolvedDeviceId { self.deviceId = id }

        // readAnonIdDurably checks the Keychain and then the regular-storage fallback, so
        // a persisted anonId is never missed just because the Keychain was locked at boot.
        if let anonId = await IdentityStorage.readAnonIdDurably(storage: secureStorage) {
            let legacyPrefix = "$paywallo_anon:"
            if anonId.hasPrefix(legacyPrefix) {
                let stripped = String(anonId.dropFirst(legacyPrefix.count))
                self.anonId = stripped
                await secureStorage.set(PaywalloConstants.anonIdKey, value: stripped)
            } else {
                self.anonId = anonId
            }
        }

        if let email = state.email { self.email = email }
        if let json = state.propertiesJson {
            self.properties = IdentityStorage.parseProperties(json)
        }
        if let distinctId = state.distinctId { self.distinctId = distinctId }

        // PII fields with legacy key migration
        if let phone = await IdentityStorage.readWithPiiMigration(
            storage: secureStorage,
            newKey: PaywalloConstants.userPhoneKey,
            legacyKey: PaywalloConstants.legacyUserPhoneKey
        ) { self.phone = phone }

        if let firstName = await IdentityStorage.readWithPiiMigration(
            storage: secureStorage,
            newKey: PaywalloConstants.userFirstNameKey,
            legacyKey: PaywalloConstants.legacyUserFirstNameKey
        ) { self.firstName = firstName }

        if let lastName = await IdentityStorage.readWithPiiMigration(
            storage: secureStorage,
            newKey: PaywalloConstants.userLastNameKey,
            legacyKey: PaywalloConstants.legacyUserLastNameKey
        ) { self.lastName = lastName }

        if let dob = await IdentityStorage.readWithPiiMigration(
            storage: secureStorage,
            newKey: PaywalloConstants.userDobKey,
            legacyKey: PaywalloConstants.legacyUserDobKey
        ) { self.dateOfBirth = dob }

        if let gender = await IdentityStorage.readWithPiiMigration(
            storage: secureStorage,
            newKey: PaywalloConstants.userGenderKey,
            legacyKey: PaywalloConstants.legacyUserGenderKey
        ) { self.gender = gender }

        if let zipCode = await secureStorage.get(PaywalloConstants.userZipKey) {
            self.zipCode = zipCode
        }
    }

    private func isValidEmail(_ email: String) -> Bool {
        let range = NSRange(email.startIndex..., in: email)
        return emailRegex.firstMatch(in: email, range: range) != nil
    }
}
