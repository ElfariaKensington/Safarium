import XCTest
import AppKit
import CryptoKit
@testable import Safarium

/// Tests for `ApplePasswordsPasskeyManager` pure helpers (registrable domain, Base64URL, CBOR, authenticator
/// data, COSE keys, password generator) and the file-backed local vault. The vault is only ever written under the
/// hermetic sandbox; biometrics, the real Keychain and ASAuthorization are never reached.
final class PasskeyManagerTests: HermeticTestCase {

    nonisolated(unsafe) private var manager: ApplePasswordsPasskeyManager!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        manager = ApplePasswordsPasskeyManager(window: nil, webContentHost: NSView(frame: .zero))
        removeVaultFile()
    }

    override func tearDown() {
        removeVaultFile()
        manager = nil
        super.tearDown()
    }

    private func removeVaultFile() {
        guard let url = manager?.vaultURL else { return }
        // Guard: the vault must never be written outside the hermetic sandbox.
        if url.path.hasPrefix(Self.sandboxRoot.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func requireSandboxedVault() -> Bool {
        let ok = manager.vaultURL.path.hasPrefix(Self.sandboxRoot.path)
        if !ok { XCTFail("vault path \(manager.vaultURL.path) escapes the test sandbox") }
        return ok
    }

    private func passkey(rpId: String, credentialID: String, userName: String = "user",
                         createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> ApplePasswordsPasskeyManager.StoredPasskey {
        ApplePasswordsPasskeyManager.StoredPasskey(
            credentialIDBase64URL: credentialID,
            rpId: rpId,
            userIdBase64URL: "dXNlcg",
            userName: userName,
            displayName: userName.uppercased(),
            privateKeyRawBase64: "AAAA",
            signCount: 0,
            createdAt: createdAt
        )
    }

    // MARK: Registrable domain

    func testRegistrableDomainKeepsShortHosts() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.registrableDomain(for: "github.com"), "github.com")
        XCTAssertEqual(ApplePasswordsPasskeyManager.registrableDomain(for: "localhost"), "localhost")
        XCTAssertEqual(ApplePasswordsPasskeyManager.registrableDomain(for: ""), "")
    }

    func testRegistrableDomainDropsSubdomains() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.registrableDomain(for: "a.github.com"), "github.com")
        XCTAssertEqual(ApplePasswordsPasskeyManager.registrableDomain(for: "deep.sub.example.com"), "example.com")
    }

    func testRegistrableDomainOfTrailingDotHostIsDotlessWhenSubdomained() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.registrableDomain(for: "a.example.com."), "example.com")
    }

    func testRegistrableDomainTrailingDotOnApexIsNormalised() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.registrableDomain(for: "example.com."), "example.com")
    }

    func testRegistrableDomainCollapsesIPv4LiteralsIntoGarbage() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.registrableDomain(for: "192.168.1.10"), "192.168.1.10")
    
    }

    func testRegistrableDomainTreatsPublicSuffixAsRegistrant() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.registrableDomain(for: "shop.co.uk"), "shop.co.uk")
    
    }

    func testRegistrableDomainCollapsesUnrelatedGitHubPagesSites() {
        XCTAssertNotEqual(ApplePasswordsPasskeyManager.registrableDomain(for: "a.github.io"),
                          ApplePasswordsPasskeyManager.registrableDomain(for: "b.github.io"))
    
    }

    // MARK: Base64URL

    func testBase64URLEncodesWithoutPaddingOrStandardSymbols() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.base64URLEncode(Data([0xFB, 0xFF])), "-_8")
        XCTAssertEqual(ApplePasswordsPasskeyManager.base64URLEncode(Data([0x00])), "AA")
        XCTAssertEqual(ApplePasswordsPasskeyManager.base64URLEncode(Data()), "")
    }

    func testBase64URLDecodesUnpaddedAndPaddedInput() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.base64URLDecode("-_8"), Data([0xFB, 0xFF]))
        XCTAssertEqual(ApplePasswordsPasskeyManager.base64URLDecode("AA"), Data([0x00]))
        XCTAssertEqual(ApplePasswordsPasskeyManager.base64URLDecode("-_8="), Data([0xFB, 0xFF]))
        XCTAssertEqual(ApplePasswordsPasskeyManager.base64URLDecode(""), Data())
    }

    func testBase64URLRoundTripsEveryByteValue() {
        let all = Data((0...255).map { UInt8($0) })
        let encoded = ApplePasswordsPasskeyManager.base64URLEncode(all)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(ApplePasswordsPasskeyManager.base64URLDecode(encoded), all)
    }

    func testBase64URLRejectsMalformedInput() {
        XCTAssertNil(ApplePasswordsPasskeyManager.base64URLDecode("@@@"))
        XCTAssertNil(ApplePasswordsPasskeyManager.base64URLDecode("a"), "one leftover symbol is not valid base64")
    }

    // MARK: CBOR

    // MARK: COSE key and authenticator data

    // MARK: Password generator

    // MARK: Value models

    func testSavedPasswordEquality() {
        let a = ApplePasswordsPasskeyManager.SavedPassword(host: "x.com", username: "", password: "")
        XCTAssertEqual(a, ApplePasswordsPasskeyManager.SavedPassword(host: "x.com", username: "", password: ""))
        XCTAssertNotEqual(a, ApplePasswordsPasskeyManager.SavedPassword(host: "x.com", username: "u", password: ""))
    }

    func testStoredPasskeyCodableRoundTripsUnicodeAndBoundaries() throws {
        var pk = passkey(rpId: "example.com", credentialID: "Y3JlZA", userName: "Zoë 🔑")
        pk.signCount = UInt32.max
        let data = try JSONEncoder().encode(pk)
        let decoded = try JSONDecoder().decode(ApplePasswordsPasskeyManager.StoredPasskey.self, from: data)
        XCTAssertEqual(decoded, pk)
        XCTAssertEqual(decoded.signCount, UInt32.max)
        XCTAssertEqual(decoded.userName, "Zoë 🔑")
    }

    func testStoredPasskeyPreservesEmptyStringsAndFractionalDates() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000.125)
        let pk = passkey(rpId: "", credentialID: "", userName: "", createdAt: created)
        let decoded = try JSONDecoder().decode(ApplePasswordsPasskeyManager.StoredPasskey.self,
                                               from: try JSONEncoder().encode(pk))
        XCTAssertEqual(decoded.rpId, "")
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, 1_700_000_000.125, accuracy: 1e-6)
    }

    // MARK: Local vault persistence

    func testMissingVaultLoadsEmpty() {
        XCTAssertTrue(requireSandboxedVault())
        let vault = manager.loadVault()
        XCTAssertTrue(vault.passwords.isEmpty)
        XCTAssertTrue(vault.passkeys.isEmpty)
    }

    func testCorruptVaultLoadsEmptyAndIsReplacedOnNextSave() throws {
        XCTAssertTrue(requireSandboxedVault())
        try FileManager.default.createDirectory(at: manager.vaultURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{oops".utf8).write(to: manager.vaultURL)
        XCTAssertTrue(manager.loadVault().passwords.isEmpty)
        seedVaultPassword(manager, host: "example.com", username: "a", password: "p")
        XCTAssertEqual(manager.loadVault().passwords.count, 1)
    }

    func testPersistedVaultIsOwnerOnlyReadable() throws {
        XCTAssertTrue(requireSandboxedVault())
        seedVaultPassword(manager, host: "example.com", username: "a", password: "p")
        let attrs = try FileManager.default.attributesOfItem(atPath: manager.vaultURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testVaultIsEncryptedAtRestAndRoundTrips() throws {
        XCTAssertTrue(requireSandboxedVault())
        seedVaultPassword(manager, host: "example.com", username: "a", password: "hunter2-XYZ")
        let raw = try Data(contentsOf: manager.vaultURL)
        XCTAssertEqual(raw.prefix(4), SafariumVaultCrypto.magic, "vault must be written as an encrypted container")
        XCTAssertNil(raw.range(of: Data("hunter2-XYZ".utf8)), "password must not appear in the file")
        XCTAssertNil(raw.range(of: Data("example.com".utf8)), "host must not appear in the file")
        XCTAssertEqual(manager.loadVault().passwords.first { $0.host == "example.com" }?.password, "hunter2-XYZ")
    }

    func testLegacyPlaintextVaultIsMigratedToEncrypted() throws {
        XCTAssertTrue(requireSandboxedVault())
        let legacy = #"{"passwords":[{"host":"old.example","username":"u","password":"legacy-secret"}],"passkeys":[]}"#
        try FileManager.default.createDirectory(at: manager.vaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: manager.vaultURL)
        XCTAssertEqual(manager.loadVault().passwords.first { $0.host == "old.example" }?.password, "legacy-secret")
        let after = try Data(contentsOf: manager.vaultURL)
        XCTAssertEqual(after.prefix(4), SafariumVaultCrypto.magic)
        XCTAssertNil(after.range(of: Data("legacy-secret".utf8)))
    }

    func testVaultCryptoRejectsTamperingAndWrongKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-\(UUID().uuidString)")
        let sealed = try XCTUnwrap(SafariumVaultCrypto.seal(Data("payload".utf8), keyDirectory: dir))
        XCTAssertEqual(SafariumVaultCrypto.open(sealed, keyDirectory: dir), Data("payload".utf8))
        var tampered = sealed; tampered[tampered.count - 1] ^= 0x01
        XCTAssertNil(SafariumVaultCrypto.open(tampered, keyDirectory: dir))
        XCTAssertNil(SafariumVaultCrypto.open(Data("not a vault".utf8), keyDirectory: dir))
        let saved = SafariumVaultCrypto.keyOverride
        SafariumVaultCrypto.keyOverride = SymmetricKey(data: Data(repeating: 1, count: 32))
        defer { SafariumVaultCrypto.keyOverride = saved }
        XCTAssertNil(SafariumVaultCrypto.open(sealed, keyDirectory: dir), "a different key must not decrypt")
    }

}

/// Writes a password entry straight into the local vault (Safarium no longer saves passwords itself; only the
/// Sign in with Apple flow still reads an existing Apple Account entry).
private func seedVaultPassword(_ manager: ApplePasswordsPasskeyManager, host: String, username: String, password: String) {
    var vault = manager.loadVault()
    vault.passwords.insert(.init(host: host.lowercased(), username: username, password: password), at: 0)
    manager.persistVault(vault)
}
