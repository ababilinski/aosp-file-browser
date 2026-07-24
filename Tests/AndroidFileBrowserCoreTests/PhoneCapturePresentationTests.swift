import Foundation
import XCTest
@testable import AndroidFileBrowserCore

@MainActor
final class PhoneCapturePresentationTests: XCTestCase {
    func testAttachedCaptureRequestsUseOneSharedPresentationMode() {
        let model = makeModel()

        model.requestScreenshot()
        XCTAssertEqual(model.activePhoneCapturePopoverMode, .screenshot)

        model.requestScreenRecording()
        XCTAssertEqual(model.activePhoneCapturePopoverMode, .recording)

        model.requestPhoneControl()
        XCTAssertEqual(model.activePhoneCapturePopoverMode, .phoneControl)
    }

    func testDismissingCaptureControlsOnlyClearsTheMatchingMode() {
        let model = makeModel()
        model.requestScreenRecording()

        model.dismissPhoneCapturePopover(.screenshot)
        XCTAssertEqual(model.activePhoneCapturePopoverMode, .recording)

        model.dismissPhoneCapturePopover(.recording)
        XCTAssertNil(model.activePhoneCapturePopoverMode)
    }

    func testChangingToWindowPresentationClearsPendingAttachedControls() {
        let model = makeModel()
        model.requestScreenshot()
        XCTAssertEqual(model.activePhoneCapturePopoverMode, .screenshot)

        model.settings.phoneCapturePresentation = .separateWindow
        model.phoneCapturePresentationDidChange()

        XCTAssertNil(model.activePhoneCapturePopoverMode)
    }

    func testDismissedCaptureModeDoesNotReturnAfterAnotherRequest() {
        let model = makeModel()
        model.requestScreenshot()
        model.dismissPhoneCapturePopover(.screenshot)

        model.requestPhoneControl()

        XCTAssertEqual(model.activePhoneCapturePopoverMode, .phoneControl)
    }

    func testCaptureDeviceSelectorAlwaysAppearsWhenOptionalSettingsAreHidden() {
        let model = makeModel()
        model.settings.showScreenshotSetup = false
        model.settings.showRecordingSetup = false

        model.requestScreenshot()
        XCTAssertEqual(model.activePhoneCapturePopoverMode, .screenshot)

        model.requestScreenRecording()
        XCTAssertEqual(model.activePhoneCapturePopoverMode, .recording)
    }

    func testScreenshotAndRecordingKeepIndependentNonemptyDisplaySelections() {
        let model = makeModel()
        let first = AndroidDevice(
            serial: "first",
            state: .device,
            model: "First Device",
            product: nil,
            transport: nil
        )
        let second = AndroidDevice(
            serial: "second",
            state: .device,
            model: "Second Device",
            product: nil,
            transport: nil
        )
        model.devices = [first, second]
        model.selectedDeviceID = first.id

        XCTAssertEqual(model.selectedCaptureDeviceSerials(for: .screenshot), [first.serial])
        XCTAssertEqual(model.selectedCaptureDeviceSerials(for: .recording), [first.serial])

        model.setCaptureDevice(second.serial, selected: true, for: .screenshot)
        XCTAssertEqual(model.selectedCaptureDeviceSerials(for: .screenshot), [first.serial, second.serial])
        XCTAssertEqual(model.selectedCaptureDeviceSerials(for: .recording), [first.serial])

        model.setCaptureDevice(first.serial, selected: false, for: .screenshot)
        model.setCaptureDevice(second.serial, selected: false, for: .screenshot)
        XCTAssertEqual(model.selectedCaptureDeviceSerials(for: .screenshot), [second.serial])
    }

    func testCaptureToolbarControlsStayAvailableInAppsAndStorage() {
        let model = makeModel()
        let device = AndroidDevice(
            serial: "connected",
            state: .device,
            model: "Connected Device",
            product: nil,
            transport: nil
        )
        model.devices = [device]
        model.selectedDeviceID = device.id

        model.sidebarSelection = .apps
        XCTAssertTrue(model.showsPhoneCaptureToolbarControls)

        model.sidebarSelection = .storage("internal")
        XCTAssertTrue(model.showsPhoneCaptureToolbarControls)
    }

    func testInspectorUtilityStaysAvailableInAppsAndStorage() {
        let model = makeModel()
        let device = AndroidDevice(
            serial: "connected",
            state: .device,
            model: "Connected Device",
            product: nil,
            transport: nil
        )
        model.devices = [device]
        model.selectedDeviceID = device.id

        model.sidebarSelection = .apps
        XCTAssertTrue(model.hasInspectableDeviceSurface)
        XCTAssertFalse(model.canCreateFolderInActiveFileMode)

        model.sidebarSelection = .storage("internal")
        XCTAssertTrue(model.hasInspectableDeviceSurface)
        XCTAssertFalse(model.canCreateFolderInActiveFileMode)

        model.sidebarSelection = nil
        XCTAssertTrue(model.hasInspectableDeviceSurface)
        XCTAssertTrue(model.canCreateFolderInActiveFileMode)
    }

    private func makeModel() -> AppModel {
        let suiteName = "AndroidFileBrowserCoreTests.PhoneCapturePresentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            settings: AppSettings(defaults: defaults),
            initialTrashRecords: []
        )
    }
}
