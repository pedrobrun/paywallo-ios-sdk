import XCTest
@testable import PaywalloSDK

// MARK: - Fake NativeStorage (protocol-free, composition approach)
//
// NativeStorage is `final` so we can't subclass it.
// SecureStorage injects NativeStorage by value — no protocol seam.
//
// Strategy:
//  - For SecureStorage tests: use a real NativeStorage backed by an isolated
//    UserDefaults suite + a unique Keychain service (UUID-namespaced).
//    Track calls by wrapping reads/writes on the UserDefaults side directly,
//    and by checking Keychain state via the same NativeStorage instance.
//  - For NativeStorage tests: same isolated instance.
//  - For StorageMigration tests: same isolated instance, check UserDefaults flag.

// MARK: - Helpers

/// Returns a NativeStorage wired to an isolated UserDefaults suite and a
/// unique Keychain service so tests can never collide with each other or
/// with production data.
private func makeIsolatedStorage(id: String = UUID().uuidString) -> (NativeStorage, UserDefaults, String) {
    let suiteName = "com.paywallo.sdk.tests.\(id)"
    let suite = UserDefaults(suiteName: suiteName)!
    let keychainService = "com.paywallo.sdk.tests.\(id)"
    let storage = NativeStorage(service: keychainService, defaults: suite)
    return (storage, suite, suiteName)
}

// MARK: - NativeStorage Tests

final class NativeStorageTests: XCTestCase {

    private var storage: NativeStorage!
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let (s, d, name) = makeIsolatedStorage()
        storage = s
        suite = d
        suiteName = name
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: UserDefaults

    func testUserDefaults_setAndGet_returnsValue() {
        storage.set("key1", value: "hello")
        XCTAssertEqual(storage.get("key1"), "hello")
    }

    func testUserDefaults_getNonExistent_returnsNil() {
        XCTAssertNil(storage.get("missing_\(UUID().uuidString)"))
    }

    func testUserDefaults_remove_nilAfterRemoval() {
        storage.set("del_key", value: "bye")
        XCTAssertNotNil(storage.get("del_key"))
        storage.remove("del_key")
        XCTAssertNil(storage.get("del_key"))
    }

    func testUserDefaults_overwrite_returnsLatestValue() {
        storage.set("over_key", value: "first")
        storage.set("over_key", value: "second")
        XCTAssertEqual(storage.get("over_key"), "second")
    }

    func testUserDefaults_setReturnsTrue() {
        XCTAssertTrue(storage.set("ret_key", value: "v"))
    }

    func testUserDefaults_removeReturnsTrue() {
        storage.set("rm_ret_key", value: "v")
        XCTAssertTrue(storage.remove("rm_ret_key"))
    }

    func testUserDefaults_isolatedFromStandard() {
        let key = "isolation_\(UUID().uuidString)"
        storage.set(key, value: "isolated")
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    // MARK: Keychain

    func testKeychain_setAndGet_returnsValue() async {
        let key = "kc_\(UUID().uuidString)"
        let stored = await storage.secureSet(key, value: "secret")
        XCTAssertTrue(stored)
        let val = await storage.secureGet(key)
        XCTAssertEqual(val, "secret")
        await storage.secureRemove(key)
    }

    func testKeychain_getNonExistent_returnsNil() async {
        let val = await storage.secureGet("kc_missing_\(UUID().uuidString)")
        XCTAssertNil(val)
    }

    func testKeychain_remove_nilAfterDeletion() async {
        let key = "kc_rm_\(UUID().uuidString)"
        await storage.secureSet(key, value: "bye")
        await storage.secureRemove(key)
        let val = await storage.secureGet(key)
        XCTAssertNil(val)
    }

    func testKeychain_overwrite_returnsNewValue() async {
        let key = "kc_ow_\(UUID().uuidString)"
        await storage.secureSet(key, value: "v1")
        await storage.secureSet(key, value: "v2")
        let val = await storage.secureGet(key)
        XCTAssertEqual(val, "v2")
        await storage.secureRemove(key)
    }
}

// MARK: - SecureStorage Tests

final class SecureStorageTests: XCTestCase {

