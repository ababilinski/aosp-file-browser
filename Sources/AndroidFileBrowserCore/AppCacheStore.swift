import CryptoKit
import Darwin
import Foundation
import Security

public struct AppCacheUsage: Equatable, Sendable {
    public var previewBytes: Int64
    public var thumbnailBytes: Int64

    public init(previewBytes: Int64 = 0, thumbnailBytes: Int64 = 0) {
        self.previewBytes = max(0, previewBytes)
        self.thumbnailBytes = max(0, thumbnailBytes)
    }

    public var totalBytes: Int64 {
        previewBytes + thumbnailBytes
    }

    public static let zero = AppCacheUsage()
}

public actor AppCacheStore {
    public static let thumbnailFolderName = "AndroidFileBrowserThumbnails"
    public static let runtimePreviewFolderName = "AndroidFileBrowserPreviewRuntime"
    public static let trashPreviewFolderName = "AndroidFileBrowserTrashPreviews"
    private static let trashPrivacyMigrationMarkerName = ".AndroidFileBrowserTrashPrivacy-v1"

    public static let previewFolderNames: [String] = [
        "AndroidFileBrowserPreviews",
        "AndroidFileBrowserCaptures",
        "AndroidFileBrowserUSBTransferPreviews",
        "AndroidFileBrowserDragExports",
        "AndroidFileBrowserCrossDevicePaste",
        "AndroidFileBrowserArchives",
        "AndroidFileBrowserUSBTransferArchives",
        "AndroidFileBrowserAPKIcons",
        trashPreviewFolderName,
        runtimePreviewFolderName
    ]

    private static let encryptedPreviewFolderNames: Set<String> = [
        "AndroidFileBrowserPreviews",
        "AndroidFileBrowserCaptures",
        "AndroidFileBrowserUSBTransferPreviews"
    ]
    private static let encryptedFileExtension = "afbpreview"
    private static let encryptionMagic = Data("AFBPREVIEW1\n".utf8)
    private static let encryptionChunkSize = 1_048_576

    private let cacheRoot: URL
    private let runtimeSessionDirectory: URL
    private let encryptionKeyProvider: @Sendable () -> Data?
    private var encryptionKey: SymmetricKey?
    private var leaseCounts: [String: Int] = [:]
    private var backingPathByReadablePath: [String: String] = [:]

    public init(
        cacheRoot: URL? = nil,
        encryptionKeyData: Data? = nil,
        encryptionKeyProvider: (@Sendable () -> Data?)? = nil
    ) {
        let root = cacheRoot
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.cacheRoot = root
        self.runtimeSessionDirectory = root
            .appending(path: Self.runtimePreviewFolderName, directoryHint: .isDirectory)
            .appending(path: "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", directoryHint: .isDirectory)

        self.encryptionKeyProvider = encryptionKeyProvider ?? { PreviewCacheKeychain.loadOrCreateKey() }
        self.encryptionKey = encryptionKeyData.flatMap { data in
            data.count == 32 ? SymmetricKey(data: data) : nil
        }

        // Older releases stored Trash previews and thumbnails in the shared
        // caches. They cannot be identified safely if legacy metadata is
        // damaged or its key is unavailable, so discard those disposable
        // shared caches once when adopting device-bound Trash storage.
        Self.removeLegacyTrashCachesOnce(in: root)
        let runtimeRoot = root.appending(path: Self.runtimePreviewFolderName, directoryHint: .isDirectory)
        Self.removeAbandonedRuntimeSessions(in: runtimeRoot)
        // Trash previews are intentionally session-only. A prior crash must not
        // leave content from a disconnected phone available on the next launch.
        try? FileManager.default.removeItem(
            at: root.appending(path: Self.trashPreviewFolderName, directoryHint: .isDirectory)
        )
        try? Self.createPrivateDirectory(runtimeSessionDirectory)
    }

    public func usage() -> AppCacheUsage {
        AppCacheUsage(
            previewBytes: Self.previewFolderNames.reduce(0) { $0 + folderSize(named: $1) },
            thumbnailBytes: folderSize(named: Self.thumbnailFolderName)
        )
    }

    public func clearPreviewFiles() throws {
        try removeFolders(named: Self.previewFolderNames)
        leaseCounts.removeAll()
        backingPathByReadablePath.removeAll()
        try Self.createPrivateDirectory(runtimeSessionDirectory)
    }

    public func clearThumbnails() throws {
        try removeContents(ofFolderNamed: Self.thumbnailFolderName)
    }

    public func clearAll() throws {
        try removeFolders(named: Self.previewFolderNames)
        try removeContents(ofFolderNamed: Self.thumbnailFolderName)
        leaseCounts.removeAll()
        backingPathByReadablePath.removeAll()
        try Self.createPrivateDirectory(runtimeSessionDirectory)
    }

    public func makePreviewStagingDirectory() throws -> URL {
        let directory = runtimeSessionDirectory
            .appending(path: "Staging", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try Self.createPrivateDirectory(directory)
        return directory
    }

    public func trashPreviewURL(deviceIdentity: String, cacheName: String) throws -> URL {
        let directory = trashPreviewDirectory(deviceIdentity: deviceIdentity)
        try Self.createPrivateDirectory(directory)
        return directory.appending(path: (cacheName as NSString).lastPathComponent)
    }

    public func clearTrashPreviewFiles(deviceIdentity: String) throws {
        let directory = trashPreviewDirectory(deviceIdentity: deviceIdentity)
        releaseReadablePreviews(backedByDescendantsOf: directory)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func clearAllTrashPreviewFiles() throws {
        let directory = cacheRoot.appending(path: Self.trashPreviewFolderName, directoryHint: .isDirectory)
        releaseReadablePreviews(backedByDescendantsOf: directory)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func removeLegacyTrashPreviewFiles(cacheNames: Set<String>) {
        guard !cacheNames.isEmpty else { return }
        let directory = cacheRoot.appending(path: "AndroidFileBrowserPreviews", directoryHint: .isDirectory)
        let backingPaths = Set(cacheNames.flatMap { name -> [String] in
            let cacheURL = directory.appending(path: (name as NSString).lastPathComponent)
            return [
                cacheURL.standardizedFileURL.path,
                Self.encryptedURL(for: cacheURL).standardizedFileURL.path
            ]
        })

        let readablePaths = backingPathByReadablePath.compactMap { entry in
            backingPaths.contains(entry.value) ? entry.key : nil
        }
        for readablePath in readablePaths {
            try? FileManager.default.removeItem(atPath: readablePath)
            leaseCounts[readablePath] = nil
            backingPathByReadablePath[readablePath] = nil
        }
        for path in backingPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    public func storePreview(from sourceURL: URL, at cacheURL: URL, encrypt: Bool) throws {
        try Self.createPrivateDirectory(cacheURL.deletingLastPathComponent())
        let encryptedURL = Self.encryptedURL(for: cacheURL)

        if encrypt {
            try encryptFile(at: sourceURL, to: encryptedURL)
            if sourceURL.standardizedFileURL != cacheURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: sourceURL)
            }
            try? FileManager.default.removeItem(at: cacheURL)
            Self.touch(encryptedURL)
        } else {
            try? FileManager.default.removeItem(at: encryptedURL)
            if sourceURL.standardizedFileURL != cacheURL.standardizedFileURL {
                try Self.replaceItem(at: cacheURL, with: sourceURL)
            }
            try Self.makePrivateFile(cacheURL)
            Self.touch(cacheURL)
        }

        Self.removeEmptyParents(of: sourceURL, stoppingAt: runtimeSessionDirectory)
    }

    public func readablePreviewURL(for cacheURL: URL, encrypt: Bool) throws -> URL? {
        let fileManager = FileManager.default
        let encryptedURL = Self.encryptedURL(for: cacheURL)

        if encrypt {
            if !fileManager.fileExists(atPath: encryptedURL.path),
               fileManager.fileExists(atPath: cacheURL.path) {
                try storePreview(from: cacheURL, at: cacheURL, encrypt: true)
            }
            guard fileManager.fileExists(atPath: encryptedURL.path) else { return nil }

            let readableURL = runtimeReadableURL(for: cacheURL, backingURL: encryptedURL)
            if !fileManager.fileExists(atPath: readableURL.path) {
                do {
                    try decryptFile(at: encryptedURL, to: readableURL)
                } catch {
                    try? fileManager.removeItem(at: encryptedURL)
                    return nil
                }
            }
            Self.touch(encryptedURL)
            retain(readableURL: readableURL, backingURL: encryptedURL)
            return readableURL
        }

        if !fileManager.fileExists(atPath: cacheURL.path),
           fileManager.fileExists(atPath: encryptedURL.path) {
            // Cache entries are disposable. When encryption is off, discard an old
            // encrypted entry instead of consulting Keychain just to convert it.
            try? fileManager.removeItem(at: encryptedURL)
            return nil
        }
        guard fileManager.fileExists(atPath: cacheURL.path) else { return nil }
        try Self.makePrivateFile(cacheURL)
        Self.touch(cacheURL)
        retain(readableURL: cacheURL, backingURL: cacheURL)
        return cacheURL
    }

    public func releaseReadablePreview(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard let count = leaseCounts[path] else { return }
        if count > 1 {
            leaseCounts[path] = count - 1
            return
        }

        leaseCounts[path] = nil
        backingPathByReadablePath[path] = nil
        if Self.isDescendant(url, of: runtimeSessionDirectory) {
            try? FileManager.default.removeItem(at: url)
            Self.removeEmptyParents(of: url, stoppingAt: runtimeSessionDirectory)
        }
    }

    public func removeRuntimePreviewFiles() throws {
        let runtimeRoot = cacheRoot.appending(path: Self.runtimePreviewFolderName, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: runtimeRoot)
        leaseCounts.removeAll()
        backingPathByReadablePath.removeAll()
        try Self.createPrivateDirectory(runtimeSessionDirectory)
    }

    @discardableResult
    public func expirePreviewFiles(olderThan cutoff: Date) throws -> AppCacheUsage {
        let protectedPaths = activeProtectedPaths
        let fileManager = FileManager.default
        for name in Self.previewFolderNames {
            let directory = cacheRoot.appending(path: name, directoryHint: .isDirectory)
            for entry in files(in: directory) {
                guard entry.lastUsed < cutoff,
                      !protectedPaths.contains(entry.url.standardizedFileURL.path) else {
                    continue
                }
                try? fileManager.removeItem(at: entry.url)
            }
        }
        removeEmptyCacheDirectories()
        return usage()
    }

    @discardableResult
    public func reprotectPreviewFiles(encrypt: Bool) throws -> AppCacheUsage {
        let fileManager = FileManager.default
        let protectedPaths = activeProtectedPaths

        for folderName in Self.encryptedPreviewFolderNames {
            let directory = cacheRoot.appending(path: folderName, directoryHint: .isDirectory)
            for entry in files(in: directory) {
                let path = entry.url.standardizedFileURL.path
                guard !protectedPaths.contains(path) else { continue }

                if encrypt {
                    guard entry.url.pathExtension != Self.encryptedFileExtension else { continue }
                    try storePreview(from: entry.url, at: entry.url, encrypt: true)
                } else {
                    guard entry.url.pathExtension == Self.encryptedFileExtension else { continue }
                    // Do not unlock Keychain when the feature is disabled. The preview
                    // can be downloaded again as an ordinary private cache file.
                    try? fileManager.removeItem(at: entry.url)
                }
            }
        }

        removeEmptyCacheDirectories()
        return usage()
    }

    @discardableResult
    public func trim(toByteLimit byteLimit: Int64, protecting protectedURLs: Set<URL> = []) throws -> AppCacheUsage {
        let byteLimit = max(0, byteLimit)
        var entries = cacheEntries()
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > byteLimit else { return usage() }

        let protectedPaths = Set(protectedURLs.map { $0.standardizedFileURL.path })
            .union(activeProtectedPaths)
        entries.sort { lhs, rhs in
            if lhs.lastUsed == rhs.lastUsed {
                return lhs.url.path < rhs.url.path
            }
            return lhs.lastUsed < rhs.lastUsed
        }

        let fileManager = FileManager.default
        for entry in entries where total > byteLimit {
            guard !protectedPaths.contains(entry.url.standardizedFileURL.path) else { continue }
            do {
                try fileManager.removeItem(at: entry.url)
                total -= entry.size
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }

        removeEmptyCacheDirectories()
        return usage()
    }

    private var activeProtectedPaths: Set<String> {
        Set(leaseCounts.keys).union(backingPathByReadablePath.values)
    }

    private func trashPreviewDirectory(deviceIdentity: String) -> URL {
        let digest = SHA256.hash(data: Data(deviceIdentity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheRoot
            .appending(path: Self.trashPreviewFolderName, directoryHint: .isDirectory)
            .appending(path: digest, directoryHint: .isDirectory)
    }

    private func releaseReadablePreviews(backedByDescendantsOf directory: URL) {
        let root = directory.standardizedFileURL.path
        let readablePaths = backingPathByReadablePath.compactMap { entry in
            entry.value == root || entry.value.hasPrefix(root + "/") ? entry.key : nil
        }
        for readablePath in readablePaths {
            try? FileManager.default.removeItem(atPath: readablePath)
            leaseCounts[readablePath] = nil
            backingPathByReadablePath[readablePath] = nil
        }
    }

    private func retain(readableURL: URL, backingURL: URL) {
        let readablePath = readableURL.standardizedFileURL.path
        leaseCounts[readablePath, default: 0] += 1
        backingPathByReadablePath[readablePath] = backingURL.standardizedFileURL.path
    }

    private func runtimeReadableURL(for cacheURL: URL, backingURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(backingURL.standardizedFileURL.path.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return runtimeSessionDirectory
            .appending(path: "Readable", directoryHint: .isDirectory)
            .appending(path: digest, directoryHint: .isDirectory)
            .appending(path: cacheURL.lastPathComponent)
    }

    private func encryptFile(at sourceURL: URL, to destinationURL: URL) throws {
        let encryptionKey = try resolvedEncryptionKey()
        try Self.createPrivateDirectory(destinationURL.deletingLastPathComponent())
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).tmp")
        let input = try FileHandle(forReadingFrom: sourceURL)
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporaryURL)

        do {
            try output.write(contentsOf: Self.encryptionMagic)
            while let chunk = try input.read(upToCount: Self.encryptionChunkSize), !chunk.isEmpty {
                let sealed = try AES.GCM.seal(chunk, using: encryptionKey)
                guard let combined = sealed.combined else {
                    throw PreviewCacheError.encryptionFailed
                }
                try output.write(contentsOf: Self.encodedUInt32(UInt32(combined.count)))
                try output.write(contentsOf: combined)
            }
            try input.close()
            try output.synchronize()
            try output.close()
            try Self.makePrivateFile(temporaryURL)
            try Self.replaceItem(at: destinationURL, with: temporaryURL)
        } catch {
            try? input.close()
            try? output.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func decryptFile(at sourceURL: URL, to destinationURL: URL) throws {
        let encryptionKey = try resolvedEncryptionKey()
        try Self.createPrivateDirectory(destinationURL.deletingLastPathComponent())
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).tmp")
        let input = try FileHandle(forReadingFrom: sourceURL)
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporaryURL)

        do {
            let magic = try Self.readExactly(Self.encryptionMagic.count, from: input)
            guard magic == Self.encryptionMagic else { throw PreviewCacheError.invalidEncryptedFile }

            while true {
                guard let lengthData = try input.read(upToCount: 4), !lengthData.isEmpty else { break }
                guard lengthData.count == 4 else { throw PreviewCacheError.invalidEncryptedFile }
                let length = Int(Self.decodedUInt32(lengthData))
                guard length >= 28, length <= Self.encryptionChunkSize + 28 else {
                    throw PreviewCacheError.invalidEncryptedFile
                }
                let combined = try Self.readExactly(length, from: input)
                let sealed = try AES.GCM.SealedBox(combined: combined)
                let plaintext = try AES.GCM.open(sealed, using: encryptionKey)
                try output.write(contentsOf: plaintext)
            }

            try input.close()
            try output.synchronize()
            try output.close()
            try Self.makePrivateFile(temporaryURL)
            try Self.replaceItem(at: destinationURL, with: temporaryURL)
        } catch {
            try? input.close()
            try? output.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func folderSize(named name: String) -> Int64 {
        files(in: cacheRoot.appending(path: name, directoryHint: .isDirectory))
            .reduce(Int64(0)) { $0 + $1.size }
    }

    private func resolvedEncryptionKey() throws -> SymmetricKey {
        if let encryptionKey {
            return encryptionKey
        }

        guard let storedKey = encryptionKeyProvider(), storedKey.count == 32 else {
            throw PreviewCacheError.encryptionKeyUnavailable
        }
        let key = SymmetricKey(data: storedKey)
        encryptionKey = key
        return key
    }

    private func cacheEntries() -> [CacheEntry] {
        (Self.previewFolderNames + [Self.thumbnailFolderName]).flatMap { name in
            files(in: cacheRoot.appending(path: name, directoryHint: .isDirectory))
        }
    }

    private func files(in directory: URL) -> [CacheEntry] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path),
              let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [],
                errorHandler: { _, _ in true }
              ) else {
            return []
        }

        var entries: [CacheEntry] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }
            entries.append(
                CacheEntry(
                    url: url,
                    size: Int64(values.fileSize ?? 0),
                    lastUsed: values.contentModificationDate ?? .distantPast
                )
            )
        }
        return entries
    }

    private func removeFolders(named names: [String]) throws {
        let fileManager = FileManager.default
        for name in names {
            let url = cacheRoot.appending(path: name, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private func removeContents(ofFolderNamed name: String) throws {
        let fileManager = FileManager.default
        let directory = cacheRoot.appending(path: name, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: directory.path) else { return }

        for entry in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            do {
                try fileManager.removeItem(at: entry)
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }
    }

    private func removeEmptyCacheDirectories() {
        let fileManager = FileManager.default
        // ThumbnailService writes asynchronously. Keep its shared directory in place
        // so a concurrent clear or trim cannot invalidate an in-flight atomic write.
        for name in Self.previewFolderNames {
            let directory = cacheRoot.appending(path: name, directoryHint: .isDirectory)
            guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil),
                  enumerator.nextObject() == nil else {
                continue
            }
            try? fileManager.removeItem(at: directory)
        }
    }

    private static func encryptedURL(for cacheURL: URL) -> URL {
        cacheURL.appendingPathExtension(encryptedFileExtension)
    }

    private static func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
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

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private static func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let root = directory.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    private static func removeEmptyParents(of url: URL, stoppingAt root: URL) {
        let fileManager = FileManager.default
        var parent = url.deletingLastPathComponent()
        while isDescendant(parent, of: root), parent.standardizedFileURL != root.standardizedFileURL {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: parent.path), contents.isEmpty else { break }
            try? fileManager.removeItem(at: parent)
            parent.deleteLastPathComponent()
        }
    }

    private static func removeAbandonedRuntimeSessions(in runtimeRoot: URL) {
        let fileManager = FileManager.default
        guard let sessions = try? fileManager.contentsOfDirectory(
            at: runtimeRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        for session in sessions {
            let prefix = session.lastPathComponent.split(separator: "-", maxSplits: 1).first
            guard let prefix, let pid = Int32(prefix) else {
                try? fileManager.removeItem(at: session)
                continue
            }
            if pid == currentPID || processIsRunning(pid) { continue }
            try? fileManager.removeItem(at: session)
        }
    }

    private static func removeLegacyTrashCachesOnce(in root: URL) {
        let marker = root.appending(path: trashPrivacyMigrationMarkerName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for folderName in ["AndroidFileBrowserPreviews", thumbnailFolderName] {
                let folder = root.appending(path: folderName, directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: folder.path) {
                    try FileManager.default.removeItem(at: folder)
                }
            }
            try Data("1".utf8).write(to: marker, options: .atomic)
            try makePrivateFile(marker)
        } catch {
            // A missing marker retries the privacy cleanup on the next launch.
        }
    }

    private static func processIsRunning(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func encodedUInt32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private static func decodedUInt32(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                throw PreviewCacheError.invalidEncryptedFile
            }
            result.append(chunk)
        }
        return result
    }

    private struct CacheEntry {
        let url: URL
        let size: Int64
        let lastUsed: Date
    }
}

private enum PreviewCacheError: LocalizedError {
    case encryptionFailed
    case encryptionKeyUnavailable
    case invalidEncryptedFile

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            "The preview cache could not be encrypted."
        case .encryptionKeyUnavailable:
            "Preview encryption could not access its key. Turn off preview encryption or try again."
        case .invalidEncryptedFile:
            "The encrypted preview cache is damaged or no longer readable."
        }
    }
}

private enum PreviewCacheKeychain {
    private static let service = "com.adrianbabilinski.ASOPFileBrowser.preview-cache"
    private static let account = "preview-cache-key-v1"

    static func loadOrCreateKey() -> Data? {
        let firstLoad = loadKey()
        if firstLoad.status == errSecSuccess,
           let existing = firstLoad.data,
           existing.count == 32 {
            return existing
        }
        guard firstLoad.status == errSecItemNotFound else { return nil }

        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: key
        ]
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return key
        }
        if addStatus == errSecDuplicateItem {
            let secondLoad = loadKey()
            return secondLoad.status == errSecSuccess ? secondLoad.data : nil
        }
        return nil
    }

    private static func loadKey() -> (status: OSStatus, data: Data?) {
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
