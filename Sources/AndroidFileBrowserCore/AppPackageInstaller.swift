import Foundation

public enum AppPackageFormat: String, CaseIterable, Sendable {
    case apk
    case xapk
    case apks
    case splitZip = "zip"

    public static let supportedFilenameExtensions = Set(allCases.map(\.rawValue))

    public static func format(for url: URL) -> AppPackageFormat? {
        AppPackageFormat(rawValue: url.pathExtension.lowercased())
    }

    var displayName: String {
        switch self {
        case .apk: "APK"
        case .xapk: "XAPK"
        case .apks: "APK set"
        case .splitZip: "split APK ZIP"
        }
    }
}

public struct AppInstallOptions: Sendable, Equatable {
    public var allowDowngrade: Bool

    public init(allowDowngrade: Bool = false) {
        self.allowDowngrade = allowDowngrade
    }
}

public struct AppInstallationResult: Sendable, Equatable {
    public let installedAPKCount: Int
    public let copiedExpansionFileCount: Int

    public init(installedAPKCount: Int, copiedExpansionFileCount: Int = 0) {
        self.installedAPKCount = installedAPKCount
        self.copiedExpansionFileCount = copiedExpansionFileCount
    }
}

public enum AppInstallConflictKind: Sendable, Equatable {
    case newerVersionInstalled
    case differentSignature
}

public struct AppInstallConflict: LocalizedError, Sendable, Equatable {
    public let kind: AppInstallConflictKind
    public let packageName: String?
    public let details: String

    public init(kind: AppInstallConflictKind, packageName: String?, details: String) {
        self.kind = kind
        self.packageName = packageName
        self.details = details
    }

    public var errorDescription: String? {
        let appName = packageName.map { "\($0) " } ?? "This app "
        switch kind {
        case .newerVersionInstalled:
            return "\(appName)has a newer version installed. Use a newer APK, or remove the installed copy before trying this older version."
        case .differentSignature:
            return "\(appName)is signed differently from the installed copy. Remove the installed copy first only if losing its app data is acceptable."
        }
    }
}

public struct AppInstallRecoveryRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let urls: [URL]
    public let conflict: AppInstallConflict
    public let deviceID: String?
    public let deviceName: String?

    public init(
        id: UUID = UUID(),
        urls: [URL],
        conflict: AppInstallConflict,
        deviceID: String? = nil,
        deviceName: String? = nil
    ) {
        self.id = id
        self.urls = urls
        self.conflict = conflict
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    public var displayName: String {
        if urls.count == 1 {
            return urls[0].lastPathComponent
        }
        return "\(urls.count) split APKs"
    }
}

public enum AppPackageInstallError: LocalizedError, Sendable, Equatable {
    case unsupportedSelection
    case unsupportedFormat(String)
    case archiveCouldNotBeRead(String)
    case unsafeArchive
    case noAPKsFound(String)
    case bundletoolRequired
    case insufficientStorage
    case incompatibleDevice
    case incompleteSplitSet
    case installBlocked
    case invalidPackage
    case expansionCopyFailed(String)
    case failed(String)

