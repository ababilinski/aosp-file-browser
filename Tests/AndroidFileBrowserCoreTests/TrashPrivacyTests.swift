import Foundation
import XCTest
@testable import AndroidFileBrowserCore

final class TrashRecordStorePrivacyTests: XCTestCase {
    func testLegacyJSONMigratesToAuthenticatedEncryptedStorage() throws {
        let root = temporaryDirectory(named: "TrashLegacyMigration")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "trash-records.json")
        let record = makeRecord(deviceIdentity: "phone-a", name: "Private Photo.jpg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode([record]).write(to: fileURL, options: .atomic)

        let store = TrashRecordStore(
            fileURL: fileURL,
            encryptionKeyData: Data(repeating: 0x31, count: 32)
        )
        let result = store.load()

        XCTAssertTrue(result.migratedLegacyFile)
        XCTAssertEqual(result.archive.allRecords, [record])
        let protectedData = try Data(contentsOf: fileURL)
        XCTAssertTrue(protectedData.starts(with: TrashRecordStore.encryptionMagic))
        XCTAssertFalse(protectedData.range(of: Data(record.name.utf8)) != nil)
        XCTAssertFalse(protectedData.range(of: Data(record.originalPath.utf8)) != nil)
        XCTAssertEqual(store.load().archive.allRecords, [record])
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testDamagedPrimaryRecoversLastAuthenticatedBackupWithoutDeletingEvidence() throws {
        let root = temporaryDirectory(named: "TrashBackupRecovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "trash-records.json")
        let store = TrashRecordStore(
            fileURL: fileURL,
            encryptionKeyData: Data(repeating: 0x52, count: 32)
        )
        let first = makeRecord(deviceIdentity: "phone-a", name: "First.txt")
        let second = makeRecord(deviceIdentity: "phone-a", name: "Second.txt")

        try store.save(TrashRecordsArchive(records: [first]))
        try store.save(TrashRecordsArchive(records: [first, second]))
        try Data("damaged".utf8).write(to: fileURL, options: .atomic)

        let result = store.load()

        XCTAssertTrue(result.recoveredFromBackup)
        XCTAssertEqual(result.archive.allRecords, [first])
        XCTAssertNotNil(result.recoveryNotice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.unreadableURL.path))
        XCTAssertEqual(store.load().archive.allRecords, [first])
    }

    func testUnavailableProtectedHistoryIsNeverOverwrittenByLaterSave() throws {
        let root = temporaryDirectory(named: "TrashFailClosedWrite")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "trash-records.json")
        let originalStore = TrashRecordStore(
            fileURL: fileURL,
            encryptionKeyData: Data(repeating: 0x81, count: 32)
        )
        try originalStore.save(TrashRecordsArchive(records: [
            makeRecord(deviceIdentity: "phone-a", name: "Must Survive.txt")
        ]))
        let originalBytes = try Data(contentsOf: fileURL)

        let unavailableStore = TrashRecordStore(
            fileURL: fileURL,
            encryptionKeyData: Data(repeating: 0x82, count: 32)
        )
        let loadResult = unavailableStore.load()
        XCTAssertTrue(loadResult.archive.allRecords.isEmpty)
        XCTAssertNotNil(loadResult.recoveryNotice)

        XCTAssertThrowsError(try unavailableStore.save(TrashRecordsArchive(records: [
            makeRecord(deviceIdentity: "phone-b", name: "New.txt")
        ])))
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
    }

    private func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func makeRecord(deviceIdentity: String, name: String) -> TrashRecord {
        TrashRecord(
            id: UUID(),
            deviceSerial: deviceIdentity,
            originalPath: "/storage/emulated/0/\(name)",
            trashPath: "/storage/emulated/0/.AndroidFileBrowserTrash/\(name)",
            name: name,
            deletedAt: Date(timeIntervalSince1970: 100),
            size: 42,
            kind: .file
        )
    }
}

@MainActor
final class DeviceBoundTrashPresentationTests: XCTestCase {
    func testTrashShowsOnlySelectedConnectedPhonesRecordsAndHidesEverythingOnDisconnect() {
        let phoneARecord = makeRecord(deviceIdentity: "phone-a", name: "A-only.txt")
        let phoneBRecord = makeRecord(deviceIdentity: "phone-b", name: "B-only.txt")
        let model = makeModel(records: [phoneARecord, phoneBRecord])
        let phoneA = device(serial: "phone-a", name: "Phone A")
        let phoneB = device(serial: "phone-b", name: "Phone B")

        model.devices = [phoneA, phoneB]
        model.selectedDeviceID = phoneA.id
        XCTAssertEqual(model.trashRecords, [phoneARecord])

        model.selectedDeviceID = phoneB.id
        XCTAssertEqual(model.trashRecords, [phoneBRecord])
        XCTAssertFalse(model.trashRecords.contains(phoneARecord))

        model.devices = [phoneA]
        XCTAssertTrue(model.trashRecords.isEmpty)
        XCTAssertFalse(model.shouldConfirmEmptyTrashAtSessionEnd)
    }

