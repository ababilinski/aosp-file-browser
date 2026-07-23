import AppKit
import Foundation

public actor DeviceManager {
    private let adb: ADBClient

    public init(adb: ADBClient) {
        self.adb = adb
    }

    public func devices() async throws -> [AndroidDevice] {
        let result = try await adb.run(["devices", "-l"])
        return ADBParsers.parseDevices(result.stdout)
    }

    public func batteryStatus(device: AndroidDevice) async throws -> BatteryStatus? {
        let result = try await adb.shell(serial: device.serial, "dumpsys battery", allowFailure: true, timeout: 8)
        guard result.exitCode == 0 else { return nil }
        return ADBParsers.parseBatteryStatus(result.stdout)
    }

    public func connect(host: String) async throws {
        _ = try await adb.run(["connect", host], timeout: 20)
    }

    public func pair(host: String, code: String) async throws {
        _ = try await adb.run(["pair", host, code], timeout: 45)
    }

    public func enableWirelessADB(device: AndroidDevice, port: Int = 5555) async throws -> String {
        guard device.state == .device else {
            throw ADBWirelessConnectionError.deviceNotReady
        }
        guard device.connectionKind == .usb else {
            throw ADBWirelessConnectionError.requiresUSB
        }

        let network = try await adb.shell(
            serial: device.serial,
            "ip route get 1.1.1.1 2>/dev/null || ip -o -4 addr show wlan0 2>/dev/null",
            allowFailure: true,
            timeout: 8
        )
        guard let address = ADBParsers.parseWirelessIPv4Address(network.stdout) else {
            throw ADBWirelessConnectionError.noWiFiAddress
        }

        let endpoint = "\(address):\(port)"
        let tcpIP = try await adb.run(
            ["-s", device.serial, "tcpip", String(port)],
            allowFailure: true,
            timeout: 20
        )
        guard tcpIP.exitCode == 0,
              (tcpIP.stdout + tcpIP.stderr).localizedCaseInsensitiveContains("restarting in TCP mode") else {
            throw ADBWirelessConnectionError.tcpIPFailed(commandMessage(tcpIP))
        }

        var lastConnectionMessage = ""
        for attempt in 0..<4 {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(400))
            }
            let connection = try await adb.run(["connect", endpoint], allowFailure: true, timeout: 12)
            lastConnectionMessage = commandMessage(connection)
            let normalized = lastConnectionMessage.lowercased()
            if connection.exitCode == 0,
               normalized.contains("connected to") || normalized.contains("already connected") {
                if try await devices().contains(where: { $0.serial == endpoint && $0.state == .device }) {
                    return endpoint
                }
            }
        }

        throw ADBWirelessConnectionError.connectionFailed(
            endpoint: endpoint,
            message: lastConnectionMessage
        )
    }

    private func commandMessage(_ result: ADBCommandResult) -> String {
        let combined = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? "ADB did not provide additional details." : combined
    }
}

public enum ADBWirelessConnectionError: LocalizedError, Equatable, Sendable {
    case requiresUSB
    case deviceNotReady
    case noWiFiAddress
    case tcpIPFailed(String)
    case connectionFailed(endpoint: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .requiresUSB:
            "Connect this device with a USB cable before switching it to Wi-Fi."
        case .deviceNotReady:
            "Authorize Developer Options on the Android device, then try again."
        case .noWiFiAddress:
            "The device does not have a usable Wi-Fi address. Connect the Mac and Android device to the same Wi-Fi network, then try again."
        case .tcpIPFailed(let message):
            "ADB could not enable network debugging. \(message)"
        case .connectionFailed(let endpoint, let message):
            "ADB enabled network debugging but could not connect to \(endpoint). Keep the cable connected, confirm both devices are on the same Wi-Fi network, and try again. \(message)"
        }
    }
}

public actor MediaStoreScanner {
    private let adb: ADBClient

    public init(adb: ADBClient) {
        self.adb = adb
    }

    public func scanIfNeeded(serial: String, remotePath: String) async throws {
        guard remotePath.hasPrefix("/storage/emulated/0/") || remotePath.hasPrefix("/sdcard/") else {
            return
        }
        _ = try await adb.shell(
            serial: serial,
            "content call --uri content://media --method scan_volume --arg external_primary"
        )
    }
}