    public var title: String {
        switch self {
        case .unsupportedSelection: "Choose One App Package"
        case .unsupportedFormat: "Unsupported App Package"
        case .archiveCouldNotBeRead, .unsafeArchive: "App Package Couldn’t Be Opened"
        case .noAPKsFound: "No APKs Found"
        case .bundletoolRequired: "Device-Specific APK Set Needed"
        case .insufficientStorage: "Not Enough Space"
        case .incompatibleDevice: "App Isn’t Compatible"
        case .incompleteSplitSet: "Split Package Is Incomplete"
        case .installBlocked: "Installation Blocked on Android"
        case .invalidPackage: "App Package Is Invalid"
        case .expansionCopyFailed: "App Installed, Extra Data Didn’t Copy"
        case .failed: "App Couldn’t Be Installed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupportedSelection:
            "Choose one APK, XAPK, APKS, or split ZIP package. You can also choose several APK files when they are splits for the same app."
        case .unsupportedFormat(let name):
            "\(name) isn’t an APK, XAPK, APKS, or split ZIP package."
        case .archiveCouldNotBeRead(let name):
            "\(name) is damaged, incomplete, or not a readable ZIP-based app package."
        case .unsafeArchive:
            "This archive contains unsafe file paths and wasn’t opened."
        case .noAPKsFound(let name):
            "\(name) doesn’t contain an APK or a complete set of split APKs."
        case .bundletoolRequired:
            "This APKS file contains variants for several kinds of devices. Install bundletool with Android Studio, or export a universal or device-specific APKS file, then try again."
        case .insufficientStorage:
            "Free some space on the Android device, then try the installation again."
        case .incompatibleDevice:
            "The package doesn’t include code or resources for this device’s Android version or processor."
        case .incompleteSplitSet:
            "One or more required split APKs are missing. Use the complete package made for this device."
        case .installBlocked:
            "Android blocked installs over USB. Unlock the device and check its Install via USB, USB debugging, work-profile, or parental-control settings."
        case .invalidPackage:
            "Android couldn’t verify this package. It may be damaged, unsigned, or contain splits from different app versions."
        case .expansionCopyFailed(let reason):
            "The APK installed, but its expansion files could not be copied to Android/obb. \(reason)"
        case .failed(let message):
            message.isEmpty ? "Android did not return an error message." : message
        }
    }
}

public enum AppInstallFailureParser {
    public static func issue(from rawMessage: String) -> Error {
        let message = cleanedMessage(rawMessage)
        let lowercased = message.lowercased()

        if lowercased.contains("install_failed_version_downgrade") || lowercased.contains("downgrade detected") {
            return AppInstallConflict(
                kind: .newerVersionInstalled,
                packageName: packageName(in: message),
                details: message
            )
        }
        if lowercased.contains("install_failed_update_incompatible")
            || lowercased.contains("signatures do not match")
            || lowercased.contains("inconsistent certificates") {
            return AppInstallConflict(
                kind: .differentSignature,
                packageName: packageName(in: message),
                details: message
            )
        }
        if lowercased.contains("install_failed_insufficient_storage") || lowercased.contains("not enough space") {
            return AppPackageInstallError.insufficientStorage
        }
        if lowercased.contains("install_failed_no_matching_abis")
            || lowercased.contains("install_failed_older_sdk")
            || lowercased.contains("requires newer sdk") {
            return AppPackageInstallError.incompatibleDevice
        }
        if lowercased.contains("install_failed_missing_split")
            || lowercased.contains("missing existing base package")
            || lowercased.contains("split null was defined multiple times") {
            return AppPackageInstallError.incompleteSplitSet
        }
        if lowercased.contains("install_failed_user_restricted")
            || lowercased.contains("install canceled by user")
            || lowercased.contains("user restriction") {
            return AppPackageInstallError.installBlocked
        }
        if lowercased.contains("install_parse_failed")
            || lowercased.contains("install_failed_invalid_apk")
            || lowercased.contains("install_failed_invalid_uri")
            || lowercased.contains("no certificates") {
            return AppPackageInstallError.invalidPackage
        }
        return AppPackageInstallError.failed(message)
    }

    public static func packageName(in message: String) -> String? {
        let patterns = [
            #"(?i)existing package\s+([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)"#,
            #"(?i)package\s+([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: message,
                    range: NSRange(message.startIndex..., in: message)
                  ),
                  let range = Range(match.range(at: 1), in: message) else {
                continue
            }
            return String(message[range])
        }
        return nil
    }

    private static func cleanedMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Android did not return an error message." : trimmed
    }
}

private struct AppArchiveContents: Sendable {
    let apkEntries: [String]
    let expansionEntries: [String]
    let manifestEntry: String?
    let containsBundletoolTableOfContents: Bool
}

private struct XAPKManifest: Decodable, Sendable {
    struct SplitAPK: Decodable, Sendable {
        let file: String
    }

    let packageName: String?
    let splitAPKs: [SplitAPK]?

    enum CodingKeys: String, CodingKey {
        case packageName = "package_name"
        case splitAPKs = "split_apks"
    }
}

private enum BundletoolCommand: Sendable {
    case executable(URL)
    case jar(java: URL, jar: URL)
}

private final class AppInstallProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let process = process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