    func testCanonicalDeviceScopeMigratesLegacyEndpointAndKeepsItVisibleAcrossTransports() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "TrashIdentityMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "trash-records.json")
        let legacyRecord = makeRecord(deviceIdentity: "192.0.2.5:5555", name: "Legacy.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode([legacyRecord]).write(to: fileURL, options: .atomic)

        let model = makeModel(
            records: nil,
            trashRecordsFileURL: fileURL,
            encryptionKeyData: Data(repeating: 0x63, count: 32),
            scopeProvider: { device in
                TrashDeviceScope(
                    identity: "physical-phone-a",
                    legacyIdentifiers: [device.serial, "192.0.2.5:5555"]
                )
            }
        )
        let usbDevice = device(serial: "USB-ABC", name: "Phone A")
        model.devices = [usbDevice]
        model.selectedDeviceID = usbDevice.id

        XCTAssertEqual(model.trashRecords.map(\.deviceSerial), ["physical-phone-a"])
        XCTAssertEqual(model.trashRecords.map(\.name), ["Legacy.txt"])
        let reloaded = TrashRecordStore(
            fileURL: fileURL,
            encryptionKeyData: Data(repeating: 0x63, count: 32)
        ).load()
        XCTAssertEqual(reloaded.archive.allRecords.map(\.deviceSerial), ["physical-phone-a"])
    }

    func testDefaultScopeUsesPhysicalIdentityAcrossUSBAndWiFiEndpoints() {
        let legacyRecord = makeRecord(deviceIdentity: "USB-ABC", name: "Transport-stable.txt")
        let model = makeModel(records: [legacyRecord])
        let physicalDeviceID = "android-hardware:HW-A"
        let wifiDevice = AndroidDevice(
            serial: "192.0.2.5:5555",
            state: .device,
            model: "Phone A",
            product: nil,
            transport: "2",
            physicalDeviceID: physicalDeviceID,
            availableSerials: ["192.0.2.5:5555", "USB-ABC"]
        )

        model.devices = [wifiDevice]
        model.selectedDeviceID = physicalDeviceID

        XCTAssertEqual(model.trashRecords.count, 1)
        XCTAssertEqual(model.trashRecords.first?.deviceSerial, physicalDeviceID)

        model.devices = [
            AndroidDevice(
                serial: "USB-ABC",
                state: .device,
                model: "Phone A",
                product: nil,
                transport: "3",
                physicalDeviceID: physicalDeviceID,
                availableSerials: ["USB-ABC"]
            )
        ]

        XCTAssertEqual(model.selectedDeviceID, physicalDeviceID)
        XCTAssertEqual(model.trashRecords.count, 1)
        XCTAssertEqual(model.trashRecords.first?.deviceSerial, physicalDeviceID)
    }

    func testRestoreRejectsRecordFromAnotherPhoneAndRestoresOnlyVisiblePhone() async {
        let runner = TrashRestorePrivacyRunner()
        let adb = ADBClient(
            locator: ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb")),
            runner: runner
        )
        let phoneARecord = makeRecord(deviceIdentity: "phone-a", name: "A-only.txt")
        let phoneBRecord = makeRecord(deviceIdentity: "phone-b", name: "B-only.txt")
        let model = makeModel(adb: adb, records: [phoneARecord, phoneBRecord])
        let phoneB = device(serial: "phone-b", name: "Phone B")
        model.devices = [phoneB]
        model.selectedDeviceID = phoneB.id

        await model.restoreTrash(record: phoneARecord)
        let commandsAfterWrongPhone = await runner.moveCommands()
        XCTAssertTrue(commandsAfterWrongPhone.isEmpty)
        XCTAssertEqual(model.trashRecords, [phoneBRecord])

        await model.restoreTrash(record: phoneBRecord)
        let commands = await runner.moveCommands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].contains(phoneBRecord.trashPath))
        XCTAssertFalse(commands[0].contains(phoneARecord.trashPath))
        XCTAssertTrue(model.trashRecords.isEmpty)
    }

    private func makeModel(
        adb: ADBClient = ADBClient(),
        records: [TrashRecord]?,
        trashRecordsFileURL: URL? = nil,
        encryptionKeyData: Data? = nil,
        scopeProvider: @escaping @Sendable (AndroidDevice) -> TrashDeviceScope = {
            TrashDeviceScope(
                identity: $0.physicalDeviceID,
                legacyIdentifiers: Set($0.availableSerials)
            )
        }
    ) -> AppModel {
        let suiteName = "AndroidFileBrowserCoreTests.TrashPrivacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            adb: adb,
            settings: AppSettings(defaults: defaults),
            initialTrashRecords: records,
            trashRecordsFileURL: trashRecordsFileURL,
            trashRecordsEncryptionKeyData: encryptionKeyData,
            trashDeviceScopeProvider: scopeProvider
        )
    }

    private func device(serial: String, name: String) -> AndroidDevice {
        AndroidDevice(
            serial: serial,
            state: .device,
            model: name,
            product: nil,
            transport: nil
        )
    }

    private func makeRecord(deviceIdentity: String, name: String) -> TrashRecord {
        TrashRecord(
            id: UUID(),
            deviceSerial: deviceIdentity,
            originalPath: "/storage/emulated/0/\(name)",
            trashPath: "/storage/emulated/0/.AndroidFileBrowserTrash/\(name)",
            name: name,
            deletedAt: Date(timeIntervalSince1970: 100),
            size: 42,
            kind: .file
        )
    }
}