    private var storage: NativeStorage!
    private var suite: UserDefaults!
    private var suiteName: String!
    private var secureStorage: SecureStorage!

    // Mirrors private constants from SecureStorage
    private let kcPrefix  = "com.paywallo.sdk."
    private let udPrefix  = PaywalloConstants.storagePrefix  // "@paywallo:"

    override func setUp() {
        super.setUp()
        let (s, d, name) = makeIsolatedStorage()
        storage = s
        suite = d
        suiteName = name
        secureStorage = SecureStorage(nativeStorage: storage)
    }

    override func tearDown() async throws {
        // Clean Keychain entries from this session
        for suffix in ["device_id", "anon_id", "user_email", "user_phone",
                       "install_tracked", "user_name", "distinct_id"] {
            await storage.secureRemove("\(kcPrefix)\(suffix)")
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: Write — only to Keychain

    func testSet_writesToKeychain() async {
        let key = "device_id"
        await secureStorage.set(key, value: "abc123")

        // Value must be readable from Keychain
        let kcVal = await storage.secureGet("\(kcPrefix)\(key)")
        XCTAssertEqual(kcVal, "abc123")

        // Value must NOT appear in UserDefaults
        let udVal = suite.string(forKey: "\(udPrefix)\(key)")
        XCTAssertNil(udVal, "SecureStorage.set must never write to UserDefaults")
    }

    // MARK: Read — Keychain hit

    func testGet_keychainHit_returnsValue() async {
        let key = "anon_id"
        await secureStorage.set(key, value: "kc_value")

        let result = await secureStorage.get(key)
        XCTAssertEqual(result, "kc_value")
    }

    func testGet_keychainHit_doesNotTouchUserDefaults() async {
        let key = "anon_id"
        await secureStorage.set(key, value: "kc_value")

        _ = await secureStorage.get(key)

        // UserDefaults must remain empty for this key
        XCTAssertNil(suite.string(forKey: "\(udPrefix)\(key)"),
                     "Keychain hit must not write to UserDefaults")
    }

    // MARK: Read — promotion from UserDefaults → Keychain

    func testGet_promotesPlaintextValueToKeychain() async {
        let key = "user_email"
        let udKey = "\(udPrefix)\(key)"
        let kcKey = "\(kcPrefix)\(key)"

        // Seed UserDefaults only (pre-migration state)
        suite.set("test@example.com", forKey: udKey)

        let result = await secureStorage.get(key)
        XCTAssertEqual(result, "test@example.com", "Promotion path must return the value")

        // Must now exist in Keychain
        let promoted = await storage.secureGet(kcKey)
        XCTAssertEqual(promoted, "test@example.com", "Value must be promoted to Keychain")
    }

    func testGet_promotionRemovesPlaintextCopy() async {
        let key = "user_email"
        let udKey = "\(udPrefix)\(key)"

        suite.set("test@example.com", forKey: udKey)
        _ = await secureStorage.get(key)

        XCTAssertNil(suite.string(forKey: udKey),
                     "Plaintext must be erased from UserDefaults after promotion")
    }

    func testGet_afterPromotion_secondReadHitsKeychain() async {
        let key = "user_email"
        let udKey = "\(udPrefix)\(key)"

        suite.set("test@example.com", forKey: udKey)
        _ = await secureStorage.get(key)  // promotes

        // Erase UserDefaults manually to confirm next read comes from Keychain
        suite.removeObject(forKey: udKey)

        let result = await secureStorage.get(key)
        XCTAssertEqual(result, "test@example.com",
                       "Second read must come from Keychain, not UserDefaults")
    }

    // MARK: Read — both empty

    func testGet_bothEmpty_returnsNil() async {
        let result = await secureStorage.get("no_such_key_\(UUID().uuidString)")
        XCTAssertNil(result)
    }

    // MARK: Remove

    func testRemove_clearsKeychain() async {
        let key = "install_tracked"
        await secureStorage.set(key, value: "1")
        await secureStorage.remove(key)

        let val = await storage.secureGet("\(kcPrefix)\(key)")
        XCTAssertNil(val, "Keychain must be cleared after remove()")
    }

    func testRemove_clearsUserDefaults() async {
        let key = "user_name"
        let udKey = "\(udPrefix)\(key)"

        suite.set("legacy_value", forKey: udKey)
        await secureStorage.remove(key)

        XCTAssertNil(suite.string(forKey: udKey),
                     "UserDefaults legacy key must be cleared by remove()")
    }

    func testRemove_clearsBothSlotsWhenBothPresent() async {
        let key = "distinct_id"
        let udKey = "\(udPrefix)\(key)"
        let kcKey = "\(kcPrefix)\(key)"

        // Seed both (partially migrated state)
        suite.set("old_value", forKey: udKey)
        await storage.secureSet(kcKey, value: "new_value")

        await secureStorage.remove(key)

        XCTAssertNil(suite.string(forKey: udKey), "UserDefaults must be cleared")
        let kcVal = await storage.secureGet(kcKey)
        XCTAssertNil(kcVal, "Keychain must be cleared")
    }

    func testRemove_getReturnsNilAfterwards() async {
        let key = "user_phone"
        await secureStorage.set(key, value: "5511999999999")
        await secureStorage.remove(key)

        let result = await secureStorage.get(key)
        XCTAssertNil(result, "get() must return nil after remove()")
    }
}

// MARK: - StorageMigration Tests

final class StorageMigrationTests: XCTestCase {

    private var storage: NativeStorage!
    private var suite: UserDefaults!
    private var suiteName: String!

    private let migrationKey = PaywalloConstants.migrationV152DoneKey

    override func setUp() {
        super.setUp()
        let (s, d, name) = makeIsolatedStorage()
        storage = s
        suite = d
        suiteName = name
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: Run-once guard

    func testRunIfNeeded_skipsWhenFlagAlreadySet() async {
        // Pre-set the migration done flag
        storage.set(migrationKey, value: "1")

        // Run migration — should be a no-op
        await StorageMigration.runIfNeeded(using: storage)

        // Flag must remain "1" (not duplicated, not cleared)
        XCTAssertEqual(storage.get(migrationKey), "1")
    }

    func testRunIfNeeded_setsCompletionFlagAfterFirstRun() async {
        XCTAssertNil(storage.get(migrationKey), "Precondition: flag must be absent")

        await StorageMigration.runIfNeeded(using: storage)

        XCTAssertEqual(storage.get(migrationKey), "1",
                       "Migration flag must be '1' after first run")
    }

    // MARK: Idempotency

    func testRunIfNeeded_idempotent_secondRunIsNoOp() async {
        await StorageMigration.runIfNeeded(using: storage)
        let flagAfterFirst = storage.get(migrationKey)

        // Capture any Keychain state before second run
        await StorageMigration.runIfNeeded(using: storage)

        // Flag must be unchanged
        XCTAssertEqual(storage.get(migrationKey), flagAfterFirst,
                       "Flag must not change on second run")
    }

    // MARK: Flag correctness

    func testMigrationFlag_valueIsExactlyOne() async {
        await StorageMigration.runIfNeeded(using: storage)
        XCTAssertEqual(storage.get(migrationKey), "1")
    }

    // MARK: No legacy data

    func testRunIfNeeded_noLegacyData_completesSuccessfully() async {
        // No legacy Keychain entries → migration runs but writes nothing to Keychain
        await StorageMigration.runIfNeeded(using: storage)

        // Completion flag must still be set
        XCTAssertEqual(storage.get(migrationKey), "1")
    }
}
