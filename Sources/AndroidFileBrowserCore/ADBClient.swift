import Darwin
import Foundation

public struct ADBCommandResult: Sendable {
    public let stdoutData: Data
    public let stderrData: Data
    public let exitCode: Int32

    public var stdout: String {
        String(data: stdoutData, encoding: .utf8) ?? ""
    }

    public var stderr: String {
        String(data: stderrData, encoding: .utf8) ?? ""
    }
}

public final class DetachedProcessHandle: @unchecked Sendable {
    private let process: Process
    private let condition = NSCondition()
    private var cachedTerminationStatus: Int32?

    fileprivate init(process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            condition.lock()
            cachedTerminationStatus = process.terminationStatus
            condition.broadcast()
            condition.unlock()
        }
    }

    public var isRunning: Bool {
        process.isRunning
    }

    public func interrupt() {
        guard process.isRunning else { return }
        Darwin.kill(pid_t(process.processIdentifier), SIGINT)
    }

    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    public func waitUntilExit() -> Int32 {
        condition.lock()
        while cachedTerminationStatus == nil {
            condition.wait()
        }
        let status = cachedTerminationStatus ?? process.terminationStatus
        condition.unlock()
        return status
    }

    public func waitUntilExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        condition.lock()
        while cachedTerminationStatus == nil, process.isRunning, Date() < deadline {
            condition.wait(until: deadline)
        }
        let exited = cachedTerminationStatus != nil || !process.isRunning
        condition.unlock()
        return exited
    }
}

public struct DetachedLaunchObservation: Sendable {
    public let processIdentifier: Int32
    public let isRunningAfterObservation: Bool
    public let exitCode: Int32?
    public let output: String
    public let logURL: URL
    public let processHandle: DetachedProcessHandle
}

public final class ADBScreenRecordingProcess: @unchecked Sendable {
    public let serial: String
    public let remotePath: String
    public let startedAt: Date
    public let logURL: URL

    private let process: Process
    private let logHandle: FileHandle
    private let closeLock = NSLock()
    private var didCloseLog = false

    init(serial: String, remotePath: String, startedAt: Date, logURL: URL, process: Process, logHandle: FileHandle) {
        self.serial = serial
        self.remotePath = remotePath
        self.startedAt = startedAt
        self.logURL = logURL
        self.process = process
        self.logHandle = logHandle
    }

    deinit {
        closeLog()
    }

    public var isRunning: Bool {
        process.isRunning
    }

    public func stop() {
        guard process.isRunning else { return }
        Darwin.kill(pid_t(process.processIdentifier), SIGINT)
    }

    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    public func waitUntilExit(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while process.isRunning,
              Self.isProcessAlive(process.processIdentifier),
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning, Self.isProcessAlive(process.processIdentifier) {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning,
                  Self.isProcessAlive(process.processIdentifier),
                  Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        let exited = !process.isRunning || !Self.isProcessAlive(process.processIdentifier)
        closeLog()
        return exited
    }

    private static func isProcessAlive(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else { return false }
        if Darwin.kill(pid_t(processIdentifier), 0) == 0 { return true }
        return errno != ESRCH
    }

    private func closeLog() {
        closeLock.lock()
        guard !didCloseLog else {
            closeLock.unlock()
            return
        }
        didCloseLog = true
        closeLock.unlock()

        try? logHandle.synchronize()
        try? logHandle.close()
    }
}

public final class ScrcpyScreenRecordingProcess: @unchecked Sendable {
    public let serial: String
    public let localURL: URL
    public let startedAt: Date
    public let logURL: URL

    private let processHandle: DetachedProcessHandle

    init(
        serial: String,
        localURL: URL,
        startedAt: Date,
        logURL: URL,
        processHandle: DetachedProcessHandle
    ) {
        self.serial = serial
        self.localURL = localURL
        self.startedAt = startedAt
        self.logURL = logURL
        self.processHandle = processHandle
    }

    public var isRunning: Bool {
        processHandle.isRunning
    }

    public func stop() {
        processHandle.interrupt()
    }

    public func terminate() {
        processHandle.terminate()
    }

    public func waitUntilExit(timeout: TimeInterval = 5) -> Bool {
        if processHandle.waitUntilExit(timeout: timeout) {
            return true
        }
        processHandle.terminate()
        return processHandle.waitUntilExit(timeout: 1)
    }
}

public enum ScreenRecordingProcess: @unchecked Sendable {
    case adb(ADBScreenRecordingProcess)
    case scrcpy(ScrcpyScreenRecordingProcess)

    public var serial: String {
        switch self {
        case .adb(let handle): handle.serial
        case .scrcpy(let handle): handle.serial
        }
    }

    public var startedAt: Date {
        switch self {
        case .adb(let handle): handle.startedAt
        case .scrcpy(let handle): handle.startedAt
        }
    }

    public var logURL: URL {
        switch self {
        case .adb(let handle): handle.logURL
        case .scrcpy(let handle): handle.logURL
        }
    }

    public var isRunning: Bool {
        switch self {
        case .adb(let handle): handle.isRunning
        case .scrcpy(let handle): handle.isRunning
        }
    }

    public var recommendedStartupTrim: TimeInterval {
        switch self {
        case .adb: 0.75
        case .scrcpy: 0
        }
    }

    public var localArtifactURL: URL? {
        guard case .scrcpy(let handle) = self else { return nil }
        return handle.localURL
    }

    public func stop() {
        switch self {
        case .adb(let handle): handle.stop()
        case .scrcpy(let handle): handle.stop()
        }
    }

    public func terminate() {
        switch self {
        case .adb(let handle): handle.terminate()
        case .scrcpy(let handle): handle.terminate()
        }
    }

