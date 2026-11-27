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

    func testCBORHeaderUsesShortFormUpToTwentyThree() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.cborHeader(majorType: 0, length: 0), Data([0x00]))
        XCTAssertEqual(ApplePasswordsPasskeyManager.cborHeader(majorType: 0, length: 23), Data([0x17]))
        XCTAssertEqual(ApplePasswordsPasskeyManager.cborHeader(majorType: 2, length: 1), Data([0x41]))
    }

    func testCBORHeaderUsesOneByteLengthFromTwentyFour() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.cborHeader(majorType: 0, length: 24), Data([0x18, 0x18]))
        XCTAssertEqual(ApplePasswordsPasskeyManager.cborHeader(majorType: 3, length: 255), Data([0x78, 0xFF]))
    }

    func testCBORHeaderUsesTwoByteLengthFromTwoFiftySix() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.cborHeader(majorType: 2, length: 256), Data([0x59, 0x01, 0x00]))
        XCTAssertEqual(ApplePasswordsPasskeyManager.cborHeader(majorType: 2, length: 65535), Data([0x59, 0xFF, 0xFF]))
    }

    func testCBORHeaderOverflowsBeyondSixteenBitLengths() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.cborHeader(majorType: 2, length: 65536),
                       Data([0x5A, 0x00, 0x01, 0x00, 0x00]))
    
    }

    func testCBORTextEncodesUTF8WithTextMajorType() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.cborText("fmt"), Data([0x63, 0x66, 0x6D, 0x74]))
        XCTAssertEqual(ApplePasswordsPasskeyManager.cborText(""), Data([0x60]))
        // "é" is two UTF-8 bytes.
        XCTAssertEqual(ApplePasswordsPasskeyManager.cborText("é"), Data([0x62, 0xC3, 0xA9]))
    }

    func testCBORBytesUsesByteStringMajorType() {
        XCTAssertEqual(ApplePasswordsPasskeyManager.cborBytes(Data([1, 2])), Data([0x42, 0x01, 0x02]))
        XCTAssertEqual(ApplePasswordsPasskeyManager.cborBytes(Data()), Data([0x40]))
    }

    func testNoneAttestationObjectMatchesCBORLayout() {
        let object = ApplePasswordsPasskeyManager.buildNoneAttestationObject(authData: Data([1, 2, 3]))
        let expected: [UInt8] = [
            0xA3,
            0x63, 0x66, 0x6D, 0x74,                         // "fmt"
            0x64, 0x6E, 0x6F, 0x6E, 0x65,                   // "none"
            0x67, 0x61, 0x74, 0x74, 0x53, 0x74, 0x6D, 0x74, // "attStmt"
            0xA0,                                           // {}
            0x68, 0x61, 0x75, 0x74, 0x68, 0x44, 0x61, 0x74, 0x61, // "authData"
            0x43, 0x01, 0x02, 0x03                          // bstr(3)
        ]
        XCTAssertEqual([UInt8](object), expected)
    }

    // MARK: COSE key and authenticator data

    func testCOSEPublicKeyCarriesEC2P256Coordinates() {
        let key = P256.Signing.PrivateKey().publicKey
        let cose = ApplePasswordsPasskeyManager.encodeCOSEPublicKey(key)
        let bytes = [UInt8](cose)
        XCTAssertEqual(cose.count, 77)
        XCTAssertEqual(bytes[0], 0xA5, "map(5)")
        XCTAssertEqual(Array(bytes[1...2]), [0x01, 0x02], "kty: EC2")
        XCTAssertEqual(Array(bytes[3...4]), [0x03, 0x26], "alg: ES256 (-7)")
        XCTAssertEqual(Array(bytes[5...6]), [0x20, 0x01], "crv: P-256")
        XCTAssertEqual(Array(bytes[7...9]), [0x21, 0x58, 0x20], "x: bstr(32)")
        XCTAssertEqual(Array(bytes[42...44]), [0x22, 0x58, 0x20], "y: bstr(32)")
        let raw = key.rawRepresentation
        XCTAssertEqual(cose.subdata(in: 10..<42), raw.prefix(32))
        XCTAssertEqual(cose.subdata(in: 45..<77), raw.suffix(32))
    }

    func testRegistrationAuthDataLayout() {
        let key = P256.Signing.PrivateKey().publicKey
        let credential = Data(repeating: 0xAB, count: 32)
        let auth = ApplePasswordsPasskeyManager.buildRegistrationAuthData(
            rpId: "example.com", signCount: 7, credentialId: credential, publicKey: key)
        let bytes = [UInt8](auth)
        XCTAssertEqual(auth.count, 37 + 16 + 2 + 32 + 77)
        XCTAssertEqual(auth.prefix(32), Data(SHA256.hash(data: Data("example.com".utf8))))
        XCTAssertEqual(bytes[32], 0x5D, "UP | UV | BE | BS | AT")
        XCTAssertEqual(Array(bytes[33..<37]), [0, 0, 0, 7])
        XCTAssertEqual(Array(bytes[37..<53]), Array("SafariumPasskey".utf8) + [0x01])
        XCTAssertEqual(Array(bytes[53..<55]), [0x00, 0x20], "credential length is big-endian 32")
        XCTAssertEqual(auth.subdata(in: 55..<87), credential)
        XCTAssertEqual(auth.subdata(in: 87..<164), ApplePasswordsPasskeyManager.encodeCOSEPublicKey(key))
    }

    func testRegistrationSignCountIsBigEndianMaximum() {
        let key = P256.Signing.PrivateKey().publicKey
        let auth = ApplePasswordsPasskeyManager.buildRegistrationAuthData(
            rpId: "a.test", signCount: UInt32.max, credentialId: Data([1]), publicKey: key)
        XCTAssertEqual(Array(auth[33..<37]), [0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testAssertionAuthDataLayout() {
        let auth = ApplePasswordsPasskeyManager.buildAssertionAuthData(rpId: "example.com", signCount: 258)
        let bytes = [UInt8](auth)
        XCTAssertEqual(auth.count, 37)
        XCTAssertEqual(auth.prefix(32), Data(SHA256.hash(data: Data("example.com".utf8))))
        XCTAssertEqual(bytes[32], 0x1D, "UP | UV | BE | BS, no attested credential data")
        XCTAssertEqual(Array(bytes[33..<37]), [0, 0, 1, 2])
    }

    // MARK: Password generator

    func testGeneratedPasswordHasThreeFiveCharacterGroups() {
        let allowed = Set("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789")
        for _ in 0..<200 {
            let pw = ApplePasswordsPasskeyManager.generateStrongPassword()
            let groups = pw.split(separator: "-", omittingEmptySubsequences: false)
            XCTAssertEqual(groups.count, 3)
            XCTAssertEqual(pw.count, 17)
            for g in groups {
                XCTAssertEqual(g.count, 5)
                XCTAssertTrue(g.allSatisfy { allowed.contains($0) }, "unexpected character in \(pw)")
            }
        }
    }

    func testGeneratedPasswordsAreNotConstant() {
        let a = ApplePasswordsPasskeyManager.generateStrongPassword()
        let b = ApplePasswordsPasskeyManager.generateStrongPassword()
        XCTAssertNotEqual(a, b)
    }

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
        manager.savePasswordToAppleKeychain(host: "example.com", username: "a", password: "p")
        XCTAssertEqual(manager.loadVault().passwords.count, 1)
    }

    func testPasswordSaveLowercasesHostAndInsertsNewestFirst() {
        XCTAssertTrue(requireSandboxedVault())
        manager.savePasswordToAppleKeychain(host: "Example.COM", username: "alice", password: "one")
        manager.savePasswordToAppleKeychain(host: "other.org", username: "bob", password: "two")
        let entries = manager.loadVault().passwords
        XCTAssertEqual(entries.map { $0.host }, ["other.org", "example.com"])
        XCTAssertEqual(entries.last?.password, "one")
    }

    func testPasswordSaveReplacesSameHostAndUsername() {
        XCTAssertTrue(requireSandboxedVault())
        manager.savePasswordToAppleKeychain(host: "example.com", username: "alice", password: "old")
        manager.savePasswordToAppleKeychain(host: "EXAMPLE.com", username: "alice", password: "new")
        manager.savePasswordToAppleKeychain(host: "example.com", username: "carol", password: "other")
        let entries = manager.loadVault().passwords
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first(where: { $0.username == "alice" })?.password, "new")
    }

    func testPersistedVaultIsOwnerOnlyReadable() throws {
        XCTAssertTrue(requireSandboxedVault())
        manager.savePasswordToAppleKeychain(host: "example.com", username: "a", password: "p")
        let attrs = try FileManager.default.attributesOfItem(atPath: manager.vaultURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testVaultIsEncryptedAtRestAndRoundTrips() throws {
        XCTAssertTrue(requireSandboxedVault())
        manager.savePasswordToAppleKeychain(host: "example.com", username: "a", password: "hunter2-XYZ")
        let raw = try Data(contentsOf: manager.vaultURL)
        XCTAssertEqual(raw.prefix(4), SafariumVaultCrypto.magic, "vault must be written as an encrypted container")
        XCTAssertNil(raw.range(of: Data("hunter2-XYZ".utf8)), "password must not appear in the file")
        XCTAssertNil(raw.range(of: Data("example.com".utf8)), "host must not appear in the file")
        XCTAssertEqual(manager.queryAppleKeychainPasswords(forHost: "example.com").first?.password, "hunter2-XYZ")
    }

    func testLegacyPlaintextVaultIsMigratedToEncrypted() throws {
        XCTAssertTrue(requireSandboxedVault())
        let legacy = #"{"passwords":[{"host":"old.example","username":"u","password":"legacy-secret"}],"passkeys":[]}"#
        try FileManager.default.createDirectory(at: manager.vaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: manager.vaultURL)
        XCTAssertEqual(manager.queryAppleKeychainPasswords(forHost: "old.example").first?.password, "legacy-secret")
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

    func testPasswordQueryMatchesHostAndSubdomainsOnly() {
        XCTAssertTrue(requireSandboxedVault())
        manager.savePasswordToAppleKeychain(host: "example.com", username: "a", password: "p")
        XCTAssertEqual(manager.queryAppleKeychainPasswords(forHost: "example.com").count, 1)
        XCTAssertEqual(manager.queryAppleKeychainPasswords(forHost: "WWW.Example.com").count, 1)
        XCTAssertEqual(manager.queryAppleKeychainPasswords(forHost: "login.example.com").count, 1)
        XCTAssertEqual(manager.queryAppleKeychainPasswords(forHost: "evilexample.com").count, 0,
                       "a suffix match must respect the dot boundary")
        XCTAssertEqual(manager.queryAppleKeychainPasswords(forHost: "example.org").count, 0)
    }

    func testSubdomainPasswordDoesNotLeakToParent() {
        XCTAssertTrue(requireSandboxedVault())
        manager.savePasswordToAppleKeychain(host: "login.example.com", username: "a", password: "p")
        XCTAssertEqual(manager.queryAppleKeychainPasswords(forHost: "example.com").count, 0)
        XCTAssertEqual(manager.queryAppleKeychainPasswords(forHost: "login.example.com").count, 1)
    }

    func testPublicSuffixPasswordMustNotMatchUnrelatedRegistrant() {
        XCTAssertTrue(requireSandboxedVault())
        manager.savePasswordToAppleKeychain(host: "co.uk", username: "a", password: "p")
        XCTAssertEqual(manager.queryAppleKeychainPasswords(forHost: "shop.co.uk").count, 0)
    
    }

    func testPasskeyLookupMatchesRelyingPartyAndSubdomains() {
        XCTAssertTrue(requireSandboxedVault())
        manager.savePasskeyToKeychain(passkey(rpId: "example.com", credentialID: "c1"))
        XCTAssertEqual(manager.queryPasskeys(forRpId: "example.com").count, 1)
        XCTAssertEqual(manager.queryPasskeys(forRpId: "login.example.com").count, 1)
        XCTAssertEqual(manager.queryPasskeys(forRpId: "evilexample.com").count, 0)
        XCTAssertEqual(manager.queryPasskeys(forRpId: "example.org").count, 0)
    }

    func testPasskeyLookupIsCaseInsensitive() {
        XCTAssertTrue(requireSandboxedVault())
        manager.savePasskeyToKeychain(passkey(rpId: "Example.com", credentialID: "c1"))
        XCTAssertEqual(manager.queryPasskeys(forRpId: "EXAMPLE.COM").count, 1)
    }

    func testPasskeySaveReplacesSameCredentialAndSortsNewestFirst() {
        XCTAssertTrue(requireSandboxedVault())
        manager.savePasskeyToKeychain(passkey(rpId: "example.com", credentialID: "old", userName: "a",
                                              createdAt: Date(timeIntervalSince1970: 100)))
        manager.savePasskeyToKeychain(passkey(rpId: "example.com", credentialID: "new", userName: "b",
                                              createdAt: Date(timeIntervalSince1970: 300)))
        manager.savePasskeyToKeychain(passkey(rpId: "example.com", credentialID: "old", userName: "c",
                                              createdAt: Date(timeIntervalSince1970: 200)))
        let found = manager.queryPasskeys(forRpId: "example.com")
        XCTAssertEqual(found.map { $0.credentialIDBase64URL }, ["new", "old"])
        XCTAssertEqual(found.last?.userName, "c", "the replacement wins")
    }

    func testPasskeyLookupIgnoresUnrelatedRelyingParties() {
        XCTAssertTrue(requireSandboxedVault())
        manager.savePasskeyToKeychain(passkey(rpId: "github.com", credentialID: "g"))
        XCTAssertTrue(manager.queryPasskeys(forRpId: "gitlab.com").isEmpty)
    }

    func testPublicSuffixPasskeyMustNotMatchUnrelatedRegistrant() {
        XCTAssertTrue(requireSandboxedVault())
        manager.savePasskeyToKeychain(passkey(rpId: "co.uk", credentialID: "p"))
        XCTAssertTrue(manager.queryPasskeys(forRpId: "shop.co.uk").isEmpty)
    
    }

    func testVaultRoundTripsBothCollections() {
        XCTAssertTrue(requireSandboxedVault())
        manager.savePasswordToAppleKeychain(host: "example.com", username: "a", password: "p")
        manager.savePasskeyToKeychain(passkey(rpId: "example.com", credentialID: "c1"))
        let vault = manager.loadVault()
        XCTAssertEqual(vault.passwords.count, 1)
        XCTAssertEqual(vault.passkeys.map { $0.credentialIDBase64URL }, ["c1"])
    }
}
