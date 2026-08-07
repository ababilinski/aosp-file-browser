import Foundation
import XCTest
@testable import AndroidFileBrowserCore

final class ToolchainManagerTests: XCTestCase {
    @MainActor
    func testScrcpyVersionDropsTheProjectURL() {
        let output = "scrcpy 4.1 <https://github.com/Genymobile/scrcpy>\n"

        XCTAssertEqual(ToolchainManager.shortVersion(for: .scrcpy, output: output), "4.1")
    }

    func testAutomaticSelectionPrefersManagedTools() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let adbURL = try makeExecutable(named: "adb", in: directory)
        let scrcpyURL = try makeExecutable(named: "scrcpy", in: directory)
        let preferences = ToolchainPreferences(adbMode: .automatic, scrcpyMode: .automatic)
        let locator = ToolchainLocator(
            preferencesProvider: { preferences },
            managedToolsDirectoryProvider: { directory }
        )

        let adbCandidate = try locator.resolvedCandidate(for: .adb)
        let scrcpyCandidate = try locator.resolvedCandidate(for: .scrcpy)

        XCTAssertEqual(adbCandidate.source, .managed)
        XCTAssertEqual(adbCandidate.url, adbURL.standardizedFileURL)
        XCTAssertEqual(scrcpyCandidate.source, .managed)
        XCTAssertEqual(scrcpyCandidate.url, scrcpyURL.standardizedFileURL)
    }

    func testManagedSelectionDoesNotFallBackToExternalTools() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let adbURL = try makeExecutable(named: "adb", in: directory)
        let preferences = ToolchainPreferences(adbMode: .managed)
        let locator = ToolchainLocator(
            preferencesProvider: { preferences },
            managedToolsDirectoryProvider: { directory }
        )

        let candidate = try locator.resolvedCandidate(for: .adb)
        XCTAssertEqual(candidate.source, .managed)
        XCTAssertEqual(candidate.url, adbURL.standardizedFileURL)

        try FileManager.default.removeItem(at: adbURL)
        XCTAssertThrowsError(try locator.resolvedCandidate(for: .adb))
    }

    func testCustomSelectionDoesNotFallBackToManagedToolForInvalidOrMissingPath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try makeExecutable(named: "adb", in: directory)
        let nonExecutableURL = directory.appending(path: "not-executable-adb")
        try Data("not executable".utf8).write(to: nonExecutableURL)
        let missingURL = directory.appending(path: "missing-adb")

        for selectedURL in [nonExecutableURL, missingURL] {
            let preferences = ToolchainPreferences(adbMode: .custom, adbPath: selectedURL.path)
            let locator = ToolchainLocator(
                preferencesProvider: { preferences },
                managedToolsDirectoryProvider: { directory }
            )

            XCTAssertThrowsError(try locator.resolvedCandidate(for: .adb)) { error in
                guard case FileOperationError.missingTool(let executableName) = error else {
                    return XCTFail("Expected missingTool, received \(error)")
                }
                XCTAssertEqual(executableName, "adb")
            }
        }
    }

    func testOfficialArm64ReleaseManifest() throws {
        let release = try ManagedToolchainRelease.current(machineArchitecture: "arm64")

        XCTAssertEqual(release.version, "4.1")
        XCTAssertEqual(release.architecture, "aarch64")
        XCTAssertEqual(
            release.archiveURL.absoluteString,
            "https://github.com/Genymobile/scrcpy/releases/download/v4.1/scrcpy-macos-aarch64-v4.1.tar.gz"
        )
        XCTAssertEqual(release.archiveDirectoryName, "scrcpy-macos-aarch64-v4.1")
        XCTAssertEqual(release.archiveSHA256, "20fd47c9014dd5e0fa77091f3cb7adbda8445a360c4584aeaa0150b5b3988ff3")
        XCTAssertEqual(release.adbSHA256, "9fdf861259dc807937b13afdd5f053c7fda9f3b7726933fe0e0f45130ecb8dc7")
        XCTAssertEqual(release.scrcpySHA256, "e318a04c11986d9afa7f438a81cc9c7cc0f3ea66945db1e127f373eb02f4e1d3")
        XCTAssertEqual(release.scrcpyServerSHA256, "deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae")
        XCTAssertEqual(release.adbVersionMarker, "37.0.0-14910828")
        XCTAssertEqual(release.scrcpyVersionMarker, "scrcpy 4.1")
    }

    func testOfficialX8664ReleaseManifest() throws {
        let release = try ManagedToolchainRelease.current(machineArchitecture: "x86_64")

        XCTAssertEqual(release.version, "4.1")
        XCTAssertEqual(release.architecture, "x86_64")
        XCTAssertEqual(
            release.archiveURL.absoluteString,
            "https://github.com/Genymobile/scrcpy/releases/download/v4.1/scrcpy-macos-x86_64-v4.1.tar.gz"
        )
        XCTAssertEqual(release.archiveDirectoryName, "scrcpy-macos-x86_64-v4.1")
        XCTAssertEqual(release.archiveSHA256, "ee2a7223bc8dbdc4f482db1134bcf441178dafb833492b71ca4c22090c58ce72")
        XCTAssertEqual(release.adbSHA256, "9fdf861259dc807937b13afdd5f053c7fda9f3b7726933fe0e0f45130ecb8dc7")
        XCTAssertEqual(release.scrcpySHA256, "3f2c348954c2b19be55def5b72b9d3274dfe5eddee99a060e0d7469f7b3ef159")
        XCTAssertEqual(release.scrcpyServerSHA256, "deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae")
        XCTAssertEqual(release.adbVersionMarker, "37.0.0-14910828")
        XCTAssertEqual(release.scrcpyVersionMarker, "scrcpy 4.1")
    }

    func testChecksumMismatchKeepsExistingInstallAndRemovesStagingDirectory() async throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let rootURL = testDirectory.appending(path: "managed-tools", directoryHint: .isDirectory)
        let archiveURL = testDirectory.appending(path: "untrusted-archive.tar.gz")
        try Data("not an official archive".utf8).write(to: archiveURL)
        let release = ManagedToolchainRelease(
            version: "test",
            architecture: "test",
            archiveURL: URL(string: "https://example.invalid/phone-tools.tar.gz")!,
            archiveDirectoryName: "phone-tools-test",
            archiveSHA256: String(repeating: "0", count: 64),
            adbSHA256: String(repeating: "1", count: 64),
            scrcpySHA256: String(repeating: "2", count: 64),
            scrcpyServerSHA256: String(repeating: "3", count: 64),
            adbVersionMarker: "unused",
            scrcpyVersionMarker: "unused"
        )
        let installer = try ManagedToolchainInstaller(
            rootURL: rootURL,
            release: release,
            downloader: LocalArchiveDownloader(archiveURL: archiveURL),
            runner: UnexpectedProcessRunner()
        )
        let existingInstallationURL = installer.installationDirectoryURL
        let sentinelURL = existingInstallationURL.appending(path: "existing-install.txt")
        try FileManager.default.createDirectory(at: existingInstallationURL, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: sentinelURL)

        do {
            _ = try await installer.install()
            XCTFail("Expected a checksum verification failure")
        } catch let error as ToolchainInstallError {
            XCTAssertEqual(error, .verificationFailed)
        } catch {
            XCTFail("Expected ToolchainInstallError.verificationFailed, received \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("keep me".utf8))
        let rootContents = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(rootContents.contains { $0.lastPathComponent.hasPrefix(".staging-") })
        XCTAssertFalse(rootContents.contains { $0.lastPathComponent.hasPrefix(".backup-") })
    }

    func testFailureMovingExistingInstallDoesNotDeleteIt() async throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let rootURL = testDirectory.appending(path: "managed-tools", directoryHint: .isDirectory)
        let fixture = try makeValidToolArchive(in: testDirectory)
        let destinationURL = rootURL.appending(path: fixture.release.installationDirectoryName, directoryHint: .isDirectory)
        let sentinelURL = destinationURL.appending(path: "existing-install.txt")
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: sentinelURL)

        let fileManager = FirstMoveFailingFileManager(blockedSourcePath: destinationURL.path)
        let installer = try ManagedToolchainInstaller(
            rootURL: rootURL,
            release: fixture.release,
            downloader: LocalArchiveDownloader(archiveURL: fixture.archiveURL),
            runner: ProcessRunner(),
            fileManager: fileManager
        )

        do {
            _ = try await installer.install()
            XCTFail("Expected the replacement move to fail")
        } catch let error as ToolchainInstallError {
            guard case .validationFailed(let message) = error else {
                return XCTFail("Expected validationFailed, received \(error)")
            }
            XCTAssertTrue(message.contains("previous copy was kept"))
        }

        XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("keep me".utf8))
    }

    func testScrcpyOnlyManagedSetupDoesNotInstallADB() async throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let rootURL = testDirectory.appending(path: "managed-tools", directoryHint: .isDirectory)
        let fixture = try makeValidToolArchive(in: testDirectory)
        let installer = try ManagedToolchainInstaller(
            rootURL: rootURL,
            release: fixture.release,
            downloader: LocalArchiveDownloader(archiveURL: fixture.archiveURL),
            runner: ProcessRunner()
        )

        let installation = try await installer.install(tools: [.scrcpy])

        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.adbURL.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.scrcpyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installation.scrcpyServerURL.path))
    }

    func testScrcpyRepairPreservesExistingManagedADBWithoutReplacingIt() async throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let rootURL = testDirectory.appending(path: "managed-tools", directoryHint: .isDirectory)
        let fixture = try makeValidToolArchive(in: testDirectory)
        let installer = try ManagedToolchainInstaller(
            rootURL: rootURL,
            release: fixture.release,
            downloader: LocalArchiveDownloader(archiveURL: fixture.archiveURL),
            runner: ProcessRunner()
        )
        let existingDirectory = installer.installationDirectoryURL
        try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
        let existingADBURL = existingDirectory.appending(path: "adb")
        let existingADB = Data("existing adb".utf8)
        try existingADB.write(to: existingADBURL)

        let installation = try await installer.install(tools: [.scrcpy])

        XCTAssertEqual(try Data(contentsOf: installation.adbURL), existingADB)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.scrcpyURL.path))
    }

    func testADBClientMapsRunnerLaunchFailureToToolUnavailable() async throws {
        let adbURL = URL(fileURLWithPath: "/tmp/test-adb")
        let recorder = ExecutableRecorder()
        let locator = ToolchainLocator(adbOverride: adbURL)
        let client = ADBClient(locator: locator, runner: FailingRunProcessRunner(recorder: recorder))

        do {
            _ = try await client.run(["version"])
            XCTFail("Expected ADB to be unavailable")
        } catch FileOperationError.toolUnavailable(let tool, let reason) {
            XCTAssertEqual(tool, .adb)
            XCTAssertFalse(reason.isEmpty)
        } catch {
            XCTFail("Expected toolUnavailable, received \(error)")
        }
        let recordedPaths = await recorder.paths()
        XCTAssertEqual(recordedPaths, [adbURL.standardizedFileURL.path])
    }

    func testDeviceManagerPropagatesDevicesFailureAsToolUnavailable() async throws {
        let locator = ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb"))
        let client = ADBClient(
            locator: locator,
            runner: VersionThenFixedRunProcessRunner(
                result: ADBCommandResult(
                    stdoutData: Data(),
                    stderrData: Data("ADB server didn't ACK\nfailed to start daemon".utf8),
                    exitCode: 1
                )
            )
        )
        let manager = DeviceManager(adb: client)

        do {
            _ = try await manager.devices()
            XCTFail("Expected the devices check to fail")
        } catch FileOperationError.toolUnavailable(let tool, let reason) {
            XCTAssertEqual(tool, .adb)
            XCTAssertEqual(reason, "ADB could not start its connection service.")
        } catch {
            XCTFail("Expected toolUnavailable, received \(error)")
        }
    }

    func testADBCommandTimeoutIsAnOperationFailureNotAMissingTool() async throws {
        let locator = ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb"))
        let client = ADBClient(locator: locator, runner: VersionThenSlowRunProcessRunner())

        do {
            _ = try await client.run(["-s", "device", "shell", "input keyevent 3"], timeout: 0.01)
            XCTFail("Expected the command to time out")
        } catch FileOperationError.commandFailed(let message) {
            XCTAssertEqual(message, "ADB took too long to respond.")
        } catch {
            XCTFail("Expected commandFailed, received \(error)")
        }
    }

    func testReplacingADBAtSamePathBypassesRecentFailureCache() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let adbURL = try makeExecutable(named: "adb", in: directory)
        let runner = RecoveringVersionProcessRunner()
        let client = ADBClient(
            locator: ToolchainLocator(adbOverride: adbURL),
            runner: runner
        )

        do {
            _ = try await client.run(["devices"])
            XCTFail("Expected the first version check to fail")
        } catch FileOperationError.toolUnavailable {
            // Expected. This records a short-lived negative cache entry.
        }

        try FileManager.default.removeItem(at: adbURL)
        _ = try makeExecutable(named: "adb", in: directory)

        let result = try await client.run(["devices"])
        let versionAttemptCount = await runner.versionAttemptCount()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(versionAttemptCount, 2)
    }

    func testObservedProcessHandleReportsFailureAfterStartupWindow() async throws {
        let observation = try await ProcessRunner().launchObserved(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 0.15; exit 7"],
            environment: [:],
            observationDuration: 0.02
        )

        XCTAssertTrue(observation.isRunningAfterObservation)
        XCTAssertNil(observation.exitCode)
        let exitCode = await Task.detached {
            observation.processHandle.waitUntilExit()
        }.value
        XCTAssertEqual(exitCode, 7)
    }

    func testLiveOfficialArchiveInstallsBothToolsWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AFB_LIVE_TOOLCHAIN_TEST"] == "1" else {
            throw XCTSkip("Set AFB_LIVE_TOOLCHAIN_TEST=1 to download and verify the official tool archive.")
        }

        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let installer = try ManagedToolchainInstaller(rootURL: rootURL)

        let installation = try await installer.install()

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.adbURL.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.scrcpyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installation.scrcpyServerURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AndroidFileBrowserCoreTests-Toolchain-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeValidToolArchive(in directory: URL) throws -> (archiveURL: URL, release: ManagedToolchainRelease) {
        let packageDirectoryName = "phone-tools-test"
        let buildDirectory = directory.appending(path: "fixture", directoryHint: .isDirectory)
        let packageDirectory = buildDirectory.appending(path: packageDirectoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)

        let adbURL = packageDirectory.appending(path: "adb")
        let scrcpyURL = packageDirectory.appending(path: "scrcpy")
        let serverURL = packageDirectory.appending(path: "scrcpy-server")
        try Data("#!/bin/sh\necho 'Android Debug Bridge version 1.0.41'\necho 'Version test-adb'\n".utf8).write(to: adbURL)
        try Data("#!/bin/sh\necho 'scrcpy test-version'\n".utf8).write(to: scrcpyURL)
        try Data("test server".utf8).write(to: serverURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scrcpyURL.path)

        let archiveURL = directory.appending(path: "phone-tools-test.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archiveURL.path, "-C", buildDirectory.path, packageDirectoryName]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        let release = ManagedToolchainRelease(
            version: "test",
            architecture: "test",
            archiveURL: URL(string: "https://example.invalid/phone-tools-test.tar.gz")!,
            archiveDirectoryName: packageDirectoryName,
            archiveSHA256: try ManagedToolchainInstaller.sha256(of: archiveURL),
            adbSHA256: try ManagedToolchainInstaller.sha256(of: adbURL),
            scrcpySHA256: try ManagedToolchainInstaller.sha256(of: scrcpyURL),
            scrcpyServerSHA256: try ManagedToolchainInstaller.sha256(of: serverURL),
            adbVersionMarker: "Version test-adb",
            scrcpyVersionMarker: "scrcpy test-version"
        )
        return (archiveURL, release)
    }
}