    public func waitUntilExit(timeout: TimeInterval = 5) -> Bool {
        switch self {
        case .adb(let handle): handle.waitUntilExit(timeout: timeout)
        case .scrcpy(let handle): handle.waitUntilExit(timeout: timeout)
        }
    }
}

struct ScrcpyScreenRecordingAudioCapabilities: Equatable, Sendable {
    private static let requiredRecordingOptions: Set<String> = [
        "--serial",
        "--record",
        "--record-format",
        "--no-playback",
        "--no-window",
        "--no-control",
        "--no-clipboard-autosync",
        "--video-codec",
        "--audio-codec",
        "--audio-bit-rate",
        "--audio-source",
        "--require-audio",
        "--video-bit-rate",
        "--max-size",
        "--time-limit"
    ]
    private static let knownAudioSources = ["output", "mic", "voice-performance"]

    let options: Set<String>
    let audioSources: Set<String>

    static func supportsRequiredVersion(_ output: String) -> Bool {
        guard let versionLine = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.lowercased().hasPrefix("scrcpy ") }) else {
            return false
        }
        let fields = versionLine.split(whereSeparator: \.isWhitespace)
        guard fields.count > 1 else { return false }
        let components = fields[1].split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              let major = Int(components[0].prefix(while: \.isNumber)),
              let minor = Int(components[1].prefix(while: \.isNumber)) else {
            return false
        }
        return major > 4 || (major == 4 && minor >= 1)
    }

    static func parse(helpOutput: String) -> ScrcpyScreenRecordingAudioCapabilities {
        let lowercased = helpOutput.lowercased()
        let options = Set(lowercased.components(separatedBy: .whitespacesAndNewlines).compactMap {
            component -> String? in
            guard let optionStart = component.range(of: "--")?.lowerBound else { return nil }
            let suffix = component[optionStart...]
            let option = suffix.prefix { character in
                character == "-" || character.isLetter || character.isNumber
            }
            return option.count > 2 ? String(option) : nil
        })
        let audioSources = Set(knownAudioSources.filter { source in
            lowercased.contains("\"\(source)\"") || lowercased.contains("'\(source)'")
        })
        return ScrcpyScreenRecordingAudioCapabilities(
            options: options,
            audioSources: audioSources
        )
    }

    func supports(audioSources requestedSources: [PhoneRecordingAudioSource]) -> Bool {
        guard Self.requiredRecordingOptions.isSubset(of: options) else { return false }
        let requestedAudioSources = Set(requestedSources.compactMap(\.scrcpyAudioSource))
        return requestedAudioSources.isSubset(of: audioSources)
    }
}

public protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult
    func runStreaming(
        executable: URL,
        arguments: [String],
        output: @escaping @Sendable (Data) -> Void
    ) async throws -> ADBCommandResult
    func launchDetached(executable: URL, arguments: [String]) async throws
    func launchObserved(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        observationDuration: TimeInterval
    ) async throws -> DetachedLaunchObservation
}

private final class RunningProcessBox: @unchecked Sendable {
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

        guard process?.isRunning == true else { return }
        process?.terminate()
    }
}

