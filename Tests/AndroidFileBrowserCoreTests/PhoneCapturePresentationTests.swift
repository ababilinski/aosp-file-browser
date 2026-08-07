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

    func testRecordingRequestForDeviceOpensSetupAndAddsClickedDisplayWithoutStarting() {
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

        model.requestScreenRecording(deviceSerial: second.serial)

        XCTAssertEqual(model.activePhoneCapturePopoverMode, .recording)
        XCTAssertEqual(
            model.selectedCaptureDeviceSerials(for: .recording),
            [second.serial]
        )
        XCTAssertFalse(model.isStartingScreenRecording)
        XCTAssertNil(model.screenRecordingSession)
        XCTAssertNil(model.screenRecordingRequestDeviceSerial)
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

    func testRecordingAudioChoicesAreIndependentForEachSelectedPhone() {
        let model = makeModel()
        model.setScreenRecordingPhoneAudioSource(.deviceAudio, for: "first")
        model.setScreenRecordingPhoneAudioSource(.phoneMicrophone, for: "second")
        model.screenRecordingAudioOptions.capturesMacMicrophone = true

        XCTAssertEqual(model.screenRecordingPhoneAudioSource(for: "first"), .deviceAudio)
        XCTAssertEqual(model.screenRecordingPhoneAudioSource(for: "second"), .phoneMicrophone)
        XCTAssertEqual(
            model.screenRecordingAudioOptions.sourceCount(for: ["first", "second"]),
            3
        )

        model.setScreenRecordingPhoneAudioSource(.none, for: "first")
        XCTAssertEqual(model.screenRecordingPhoneAudioSource(for: "first"), .none)
        XCTAssertNil(model.screenRecordingAudioOptions.phoneSourcesByDeviceSerial["first"])

        model.setScreenRecordingPhoneAudioSource(.deviceAndMicrophone, for: "second")
        XCTAssertEqual(
            model.screenRecordingAudioOptions.sourceCount(for: ["first", "second"]),
            3
        )
    }

    func testPhoneRecordingAudioSourceMapsIndependentSystemAndMicrophoneChoices() {
        let choices: [(Bool, Bool, PhoneRecordingAudioSource)] = [
            (false, false, .none),
            (true, false, .deviceAudio),
            (false, true, .phoneMicrophone),
            (true, true, .deviceAndMicrophone)
        ]

        for (capturesSystemAudio, capturesPhoneMicrophone, expected) in choices {
            let source = PhoneRecordingAudioSource(
                capturesSystemAudio: capturesSystemAudio,
                capturesPhoneMicrophone: capturesPhoneMicrophone
            )
            XCTAssertEqual(source, expected)
            XCTAssertEqual(source.capturesSystemAudio, capturesSystemAudio)
            XCTAssertEqual(source.capturesPhoneMicrophone, capturesPhoneMicrophone)
        }
    }

    func testRecordingResolutionKeepsExactRequestedDimensions() {
        XCTAssertEqual(
            ScreenRecordingOptions(resolutionPreset: .hd720).requestedRecordingSize,
            CGSize(width: 1_280, height: 720)
        )
        XCTAssertEqual(
            ScreenRecordingOptions(resolutionPreset: .fullHD1080).requestedRecordingSize,
            CGSize(width: 1_920, height: 1_080)
        )
        XCTAssertEqual(
            ScreenRecordingOptions(
                resolutionPreset: .custom,
                customWidth: 1_344,
                customHeight: 768
            ).requestedRecordingSize,
            CGSize(width: 1_344, height: 768)
        )
        XCTAssertNil(ScreenRecordingOptions().requestedRecordingSize)
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
        XCTAssertTrue(model.showsAppManagementToolbarControls)
        XCTAssertFalse(model.showsNewFolderToolbarControl)
        XCTAssertTrue(model.hasInspectableDeviceSurface)
        XCTAssertFalse(model.canCreateFolderInActiveFileMode)

        model.sidebarSelection = .storage("internal")
        XCTAssertFalse(model.showsAppManagementToolbarControls)
        XCTAssertFalse(model.showsNewFolderToolbarControl)
        XCTAssertTrue(model.hasInspectableDeviceSurface)
        XCTAssertFalse(model.canCreateFolderInActiveFileMode)

        model.sidebarSelection = nil
        XCTAssertFalse(model.showsAppManagementToolbarControls)
        XCTAssertTrue(model.showsNewFolderToolbarControl)
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
