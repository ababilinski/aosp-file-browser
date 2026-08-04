import Combine
import CryptoKit
import Darwin
import Foundation

public struct ManagedToolchainRelease: Sendable, Equatable {
    public let version: String
    public let architecture: String
    public let archiveURL: URL
    public let archiveDirectoryName: String
    public let archiveSHA256: String
    public let adbSHA256: String
    public let scrcpySHA256: String
    public let scrcpyServerSHA256: String
    public let adbVersionMarker: String
    public let scrcpyVersionMarker: String

    public static func current(machineArchitecture: String = ToolchainPaths.machineArchitecture()) throws -> Self {
        switch machineArchitecture {
        case "arm64", "arm64e", "aarch64":
            return Self(
                version: "4.1",
                architecture: "aarch64",
                archiveURL: URL(string: "https://github.com/Genymobile/scrcpy/releases/download/v4.1/scrcpy-macos-aarch64-v4.1.tar.gz")!,
                archiveDirectoryName: "scrcpy-macos-aarch64-v4.1",
                archiveSHA256: "20fd47c9014dd5e0fa77091f3cb7adbda8445a360c4584aeaa0150b5b3988ff3",
                adbSHA256: "9fdf861259dc807937b13afdd5f053c7fda9f3b7726933fe0e0f45130ecb8dc7",
                scrcpySHA256: "e318a04c11986d9afa7f438a81cc9c7cc0f3ea66945db1e127f373eb02f4e1d3",
                scrcpyServerSHA256: "deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae",
                adbVersionMarker: "37.0.0-14910828",
                scrcpyVersionMarker: "scrcpy 4.1"
            )
        case "x86_64", "amd64":
            return Self(
                version: "4.1",
                architecture: "x86_64",
                archiveURL: URL(string: "https://github.com/Genymobile/scrcpy/releases/download/v4.1/scrcpy-macos-x86_64-v4.1.tar.gz")!,
                archiveDirectoryName: "scrcpy-macos-x86_64-v4.1",
                archiveSHA256: "ee2a7223bc8dbdc4f482db1134bcf441178dafb833492b71ca4c22090c58ce72",
                adbSHA256: "9fdf861259dc807937b13afdd5f053c7fda9f3b7726933fe0e0f45130ecb8dc7",
                scrcpySHA256: "3f2c348954c2b19be55def5b72b9d3274dfe5eddee99a060e0d7469f7b3ef159",
                scrcpyServerSHA256: "deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae",
                adbVersionMarker: "37.0.0-14910828",
                scrcpyVersionMarker: "scrcpy 4.1"
            )
        default:
            throw ToolchainInstallError.unsupportedMac
        }
    }

    var installationDirectoryName: String {
        "scrcpy-\(version)-\(architecture)"
    }
}

public enum ToolchainPaths {
    public static func managedToolsRoot(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return applicationSupport
            .appending(path: "com.ababilinski.android-file-browser", directoryHint: .isDirectory)
            .appending(path: "Tools", directoryHint: .isDirectory)
    }

    public static func currentManagedToolchainDirectory(fileManager: FileManager = .default) -> URL? {
        guard let release = try? ManagedToolchainRelease.current() else { return nil }
        return managedToolsRoot(fileManager: fileManager)
            .appending(path: release.installationDirectoryName, directoryHint: .isDirectory)
    }

    public static func machineArchitecture() -> String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }
        var machine = systemInfo.machine
        let machineSize = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: machineSize) {
                String(cString: $0)
            }
        }
    }
}

public enum ToolchainInstallError: LocalizedError, Equatable {
    case unsupportedMac
    case downloadFailed
    case verificationFailed
    case invalidPackage
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedMac:
            "This Mac cannot use the available phone tools."
        case .downloadFailed:
            "Phone tools could not be downloaded. Check your connection and try again, or choose an existing copy."
        case .verificationFailed:
            "The download could not be verified. Nothing was installed."
        case .invalidPackage:
            "The downloaded phone tools were incomplete. Nothing was installed."
        case .validationFailed(let reason):
            "The phone tools could not be opened. \(reason)"
        }
    }
}