public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        let processBox = RunningProcessBox()
        let task = Task.detached(priority: .userInitiated) {
            let process = Process()
            processBox.set(process)
            defer { processBox.clear(process) }

            process.executableURL = executable
            process.arguments = arguments

            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appending(path: "AndroidFileBrowser-process-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let stdoutURL = temporaryDirectory.appending(path: "stdout")
            let stderrURL = temporaryDirectory.appending(path: "stderr")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            try Task.checkCancellation()
            try process.run()
            process.waitUntilExit()
            try Task.checkCancellation()
            try stdoutHandle.synchronize()
            try stderrHandle.synchronize()
            let stdoutData = try Data(contentsOf: stdoutURL)
            let stderrData = try Data(contentsOf: stderrURL)

            return ADBCommandResult(
                stdoutData: stdoutData,
                stderrData: stderrData,
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

    public func runStreaming(
        executable: URL,
        arguments: [String],
        output: @escaping @Sendable (Data) -> Void
    ) async throws -> ADBCommandResult {
        let processBox = RunningProcessBox()
        let task = Task.detached(priority: .userInitiated) {
            let process = Process()
            processBox.set(process)
            defer { processBox.clear(process) }

            process.executableURL = executable
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try Task.checkCancellation()
            try process.run()

            var outputData = Data()
            let handle = pipe.fileHandleForReading
            while true {
                try Task.checkCancellation()
                let data = handle.availableData
                guard !data.isEmpty else { break }
                outputData.append(data)
                output(data)
            }

            process.waitUntilExit()
            try Task.checkCancellation()
            return ADBCommandResult(
                stdoutData: outputData,
                stderrData: Data(),
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

    public func launchDetached(executable: URL, arguments: [String]) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = nil
            process.standardError = nil
            try process.run()
        }.value
    }

    public func launchObserved(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        observationDuration: TimeInterval = 1.5
    ) async throws -> DetachedLaunchObservation {
        try await Task.detached(priority: .userInitiated) {
            let logURL = FileManager.default.temporaryDirectory
                .appending(path: "AndroidFileBrowser-\(executable.lastPathComponent)-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let logHandle = try FileHandle(forWritingTo: logURL)
            defer { try? logHandle.close() }

            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = logHandle
            process.standardError = logHandle
            var processEnvironment = ProcessInfo.processInfo.environment
            environment.forEach { key, value in
                processEnvironment[key] = value
            }
            process.environment = processEnvironment

            let processHandle = DetachedProcessHandle(process: process)
            try process.run()
            let processIdentifier = process.processIdentifier
            let observationNanoseconds = UInt64(max(0, observationDuration) * 1_000_000_000)
            try await Task.sleep(nanoseconds: observationNanoseconds)
            try? logHandle.synchronize()

            if process.isRunning {
                return DetachedLaunchObservation(
                    processIdentifier: processIdentifier,
                    isRunningAfterObservation: true,
                    exitCode: nil,
                    output: Self.readLog(at: logURL),
                    logURL: logURL,
                    processHandle: processHandle
                )
            }

            _ = processHandle.waitUntilExit()
            try? logHandle.synchronize()
            return DetachedLaunchObservation(
                processIdentifier: processIdentifier,
                isRunningAfterObservation: false,
                exitCode: process.terminationStatus,
                output: Self.readLog(at: logURL),
                logURL: logURL,
                processHandle: processHandle
            )
        }.value
    }

    private static func readLog(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ADBCommandTimedOut: Error, Sendable {}

public enum ToolchainTool: String, CaseIterable, Identifiable, Sendable {
    case adb
    case scrcpy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .adb: "ADB"
        case .scrcpy: "scrcpy"
        }
    }

    public var executableName: String { rawValue }

    public var symbol: String {
        switch self {
        case .adb: "terminal"
        case .scrcpy: "iphone.gen2"
        }
    }
}

public enum ToolSelectionMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case managed
    case custom
    case bundled

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .managed: "Managed Copy"
        case .custom: "Selected Path"
        case .bundled: "Bundled Copy"
        }
    }
}

public struct ToolchainPreferences: Sendable {
    public static let adbModeKey = "settings.adbToolMode"
    public static let adbPathKey = "settings.adbToolPath"
    public static let scrcpyModeKey = "settings.scrcpyToolMode"
    public static let scrcpyPathKey = "settings.scrcpyToolPath"

    public var adbMode: ToolSelectionMode
    public var adbPath: String
    public var scrcpyMode: ToolSelectionMode
    public var scrcpyPath: String

    public init(
        adbMode: ToolSelectionMode = .automatic,
        adbPath: String = "",
        scrcpyMode: ToolSelectionMode = .automatic,
        scrcpyPath: String = ""
    ) {
        self.adbMode = adbMode
        self.adbPath = adbPath
        self.scrcpyMode = scrcpyMode
        self.scrcpyPath = scrcpyPath
    }

    public static func current(defaults: UserDefaults = .standard) -> ToolchainPreferences {
        ToolchainPreferences(
            adbMode: ToolSelectionMode(rawValue: defaults.string(forKey: adbModeKey) ?? "") ?? .automatic,
            adbPath: defaults.string(forKey: adbPathKey) ?? "",
            scrcpyMode: ToolSelectionMode(rawValue: defaults.string(forKey: scrcpyModeKey) ?? "") ?? .automatic,
            scrcpyPath: defaults.string(forKey: scrcpyPathKey) ?? ""
        )
    }
}

public struct ToolchainCandidate: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable {
        case running
        case selected
        case managed
        case bundled
        case environment
        case androidSDK
        case homebrew
        case unity
        case path
    }

    public let tool: ToolchainTool
    public let url: URL
    public let source: Source
    public let isRunning: Bool

    public var id: String { "\(tool.rawValue):\(url.standardizedFileURL.path)" }
    public var isBundled: Bool { source == .bundled }
    public var isManaged: Bool { source == .managed }

    public var sourceTitle: String {
        switch source {
        case .running: "Running"
        case .selected: "Selected"
        case .managed: "Managed by AOSP File Manager"
        case .bundled: "Bundled"
        case .environment: "Environment"
        case .androidSDK: "Android SDK"
        case .homebrew: "Homebrew"
        case .unity: "Unity"
        case .path: "PATH"
        }
    }

    public var menuTitle: String {
        let runningSuffix = isRunning ? " · Running" : ""
        return "\(sourceTitle)\(runningSuffix) — \(url.path)"
    }
}

public struct ToolchainLocator: Sendable {
    public var adbOverride: URL?
    public var scrcpyOverride: URL?
    private let preferencesProvider: @Sendable () -> ToolchainPreferences
    private let managedToolsDirectoryProvider: @Sendable () -> URL?

    public init(
        adbOverride: URL? = nil,
        scrcpyOverride: URL? = nil,
        preferencesProvider: @escaping @Sendable () -> ToolchainPreferences = { ToolchainPreferences.current() },
        managedToolsDirectoryProvider: @escaping @Sendable () -> URL? = {
            ToolchainPaths.currentManagedToolchainDirectory()
        }
    ) {
        self.adbOverride = adbOverride
        self.scrcpyOverride = scrcpyOverride
        self.preferencesProvider = preferencesProvider
        self.managedToolsDirectoryProvider = managedToolsDirectoryProvider
    }

    public func adbURL() throws -> URL {
        if let adbOverride { return adbOverride }
        return try resolvedCandidate(for: .adb).url
    }

    public func scrcpyURL() throws -> URL {
        if let scrcpyOverride { return scrcpyOverride }
        return try resolvedCandidate(for: .scrcpy).url
    }

    public func resolvedCandidate(for tool: ToolchainTool) throws -> ToolchainCandidate {
        guard let candidate = try resolutionCandidates(for: tool).first else {
            throw FileOperationError.missingTool(tool.executableName)
        }
        return candidate
    }