private final class FirstMoveFailingFileManager: FileManager, @unchecked Sendable {
    private let blockedSourcePath: String

    init(blockedSourcePath: String) {
        self.blockedSourcePath = blockedSourcePath
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.standardizedFileURL.path == blockedSourcePath {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private struct LocalArchiveDownloader: ToolchainArchiveDownloading {
    let archiveURL: URL

    func download(from url: URL) async throws -> URL {
        archiveURL
    }
}

private enum StubProcessError: Error {
    case launchFailed
    case unexpectedCall
}

private actor ExecutableRecorder {
    private var recordedPaths: [String] = []

    func append(_ url: URL) {
        recordedPaths.append(url.standardizedFileURL.path)
    }

    func paths() -> [String] {
        recordedPaths
    }
}

private struct FailingRunProcessRunner: ProcessRunning {
    let recorder: ExecutableRecorder

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        await recorder.append(executable)
        throw StubProcessError.launchFailed
    }

    func runStreaming(
        executable: URL,
        arguments: [String],
        output: @escaping @Sendable (Data) -> Void
    ) async throws -> ADBCommandResult {
        throw StubProcessError.unexpectedCall
    }

    func launchDetached(executable: URL, arguments: [String]) async throws {
        throw StubProcessError.unexpectedCall
    }

    func launchObserved(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        observationDuration: TimeInterval
    ) async throws -> DetachedLaunchObservation {
        throw StubProcessError.unexpectedCall
    }
}

private struct VersionThenFixedRunProcessRunner: ProcessRunning {
    let result: ADBCommandResult

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        if arguments == ["version"] {
            return ADBCommandResult(
                stdoutData: Data("Android Debug Bridge version 1.0.41\nVersion 37.0.0-test\n".utf8),
                stderrData: Data(),
                exitCode: 0
            )
        }
        return result
    }

    func runStreaming(
        executable: URL,
        arguments: [String],
        output: @escaping @Sendable (Data) -> Void
    ) async throws -> ADBCommandResult {
        throw StubProcessError.unexpectedCall
    }

    func launchDetached(executable: URL, arguments: [String]) async throws {
        throw StubProcessError.unexpectedCall
    }

    func launchObserved(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        observationDuration: TimeInterval
    ) async throws -> DetachedLaunchObservation {
        throw StubProcessError.unexpectedCall
    }
}

private struct VersionThenSlowRunProcessRunner: ProcessRunning {
    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        if arguments == ["version"] {
            return ADBCommandResult(
                stdoutData: Data("Android Debug Bridge version 1.0.41\nVersion 37.0.0-test\n".utf8),
                stderrData: Data(),
                exitCode: 0
            )
        }
        try await Task.sleep(for: .seconds(1))
        return ADBCommandResult(stdoutData: Data(), stderrData: Data(), exitCode: 0)
    }