public actor AppPackageInstaller {
    private let adb: ADBClient
    private let processRunner: ProcessRunning
    private let fileManager: FileManager

    public init(
        adb: ADBClient,
        processRunner: ProcessRunning = ProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.adb = adb
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    public nonisolated static func isSupportedSelection(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        if urls.allSatisfy({ AppPackageFormat.format(for: $0) == .apk }) {
            return true
        }
        return urls.count == 1 && AppPackageFormat.format(for: urls[0]) != nil
    }

    public func install(
        device: AndroidDevice,
        urls rawURLs: [URL],
        options: AppInstallOptions = AppInstallOptions()
    ) async throws -> AppInstallationResult {
        let urls = deduplicated(rawURLs)
        guard !urls.isEmpty else { throw AppPackageInstallError.unsupportedSelection }

        let accessedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }

        if urls.allSatisfy({ AppPackageFormat.format(for: $0) == .apk }) {
            try await installAPKs(urls, device: device, options: options)
            return AppInstallationResult(installedAPKCount: urls.count)
        }

        guard urls.count == 1, let archiveURL = urls.first else {
            throw AppPackageInstallError.unsupportedSelection
        }
        guard let format = AppPackageFormat.format(for: archiveURL), format != .apk else {
            throw AppPackageInstallError.unsupportedFormat(archiveURL.lastPathComponent)
        }

        let workDirectory = fileManager.temporaryDirectory
            .appending(path: "AOSP-AppInstall-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let contents = try await inspectArchive(archiveURL)
        if format == .apks,
           contents.containsBundletoolTableOfContents,
           !contents.apkEntries.contains(where: isUniversalAPKEntry) {
            guard let bundletool = locateBundletool() else {
                throw AppPackageInstallError.bundletoolRequired
            }
            try await installWithBundletool(
                bundletool,
                archiveURL: archiveURL,
                device: device,
                options: options
            )
            return AppInstallationResult(installedAPKCount: 1)
        }

        var xapkManifest: XAPKManifest?
        if let manifestEntry = contents.manifestEntry {
            let manifestData = try await archiveEntryData(manifestEntry, from: archiveURL)
            xapkManifest = try? JSONDecoder().decode(XAPKManifest.self, from: manifestData)
        }

        let selectedAPKEntries = selectedAPKEntries(
            for: format,
            contents: contents,
            manifest: xapkManifest
        )
        guard !selectedAPKEntries.isEmpty else {
            throw AppPackageInstallError.noAPKsFound(archiveURL.lastPathComponent)
        }

        var extractedAPKs: [URL] = []
        for (index, entry) in selectedAPKEntries.enumerated() {
            let destination = workDirectory.appending(path: "package-\(index).apk")
            try await extractArchiveEntry(entry, from: archiveURL, to: destination)
            extractedAPKs.append(destination)
        }

        try await installAPKs(extractedAPKs, device: device, options: options)

        var copiedExpansionFileCount = 0
        for (index, entry) in contents.expansionEntries.enumerated() {
            let localURL = workDirectory.appending(path: "expansion-\(index)-\((entry as NSString).lastPathComponent)")
            try await extractArchiveEntry(entry, from: archiveURL, to: localURL)
            guard let remotePath = expansionRemotePath(for: entry) else { continue }
            do {
                let parent = (remotePath as NSString).deletingLastPathComponent
                _ = try await adb.shell(serial: device.serial, "mkdir -p \(ADBClient.quoteRemote(parent))")
                _ = try await adb.run(["-s", device.serial, "push", localURL.path, remotePath])
                copiedExpansionFileCount += 1
            } catch {
                throw AppPackageInstallError.expansionCopyFailed(error.localizedDescription)
            }
        }

        return AppInstallationResult(
            installedAPKCount: extractedAPKs.count,
            copiedExpansionFileCount: copiedExpansionFileCount
        )
    }

    private func installAPKs(
        _ apkURLs: [URL],
        device: AndroidDevice,
        options: AppInstallOptions
    ) async throws {
        var arguments = ["-s", device.serial, apkURLs.count == 1 ? "install" : "install-multiple", "-r", "-t"]
        if options.allowDowngrade {
            arguments.append("-d")
        }
        arguments.append(contentsOf: apkURLs.map(\.path))

        do {
            _ = try await adb.run(arguments, timeout: 120)
        } catch FileOperationError.commandFailed(let message) {
            throw AppInstallFailureParser.issue(from: message)
        }
    }

    private func inspectArchive(_ archiveURL: URL) async throws -> AppArchiveContents {
        let result: ADBCommandResult
        do {
            result = try await processRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-Z1", archiveURL.path]
            )
        } catch {
            throw AppPackageInstallError.archiveCouldNotBeRead(archiveURL.lastPathComponent)
        }
        guard result.exitCode == 0 else {
            throw AppPackageInstallError.archiveCouldNotBeRead(archiveURL.lastPathComponent)
        }

        let entries = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard !entries.isEmpty else {
            throw AppPackageInstallError.archiveCouldNotBeRead(archiveURL.lastPathComponent)
        }
        guard entries.allSatisfy(Self.isSafeArchiveEntry) else {
            throw AppPackageInstallError.unsafeArchive
        }

        let apkEntries = entries.filter { $0.lowercased().hasSuffix(".apk") }
        let expansionEntries = entries.filter { entry in
            let normalized = entry.replacingOccurrences(of: "\\", with: "/")
            return normalized.lowercased().contains("android/obb/") && !normalized.hasSuffix("/")
        }
        let manifestEntry = entries.first { ($0 as NSString).lastPathComponent.lowercased() == "manifest.json" }
        let containsTOC = entries.contains { ($0 as NSString).lastPathComponent.lowercased() == "toc.pb" }
        return AppArchiveContents(
            apkEntries: apkEntries,
            expansionEntries: expansionEntries,
            manifestEntry: manifestEntry,
            containsBundletoolTableOfContents: containsTOC
        )
    }

    private func selectedAPKEntries(
        for format: AppPackageFormat,
        contents: AppArchiveContents,
        manifest: XAPKManifest?
    ) -> [String] {
        if format == .apks,
           let universal = contents.apkEntries.first(where: isUniversalAPKEntry) {
            return [universal]
        }

        if format == .xapk,
           let manifestEntries = manifest?.splitAPKs?.map(\.file),
           !manifestEntries.isEmpty {
            let entriesByNormalizedPath = Dictionary(
                contents.apkEntries.map { ($0.replacingOccurrences(of: "\\", with: "/"), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let selected = manifestEntries.compactMap { declared -> String? in
                let normalized = declared.replacingOccurrences(of: "\\", with: "/")
                return entriesByNormalizedPath[normalized]
                    ?? contents.apkEntries.first { ($0 as NSString).lastPathComponent == (normalized as NSString).lastPathComponent }
            }
            if !selected.isEmpty {
                return selected
            }
        }
        return contents.apkEntries
    }

    private func archiveEntryData(_ entry: String, from archiveURL: URL) async throws -> Data {
        let result = try await processRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", archiveURL.path, entry]
        )
        guard result.exitCode == 0 else {
            throw AppPackageInstallError.archiveCouldNotBeRead(archiveURL.lastPathComponent)
        }
        return result.stdoutData
    }

    private func extractArchiveEntry(_ entry: String, from archiveURL: URL, to destination: URL) async throws {
        guard Self.isSafeArchiveEntry(entry) else { throw AppPackageInstallError.unsafeArchive }
        let result = try await runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", archiveURL.path, entry],
            standardOutputURL: destination
        )
        guard result.exitCode == 0 else {
            throw AppPackageInstallError.archiveCouldNotBeRead(archiveURL.lastPathComponent)
        }
    }

    private func installWithBundletool(
        _ command: BundletoolCommand,
        archiveURL: URL,
        device: AndroidDevice,
        options: AppInstallOptions
    ) async throws {
        let adbURL = try await adb.resolvedExecutableURL()
        var installArguments = [
            "install-apks",
            "--apks=\(archiveURL.path)",
            "--device-id=\(device.serial)",
            "--adb=\(adbURL.path)"
        ]
        if options.allowDowngrade {
            installArguments.append("--allow-downgrade")
        }

        let executable: URL
        let arguments: [String]
        switch command {
        case .executable(let url):
            executable = url
            arguments = installArguments
        case .jar(let java, let jar):
            executable = java
            arguments = ["-jar", jar.path] + installArguments
        }

        let result = try await processRunner.run(executable: executable, arguments: arguments)
        guard result.exitCode == 0 else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw AppInstallFailureParser.issue(from: message)
        }
    }

    private func locateBundletool() -> BundletoolCommand? {
        let environment = ProcessInfo.processInfo.environment
        if let configuredPath = environment["BUNDLETOOL_PATH"], !configuredPath.isEmpty,
           let command = bundletoolCommand(at: URL(fileURLWithPath: configuredPath)) {
            return command
        }

        let executableCandidates = [
            "/opt/homebrew/bin/bundletool",
            "/usr/local/bin/bundletool"
        ] + (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/bundletool" }
        for path in executableCandidates where fileManager.isExecutableFile(atPath: path) {
            return .executable(URL(fileURLWithPath: path))
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        let studioRoots = [
            "/Applications/Android Studio.app/Contents",
            "/Applications/Android Studio Preview.app/Contents",
            "\(home)/Applications/Android Studio.app/Contents",
            "\(home)/Applications/Android Studio Preview.app/Contents"
        ]
        for root in studioRoots {
            let jar = URL(fileURLWithPath: root).appending(path: "plugins/android/lib/bundletool.jar")
            let java = URL(fileURLWithPath: root).appending(path: "jbr/Contents/Home/bin/java")
            if fileManager.fileExists(atPath: jar.path), fileManager.isExecutableFile(atPath: java.path) {
                return .jar(java: java, jar: jar)
            }
        }
        return nil
    }

    private func bundletoolCommand(at url: URL) -> BundletoolCommand? {
        if url.pathExtension.lowercased() == "jar" {
            let javaCandidates = [
                "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java",
                "/Applications/Android Studio Preview.app/Contents/jbr/Contents/Home/bin/java",
                "/usr/bin/java"
            ]
            guard fileManager.fileExists(atPath: url.path),
                  let javaPath = javaCandidates.first(where: fileManager.isExecutableFile(atPath:)) else {
                return nil
            }
            return .jar(java: URL(fileURLWithPath: javaPath), jar: url)
        }
        return fileManager.isExecutableFile(atPath: url.path) ? .executable(url) : nil
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        standardOutputURL: URL
    ) async throws -> ADBCommandResult {
        let processBox = AppInstallProcessBox()
        let task = Task.detached(priority: .userInitiated) {
            let process = Process()
            processBox.set(process)
            defer { processBox.clear(process) }
            process.executableURL = executable
            process.arguments = arguments

            FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: standardOutputURL)
            defer { try? outputHandle.close() }

            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appending(path: "AOSP-AppInstallProcess-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let stderrURL = temporaryDirectory.appending(path: "stderr")
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer { try? stderrHandle.close() }

            process.standardOutput = outputHandle
            process.standardError = stderrHandle
            try Task.checkCancellation()
            try process.run()
            process.waitUntilExit()
            try Task.checkCancellation()
            try outputHandle.synchronize()
            try stderrHandle.synchronize()
            return ADBCommandResult(
                stdoutData: Data(),
                stderrData: try Data(contentsOf: stderrURL),
                exitCode: process.terminationStatus
            )
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            processBox.terminate()
        }
    }

    private func isUniversalAPKEntry(_ entry: String) -> Bool {
        (entry as NSString).lastPathComponent.lowercased() == "universal.apk"
    }

    private func expansionRemotePath(for entry: String) -> String? {
        let normalized = entry.replacingOccurrences(of: "\\", with: "/")
        let lowercased = normalized.lowercased()
        guard let range = lowercased.range(of: "android/obb/") else { return nil }
        let suffix = normalized[range.upperBound...]
        guard !suffix.isEmpty else { return nil }
        return "/sdcard/Android/obb/\(suffix)"
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var paths = Set<String>()
        return urls.filter { paths.insert($0.standardizedFileURL.path).inserted }
    }

    static func isSafeArchiveEntry(_ entry: String) -> Bool {
        let normalized = entry.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"), !normalized.isEmpty else { return false }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        let pathComponents = normalized.hasSuffix("/") ? components.dropLast() : components[...]
        return !pathComponents.contains("..") && !pathComponents.contains("")
    }
}