    public func resolutionCandidates(for tool: ToolchainTool) throws -> [ToolchainCandidate] {
        switch tool {
        case .adb where adbOverride != nil:
            return [ToolchainCandidate(tool: .adb, url: adbOverride!.standardizedFileURL, source: .selected, isRunning: false)]
        case .scrcpy where scrcpyOverride != nil:
            return [ToolchainCandidate(tool: .scrcpy, url: scrcpyOverride!.standardizedFileURL, source: .selected, isRunning: false)]
        default:
            break
        }

        let preferences = preferencesProvider()
        let mode: ToolSelectionMode
        let selectedPath: String
        switch tool {
        case .adb:
            mode = preferences.adbMode
            selectedPath = preferences.adbPath
        case .scrcpy:
            mode = preferences.scrcpyMode
            selectedPath = preferences.scrcpyPath
        }

        let candidates = Self.resolveCandidates(
            tool: tool,
            mode: mode,
            selectedPath: selectedPath,
            managedToolsDirectory: managedToolsDirectoryProvider()
        )
        guard !candidates.isEmpty else {
            throw FileOperationError.missingTool(tool.executableName)
        }
        return candidates
    }

    public func scrcpyServerURL() -> URL? {
        guard let candidate = try? resolvedCandidate(for: .scrcpy) else { return nil }
        return scrcpyServerURL(for: candidate)
    }