    func runStreaming(
        executable: URL,
        arguments: [String],
        output: @escaping @Sendable (Data) -> Void
    ) async throws -> ADBCommandResult {
        throw StubProcessError.unexpectedCall
    }

    func launchDetached(executable: URL, arguments: [String]) async throws {
        throw StubProcessError.unexpectedCall
    }

    func launchObserved(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        observationDuration: TimeInterval
    ) async throws -> DetachedLaunchObservation {
        throw StubProcessError.unexpectedCall
    }
}

private actor RecoveringVersionProcessRunner: ProcessRunning {
    private var versionAttempts = 0

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        if arguments == ["version"] {
            versionAttempts += 1
            if versionAttempts == 1 {
                return ADBCommandResult(
                    stdoutData: Data(),
                    stderrData: Data("version check failed".utf8),
                    exitCode: 1
                )
            }
            return ADBCommandResult(
                stdoutData: Data("Android Debug Bridge version 1.0.41\nVersion 37.0.0-test\n".utf8),
                stderrData: Data(),
                exitCode: 0
            )
        }
        return ADBCommandResult(stdoutData: Data(), stderrData: Data(), exitCode: 0)
    }

    func versionAttemptCount() -> Int {
        versionAttempts
    }

    func runStreaming(
        executable: URL,
        arguments: [String],
        output: @escaping @Sendable (Data) -> Void
    ) async throws -> ADBCommandResult {
        throw StubProcessError.unexpectedCall
    }

    func launchDetached(executable: URL, arguments: [String]) async throws {
        throw StubProcessError.unexpectedCall
    }

    func launchObserved(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        observationDuration: TimeInterval
    ) async throws -> DetachedLaunchObservation {
        throw StubProcessError.unexpectedCall
    }
}

private struct UnexpectedProcessRunner: ProcessRunning {
    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        throw StubProcessError.unexpectedCall
    }

    func runStreaming(
        executable: URL,
        arguments: [String],
        output: @escaping @Sendable (Data) -> Void
    ) async throws -> ADBCommandResult {
        throw StubProcessError.unexpectedCall
    }

    func launchDetached(executable: URL, arguments: [String]) async throws {
        throw StubProcessError.unexpectedCall
    }

    func launchObserved(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        observationDuration: TimeInterval
    ) async throws -> DetachedLaunchObservation {
        throw StubProcessError.unexpectedCall
    }
}
