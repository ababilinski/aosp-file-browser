import CryptoKit
import Foundation
import Security

struct TrashRecordsArchive: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    var recordsByDeviceIdentity: [String: [TrashRecord]]

    init(records: [TrashRecord] = []) {
        self.init(recordsByDeviceIdentity: Dictionary(grouping: records, by: \.deviceSerial))
    }

    init(recordsByDeviceIdentity: [String: [TrashRecord]]) {
        self.version = Self.currentVersion
        var seen = Set<TrashRecord.ID>()
        let records = recordsByDeviceIdentity
            .sorted { $0.key < $1.key }
            .flatMap(\.value)
            .filter { !$0.deviceSerial.isEmpty && seen.insert($0.id).inserted }
        self.recordsByDeviceIdentity = Dictionary(grouping: records, by: \.deviceSerial)
            .mapValues { records in
                records.sorted { lhs, rhs in
                    if lhs.deletedAt == rhs.deletedAt { return lhs.id.uuidString < rhs.id.uuidString }
                    return lhs.deletedAt > rhs.deletedAt
                }
            }
    }

    var allRecords: [TrashRecord] {
        recordsByDeviceIdentity.values
            .flatMap { $0 }
            .sorted { lhs, rhs in
                if lhs.deletedAt == rhs.deletedAt { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.deletedAt > rhs.deletedAt
            }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case recordsByDeviceIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw TrashRecordStoreError.unsupportedVersion(version)
        }
        let decoded = try container.decode([String: [TrashRecord]].self, forKey: .recordsByDeviceIdentity)
        self.init(recordsByDeviceIdentity: decoded)
    }

}

struct TrashRecordStoreLoadResult: Sendable {
    let archive: TrashRecordsArchive
    let recoveryNotice: String?
    let migratedLegacyFile: Bool
    let recoveredFromBackup: Bool

    static let empty = TrashRecordStoreLoadResult(
        archive: TrashRecordsArchive(),
        recoveryNotice: nil,
        migratedLegacyFile: false,
        recoveredFromBackup: false
    )
}

struct TrashRecordStore: Sendable {
    static let encryptionMagic = Data("AFBTRASH1\n".utf8)

    private let fileURL: URL
    private let encryptionKeyProvider: @Sendable () -> Data?

    init(
        fileURL: URL,
        encryptionKeyData: Data? = nil,
        encryptionKeyProvider: (@Sendable () -> Data?)? = nil
    ) {
        self.fileURL = fileURL
        if let encryptionKeyData {
            self.encryptionKeyProvider = { encryptionKeyData }
        } else {
            self.encryptionKeyProvider = encryptionKeyProvider ?? {
                TrashRecordsKeychain.loadOrCreateKey()
            }
        }
    }