    public func scrcpyServerURL(for candidate: ToolchainCandidate) -> URL? {
        let executableDirectory = candidate.url.deletingLastPathComponent()
        var candidates = [
            executableDirectory.appending(path: "scrcpy-server"),
            executableDirectory.deletingLastPathComponent().appending(path: "share/scrcpy/scrcpy-server")
        ]
        if candidate.source == .bundled {
            candidates.append(contentsOf: [
                Bundle.main.url(forResource: "scrcpy-server", withExtension: nil, subdirectory: "Tools"),
                Bundle.main.url(forResource: "scrcpy-server", withExtension: nil, subdirectory: "Tools/share/scrcpy")
            ].compactMap { $0 })
        }

        return Self.deduplicated(candidates).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func detectedCandidates(for tool: ToolchainTool) -> [ToolchainCandidate] {
        let runningURL = runningExecutable(named: tool.executableName)
        let runningPath = runningURL?.standardizedFileURL.path
        var candidates: [ToolchainCandidate] = []

        if let runningURL, isExecutable(runningURL) {
            candidates.append(ToolchainCandidate(tool: tool, url: runningURL, source: .running, isRunning: true))
        }

        candidates.append(contentsOf: externalCandidateURLs(for: tool).compactMap { url, source in
            executableCandidate(
                tool: tool,
                url: url,
                source: source,
                isRunning: url.standardizedFileURL.path == runningPath
            )
        })

        if let managedDirectory = ToolchainPaths.currentManagedToolchainDirectory(),
           let managedURL = managedURL(for: tool, directory: managedDirectory),
           isExecutable(managedURL) {
            candidates.append(ToolchainCandidate(
                tool: tool,
                url: managedURL,
                source: .managed,
                isRunning: managedURL.standardizedFileURL.path == runningPath
            ))
        }

        if let bundledURL = bundledURL(for: tool), isExecutable(bundledURL) {
            candidates.append(ToolchainCandidate(
                tool: tool,
                url: bundledURL,
                source: .bundled,
                isRunning: bundledURL.standardizedFileURL.path == runningPath
            ))
        }

        return deduplicated(candidates)
    }

    private static func resolveCandidates(
        tool: ToolchainTool,
        mode: ToolSelectionMode,
        selectedPath: String,
        managedToolsDirectory: URL?
    ) -> [ToolchainCandidate] {
        let selectedCandidate = executableCandidate(tool: tool, path: selectedPath, source: .selected)
        let runningCandidate = runningExecutable(named: tool.executableName).flatMap {
            executableCandidate(tool: tool, url: $0, source: .running, isRunning: true)
        }
        let externalCandidates = externalCandidateURLs(for: tool).compactMap { url, source in
            executableCandidate(tool: tool, url: url, source: source, isRunning: false)
        }
        let bundledCandidate = bundledURL(for: tool).flatMap {
            executableCandidate(tool: tool, url: $0, source: .bundled, isRunning: false)
        }
        let managedCandidate = managedToolsDirectory
            .flatMap { managedURL(for: tool, directory: $0) }
            .flatMap { executableCandidate(tool: tool, url: $0, source: .managed, isRunning: false) }

        let ordered: [ToolchainCandidate?]
        switch mode {
        case .automatic:
            ordered = [managedCandidate] + externalCandidates.map(Optional.some) + [bundledCandidate, runningCandidate]
        case .managed:
            ordered = [managedCandidate]
        case .custom:
            ordered = [selectedCandidate]
        case .bundled:
            ordered = [bundledCandidate]
        }

        return deduplicated(ordered.compactMap { $0 })
    }

    private static func externalCandidateURLs(for tool: ToolchainTool) -> [(URL, ToolchainCandidate.Source)] {
        switch tool {
        case .adb:
            var candidates: [(URL, ToolchainCandidate.Source)] = [
                environmentTool("ANDROID_HOME", relative: "platform-tools/adb").map { ($0, .environment) },
                environmentTool("ANDROID_SDK_ROOT", relative: "platform-tools/adb").map { ($0, .environment) },
                (URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Android/sdk/platform-tools/adb"), .androidSDK),
                (URL(fileURLWithPath: "/opt/homebrew/bin/adb"), .homebrew),
                (URL(fileURLWithPath: "/usr/local/bin/adb"), .homebrew)
            ].compactMap { $0 }

            candidates.append(contentsOf: unityADBCandidates().map { ($0, .unity) })
            candidates.append(contentsOf: whichCandidates(named: tool.executableName).map { ($0, .path) })
            return deduplicated(candidates)
        case .scrcpy:
            let candidates: [(URL, ToolchainCandidate.Source)] = [
                (URL(fileURLWithPath: "/opt/homebrew/bin/scrcpy"), .homebrew),
                (URL(fileURLWithPath: "/usr/local/bin/scrcpy"), .homebrew)
            ] + whichCandidates(named: tool.executableName).map { ($0, .path) }
            return deduplicated(candidates)
        }
    }

    private static func bundledURL(for tool: ToolchainTool) -> URL? {
        switch tool {
        case .adb:
            Bundle.main.url(forResource: "adb", withExtension: nil, subdirectory: "Tools/platform-tools")
        case .scrcpy:
            Bundle.main.url(forResource: "scrcpy", withExtension: nil, subdirectory: "Tools")
        }
    }

    private static func managedURL(for tool: ToolchainTool, directory: URL) -> URL? {
        switch tool {
        case .adb:
            directory.appending(path: "adb")
        case .scrcpy:
            directory.appending(path: "scrcpy")
        }
    }

    private static func executableCandidate(
        tool: ToolchainTool,
        path: String,
        source: ToolchainCandidate.Source
    ) -> ToolchainCandidate? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return executableCandidate(tool: tool, url: URL(fileURLWithPath: trimmed), source: source, isRunning: false)
    }

    private static func executableCandidate(
        tool: ToolchainTool,
        url: URL,
        source: ToolchainCandidate.Source,
        isRunning: Bool
    ) -> ToolchainCandidate? {
        guard isExecutable(url) else { return nil }
        return ToolchainCandidate(tool: tool, url: url.standardizedFileURL, source: source, isRunning: isRunning)
    }

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path) && supportsCurrentArchitecture(url)
    }

    private static func supportsCurrentArchitecture(_ url: URL) -> Bool {
        guard let archOutput = commandOutput(executable: "/usr/bin/lipo", arguments: ["-archs", url.path])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !archOutput.isEmpty else {
            return true
        }
        let supportedArchitectures = Set(archOutput.split(separator: " ").map(String.init))
        let current = currentMachineArchitecture()
        if current == "arm64e" {
            return supportedArchitectures.contains("arm64") || supportedArchitectures.contains("arm64e")
        }
        return supportedArchitectures.contains(current)
    }

    private static func currentMachineArchitecture() -> String {
        commandOutput(executable: "/usr/bin/uname", arguments: ["-m"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "arm64"
    }

    private static func environmentTool(_ variable: String, relative: String) -> URL? {
        guard let root = ProcessInfo.processInfo.environment[variable], !root.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: root).appending(path: relative)
    }

    private static func unityADBCandidates() -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications/Unity/Hub/Editor"),
            URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Applications/Unity/Hub/Editor")
        ]
        return roots.flatMap { root in
            (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        .map { editor in
            editor.appending(path: "PlaybackEngines/AndroidPlayer/SDK/platform-tools/adb")
        }
    }

    private static func whichCandidates(named executableName: String) -> [URL] {
        commandOutput(executable: "/usr/bin/which", arguments: ["-a", executableName])?
            .split(whereSeparator: \.isNewline)
            .map { URL(fileURLWithPath: String($0)) } ?? []
    }

    private static func runningExecutable(named executableName: String) -> URL? {
        guard let pidOutput = commandOutput(executable: "/usr/bin/pgrep", arguments: ["-x", executableName]) else {
            return nil
        }

        for pid in pidOutput.split(whereSeparator: \.isNewline) {
            guard let command = commandOutput(executable: "/bin/ps", arguments: ["-p", String(pid), "-o", "comm="])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !command.isEmpty else {
                continue
            }
            let url = URL(fileURLWithPath: command)
            if url.lastPathComponent == executableName, isExecutable(url) {
                return url.standardizedFileURL
            }
        }
        return nil
    }

    private static func commandOutput(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func deduplicated(_ candidates: [ToolchainCandidate]) -> [ToolchainCandidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            seen.insert(candidate.url.standardizedFileURL.path).inserted
        }
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    private static func deduplicated(_ candidates: [(URL, ToolchainCandidate.Source)]) -> [(URL, ToolchainCandidate.Source)] {
        var seen = Set<String>()
        return candidates.filter { url, _ in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }
}

public actor ADBClient {
    private let locator: ToolchainLocator
    private let runner: ProcessRunning
    private var cachedADBURL: URL?
    private var cachedADBCandidateSignatures: [String] = []
    private var cachedADBValidatedAt: Date?
    private var cachedADBFailureCandidateSignatures: [String] = []
    private var cachedADBFailureAt: Date?

    public init(locator: ToolchainLocator = ToolchainLocator(), runner: ProcessRunning = ProcessRunner()) {
        self.locator = locator
        self.runner = runner
    }

    public func resolvedExecutableURL() async throws -> URL {
        try await workingADBURL()
    }

    public func run(
        _ arguments: [String],
        allowFailure: Bool = false,
        timeout: TimeInterval? = nil
    ) async throws -> ADBCommandResult {
        let executable = try await workingADBURL()
        let result: ADBCommandResult
        do {
            let commandTimeout = timeout ?? (arguments.first == "devices" ? 10 : nil)
            if let commandTimeout {
                result = try await runWithTimeout(
                    executable: executable,
                    arguments: arguments,
                    timeout: commandTimeout
                )
            } else {
                result = try await runner.run(executable: executable, arguments: arguments)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is ADBCommandTimedOut {
            clearCachedADBResolution()
            throw FileOperationError.commandFailed("ADB took too long to respond.")
        } catch {
            clearCachedADBResolution()
            throw FileOperationError.toolUnavailable(.adb, "macOS could not open the selected copy.")
        }

        if result.exitCode != 0 {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            if Self.isADBInfrastructureFailure(message) || arguments.first == "devices" {
                clearCachedADBResolution()
                throw FileOperationError.toolUnavailable(.adb, Self.adbStartupFailureReason(message))
            }
            if !allowFailure {
                throw FileOperationError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return result
    }

    public func runStreaming(
        _ arguments: [String],
        allowFailure: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ADBCommandResult {
        let executable = try await workingADBURL()
        let result: ADBCommandResult
        do {
            result = try await runner.runStreaming(executable: executable, arguments: arguments) { data in
                guard let text = String(data: data, encoding: .utf8),
                      let fraction = ADBProgressParser.fractionCompleted(from: text) else {
                    return
                }
                progress?(fraction)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            clearCachedADBResolution()
            throw FileOperationError.toolUnavailable(.adb, "macOS could not open the selected copy.")
        }

        if result.exitCode != 0 {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            if Self.isADBInfrastructureFailure(message) {
                clearCachedADBResolution()
                throw FileOperationError.toolUnavailable(.adb, Self.adbStartupFailureReason(message))
            }
            if !allowFailure {
                throw FileOperationError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return result
    }

    public func shell(
        serial: String,
        _ command: String,
        allowFailure: Bool = false,
        timeout: TimeInterval? = nil
    ) async throws -> ADBCommandResult {
        try await run(["-s", serial, "shell", command], allowFailure: allowFailure, timeout: timeout)
    }

    public func killServer() async throws {
        _ = try await run(["kill-server"], allowFailure: true, timeout: 8)
    }

    public func validateADB() async throws {
        _ = try await run(["devices"], timeout: 10)
    }

    public func validatePhoneControlTools() async throws {
        try await validateADB()
        let candidates = try locator.resolutionCandidates(for: .scrcpy)
        for candidate in candidates {
            guard locator.scrcpyServerURL(for: candidate) != nil else { continue }
            do {
                let result = try await runWithTimeout(
                    executable: candidate.url,
                    arguments: ["--version"],
                    timeout: 5
                )
                let output = result.stdout + result.stderr
                if result.exitCode == 0,
                   output.localizedCaseInsensitiveContains("scrcpy ") {
                    return
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        throw FileOperationError.toolUnavailable(.scrcpy, "macOS could not open any compatible Phone Control copy.")
    }

    public func validateScreenRecordingAudioTools(
        audioSources: [PhoneRecordingAudioSource]
    ) async throws {
        try await validateADB()
        guard audioSources.contains(where: { $0 != .none }) else { return }

        let candidates = (try? locator.resolutionCandidates(for: .scrcpy)) ?? []
        for candidate in candidates {
            guard locator.scrcpyServerURL(for: candidate) != nil else { continue }
            do {
                guard let capabilities = try await scrcpyScreenRecordingAudioCapabilities(
                    for: candidate
                ), capabilities.supports(audioSources: audioSources) else {
                    continue
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        throw FileOperationError.toolUnavailable(
            .scrcpy,
            "Screen recording audio needs a compatible Phone Tools installation."
        )
    }

    public func launchScrcpy(
        serial: String,
        windowTitle: String = "AOSP File Manager Phone Control",
        options: ScreenRecordingOptions = ScreenRecordingOptions(),
        deviceOptions: PhoneControlDeviceOptions = PhoneControlDeviceOptions(),
        placement: ScrcpyWindowPlacement? = nil
    ) async throws -> DetachedLaunchObservation {
        let adbURL = try await workingADBURL()
        let scrcpyCandidates = try locator.resolutionCandidates(for: .scrcpy)

        let arguments = Self.scrcpyArguments(
            serial: serial,
            windowTitle: windowTitle,
            options: options,
            deviceOptions: deviceOptions,
            placement: placement
        )

        for candidate in scrcpyCandidates {
            guard let serverURL = locator.scrcpyServerURL(for: candidate) else { continue }
            let environment = [
                "ADB": adbURL.path,
                "SCRCPY_SERVER_PATH": serverURL.path
            ]
            let observation: DetachedLaunchObservation
            do {
                observation = try await runner.launchObserved(
                    executable: candidate.url,
                    arguments: arguments,
                    environment: environment,
                    observationDuration: 1.75
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            if let exitCode = observation.exitCode {
                let output = observation.output.isEmpty ? "scrcpy exited without an error message." : observation.output
                if Self.isScrcpyInstallationFailure(output) {
                    continue
                }
                throw FileOperationError.commandFailed("scrcpy exited with code \(exitCode).\n\n\(output)\n\nLog: \(observation.logURL.path)")
            }
            return observation
        }
        throw FileOperationError.toolUnavailable(.scrcpy, "Phone Control is incomplete or cannot run on this Mac.")
    }

    nonisolated static func scrcpyArguments(
        serial: String,
        windowTitle: String,
        options: ScreenRecordingOptions,
        deviceOptions: PhoneControlDeviceOptions = PhoneControlDeviceOptions(),
        placement: ScrcpyWindowPlacement?
    ) -> [String] {
        var arguments = ["--serial", serial, "--window-title", windowTitle]
        if options.showTouches {
            arguments.append("--show-touches")
        }
        if !deviceOptions.wakesDeviceOnOpen {
            arguments.append("--no-power-on")
        }
        if !deviceOptions.capturesAudio {
            arguments.append("--no-audio")
        }
        if !deviceOptions.acceptsInput {
            arguments.append("--no-control")
        }
        if !deviceOptions.synchronizesClipboard {
            arguments.append("--no-clipboard-autosync")
        }
        if deviceOptions.staysAwake {
            arguments.append("--stay-awake")
        }
        if deviceOptions.turnsDeviceScreenOff {
            arguments.append("--turn-screen-off")
        }
        if deviceOptions.frameRateLimit != .automatic {
            arguments.append(contentsOf: ["--max-fps", "\(deviceOptions.frameRateLimit.rawValue)"])
        }
        if deviceOptions.videoCodec != .automatic {
            arguments.append(contentsOf: ["--video-codec", deviceOptions.videoCodec.rawValue])
        }
        if let maxSize = options.scrcpyMaxSize {
            arguments.append(contentsOf: ["--max-size", "\(maxSize)"])
        }
        arguments.append(contentsOf: ["--video-bit-rate", "\(options.effectiveVideoBitRateMbps)M"])
        if let packageName = options.normalizedPackageName {
            arguments.append(contentsOf: ["--start-app", packageName])
        }
        if let placement {
            arguments.append(contentsOf: [
                "--window-x", "\(placement.x)",
                "--window-y", "\(placement.y)",
                "--window-width", "\(placement.width)",
                "--window-height", "\(placement.height)"
            ])
            if placement.alwaysOnTop {
                arguments.append("--always-on-top")
            }
        }
        return arguments
    }

    nonisolated static func scrcpyScreenRecordingArguments(
        serial: String,
        localURL: URL,
        options: ScreenRecordingOptions,
        audioSource: PhoneRecordingAudioSource
    ) -> [String] {
        guard let scrcpyAudioSource = audioSource.scrcpyAudioSource else { return [] }

        var arguments = [
            "--serial", serial,
            "--record=\(localURL.path)",
            "--record-format=mp4",
            "--no-playback",
            "--no-window",
            "--no-control",
            "--no-clipboard-autosync",
            "--video-codec=h264",
            "--audio-codec=aac",
            "--audio-bit-rate=128K",
            "--audio-source=\(scrcpyAudioSource)",
            "--require-audio",
            "--video-bit-rate=\(options.effectiveVideoBitRateMbps)M"
        ]
        if let maxSize = options.scrcpyMaxSize {
            arguments.append("--max-size=\(maxSize)")
        }
        if options.durationMode == .fixed {
            arguments.append("--time-limit=\(options.effectiveFixedDurationSeconds)")
        }
        return arguments
    }

    public func startScrcpyScreenRecording(
        serial: String,
        localURL: URL,
        options: ScreenRecordingOptions,
        audioSource: PhoneRecordingAudioSource
    ) async throws -> ScrcpyScreenRecordingProcess {
        guard audioSource != .none else {
            throw FileOperationError.commandFailed("Choose a phone audio source before starting an audio recording.")
        }

        let adbURL = try await workingADBURL()
        let scrcpyCandidates = try locator.resolutionCandidates(for: .scrcpy)
        let arguments = Self.scrcpyScreenRecordingArguments(
            serial: serial,
            localURL: localURL,
            options: options,
            audioSource: audioSource
        )

        for candidate in scrcpyCandidates {
            guard let serverURL = locator.scrcpyServerURL(for: candidate) else { continue }
            do {
                guard let capabilities = try await scrcpyScreenRecordingAudioCapabilities(
                    for: candidate
                ), capabilities.supports(audioSources: [audioSource]) else {
                    continue
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            try? FileManager.default.removeItem(at: localURL)
            let environment = [
                "ADB": adbURL.path,
                "SCRCPY_SERVER_PATH": serverURL.path
            ]
            let startedAt = Date()
            let observation: DetachedLaunchObservation
            do {
                observation = try await runner.launchObserved(
                    executable: candidate.url,
                    arguments: arguments,
                    environment: environment,
                    observationDuration: 1.75
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }

            if let exitCode = observation.exitCode {
                let output = observation.output.isEmpty
                    ? "scrcpy exited without an error message."
                    : observation.output
                if Self.isScrcpyInstallationFailure(output) {
                    continue
                }
                throw FileOperationError.commandFailed(
                    Self.scrcpyScreenRecordingFailureMessage(
                        output: output,
                        exitCode: exitCode,
                        audioSource: audioSource,
                        logURL: observation.logURL
                    )
                )
            }

            return ScrcpyScreenRecordingProcess(
                serial: serial,
                localURL: localURL,
                startedAt: startedAt,
                logURL: observation.logURL,
                processHandle: observation.processHandle
            )
        }
        throw FileOperationError.toolUnavailable(
            .scrcpy,
            "Screen recording audio needs a compatible Phone Tools installation."
        )
    }

    private func scrcpyScreenRecordingAudioCapabilities(
        for candidate: ToolchainCandidate
    ) async throws -> ScrcpyScreenRecordingAudioCapabilities? {
        let versionResult = try await runWithTimeout(
            executable: candidate.url,
            arguments: ["--version"],
            timeout: 5
        )
        guard versionResult.exitCode == 0,
              ScrcpyScreenRecordingAudioCapabilities.supportsRequiredVersion(
                versionResult.stdout + versionResult.stderr
              ) else {
            return nil
        }
        let result = try await runWithTimeout(
            executable: candidate.url,
            arguments: ["--help"],
            timeout: 5
        )
        guard result.exitCode == 0 else { return nil }
        return ScrcpyScreenRecordingAudioCapabilities.parse(
            helpOutput: result.stdout + result.stderr
        )
    }

    public func startScreenRecording(
        serial: String,
        remotePath: String,
        timeLimitSeconds: Int?,
        size: String?,
        bitRateMbps: Int?
    ) async throws -> ADBScreenRecordingProcess {
        let adbURL = try await workingADBURL()
        return try await Task.detached(priority: .userInitiated) {
            let logURL = FileManager.default.temporaryDirectory
                .appending(path: "AndroidFileBrowser-screenrecord-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let logHandle = try FileHandle(forWritingTo: logURL)

            let process = Process()
            process.executableURL = adbURL
            var arguments = ["-s", serial, "shell", "screenrecord"]
            if let size {
                arguments.append(contentsOf: ["--size", size])
            }
            if let bitRateMbps {
                arguments.append(contentsOf: ["--bit-rate", "\(bitRateMbps)M"])
            }
            if let timeLimitSeconds {
                arguments.append(contentsOf: ["--time-limit", "\(timeLimitSeconds)"])
            }
            arguments.append(remotePath)
            process.arguments = arguments
            process.standardOutput = logHandle
            process.standardError = logHandle

            do {
                try process.run()
            } catch {
                try? logHandle.close()
                throw FileOperationError.toolUnavailable(.adb, "macOS could not open the selected copy.")
            }

            return ADBScreenRecordingProcess(
                serial: serial,
                remotePath: remotePath,
                startedAt: Date(),
                logURL: logURL,
                process: process,
                logHandle: logHandle
            )
        }.value
    }

    public static func quoteRemote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    public static func joinRemote(_ directory: String, _ name: String) -> String {
        let trimmed = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return "/\(name)" }
        return "/\(trimmed)/\(name)"
    }

    private static func adbStartupFailureReason(_ message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("cannot bind") || lowercased.contains("address already in use") || lowercased.contains("5037") {
            return "ADB could not start because another phone tool may already be using its connection service."
        }
        if lowercased.contains("daemon") || lowercased.contains("server") {
            return "ADB could not start its connection service."
        }
        return "ADB returned an error while checking for phones."
    }

    private static func isADBInfrastructureFailure(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("adb server didn't ack")
            || lowercased.contains("failed to start daemon")
            || lowercased.contains("cannot connect to daemon")
            || lowercased.contains("cannot bind")
            || lowercased.contains("address already in use")
            || lowercased.contains("protocol fault")
            || lowercased.contains("library not loaded")
            || lowercased.contains("bad cpu type")
    }

    private static func isScrcpyInstallationFailure(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("library not loaded")
            || lowercased.contains("dyld")
            || lowercased.contains("scrcpy-server") && lowercased.contains("not found")
            || lowercased.contains("bad cpu type")
            || lowercased.contains("exec format")
    }

    private static func scrcpyScreenRecordingFailureMessage(
        output: String,
        exitCode: Int32,
        audioSource: PhoneRecordingAudioSource,
        logURL: URL
    ) -> String {
        let lowercased = output.lowercased()
        if lowercased.contains("android 11")
            || lowercased.contains("api 30")
            || lowercased.contains("audio capture is not supported") {
            return "Phone audio recording requires Android 11 or later. Android 11 phones must also be unlocked when recording starts."
        }
        if lowercased.contains("audio")
            && (lowercased.contains("failed") || lowercased.contains("error") || lowercased.contains("disabled")) {
            let sourceName = audioSource == .phoneMicrophone ? "phone microphone" : "selected phone audio"
            return "The \(sourceName) could not start. Unlock the phone, make sure another app is not using that audio source, and try again.\n\nDetails: \(logURL.path)"
        }
        return "Phone audio recording exited with code \(exitCode).\n\n\(output)\n\nLog: \(logURL.path)"
    }

    private func runWithTimeout(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ADBCommandResult {
        try await withThrowingTaskGroup(of: ADBCommandResult.self) { group in
            group.addTask { [runner] in
                try await runner.run(executable: executable, arguments: arguments)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ADBCommandTimedOut()
            }
            guard let result = try await group.next() else {
                throw ADBCommandTimedOut()
            }
            group.cancelAll()
            return result
        }
    }

    private func workingADBURL() async throws -> URL {
        let candidates = try locator.resolutionCandidates(for: .adb)
        let candidateSignatures = candidates.map { Self.cacheSignature(for: $0.url) }
        if let cachedADBURL,
           cachedADBCandidateSignatures == candidateSignatures,
           let cachedADBValidatedAt,
           Date().timeIntervalSince(cachedADBValidatedAt) < 30 {
            return cachedADBURL
        }
        if cachedADBFailureCandidateSignatures == candidateSignatures,
           let cachedADBFailureAt,
           Date().timeIntervalSince(cachedADBFailureAt) < 5 {
            throw FileOperationError.toolUnavailable(.adb, "macOS could not open any compatible ADB copy.")
        }

        for candidate in candidates {
            do {
                let result = try await runWithTimeout(
                    executable: candidate.url,
                    arguments: ["version"],
                    timeout: 3
                )
                let output = result.stdout + result.stderr
                if result.exitCode == 0,
                   output.localizedCaseInsensitiveContains("Android Debug Bridge version") {
                    cachedADBURL = candidate.url
                    cachedADBCandidateSignatures = candidateSignatures
                    cachedADBValidatedAt = Date()
                    cachedADBFailureCandidateSignatures = []
                    cachedADBFailureAt = nil
                    return candidate.url
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        clearCachedADBResolution()
        cachedADBFailureCandidateSignatures = candidateSignatures
        cachedADBFailureAt = Date()
        throw FileOperationError.toolUnavailable(.adb, "macOS could not open any compatible ADB copy.")
    }

    private static func cacheSignature(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "\(path)|missing"
        }
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "unknown"
        let fileSize = (attributes[.size] as? NSNumber)?.stringValue ?? "unknown"
        let modificationDate = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(fileNumber)|\(fileSize)|\(modificationDate)"
    }

    private func clearCachedADBResolution() {
        cachedADBURL = nil
        cachedADBCandidateSignatures = []
        cachedADBValidatedAt = nil
    }
}
