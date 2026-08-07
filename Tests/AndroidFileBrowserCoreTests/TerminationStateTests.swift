import Foundation
import XCTest
@testable import AndroidFileBrowserCore

@MainActor
final class TerminationStateTests: XCTestCase {
    func testTerminationRequestLocksUntilCanceled() {
        let model = makeModel()

        XCTAssertTrue(model.beginTerminationRequest())
        XCTAssertTrue(model.isPreparingForTermination)
        XCTAssertFalse(model.beginTerminationRequest())

        model.cancelTerminationRequest()

        XCTAssertFalse(model.isPreparingForTermination)
        XCTAssertTrue(model.beginTerminationRequest())
    }

    func testOperationActivityRemainsBusyUntilEveryOperationFinishes() {
        var activity = OperationActivityTracker()

        activity.begin()
        activity.begin()
        XCTAssertTrue(activity.isBusy)
        XCTAssertTrue(activity.hasTerminationBlockingActivity)
        XCTAssertEqual(activity.activeCount, 2)

        activity.end()
        XCTAssertTrue(activity.isBusy)
        XCTAssertEqual(activity.activeCount, 1)

        activity.end()
        XCTAssertFalse(activity.isBusy)
        XCTAssertFalse(activity.hasTerminationBlockingActivity)
        XCTAssertEqual(activity.activeCount, 0)
    }

    func testRefreshActivityDoesNotBlockTermination() {
        var activity = OperationActivityTracker()

        activity.begin(blocksTermination: false)

        XCTAssertTrue(activity.isBusy)
        XCTAssertFalse(activity.hasTerminationBlockingActivity)

        activity.end(blocksTermination: false)

        XCTAssertFalse(activity.isBusy)
        XCTAssertFalse(activity.hasTerminationBlockingActivity)
    }

    func testTerminationCancelsAnActiveRefresh() async {
        let model = makeModel()
        let refreshStarted = expectation(description: "Refresh started")
        let refresh = Task { @MainActor in
            await model.performCancellableRead("Refreshing...") {
                refreshStarted.fulfill()
                try await Task.sleep(for: .seconds(30))
            }
        }

        await fulfillment(of: [refreshStarted], timeout: 1)
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.beginTerminationRequest())

        await refresh.value
        XCTAssertFalse(model.isBusy)
    }

    func testQueuedTransferBlocksTermination() {
        let queue = TransferQueue()
        queue.maxActiveTransfers = 0
        queue.enqueue(
            kind: .download,
            title: "Download",
            subtitle: "Queued",
            source: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/file"),
            destination: TransferEndpoint(kind: .mac, path: "/tmp/file")
        ) { _ in
            TransferJobResult()
        }
        let model = makeModel(transferQueue: queue)

        XCTAssertFalse(model.beginTerminationRequest())
        XCTAssertFalse(model.isPreparingForTermination)
    }

    func testQueuedPreviewIsCanceledInsteadOfBlockingTermination() {
        let queue = TransferQueue()
        queue.maxActiveTransfers = 0
        let jobID = queue.enqueue(
            kind: .preview,
            title: "Preview",
            subtitle: "Queued",
            source: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/file"),
            destination: TransferEndpoint(kind: .mac, path: "/tmp/file")
        ) { _ in
            TransferJobResult()
        }
        let model = makeModel(transferQueue: queue)

        XCTAssertTrue(model.beginTerminationRequest())
        XCTAssertEqual(queue.job(id: jobID)?.state, .canceled)
    }

    func testActiveUSBWriteBlocksTermination() {
        let usbTransferManager = USBTransferManager()
        usbTransferManager.beginTerminationBlockingActivity()
        let model = makeModel(usbTransferManager: usbTransferManager)

        XCTAssertFalse(model.beginTerminationRequest())

        usbTransferManager.endTerminationBlockingActivity()
        XCTAssertTrue(model.beginTerminationRequest())
    }

    func testQuitPromptUsesOnlySelectedConnectedPhonesTrash() {
        let record = makeRecord()
        let model = makeModel(initialTrashRecords: [record])

        XCTAssertTrue(model.shouldConfirmEmptyTrashAtSessionEnd)
        XCTAssertEqual(model.trashItemsAddedThisSessionCount, 0)

        model.devices = []
        XCTAssertFalse(model.shouldConfirmEmptyTrashAtSessionEnd)
    }

    func testAutomaticTrashBehaviorUsesSelectedConnectedPhonesRecordsWithoutPrompting() {
        let model = makeModel(initialTrashRecords: [makeRecord()])
        model.settings.trashQuitBehavior = .emptyAutomatically

        XCTAssertTrue(model.shouldAutomaticallyEmptyTrashAtSessionEnd)
        XCTAssertFalse(model.shouldConfirmEmptyTrashAtSessionEnd)

        model.settings.trashQuitBehavior = .keep
        XCTAssertFalse(model.shouldAutomaticallyEmptyTrashAtSessionEnd)
        XCTAssertFalse(model.shouldConfirmEmptyTrashAtSessionEnd)
    }

    private func makeModel(
        transferQueue: TransferQueue = TransferQueue(),
        usbTransferManager: USBTransferManager = USBTransferManager(),
        initialTrashRecords: [TrashRecord] = []
    ) -> AppModel {
        let suiteName = "AndroidFileBrowserCoreTests.TerminationState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            settings: AppSettings(defaults: defaults),
            usbTransferManager: usbTransferManager,
            transferQueue: transferQueue,
            initialTrashRecords: initialTrashRecords
        )
        if let record = initialTrashRecords.first {
            let device = AndroidDevice(
                serial: record.deviceSerial,
                state: .device,
                model: "Test Phone",
                product: nil,
                transport: nil
            )
            model.devices = [device]
            model.selectedDeviceID = device.id
        }
        return model
    }

    private func makeRecord() -> TrashRecord {
        TrashRecord(
            id: UUID(),
            deviceSerial: "test-device",
            originalPath: "/storage/emulated/0/Test.txt",
            trashPath: "/storage/emulated/0/.AndroidFileBrowserTrash/Test.txt",
            name: "Test.txt",
            deletedAt: Date(),
            size: 1
        )
    }
}