public protocol ToolchainArchiveDownloading: Sendable {
    func download(from url: URL) async throws -> URL
}

public struct URLSessionToolchainArchiveDownloader: ToolchainArchiveDownloading {
    public init() {}

    public func download(from url: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (temporaryURL, response) = try await session.download(from: url)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw ToolchainInstallError.downloadFailed
        }
        return temporaryURL
    }
}

public struct ManagedToolchainInstallation: Sendable, Equatable {
    public let directoryURL: URL
    public let adbURL: URL
    public let scrcpyURL: URL
    public let scrcpyServerURL: URL
}

private struct ManagedToolchainInstallationRecord: Codable {
    let version: String
    let architecture: String
    let sourceURL: String
    let archiveSHA256: String
    let installedAt: Date
}

public actor ManagedToolchainInstaller {
    private let rootURL: URL
    private let release: ManagedToolchainRelease
    private let downloader: ToolchainArchiveDownloading
    private let runner: ProcessRunning
    private let fileManager: FileManager

    public init(
        rootURL: URL = ToolchainPaths.managedToolsRoot(),
        release: ManagedToolchainRelease? = nil,
        downloader: ToolchainArchiveDownloading = URLSessionToolchainArchiveDownloader(),
        runner: ProcessRunning = ProcessRunner(),
        fileManager: FileManager = .default
    ) throws {
        self.rootURL = rootURL
        self.release = try release ?? ManagedToolchainRelease.current()
        self.downloader = downloader
        self.runner = runner
        self.fileManager = fileManager
    }

    public nonisolated var installationDirectoryURL: URL {
        rootURL.appending(path: release.installationDirectoryName, directoryHint: .isDirectory)
    }

    public func install(
        tools requestedTools: Set<ToolchainTool> = Set(ToolchainTool.allCases)
    ) async throws -> ManagedToolchainInstallation {
        guard !requestedTools.isEmpty else {
            throw ToolchainInstallError.validationFailed("Choose at least one tool to install.")
        }
        try Task.checkCancellation()
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            throw ToolchainInstallError.validationFailed("Application Support is not writable.")
        }
        let lockDescriptor = try acquireInstallationLock()
        defer { releaseInstallationLock(lockDescriptor) }
        recoverInterruptedInstall()

        let stagingURL = rootURL.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        } catch {
            throw ToolchainInstallError.validationFailed("Application Support is not writable.")
        }
        defer { try? fileManager.removeItem(at: stagingURL) }

        let downloadedURL: URL
        do {
            downloadedURL = try await downloader.download(from: release.archiveURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolchainInstallError {
            throw error
        } catch {
            throw ToolchainInstallError.downloadFailed
        }

        try Task.checkCancellation()
        let archiveURL = stagingURL.appending(path: "phone-tools.tar.gz")
        do {
            try fileManager.copyItem(at: downloadedURL, to: archiveURL)
        } catch {
            throw ToolchainInstallError.downloadFailed
        }

        guard try Self.sha256(of: archiveURL) == release.archiveSHA256 else {
            throw ToolchainInstallError.verificationFailed
        }

        let extractionURL = stagingURL.appending(path: "extracted", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)
        } catch {
            throw ToolchainInstallError.validationFailed("The downloaded package could not be prepared.")
        }
        let extractionResult = try await runWithTimeout(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archiveURL.path, "-C", extractionURL.path],
            timeout: 30
        )
        guard extractionResult.exitCode == 0 else {
            throw ToolchainInstallError.invalidPackage
        }

        let extractedDirectory = extractionURL.appending(path: release.archiveDirectoryName, directoryHint: .isDirectory)
        let installation = ManagedToolchainInstallation(
            directoryURL: extractedDirectory,
            adbURL: extractedDirectory.appending(path: "adb"),
            scrcpyURL: extractedDirectory.appending(path: "scrcpy"),
            scrcpyServerURL: extractedDirectory.appending(path: "scrcpy-server")
        )
        try validateFiles(in: installation)
        do {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installation.adbURL.path)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installation.scrcpyURL.path)
        } catch {
            throw ToolchainInstallError.validationFailed("The downloaded tools could not be made executable.")
        }
        try await validateExecutables(in: installation, tools: requestedTools)
        try preserveUnrequestedManagedTools(
            in: installation,
            requestedTools: requestedTools
        )

        let record = ManagedToolchainInstallationRecord(
            version: release.version,
            architecture: release.architecture,
            sourceURL: release.archiveURL.absoluteString,
            archiveSHA256: release.archiveSHA256,
            installedAt: Date()
        )
        do {
            let recordData = try JSONEncoder().encode(record)
            try recordData.write(to: extractedDirectory.appending(path: "INSTALLATION.json"), options: .atomic)
        } catch {
            throw ToolchainInstallError.validationFailed("The installation record could not be saved.")
        }

        let destinationURL = installationDirectoryURL
        let backupURL = rootURL.appending(
            path: ".backup-\(release.installationDirectoryName)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let hadExistingInstall = fileManager.fileExists(atPath: destinationURL.path)
        var movedExistingInstall = false
        do {
            if hadExistingInstall {
                try fileManager.moveItem(at: destinationURL, to: backupURL)
                movedExistingInstall = true
            }
            try fileManager.moveItem(at: extractedDirectory, to: destinationURL)
            if hadExistingInstall {
                try? fileManager.removeItem(at: backupURL)
            }
        } catch {
            movedExistingInstall = movedExistingInstall || fileManager.fileExists(atPath: backupURL.path)
            if (!hadExistingInstall || movedExistingInstall),
               fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            if movedExistingInstall, fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
            }
            let reason: String
            if !hadExistingInstall {
                reason = "Nothing was installed."
            } else if fileManager.fileExists(atPath: destinationURL.path) {
                reason = "The previous copy was kept."
            } else {
                reason = "The previous copy could not be restored. Choose an existing copy or try setup again."
            }
            throw ToolchainInstallError.validationFailed(reason)
        }

        return ManagedToolchainInstallation(
            directoryURL: destinationURL,
            adbURL: destinationURL.appending(path: "adb"),
            scrcpyURL: destinationURL.appending(path: "scrcpy"),
            scrcpyServerURL: destinationURL.appending(path: "scrcpy-server")
        )
    }

    public func remove() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let lockDescriptor = try acquireInstallationLock()
        defer { releaseInstallationLock(lockDescriptor) }
        recoverInterruptedInstall()
        let destinationURL = installationDirectoryURL
        guard fileManager.fileExists(atPath: destinationURL.path) else { return }
        try fileManager.removeItem(at: destinationURL)
    }

    private func acquireInstallationLock() throws -> Int32 {
        let lockURL = rootURL.appending(path: ".install.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw ToolchainInstallError.validationFailed("Application Support is not writable.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw ToolchainInstallError.validationFailed("Another setup is still running.")
        }
        return descriptor
    }

    private func releaseInstallationLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private func recoverInterruptedInstall() {
        let contents = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        let stagingDirectories = contents.filter { $0.lastPathComponent.hasPrefix(".staging-") }
        stagingDirectories.forEach { try? fileManager.removeItem(at: $0) }

        let backupPrefix = ".backup-\(release.installationDirectoryName)-"
        let backupDirectories = contents.filter { $0.lastPathComponent.hasPrefix(backupPrefix) }
        guard let backup = backupDirectories.first else { return }
        if fileManager.fileExists(atPath: installationDirectoryURL.path) {
            backupDirectories.forEach { try? fileManager.removeItem(at: $0) }
            return
        }
        try? fileManager.moveItem(at: backup, to: installationDirectoryURL)
        backupDirectories.dropFirst().forEach { try? fileManager.removeItem(at: $0) }
    }

    private func validateFiles(in installation: ManagedToolchainInstallation) throws {
        let expected: [(URL, String)] = [
            (installation.adbURL, release.adbSHA256),
            (installation.scrcpyURL, release.scrcpySHA256),
            (installation.scrcpyServerURL, release.scrcpyServerSHA256)
        ]
        for (url, expectedHash) in expected {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular,
                  (try? Self.sha256(of: url)) == expectedHash else {
                throw ToolchainInstallError.invalidPackage
            }
        }
    }

    private func validateExecutables(
        in installation: ManagedToolchainInstallation,
        tools: Set<ToolchainTool>
    ) async throws {
        if tools.contains(.adb) {
            let adbResult = try await runWithTimeout(executable: installation.adbURL, arguments: ["version"], timeout: 8)
            let adbOutput = adbResult.stdout + adbResult.stderr
            guard adbResult.exitCode == 0, adbOutput.contains(release.adbVersionMarker) else {
                throw ToolchainInstallError.validationFailed("ADB did not pass its version check.")
            }
        }

        if tools.contains(.scrcpy) {
            let scrcpyResult = try await runWithTimeout(executable: installation.scrcpyURL, arguments: ["--version"], timeout: 8)
            let scrcpyOutput = scrcpyResult.stdout + scrcpyResult.stderr
            guard scrcpyResult.exitCode == 0, scrcpyOutput.contains(release.scrcpyVersionMarker) else {
                throw ToolchainInstallError.validationFailed("Phone Control did not pass its version check.")
            }
        }
    }

    private func preserveUnrequestedManagedTools(
        in installation: ManagedToolchainInstallation,
        requestedTools: Set<ToolchainTool>
    ) throws {
        let existingDirectory = installationDirectoryURL
        if !requestedTools.contains(.adb) {
            try preserveExistingFileOrRemove(
                stagedURL: installation.adbURL,
                existingURL: existingDirectory.appending(path: "adb")
            )
        }
        if !requestedTools.contains(.scrcpy) {
            try preserveExistingFileOrRemove(
                stagedURL: installation.scrcpyURL,
                existingURL: existingDirectory.appending(path: "scrcpy")
            )
            try preserveExistingFileOrRemove(
                stagedURL: installation.scrcpyServerURL,
                existingURL: existingDirectory.appending(path: "scrcpy-server")
            )
        }
    }

    private func preserveExistingFileOrRemove(stagedURL: URL, existingURL: URL) throws {
        if fileManager.fileExists(atPath: stagedURL.path) {
            try fileManager.removeItem(at: stagedURL)
        }
        guard fileManager.fileExists(atPath: existingURL.path) else { return }
        do {
            try fileManager.copyItem(at: existingURL, to: stagedURL)
        } catch {
            throw ToolchainInstallError.validationFailed(
                "The existing managed tool could not be preserved. The previous copy was kept."
            )
        }
    }

    private func runWithTimeout(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ADBCommandResult {
        do {
            return try await withThrowingTaskGroup(of: ADBCommandResult.self) { group in
                group.addTask { [runner] in
                    try await runner.run(executable: executable, arguments: arguments)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw ToolchainInstallError.validationFailed("Setup took too long and was stopped.")
                }
                guard let result = try await group.next() else {
                    throw ToolchainInstallError.validationFailed("Setup did not finish.")
                }
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolchainInstallError {
            throw error
        } catch {
            throw ToolchainInstallError.validationFailed("macOS could not run the downloaded copy.")
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum ToolchainHealth: Equatable, Sendable {
    case unknown
    case checking
    case installing
    case ready(candidate: ToolchainCandidate, version: String)
    case missing
    case needsRepair(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

@MainActor
public final class ToolchainManager: ObservableObject {
    @Published public private(set) var health: [ToolchainTool: ToolchainHealth] = [
        .adb: .unknown,
        .scrcpy: .unknown
    ]
    @Published public private(set) var lastInstallError: String?

    private let locator: ToolchainLocator
    private let installer: ManagedToolchainInstaller?
    private let runner: ProcessRunning
    private var stateRevision = 0
    private var installationInProgress = false

    public init(
        locator: ToolchainLocator = ToolchainLocator(),
        installer: ManagedToolchainInstaller? = try? ManagedToolchainInstaller(),
        runner: ProcessRunning = ProcessRunner()
    ) {
        self.locator = locator
        self.installer = installer
        self.runner = runner
    }

    public func refresh() async {
        guard !installationInProgress else { return }
        stateRevision += 1
        let revision = stateRevision
        for tool in ToolchainTool.allCases {
            guard revision == stateRevision, !installationInProgress else { return }
            health[tool] = .checking
            let result = await checkHealth(for: tool)
            guard revision == stateRevision, !installationInProgress else { return }
            health[tool] = result
        }
    }

    @discardableResult
    public func installManagedTools(for requestedTool: ToolchainTool? = nil) async -> Bool {
        guard !installationInProgress else { return false }
        guard let installer else {
            lastInstallError = ToolchainInstallError.unsupportedMac.localizedDescription
            return false
        }
        installationInProgress = true
        stateRevision += 1
        lastInstallError = nil
        let requestedTools = requestedTool.map { Set([$0]) }
            ?? Set(ToolchainTool.allCases)
        requestedTools.forEach { health[$0] = .installing }
        do {
            _ = try await installer.install(tools: requestedTools)
            installationInProgress = false
            await refresh()
            return true
        } catch is CancellationError {
            installationInProgress = false
            await refresh()
            return false
        } catch {
            lastInstallError = error.localizedDescription
            installationInProgress = false
            await refresh()
            return false
        }
    }

    public func removeManagedTools() async {
        guard !installationInProgress, let installer else { return }
        stateRevision += 1
        do {
            try await installer.remove()
            lastInstallError = nil
        } catch {
            lastInstallError = "The managed phone tools could not be removed."
        }
        await refresh()
    }

    public func status(for tool: ToolchainTool) -> ToolchainHealth {
        health[tool] ?? .unknown
    }

    public func clearInstallError() {
        lastInstallError = nil
    }

    public var hasManagedTools: Bool {
        guard let directory = ToolchainPaths.currentManagedToolchainDirectory() else { return false }
        return FileManager.default.fileExists(atPath: directory.path)
    }

    public func hasManagedTool(_ tool: ToolchainTool) -> Bool {
        guard let directory = ToolchainPaths.currentManagedToolchainDirectory() else { return false }
        let executable = directory.appending(path: tool.executableName)
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }

    private func checkHealth(for tool: ToolchainTool) async -> ToolchainHealth {
        let locator = self.locator
        let candidates: [ToolchainCandidate]
        do {
            candidates = try await Task.detached(priority: .utility) {
                try locator.resolutionCandidates(for: tool)
            }.value
        } catch FileOperationError.missingTool {
            return .missing
        } catch {
            return .needsRepair("The selected copy could not be found.")
        }

        let arguments = tool == .adb ? ["version"] : ["--version"]
        var lastIssue = "The selected copy could not be opened."
        for candidate in candidates {
            if tool == .scrcpy, locator.scrcpyServerURL(for: candidate) == nil {
                lastIssue = "Phone Control is missing one of its required files."
                continue
            }
            do {
                let result = try await probe(executable: candidate.url, arguments: arguments, timeout: 8)
                let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.exitCode == 0 else {
                    lastIssue = "The selected copy did not start correctly."
                    continue
                }
                let marker = tool == .adb ? "Android Debug Bridge version" : "scrcpy "
                guard output.localizedCaseInsensitiveContains(marker) else {
                    lastIssue = "The selected file is not a compatible \(tool.title) copy."
                    continue
                }
                return .ready(candidate: candidate, version: Self.shortVersion(for: tool, output: output))
            } catch {
                lastIssue = "The selected copy could not be opened."
            }
        }
        return .needsRepair(lastIssue)
    }

    private func probe(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ADBCommandResult {
        try await withThrowingTaskGroup(of: ADBCommandResult.self) { group in
            group.addTask { [runner] in
                try await runner.run(executable: executable, arguments: arguments)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ToolchainInstallError.validationFailed("The check took too long.")
            }
            guard let result = try await group.next() else {
                throw ToolchainInstallError.validationFailed("The check did not finish.")
            }
            group.cancelAll()
            return result
        }
    }

    static func shortVersion(for tool: ToolchainTool, output: String) -> String {
        switch tool {
        case .adb:
            if let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains("Version ") }) {
                return line.replacingOccurrences(of: "Version ", with: "")
            }
            return "Ready"
        case .scrcpy:
            if let line = output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { $0.lowercased().hasPrefix("scrcpy ") }) {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count > 1 {
                    return String(fields[1])
                }
            }
            return "Ready"
        }
    }
}