final class TrashPreviewPrivacyTests: XCTestCase {
    func testFirstLaunchPurgesLegacySharedPreviewAndThumbnailCaches() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "TrashLegacyCachePrivacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let previewDirectory = root.appending(path: "AndroidFileBrowserPreviews", directoryHint: .isDirectory)
        let thumbnailDirectory = root.appending(path: AppCacheStore.thumbnailFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        try Data("legacy preview".utf8).write(to: previewDirectory.appending(path: "private.jpg"))
        try Data("legacy thumbnail".utf8).write(to: thumbnailDirectory.appending(path: "private.jpg"))

        _ = AppCacheStore(cacheRoot: root, encryptionKeyData: Data(repeating: 0x73, count: 32))

        XCTAssertFalse(FileManager.default.fileExists(atPath: previewDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailDirectory.path))
    }

    func testClearingOnePhonesTrashPreviewsRemovesReadableAndEncryptedCopiesOnlyForThatPhone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "TrashPreviewPrivacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppCacheStore(
            cacheRoot: root,
            encryptionKeyData: Data(repeating: 0x74, count: 32)
        )

        let phoneAURL = try await store.trashPreviewURL(deviceIdentity: "phone-a", cacheName: "a.jpg")
        let phoneBURL = try await store.trashPreviewURL(deviceIdentity: "phone-b", cacheName: "b.jpg")
        let sourceA = root.appending(path: "source-a.jpg")
        let sourceB = root.appending(path: "source-b.jpg")
        try Data("phone a private preview".utf8).write(to: sourceA)
        try Data("phone b private preview".utf8).write(to: sourceB)
        try await store.storePreview(from: sourceA, at: phoneAURL, encrypt: true)
        try await store.storePreview(from: sourceB, at: phoneBURL, encrypt: true)
        let loadedReadableA = try await store.readablePreviewURL(for: phoneAURL, encrypt: true)
        let loadedReadableB = try await store.readablePreviewURL(for: phoneBURL, encrypt: true)
        let readableA = try XCTUnwrap(loadedReadableA)
        let readableB = try XCTUnwrap(loadedReadableB)

        try await store.clearTrashPreviewFiles(deviceIdentity: "phone-a")

        XCTAssertFalse(FileManager.default.fileExists(atPath: readableA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: phoneAURL.appendingPathExtension("afbpreview").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: readableB.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: phoneBURL.appendingPathExtension("afbpreview").path))
        await store.releaseReadablePreview(readableB)
    }
}

private actor TrashRestorePrivacyRunner: ProcessRunning {
    private var recordedMoveCommands: [String] = []

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        if arguments == ["version"] {
            return result("Android Debug Bridge version 1.0.41\nVersion 37.0.0-test\n")
        }
        let command = arguments.last ?? ""
        if command.contains("test -e") {
            return result("1")
        }
        if command.hasPrefix("mv ") {
            recordedMoveCommands.append(command)
        }
        return result("")
    }

    func runStreaming(
        executable: URL,
        arguments: [String],
        output: @escaping @Sendable (Data) -> Void
    ) async throws -> ADBCommandResult {
        throw CancellationError()
    }

    func launchDetached(executable: URL, arguments: [String]) async throws {
        throw CancellationError()
    }

    func launchObserved(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        observationDuration: TimeInterval
    ) async throws -> DetachedLaunchObservation {
        throw CancellationError()
    }

    func moveCommands() -> [String] {
        recordedMoveCommands
    }

    private func result(_ output: String) -> ADBCommandResult {
        ADBCommandResult(stdoutData: Data(output.utf8), stderrData: Data(), exitCode: 0)
    }
}