public actor AndroidFileRepository {
    private let adb: ADBClient
    private let scanner: MediaStoreScanner
    private let trashRoot = "/storage/emulated/0/.AndroidFileBrowserTrash"
    private let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "dng", "avif"]
    private let videoExtensions = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "3gp"]
    private let audioExtensions = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "amr"]
    private let documentExtensions = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "csv", "epub"]

    public init(adb: ADBClient, scanner: MediaStoreScanner) {
        self.adb = adb
        self.scanner = scanner
    }

    public func listFiles(device: AndroidDevice, path: String) async throws -> [AndroidFile] {
        let quoted = ADBClient.quoteRemote(path)
        // %W is birth time when the phone/filesystem provides it. A zero or an
        // unsupported value is parsed as unavailable; %Z is inode change time
        // and must not be presented to users as a creation date.
        let statFormat = "'%A|%s|%Y|%W|%n'"
        let command = "find \(quoted) -mindepth 1 -maxdepth 1 -exec stat -c \(statFormat) {} + 2>/dev/null"
        let result = try await adb.shell(serial: device.serial, command, allowFailure: true)
        if result.exitCode != 0 {
            if isPrivateAndroidDataPath(path) {
                return [AndroidFile(name: "Private app data requires a debuggable app or Android-granted access", path: path, kind: .locked, size: nil, modified: nil, permissions: nil)]
            }
            let fallback = try await adb.shell(serial: device.serial, "ls -la \(quoted)", allowFailure: true)
            if fallback.exitCode != 0 {
                throw FileOperationError.commandFailed(fallback.stderr.isEmpty ? fallback.stdout : fallback.stderr)
            }
            return ADBParsers.parseLongListing(fallback.stdout, parentPath: path)
        }
        return ADBParsers.parseStatListing(result.stdout)
    }

    public func searchFiles(
        device: AndroidDevice,
        query: String,
        root: String,
        kindFilter: FileSearchKindFilter,
        dateFilter: FileSearchDateFilter
    ) async throws -> [AndroidFile] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty || kindFilter != .any || dateFilter != .any else { return [] }

        let kindPredicate: String
        switch kindFilter {
        case .any:
            kindPredicate = ""
        case .folders:
            kindPredicate = "-type d"
        case _ where kindFilter.requiresFilePredicate:
            kindPredicate = "-type f"
        default:
            kindPredicate = ""
        }

        let datePredicate = dateFilter.findPredicate ?? ""
        let namePredicate = trimmedQuery.isEmpty
            ? ""
            : "-iname \(ADBClient.quoteRemote("*\(trimmedQuery)*"))"
        let extensionPredicate = kindFilter.adbFindExtensionPredicate ?? ""
        let command = [
            "find \(ADBClient.quoteRemote(root)) -maxdepth 8",
            kindPredicate,
            extensionPredicate,
            datePredicate,
            namePredicate,
            "-exec stat -c '%A|%s|%Y|%Z|%n' {} +",
            "2>/dev/null | head -n 500"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        let result = try await adb.shell(serial: device.serial, command, allowFailure: true)
        if result.exitCode != 0, result.stdout.isEmpty {
            throw FileOperationError.commandFailed(result.stderr)
        }

        let files = ADBParsers.parseStatListing(result.stdout)
        return files.filter { kindFilter.matches(file: $0) }
    }

    public func storageSummaries(device: AndroidDevice) async throws -> [StorageSummary] {
        let result = try await adb.shell(serial: device.serial, "df -k /storage/emulated/0 /storage/emulated /storage /data 2>/dev/null", allowFailure: true)
        return ADBParsers.parseStorage(result.stdout)
    }

    public func storageBreakdown(device: AndroidDevice, summary: StorageSummary) async throws -> StorageBreakdown {
        let root = visibleStorageRoot(for: summary.path)
        let visibleRootBytes = try await directorySizeBytes(device: device, path: root)
        let appDataBytes = try await directorySizeBytes(device: device, path: storageSubpath(root, "Android/data"))
        let appMediaBytes = try await directorySizeBytes(device: device, path: storageSubpath(root, "Android/media"))
        let appBytes = appDataBytes + appMediaBytes
        let gameBytes = try await directorySizeBytes(device: device, path: storageSubpath(root, "Android/obb"))
        let appTrashBytes = try await directorySizeBytes(device: device, path: storageSubpath(root, ".AndroidFileBrowserTrash"))
        let macTrashBytes = try await directorySizeBytes(device: device, path: storageSubpath(root, ".Trash"))
        let trashBytes = appTrashBytes + macTrashBytes
        let imageBytes = try await fileBytesMatchingExtensions(
            device: device,
            root: root,
            extensions: imageExtensions
        )
        let videoBytes = try await fileBytesMatchingExtensions(
            device: device,
            root: root,
            extensions: videoExtensions
        )
        let audioBytes = try await fileBytesMatchingExtensions(
            device: device,
            root: root,
            extensions: audioExtensions
        )
        let documentBytes = try await fileBytesMatchingExtensions(
            device: device,
            root: root,
            extensions: documentExtensions
        )
        let systemBytes = isInternalStoragePath(summary.path) ? max(0, summary.usedBytes - visibleRootBytes) : 0
        let detectedAndroidSystemBytes = try await androidSystemImageBytes(device: device)
        let androidSystemBytes = systemBytes > 0
            ? min(systemBytes, detectedAndroidSystemBytes > 0 ? detectedAndroidSystemBytes : systemBytes)
            : 0
        let temporarySystemBytes = max(0, systemBytes - androidSystemBytes)
        let androidSystemTitle = try await androidSystemTitle(device: device)
        let accountedBytes = appBytes
            + gameBytes
            + trashBytes
            + imageBytes
            + videoBytes
            + audioBytes
            + documentBytes
            + androidSystemBytes
            + temporarySystemBytes
        let otherBytes = max(0, summary.usedBytes - accountedBytes)
        let categories = [
            StorageBreakdownCategory(kind: .apps, bytes: appBytes),
            StorageBreakdownCategory(kind: .videos, bytes: videoBytes),
            StorageBreakdownCategory(kind: .images, bytes: imageBytes),
            StorageBreakdownCategory(kind: .audio, bytes: audioBytes),
            StorageBreakdownCategory(kind: .trash, bytes: trashBytes),
            StorageBreakdownCategory(kind: .documents, bytes: documentBytes),
            StorageBreakdownCategory(kind: .other, bytes: otherBytes),
            StorageBreakdownCategory(kind: .games, bytes: gameBytes),
            StorageBreakdownCategory(kind: .androidSystem, bytes: androidSystemBytes, titleOverride: androidSystemTitle),
            StorageBreakdownCategory(kind: .temporarySystemFiles, bytes: temporarySystemBytes)
        ]

        return StorageBreakdown(summary: summary, categories: categories)
    }

    public func storageCategoryFiles(
        device: AndroidDevice,
        summary: StorageSummary,
        category: StorageBreakdownCategory,
        limit: Int = 200
    ) async throws -> [AndroidFile] {
        guard category.kind.canBrowseFiles else { return [] }
        let root = visibleStorageRoot(for: summary.path)
        let command = storageCategoryFileCommand(root: root, category: category.kind, limit: limit)
        guard !command.isEmpty else { return [] }
        let result = try await adb.shell(serial: device.serial, command, allowFailure: true)
        if result.exitCode != 0, result.stdout.isEmpty {
            throw FileOperationError.commandFailed(result.stderr)
        }
        return ADBParsers.parseStatListing(result.stdout)
            .sorted { lhs, rhs in
                (lhs.size ?? -1) > (rhs.size ?? -1)
            }
    }

    public func createFolder(device: AndroidDevice, parent: String, name: String) async throws {
        let remote = ADBClient.joinRemote(parent, name)
        if try await fileExists(device: device, path: remote) {
            throw FileOperationError.duplicateExists(remote)
        }
        _ = try await adb.shell(serial: device.serial, "mkdir \(ADBClient.quoteRemote(remote))")
    }

    public func fileExists(device: AndroidDevice, path: String) async throws -> Bool {
        let result = try await adb.shell(serial: device.serial, "test -e \(ADBClient.quoteRemote(path)); echo $?", allowFailure: true)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    public func directoryHasVisibleContent(device: AndroidDevice, path: String) async throws -> Bool {
        let quoted = ADBClient.quoteRemote(path)
        let command = "if [ -d \(quoted) ]; then find \(quoted) -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1; fi"
        let result = try await adb.shell(serial: device.serial, command, allowFailure: true)
        return result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func folderSizeBytes(device: AndroidDevice, path: String) async throws -> Int64 {
        let quoted = ADBClient.quoteRemote(path)
        let command = "find \(quoted) -mindepth 1 -type f -exec stat -c '%s' {} + 2>/dev/null | awk '{s += $1} END {printf \"%.0f\", s}'"
        return try await byteCountFromShell(device: device, command: command)
    }

    public func push(
        device: AndroidDevice,
        localURL: URL,
        to directory: String,
        remoteName: String? = nil,
        replace: Bool,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        let remotePath = ADBClient.joinRemote(directory, remoteName ?? localURL.lastPathComponent)
        if try await fileExists(device: device, path: remotePath), !replace {
            throw FileOperationError.duplicateExists(remotePath)
        }
        if replace {
            _ = try await adb.shell(serial: device.serial, "rm -rf \(ADBClient.quoteRemote(remotePath))", allowFailure: true)
        }

        _ = try await adb.runStreaming(["-s", device.serial, "push", localURL.path, remotePath], progress: progress)
        try await scanner.scanIfNeeded(serial: device.serial, remotePath: remotePath)
        return remotePath
    }

    public func pull(
        device: AndroidDevice,
        remotePath: String,
        to localDirectory: URL,
        localName: String? = nil,
        replace: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let destination = localDirectory.appending(path: localName ?? (remotePath as NSString).lastPathComponent)
        if replace, FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        _ = try await adb.runStreaming(["-s", device.serial, "pull", remotePath, destination.path], progress: progress)
        return destination
    }

    public func pullToCache(device: AndroidDevice, remotePath: String, localName: String? = nil) async throws -> URL {
        let cacheDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "AndroidFileBrowserPreviews", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        return try await pull(
            device: device,
            remotePath: remotePath,
            to: cacheDirectory,
            localName: localName,
            replace: true
        )
    }

    public func compressToZip(
        device: AndroidDevice,
        files: [AndroidFile],
        baseDirectory: String,
        archiveName rawArchiveName: String
    ) async throws -> String {
        let archiveName = normalizedArchiveName(rawArchiveName)
        let remoteArchivePath = ADBClient.joinRemote(baseDirectory, archiveName)
        if try await fileExists(device: device, path: remoteArchivePath) {
            throw FileOperationError.duplicateExists(remoteArchivePath)
        }

        let workDirectory = try archiveWorkDirectory(prefix: "Compress")
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let payloadDirectory = workDirectory.appending(path: "Payload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)

        var relativePaths: [String] = []
        for file in files {
            let relativePath = relativeArchivePath(for: file.path, baseDirectory: baseDirectory)
            let localURL = payloadDirectory.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try await adb.run(["-s", device.serial, "pull", file.path, localURL.path])
            relativePaths.append(relativePath)
        }

        let localArchiveURL = workDirectory.appending(path: archiveName)
        try await runLocalArchiveTool(
            executable: "/usr/bin/zip",
            arguments: ["-qry", localArchiveURL.path, "--"] + relativePaths,
            currentDirectory: payloadDirectory
        )

        _ = try await adb.run(["-s", device.serial, "push", localArchiveURL.path, remoteArchivePath])
        try await scanner.scanIfNeeded(serial: device.serial, remotePath: remoteArchivePath)
        return remoteArchivePath
    }

    public func extractArchive(
        device: AndroidDevice,
        archive: AndroidFile,
        toParent parentDirectory: String
    ) async throws -> String {
        guard archive.isExtractableArchive else {
            throw FileOperationError.commandFailed("\(archive.name) is not a supported archive. Supported formats are ZIP, TAR, TAR.GZ, TGZ, TAR.BZ2, TBZ2, TAR.XZ, and TXZ.")
        }

        let destinationName = safeRemoteName(archive.archiveExtractionFolderName.isEmpty ? "Extracted Archive" : archive.archiveExtractionFolderName)
        let remoteDestination = ADBClient.joinRemote(parentDirectory, destinationName)
        if try await fileExists(device: device, path: remoteDestination) {
            throw FileOperationError.duplicateExists(remoteDestination)
        }

        let workDirectory = try archiveWorkDirectory(prefix: "Extract")
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let localArchiveURL = workDirectory.appending(path: archive.name)
        let extractDirectory = workDirectory.appending(path: destinationName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)

        _ = try await adb.run(["-s", device.serial, "pull", archive.path, localArchiveURL.path])
        try await extractLocalArchive(localArchiveURL, to: extractDirectory)
        _ = try await adb.run(["-s", device.serial, "push", extractDirectory.path, parentDirectory])
        try await scanner.scanIfNeeded(serial: device.serial, remotePath: remoteDestination)
        return remoteDestination
    }

    public func rename(device: AndroidDevice, source: String, newName: String) async throws -> String {
        let parent = (source as NSString).deletingLastPathComponent
        let destination = ADBClient.joinRemote(parent, newName)
        if source != destination, try await fileExists(device: device, path: destination) {
            throw FileOperationError.duplicateExists(destination)
        }
        _ = try await adb.shell(serial: device.serial, "mv \(ADBClient.quoteRemote(source)) \(ADBClient.quoteRemote(destination))")
        // Renaming succeeded even if Android's media index is temporarily unavailable.
        try? await scanner.scanIfNeeded(serial: device.serial, remotePath: destination)
        return destination
    }

    public func availableRemoteName(device: AndroidDevice, directory: String, preferredName: String) async throws -> String {
        var existingNames: [String] = []
        var candidate = preferredName
        while try await fileExists(device: device, path: ADBClient.joinRemote(directory, candidate)) {
            existingNames.append(candidate)
            candidate = TransferConflictResolver.enumeratedName(for: preferredName, existingNames: existingNames)
        }
        return candidate
    }

    public func copy(
        device: AndroidDevice,
        source: String,
        to directory: String,
        destinationName: String? = nil,
        replace: Bool = false
    ) async throws -> String {
        let destination = ADBClient.joinRemote(directory, destinationName ?? (source as NSString).lastPathComponent)
        if try await fileExists(device: device, path: destination), !replace {
            throw FileOperationError.duplicateExists(destination)
        }
        if replace {
            _ = try await adb.shell(serial: device.serial, "rm -rf \(ADBClient.quoteRemote(destination))", allowFailure: true)
        }
        _ = try await adb.shell(serial: device.serial, "cp -R \(ADBClient.quoteRemote(source)) \(ADBClient.quoteRemote(destination))")
        try await scanner.scanIfNeeded(serial: device.serial, remotePath: destination)
        return destination
    }

    public func move(device: AndroidDevice, source: String, to directory: String, destinationName: String? = nil, replace: Bool) async throws -> String {
        let destination = ADBClient.joinRemote(directory, destinationName ?? (source as NSString).lastPathComponent)
        let destinationExists = try await fileExists(device: device, path: destination)
        if destinationExists, !replace {
            throw FileOperationError.duplicateExists(destination)
        }

        let destinationFileName = (destination as NSString).lastPathComponent
        let replacementBackup = destinationExists && replace
            ? ADBClient.joinRemote(
                directory,
                "\(destinationFileName) (Replaced backup \(UUID().uuidString.prefix(8)))"
            )
            : nil
        if let replacementBackup {
            _ = try await adb.shell(
                serial: device.serial,
                "mv \(ADBClient.quoteRemote(destination)) \(ADBClient.quoteRemote(replacementBackup))"
            )
        }

        do {
            _ = try await adb.shell(serial: device.serial, "mv \(ADBClient.quoteRemote(source)) \(ADBClient.quoteRemote(destination))")
        } catch let moveError {
            if let replacementBackup {
                do {
                    _ = try await adb.shell(
                        serial: device.serial,
                        "mv \(ADBClient.quoteRemote(replacementBackup)) \(ADBClient.quoteRemote(destination))"
                    )
                } catch let restoreError {
                    throw FileOperationError.commandFailed(
                        "The move did not finish, and the replaced item could not be returned to its original name. It is safe at \(replacementBackup). \(restoreError.localizedDescription)"
                    )
                }
            }
            throw moveError
        }

        if let replacementBackup {
            do {
                _ = try await adb.shell(
                    serial: device.serial,
                    "rm -rf \(ADBClient.quoteRemote(replacementBackup))"
                )
            } catch {
                throw FileOperationError.moveCompletedWithRecoveryCopy(
                    destination: destination,
                    recoveryPath: replacementBackup,
                    reason: error.localizedDescription
                )
            }
        }
        // Media indexing is advisory. Once mv succeeds, the move itself is authoritative.
        try? await scanner.scanIfNeeded(serial: device.serial, remotePath: destination)
        return destination
    }

    public func trash(device: AndroidDevice, file: AndroidFile) async throws -> TrashRecord {
        _ = try await adb.shell(serial: device.serial, "mkdir -p \(ADBClient.quoteRemote(trashRoot))")
        let safeName = file.name.replacingOccurrences(of: "/", with: "_")
        let uniqueName = "\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString)-\(safeName)"
        let remoteTrashPath = ADBClient.joinRemote(trashRoot, uniqueName)
        _ = try await adb.shell(serial: device.serial, "mv \(ADBClient.quoteRemote(file.path)) \(ADBClient.quoteRemote(remoteTrashPath))")
        return TrashRecord(
            id: UUID(),
            deviceSerial: device.serial,
            originalPath: file.path,
            trashPath: remoteTrashPath,
            name: file.name,
            deletedAt: Date(),
            size: file.size,
            kind: file.kind
        )
    }

    public func restore(device: AndroidDevice, record: TrashRecord, replace: Bool) async throws {
        if try await fileExists(device: device, path: record.originalPath), !replace {
            throw FileOperationError.duplicateExists(record.originalPath)
        }
        _ = try await adb.shell(serial: device.serial, "mkdir -p \(ADBClient.quoteRemote((record.originalPath as NSString).deletingLastPathComponent))")
        _ = try await adb.shell(serial: device.serial, "mv \(ADBClient.quoteRemote(record.trashPath)) \(ADBClient.quoteRemote(record.originalPath))")
        // The file move is authoritative; media indexing can catch up later.
        try? await scanner.scanIfNeeded(serial: device.serial, remotePath: record.originalPath)
    }

    public func deletePermanently(device: AndroidDevice, remotePath: String) async throws {
        _ = try await adb.shell(serial: device.serial, "rm -rf \(ADBClient.quoteRemote(remotePath))")
    }

    private func isPrivateAndroidDataPath(_ path: String) -> Bool {
        path == "/data"
            || path.hasPrefix("/data/data")
            || path.hasPrefix("/data/user")
            || path == "/storage/emulated/0/Android/data"
            || path.hasPrefix("/storage/emulated/0/Android/data/")
            || path == "/storage/emulated/0/Android/obb"
            || path.hasPrefix("/storage/emulated/0/Android/obb/")
            || path == "/sdcard/Android/data"
            || path.hasPrefix("/sdcard/Android/data/")
            || path == "/sdcard/Android/obb"
            || path.hasPrefix("/sdcard/Android/obb/")
    }

    private func directorySizeBytes(device: AndroidDevice, path: String) async throws -> Int64 {
        let command = "du -sk \(ADBClient.quoteRemote(path)) 2>/dev/null | awk '{s += $1} END {printf \"%.0f\", s * 1024}'"
        return try await byteCountFromShell(device: device, command: command)
    }

    private func storageCategoryFileCommand(
        root: String,
        category: StorageBreakdownCategoryKind,
        limit: Int
    ) -> String {
        let limit = max(1, min(limit, 500))
        switch category {
        case .apps:
            return sortedFindFilesCommand(
                roots: [storageSubpath(root, "Android/data"), storageSubpath(root, "Android/media")],
                limit: limit
            )
        case .games:
            return sortedFindFilesCommand(roots: [storageSubpath(root, "Android/obb")], limit: limit)
        case .trash:
            return sortedFindFilesCommand(
                roots: [storageSubpath(root, ".AndroidFileBrowserTrash"), storageSubpath(root, ".Trash")],
                limit: limit
            )
        case .videos:
            return sortedFindFilesCommand(
                root: root,
                prunePaths: storageBreakdownPrunePaths(root: root),
                condition: groupedExtensionFindPredicate(videoExtensions),
                limit: limit
            )
        case .images:
            return sortedFindFilesCommand(
                root: root,
                prunePaths: storageBreakdownPrunePaths(root: root),
                condition: groupedExtensionFindPredicate(imageExtensions),
                limit: limit
            )
        case .audio:
            return sortedFindFilesCommand(
                root: root,
                prunePaths: storageBreakdownPrunePaths(root: root),
                condition: groupedExtensionFindPredicate(audioExtensions),
                limit: limit
            )
        case .documents:
            return sortedFindFilesCommand(
                root: root,
                prunePaths: storageBreakdownPrunePaths(root: root),
                condition: groupedExtensionFindPredicate(documentExtensions),
                limit: limit
            )
        case .other:
            return sortedFindFilesCommand(
                root: root,
                prunePaths: storageBreakdownPrunePaths(root: root),
                condition: excludedExtensionFindPredicate(imageExtensions + videoExtensions + audioExtensions + documentExtensions),
                limit: limit
            )
        case .androidSystem, .temporarySystemFiles:
            return ""
        }
    }

    private func sortedFindFilesCommand(
        roots: [String],
        condition: String = "",
        limit: Int
    ) -> String {
        let commands = roots.map { root in
            let quoted = ADBClient.quoteRemote(root)
            let conditionClause = condition.isEmpty ? "" : "\(condition) "
            return "if [ -d \(quoted) ]; then find \(quoted) -type f \(conditionClause)-exec stat -c '%A|%s|%Y|%Z|%n' {} +; fi"
        }
        return "{ \(commands.joined(separator: "; ")); } 2>/dev/null | sort -t '|' -k2,2nr | head -n \(limit)"
    }

    private func sortedFindFilesCommand(
        root: String,
        prunePaths: [String],
        condition: String,
        limit: Int
    ) -> String {
        let prunePredicate = prunePaths
            .map { "-path \(ADBClient.quoteRemote($0))" }
            .joined(separator: " -o ")
        let pruneClause = prunePredicate.isEmpty ? "" : "\\( \(prunePredicate) \\) -prune -o"
        let conditionClause = condition.isEmpty ? "" : condition
        let command = [
            "find \(ADBClient.quoteRemote(root))",
            pruneClause,
            "-type f",
            conditionClause,
            "-exec stat -c '%A|%s|%Y|%Z|%n' {} +"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        return "\(command) 2>/dev/null | sort -t '|' -k2,2nr | head -n \(limit)"
    }

    private func extensionFindPredicate(_ extensions: [String]) -> String {
        extensions
            .map { "-iname \(ADBClient.quoteRemote("*.\($0)"))" }
            .joined(separator: " -o ")
    }

    private func groupedExtensionFindPredicate(_ extensions: [String]) -> String {
        "\\( \(extensionFindPredicate(extensions)) \\)"
    }

    private func excludedExtensionFindPredicate(_ extensions: [String]) -> String {
        "! \(groupedExtensionFindPredicate(extensions))"
    }

    private func androidSystemTitle(device: AndroidDevice) async throws -> String {
        let result = try await adb.shell(
            serial: device.serial,
            "getprop ro.build.version.codename; getprop ro.build.version.release_or_codename; getprop ro.build.version.release",
            allowFailure: true
        )
        let label = result.stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0.uppercased() != "REL" }

        guard let label, !label.isEmpty else { return StorageBreakdownCategoryKind.androidSystem.title }
        return "Android \(label)"
    }

    private func androidSystemImageBytes(device: AndroidDevice) async throws -> Int64 {
        let result = try await adb.shell(
            serial: device.serial,
            "df -k /system /system_ext /product /vendor /odm 2>/dev/null",
            allowFailure: true
        )
        var seen = Set<String>()
        return result.stdout
            .split(separator: "\n")
            .dropFirst()
            .reduce(Int64(0)) { total, rawLine in
                let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard fields.count >= 6,
                      let usedBlocks = Int64(fields[2]) else {
                    return total
                }
                let key = "\(fields[0]):\(fields[5])"
                guard seen.insert(key).inserted else { return total }
                return total + usedBlocks * 1024
            }
    }

    private func fileBytesMatchingExtensions(
        device: AndroidDevice,
        root: String,
        extensions: [String]
    ) async throws -> Int64 {
        guard !extensions.isEmpty else { return 0 }
        let extensionPredicate = extensions
            .map { "-iname \(ADBClient.quoteRemote("*.\($0)"))" }
            .joined(separator: " -o ")
        let prunePredicate = storageBreakdownPrunePaths(root: root)
            .map { "-path \(ADBClient.quoteRemote($0))" }
            .joined(separator: " -o ")
        let command = [
            "find \(ADBClient.quoteRemote(root))",
            "\\( \(prunePredicate) \\) -prune -o",
            "-type f \\( \(extensionPredicate) \\)",
            "-exec stat -c %s {} \\;",
            "2>/dev/null | awk '{s += $1} END {printf \"%.0f\", s}'"
        ].joined(separator: " ")

        return try await byteCountFromShell(device: device, command: command)
    }

    private func byteCountFromShell(device: AndroidDevice, command: String) async throws -> Int64 {
        let result = try await adb.shell(serial: device.serial, command, allowFailure: true)
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int64(trimmed) else { return 0 }
        return max(0, value)
    }

    private func archiveWorkDirectory(prefix: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "AndroidFileBrowserArchives", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func normalizedArchiveName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = safeRemoteName(trimmed.isEmpty ? "Archive.zip" : trimmed)
        return safeName.lowercased().hasSuffix(".zip") ? safeName : "\(safeName).zip"
    }

    private func safeRemoteName(_ rawName: String) -> String {
        rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
    }

    private func relativeArchivePath(for remotePath: String, baseDirectory: String) -> String {
        let normalizedBase = baseDirectory.hasSuffix("/") ? String(baseDirectory.dropLast()) : baseDirectory
        if remotePath == normalizedBase {
            return (remotePath as NSString).lastPathComponent
        }
        let prefix = "\(normalizedBase)/"
        if remotePath.hasPrefix(prefix) {
            return String(remotePath.dropFirst(prefix.count))
        }
        return (remotePath as NSString).lastPathComponent
    }

    private func extractLocalArchive(_ archiveURL: URL, to destination: URL) async throws {
        let lowercasedName = archiveURL.lastPathComponent.lowercased()
        if lowercasedName.hasSuffix(".zip") {
            try await runLocalArchiveTool(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", archiveURL.path, destination.path],
                currentDirectory: nil
            )
            return
        }

        let flags: String
        if lowercasedName.hasSuffix(".tar.gz") || lowercasedName.hasSuffix(".tgz") {
            flags = "-xzf"
        } else if lowercasedName.hasSuffix(".tar.bz2") || lowercasedName.hasSuffix(".tbz2") {
            flags = "-xjf"
        } else if lowercasedName.hasSuffix(".tar.xz") || lowercasedName.hasSuffix(".txz") {
            flags = "-xJf"
        } else if lowercasedName.hasSuffix(".tar") {
            flags = "-xf"
        } else {
            throw FileOperationError.commandFailed("\(archiveURL.lastPathComponent) is not a supported archive.")
        }

        try await runLocalArchiveTool(
            executable: "/usr/bin/tar",
            arguments: [flags, archiveURL.path, "-C", destination.path],
            currentDirectory: nil
        )
    }

    private func runLocalArchiveTool(
        executable: String,
        arguments: [String],
        currentDirectory: URL?
    ) async throws {
        let result = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return ADBCommandResult(
                stdoutData: stdoutData,
                stderrData: stderrData,
                exitCode: process.terminationStatus
            )
        }.value

        guard result.exitCode == 0 else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw FileOperationError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func storageSubpath(_ root: String, _ relativePath: String) -> String {
        ADBClient.joinRemote(root, relativePath)
    }

    private func storageBreakdownPrunePaths(root: String) -> [String] {
        [
            storageSubpath(root, "Android"),
            storageSubpath(root, ".AndroidFileBrowserTrash"),
            storageSubpath(root, ".Trash")
        ]
    }

    private func visibleStorageRoot(for path: String) -> String {
        path == "/storage/emulated" ? "/storage/emulated/0" : path
    }

    private func isInternalStoragePath(_ path: String) -> Bool {
        path == "/storage/emulated/0" || path == "/storage/emulated" || path == "/sdcard"
    }
}

public actor AppManagerService {
    private let adb: ADBClient
    private let metadataBridge: AppMetadataBridge
    private let installer: AppPackageInstaller

    public init(adb: ADBClient) {
        self.adb = adb
        self.metadataBridge = AppMetadataBridge(adb: adb)
        self.installer = AppPackageInstaller(adb: adb)
    }

    public func packages(device: AndroidDevice, kind: AppKind) async throws -> [AndroidPackage] {
        let systemResult = try await adb.shell(serial: device.serial, "pm list packages -f -s", timeout: 15)
        let userResult = try await adb.shell(serial: device.serial, "pm list packages -f -3", timeout: 15)
        let systemPackages = ADBParsers.parsePackages(systemResult.stdout, kind: .system)
        let systemPackageNames = Set(systemPackages.map(\.packageName))
        let userPackages = ADBParsers.parsePackages(userResult.stdout, kind: .user)
            .filter { !systemPackageNames.contains($0.packageName) }

        switch kind {
        case .all:
            return (systemPackages + userPackages)
                .sorted { $0.packageName.localizedStandardCompare($1.packageName) == .orderedAscending }
        case .system:
            return systemPackages
        case .user:
            return userPackages
        }
    }

    public func launchablePackageNames(device: AndroidDevice) async -> Set<String>? {
        let command = "cmd package query-activities --brief --components -a android.intent.action.MAIN -c android.intent.category.LAUNCHER"
        guard let result = try? await adb.shell(serial: device.serial, command, allowFailure: true),
              result.exitCode == 0 else {
            return nil
        }

        let packageNames = Set(result.stdout.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "/"), separator != trimmed.startIndex else {
                return nil
            }
            return String(trimmed[..<separator])
        })
        return packageNames.isEmpty ? nil : packageNames
    }

    func presentations(
        device: AndroidDevice,
        packages: [AndroidPackage],
        onBatch: (@Sendable ([String: AndroidAppPresentation]) async throws -> Void)? = nil
    ) async throws -> [String: AndroidAppPresentation] {
        try await metadataBridge.presentations(
            device: device,
            packages: packages,
            onBatch: onBatch
        )
    }

    public func details(device: AndroidDevice, package: AndroidPackage) async throws -> AndroidPackage {
        let result = try await adb.shell(
            serial: device.serial,
            "dumpsys package \(ADBClient.quoteRemote(package.packageName))",
            allowFailure: true,
            timeout: 12
        )
        var updated = ADBParsers.parsePackageDetails(package: package, dumpsys: result.stdout)
        try Task.checkCancellation()
        do {
            updated.apkSizeBytes = try await apkSizeBytes(device: device, package: updated)
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        try Task.checkCancellation()
        do {
            updated.storageStats = try await storageStats(device: device, package: updated)
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        try Task.checkCancellation()
        updated.appStorageLocationSizes = try await appStorageLocationSizes(device: device, package: updated)
        return updated
    }

    public func runningProcessNames(device: AndroidDevice) async throws -> Set<String> {
        let command = "ps -A -o NAME 2>/dev/null || ps -A 2>/dev/null || ps 2>/dev/null"
        let result = try await adb.shell(serial: device.serial, command, allowFailure: true, timeout: 10)
        return ADBParsers.parseRunningProcessNames(result.stdout)
    }

    public func launch(device: AndroidDevice, packageName: String) async throws {
        _ = try await adb.shell(
            serial: device.serial,
            "monkey -p \(ADBClient.quoteRemote(packageName)) -c android.intent.category.LAUNCHER 1"
        )
    }

    public func forceStop(device: AndroidDevice, packageName: String) async throws {
        _ = try await adb.shell(serial: device.serial, "am force-stop \(ADBClient.quoteRemote(packageName))")
    }

    public func clearCache(device: AndroidDevice, packageName: String) async throws {
        let result = try await adb.shell(
            serial: device.serial,
            "pm clear --user 0 --cache-only \(ADBClient.quoteRemote(packageName))",
            allowFailure: true
        )
        guard result.exitCode == 0 else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw FileOperationError.commandFailed(
                message.isEmpty
                    ? "Android did not allow cache-only clearing for \(packageName)."
                    : message
            )
        }
    }

    public func clearStorage(device: AndroidDevice, packageName: String) async throws {
        let result = try await adb.shell(
            serial: device.serial,
            "pm clear --user 0 \(ADBClient.quoteRemote(packageName))",
            allowFailure: true
        )
        guard result.exitCode == 0 else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw FileOperationError.commandFailed(
                message.isEmpty
                    ? "Android did not allow storage clearing for \(packageName)."
                    : message
            )
        }
    }

    public func pullAPK(
        device: AndroidDevice,
        package: AndroidPackage,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let apkPath = package.apkPath, !apkPath.isEmpty else {
            throw FileOperationError.commandFailed("Android did not report an APK path for \(package.packageName).")
        }
        _ = try await adb.runStreaming(["-s", device.serial, "pull", apkPath, destination.path], progress: progress)
    }

    private func apkSizeBytes(device: AndroidDevice, package: AndroidPackage) async throws -> Int64? {
        guard let apkPath = package.apkPath, !apkPath.isEmpty else { return nil }
        let result = try await adb.shell(
            serial: device.serial,
            "stat -c %s \(ADBClient.quoteRemote(apkPath)) 2>/dev/null",
            allowFailure: true,
            timeout: 8
        )
        guard result.exitCode == 0 else { return nil }
        return Int64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func storageStats(device: AndroidDevice, package: AndroidPackage) async throws -> AppStorageStats? {
        let packageName = ADBClient.quoteRemote(package.packageName)
        let commands = [
            "cmd storagestats query package --user 0 private \(packageName)",
            "cmd storagestats query package private \(packageName) 0",
            "dumpsys storagestats --package \(packageName)"
        ]

        for command in commands {
            try Task.checkCancellation()
            let result = try await adb.shell(serial: device.serial, command, allowFailure: true, timeout: 8)
            guard result.exitCode == 0 else { continue }
            if let stats = ADBParsers.parseAppStorageStats(result.stdout) {
                return stats
            }
        }
        return nil
    }

    private func appStorageLocationSizes(device: AndroidDevice, package: AndroidPackage) async throws -> [AppStorageLocation.Kind: Int64] {
        var sizes: [AppStorageLocation.Kind: Int64] = [:]
        for location in package.appStorageLocations {
            try Task.checkCancellation()
            guard location.kind != .userData else { continue }
            do {
                if let bytes = try await directorySizeBytesIfVisible(device: device, path: location.path),
                   bytes > 0 {
                    sizes[location.kind] = bytes
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return sizes
    }

    private func directorySizeBytesIfVisible(device: AndroidDevice, path: String) async throws -> Int64? {
        let quoted = ADBClient.quoteRemote(path)
        let command = "if [ -d \(quoted) ]; then du -sk \(quoted) 2>/dev/null | awk '{s += $1} END {printf \"%.0f\", s * 1024}'; fi"
        let result = try await adb.shell(serial: device.serial, command, allowFailure: true, timeout: 8)
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int64(trimmed)
    }

    public func install(
        device: AndroidDevice,
        packageURLs: [URL],
        options: AppInstallOptions = AppInstallOptions()
    ) async throws -> AppInstallationResult {
        try await installer.install(device: device, urls: packageURLs, options: options)
    }

    public func install(device: AndroidDevice, apkURL: URL) async throws {
        _ = try await install(device: device, packageURLs: [apkURL])
    }

    public func uninstall(device: AndroidDevice, packageName: String) async throws {
        _ = try await adb.run(["-s", device.serial, "uninstall", packageName])
    }

    public func disable(device: AndroidDevice, packageName: String) async throws {
        _ = try await adb.shell(serial: device.serial, "pm disable-user --user 0 \(ADBClient.quoteRemote(packageName))")
    }

    public func enable(device: AndroidDevice, packageName: String) async throws {
        _ = try await adb.shell(serial: device.serial, "pm enable \(ADBClient.quoteRemote(packageName))")
    }

}

public actor DeviceCaptureService {
    private let adb: ADBClient
    private static let appearanceTransitionSettleDelay = Duration.milliseconds(400)

    public init(adb: ADBClient) {
        self.adb = adb
    }

    public func phoneControlCapabilities(device: AndroidDevice) async throws -> PhoneControlCapabilities {
        let command = "for tool in input settings screencap screenrecord dumpsys; do if [ -x /system/bin/$tool ]; then echo $tool; fi; done"
        let result = try await adb.shell(
            serial: device.serial,
            command,
            allowFailure: true,
            timeout: 6
        )
        guard result.exitCode == 0 else {
            throw FileOperationError.commandFailed("Available controls could not be checked.")
        }
        return PhoneControlCapabilities.detected(fromProbeOutput: result.stdout)
    }

    public func screenshot(device: AndroidDevice) async throws -> URL {
        await wakeDisplay(serial: device.serial)
        let result = try await adb.run(["-s", device.serial, "exec-out", "screencap", "-p"], timeout: 20)
        let url = try outputURL(prefix: "Screenshot", extension: "png")
        try result.stdoutData.write(to: url)
        return url
    }

    public func prepareScreenRecording(device: AndroidDevice, options: ScreenRecordingOptions) async -> ScreenRecordingRestorePlan {
        let restorePlan = ScreenRecordingRestorePlan(
            showTouchesValue: await systemSetting(serial: device.serial, namespace: "system", key: "show_touches"),
            nightMode: await nightMode(serial: device.serial),
            shouldExitDemoMode: true
        )

        await applyCapturePresentation(
            device: device,
            options: options,
            restorePlan: restorePlan,
            exitDemoWhenDisabled: false
        )

        await launchCaptureApp(device: device, packageName: options.normalizedPackageName)

        return restorePlan
    }

    public func launchCaptureApp(device: AndroidDevice, packageName: String?) async {
        guard let packageName else { return }
        let command = "monkey -p \(ADBClient.quoteRemote(packageName)) -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1"
        _ = try? await adb.shell(serial: device.serial, command, allowFailure: true, timeout: 8)
    }

    public func applyCapturePresentation(
        device: AndroidDevice,
        options: ScreenRecordingOptions,
        restorePlan: ScreenRecordingRestorePlan?,
        exitDemoWhenDisabled: Bool = true
    ) async {
        if options.demoMode {
            await enterDemoMode(serial: device.serial)
        } else if exitDemoWhenDisabled {
            await exitDemoMode(serial: device.serial)
        }

        let touchesValue = options.showTouches ? "1" : "0"
        _ = try? await adb.shell(
            serial: device.serial,
            "settings put system show_touches \(touchesValue)",
            allowFailure: true,
            timeout: 8
        )

        await applyDeviceAppearance(
            serial: device.serial,
            appearance: options.deviceAppearance,
            originalNightMode: restorePlan?.nightMode
        )
    }

    public func startScreenRecording(device: AndroidDevice, options: ScreenRecordingOptions) async throws -> ADBScreenRecordingProcess {
        await wakeDisplay(serial: device.serial)
        let remotePath = "/sdcard/AndroidFileBrowserRecording-\(UUID().uuidString).mp4"
        let handle = try await adb.startScreenRecording(
            serial: device.serial,
            remotePath: remotePath,
            timeLimitSeconds: options.timeLimitSeconds,
            size: options.screenRecordSize,
            bitRateMbps: options.effectiveVideoBitRateMbps
        )
        try await Task.sleep(for: .milliseconds(350))
        let startupIssue = recordingStartupIssue(logURL: handle.logURL)
        guard handle.isRunning, startupIssue == nil else {
            handle.stop()
            _ = handle.waitUntilExit(timeout: 0.2)
            _ = try? await adb.shell(
                serial: device.serial,
                "rm -f \(ADBClient.quoteRemote(remotePath))",
                allowFailure: true,
                timeout: 8
            )
            throw FileOperationError.commandFailed(
                startupIssue
                    ?? "A selected display stopped before recording began. Make sure it is connected and awake, then try again."
            )
        }
        return handle
    }

    private func wakeDisplay(serial: String) async {
        _ = try? await adb.shell(
            serial: serial,
            "input keyevent KEYCODE_WAKEUP; sleep 0.2; input keyevent KEYCODE_WAKEUP; sleep 0.2; input keyevent KEYCODE_WAKEUP",
            allowFailure: true,
            timeout: 4
        )
    }

    public func finishScreenRecording(
        handle: ADBScreenRecordingProcess,
        restorePlan: ScreenRecordingRestorePlan?
    ) async throws -> URL {
        _ = await Task.detached(priority: .userInitiated) {
            handle.waitUntilExit(timeout: 5)
        }.value
        try? await Task.sleep(for: .milliseconds(350))

        let localDirectory = try captureDirectory()
        let remoteName = (handle.remotePath as NSString).lastPathComponent
        let localURL = localDirectory.appending(path: remoteName)
        do {
            let result = try await adb.run(["-s", handle.serial, "pull", handle.remotePath, localURL.path])
            let fileSize = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard result.exitCode == 0, fileSize > 0 else {
                throw FileOperationError.commandFailed(
                    "A selected display stopped before its recording could be saved."
                )
            }
            await restoreScreenRecordingSettings(serial: handle.serial, restorePlan: restorePlan)
            _ = try? await adb.shell(serial: handle.serial, "rm -f \(ADBClient.quoteRemote(handle.remotePath))", allowFailure: true, timeout: 8)
            return localURL
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            await restoreScreenRecordingSettings(serial: handle.serial, restorePlan: restorePlan)
            _ = try? await adb.shell(serial: handle.serial, "rm -f \(ADBClient.quoteRemote(handle.remotePath))", allowFailure: true, timeout: 8)
            throw error
        }
    }

    public func restoreScreenRecordingSettings(serial: String, restorePlan: ScreenRecordingRestorePlan?) async {
        guard let restorePlan else { return }

        if let showTouchesValue = restorePlan.showTouchesValue {
            if showTouchesValue == "null" {
                _ = try? await adb.shell(serial: serial, "settings delete system show_touches", allowFailure: true, timeout: 8)
            } else {
                _ = try? await adb.shell(serial: serial, "settings put system show_touches \(ADBClient.quoteRemote(showTouchesValue))", allowFailure: true, timeout: 8)
            }
        }

        if let nightMode = restorePlan.nightMode {
            _ = try? await adb.shell(serial: serial, "cmd uimode night \(nightMode)", allowFailure: true, timeout: 8)
        }

        if restorePlan.shouldExitDemoMode {
            await exitDemoMode(serial: serial)
        }
    }

    private func outputURL(prefix: String, extension pathExtension: String) throws -> URL {
        let directory = try captureDirectory()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        return directory.appending(
            path: "\(prefix)-\(formatter.string(from: Date()))-\(UUID().uuidString).\(pathExtension)"
        )
    }

    private func captureDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "AndroidFileBrowserCaptures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func recordingStartupIssue(logURL: URL) -> String? {
        let output = (try? String(contentsOf: logURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowercased = output.lowercased()
        if lowercased.contains("unassigned_layer_stack")
            || lowercased.contains("display state") {
            return "A selected display is not available for recording. Wake it, make sure it is showing content, and try again."
        }
        if !output.isEmpty {
            return "A selected display stopped before recording began. Make sure it is connected and awake, then try again."
        }
        return nil
    }

    private func systemSetting(serial: String, namespace: String, key: String) async -> String? {
        guard let result = try? await adb.shell(serial: serial, "settings get \(namespace) \(key)", allowFailure: true, timeout: 8),
              result.exitCode == 0 else {
            return nil
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func nightMode(serial: String) async -> String? {
        guard let result = try? await adb.shell(serial: serial, "cmd uimode night", allowFailure: true, timeout: 8),
              result.exitCode == 0 else {
            return nil
        }
        let output = "\(result.stdout)\n\(result.stderr)".lowercased()
        let tokens = Set(output.components(separatedBy: CharacterSet.alphanumerics.inverted))
        if tokens.contains("yes") { return "yes" }
        if tokens.contains("no") { return "no" }
        if tokens.contains("auto") { return "auto" }
        return nil
    }

    private func applyDeviceAppearance(
        serial: String,
        appearance: ScreenRecordingDeviceAppearance,
        originalNightMode: String?
    ) async {
        let targetNightMode = Self.targetNightMode(for: appearance, originalNightMode: originalNightMode)
        guard let targetNightMode else { return }
        let currentNightMode = await nightMode(serial: serial)
        guard Self.appearanceTransitionIsNeeded(
            currentNightMode: currentNightMode,
            targetNightMode: targetNightMode
        ) else { return }

        guard let result = try? await adb.shell(
            serial: serial,
            "cmd uimode night \(targetNightMode)",
            allowFailure: true,
            timeout: 8
        ), result.exitCode == 0 else { return }

        try? await Task.sleep(for: Self.appearanceTransitionSettleDelay)
    }

    nonisolated static func targetNightMode(
        for appearance: ScreenRecordingDeviceAppearance,
        originalNightMode: String?
    ) -> String? {
        switch appearance {
        case .unchanged: originalNightMode
        case .light: "no"
        case .dark: "yes"
        }
    }

    nonisolated static func appearanceTransitionIsNeeded(
        currentNightMode: String?,
        targetNightMode: String
    ) -> Bool {
        currentNightMode != targetNightMode
    }

    private func enterDemoMode(serial: String) async {
        let commands = [
            "settings put global sysui_demo_allowed 1",
            "am broadcast -a com.android.systemui.demo -e command enter",
            "am broadcast -a com.android.systemui.demo -e command clock -e hhmm 1000",
            "am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false",
            "am broadcast -a com.android.systemui.demo -e command network -e wifi show -e level 4 -e mobile hide",
            "am broadcast -a com.android.systemui.demo -e command notifications -e visible false"
        ]
        for command in commands {
            _ = try? await adb.shell(serial: serial, command, allowFailure: true, timeout: 8)
        }
    }

    private func exitDemoMode(serial: String) async {
        _ = try? await adb.shell(
            serial: serial,
            "am broadcast -a com.android.systemui.demo -e command exit",
            allowFailure: true,
            timeout: 8
        )
    }
}

public struct ScreenRecordingRestorePlan: Sendable {
    public let showTouchesValue: String?
    public let nightMode: String?
    public let shouldExitDemoMode: Bool
}