    var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }

    var unreadableURL: URL {
        fileURL.appendingPathExtension("unreadable")
    }

    func load() -> TrashRecordStoreLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if let recovered = recoverFromBackup() {
                return recovered
            }
            if FileManager.default.fileExists(atPath: backupURL.path) {
                return unavailableResult(
                    "Trash history could not be unlocked. Its protected backup was left in place so recovery can be retried."
                )
            }
            return .empty
        }

        do {
            let data = try Data(contentsOf: fileURL)
            if data.starts(with: Self.encryptionMagic) {
                do {
                    return TrashRecordStoreLoadResult(
                        archive: try decodeEncrypted(data),
                        recoveryNotice: nil,
                        migratedLegacyFile: false,
                        recoveredFromBackup: false
                    )
                } catch {
                    if let recovered = recoverFromBackup() {
                        return recovered
                    }
                    return unavailableResult(
                        "Trash history could not be unlocked. Its protected metadata was left in place so recovery can be retried."
                    )
                }
            }

            let records = try JSONDecoder().decode([TrashRecord].self, from: data)
            let archive = TrashRecordsArchive(records: records)
            do {
                try saveMigratingLegacy(archive, expectedLegacyData: data)
                return TrashRecordStoreLoadResult(
                    archive: archive,
                    recoveryNotice: nil,
                    migratedLegacyFile: true,
                    recoveredFromBackup: false
                )
            } catch {
                // Keep the legacy file so a later launch can retry migration, but
                // do not expose records that could not be placed in protected storage.
                try? Self.makePrivateFile(fileURL)
                return TrashRecordStoreLoadResult(
                    archive: TrashRecordsArchive(),
                    recoveryNotice: "Legacy Trash history could not be encrypted and is unavailable. Its private metadata file was preserved for a later migration retry.",
                    migratedLegacyFile: false,
                    recoveredFromBackup: false
                )
            }
        } catch {
            if let recovered = recoverFromBackup() {
                return recovered
            }
            return unavailableResult(
                "Trash history is unreadable. The metadata file was left in place so recovery can be retried."
            )
        }
    }

    func save(_ archive: TrashRecordsArchive) throws {
        try save(archive, expectedLegacyData: nil)
    }

    private func saveMigratingLegacy(
        _ archive: TrashRecordsArchive,
        expectedLegacyData: Data
    ) throws {
        try save(archive, expectedLegacyData: expectedLegacyData)
    }

    private func save(
        _ archive: TrashRecordsArchive,
        expectedLegacyData: Data?
    ) throws {
        let encoded = try JSONEncoder().encode(archive)
        let encrypted = try encrypt(encoded)
        try Self.createPrivateDirectory(fileURL.deletingLastPathComponent())

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let current = try Data(contentsOf: fileURL)
            if current.starts(with: Self.encryptionMagic) {
                // Never replace protected history unless the current key can
                // authenticate and decode it first. This prevents a Keychain
                // reset or damaged archive from turning the next Trash action
                // into silent history loss.
                _ = try decodeEncrypted(current)
                try? FileManager.default.removeItem(at: backupURL)
                try current.write(to: backupURL, options: .atomic)
                try Self.makePrivateFile(backupURL)
            } else {
                guard let expectedLegacyData, current == expectedLegacyData else {
                    throw TrashRecordStoreError.existingHistoryUnavailable
                }
                _ = try JSONDecoder().decode([TrashRecord].self, from: current)
            }
        } else if FileManager.default.fileExists(atPath: backupURL.path) {
            // A backup without a primary may be the only recoverable copy. A
            // normal write must not eventually rotate it away.
            throw TrashRecordStoreError.existingHistoryUnavailable
        }

        try encrypted.write(to: fileURL, options: .atomic)
        try Self.makePrivateFile(fileURL)
    }

    private func unavailableResult(_ notice: String) -> TrashRecordStoreLoadResult {
        TrashRecordStoreLoadResult(
            archive: TrashRecordsArchive(),
            recoveryNotice: notice,
            migratedLegacyFile: false,
            recoveredFromBackup: false
        )
    }

    private func recoverFromBackup() -> TrashRecordStoreLoadResult? {
        guard let backupData = try? Data(contentsOf: backupURL),
              backupData.starts(with: Self.encryptionMagic),
              let archive = try? decodeEncrypted(backupData) else {
            return nil
        }

        do {
            if FileManager.default.fileExists(atPath: unreadableURL.path) {
                try FileManager.default.removeItem(at: unreadableURL)
            }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.moveItem(at: fileURL, to: unreadableURL)
                try Self.makePrivateFile(unreadableURL)
            }
            try backupData.write(to: fileURL, options: .atomic)
            try Self.makePrivateFile(fileURL)
        } catch {
            // Returning the verified backup in memory is still safer than discarding
            // the history. Leave both source files untouched for a later retry.
        }

        return TrashRecordStoreLoadResult(
            archive: archive,
            recoveryNotice: "Trash history was recovered from its last protected backup.",
            migratedLegacyFile: false,
            recoveredFromBackup: true
        )
    }

    private func encrypt(_ plaintext: Data) throws -> Data {
        let key = try resolvedKey()
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw TrashRecordStoreError.encryptionFailed
        }
        return Self.encryptionMagic + combined
    }

    private func decodeEncrypted(_ data: Data) throws -> TrashRecordsArchive {
        guard data.starts(with: Self.encryptionMagic) else {
            throw TrashRecordStoreError.invalidEncryptedFile
        }
        let encrypted = data.dropFirst(Self.encryptionMagic.count)
        guard encrypted.count >= 28 else {
            throw TrashRecordStoreError.invalidEncryptedFile
        }
        let box = try AES.GCM.SealedBox(combined: Data(encrypted))
        let plaintext = try AES.GCM.open(box, using: resolvedKey())
        return try JSONDecoder().decode(TrashRecordsArchive.self, from: plaintext)
    }

    private func resolvedKey() throws -> SymmetricKey {
        guard let keyData = encryptionKeyProvider(), keyData.count == 32 else {
            throw TrashRecordStoreError.encryptionKeyUnavailable
        }
        return SymmetricKey(data: keyData)
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func makePrivateFile(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum TrashRecordStoreError: LocalizedError {
    case encryptionFailed
    case encryptionKeyUnavailable
    case existingHistoryUnavailable
    case invalidEncryptedFile
    case storageUnavailable
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            "Trash history could not be encrypted."
        case .encryptionKeyUnavailable:
            "Trash history could not access its encryption key."
        case .existingHistoryUnavailable:
            "Existing Trash history is unavailable and was not overwritten."
        case .invalidEncryptedFile:
            "The protected Trash history is damaged or unreadable."
        case .storageUnavailable:
            "Protected Trash history storage is unavailable."
        case .unsupportedVersion(let version):
            "Trash history uses unsupported format version \(version)."
        }
    }
}

private enum TrashRecordsKeychain {
    private static let service = "com.adrianbabilinski.AOSPFileManager.trash-records"
    // Preserve access to Trash records encrypted before the product rename.
    private static let legacyService = "com.adrianbabilinski.ASOPFileBrowser.trash-records"
    private static let account = "trash-records-key-v1"

    static func loadOrCreateKey() -> Data? {
        let firstLoad = loadKey(service: service)
        if firstLoad.status == errSecSuccess,
           let existing = firstLoad.data,
           existing.count == 32 {
            return existing
        }
        let legacyLoad = loadKey(service: legacyService)
        if firstLoad.status == errSecItemNotFound,
           legacyLoad.status == errSecSuccess,
           let legacy = legacyLoad.data,
           legacy.count == 32 {
            storeKey(legacy)
            return legacy
        }
        guard firstLoad.status == errSecItemNotFound else { return nil }

        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { return nil }

        if storeKey(key) == errSecSuccess {
            return key
        }
        let secondLoad = loadKey(service: service)
        return secondLoad.status == errSecSuccess ? secondLoad.data : nil
    }

    @discardableResult
    private static func storeKey(_ key: Data) -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: key
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadKey(service: String) -> (status: OSStatus, data: Data?) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
}
