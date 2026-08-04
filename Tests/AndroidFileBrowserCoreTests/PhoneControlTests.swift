import AppKit
import XCTest
@testable import AndroidFileBrowserCore

final class PhoneControlTests: XCTestCase {
    func testScrcpyArgumentsTargetOneDeviceAndUseItsUniqueWindowTitle() {
        let options = ScreenRecordingOptions(
            showTouches: true,
            resolutionPreset: .hd720,
            videoBitRateMbps: 18,
            appPackageName: "com.example.photos"
        )
        let placement = ScrcpyWindowPlacement(x: 20, y: 30, width: 400, height: 700, alwaysOnTop: false)

        let arguments = ADBClient.scrcpyArguments(
            serial: "device-serial",
            windowTitle: "ASOP File Browser — Device [e-serial]",
            options: options,
            placement: placement
        )

        XCTAssertEqual(Array(arguments.prefix(4)), [
            "--serial", "device-serial",
            "--window-title", "ASOP File Browser — Device [e-serial]"
        ])
        XCTAssertTrue(arguments.contains("--no-power-on"))
        XCTAssertTrue(arguments.contains("--show-touches"))
        XCTAssertEqual(value(after: "--max-size", in: arguments), "1280")
        XCTAssertEqual(value(after: "--video-bit-rate", in: arguments), "18M")
        XCTAssertEqual(value(after: "--start-app", in: arguments), "com.example.photos")
        XCTAssertEqual(value(after: "--window-width", in: arguments), "400")
        XCTAssertFalse(arguments.contains("--always-on-top"))
    }

    func testScrcpyOptionsCanOverrideSafeDefaults() {
        let deviceOptions = PhoneControlDeviceOptions(
            wakesDeviceOnOpen: true,
            capturesAudio: false,
            acceptsInput: false,
            synchronizesClipboard: false,
            staysAwake: true,
            turnsDeviceScreenOff: true,
            alwaysOnTop: false,
            frameRateLimit: .fps30,
            videoCodec: .h265
        )
        let arguments = ADBClient.scrcpyArguments(
            serial: "device-serial",
            windowTitle: "Device",
            options: ScreenRecordingOptions(videoBitRateMbps: 18),
            deviceOptions: deviceOptions,
            placement: nil
        )

        XCTAssertFalse(arguments.contains("--no-power-on"))
        XCTAssertTrue(arguments.contains("--no-audio"))
        XCTAssertTrue(arguments.contains("--no-control"))
        XCTAssertTrue(arguments.contains("--no-clipboard-autosync"))
        XCTAssertTrue(arguments.contains("--stay-awake"))
        XCTAssertTrue(arguments.contains("--turn-screen-off"))
        XCTAssertEqual(value(after: "--max-fps", in: arguments), "30")
        XCTAssertEqual(value(after: "--video-codec", in: arguments), "h265")
        XCTAssertEqual(value(after: "--video-bit-rate", in: arguments), "18M")
    }

    func testScreenRecordingAudioArgumentsUseSynchronizedQuickTimeCompatibleCapture() {
        let outputURL = URL(filePath: "/tmp/Recording with audio.mp4")
        let options = ScreenRecordingOptions(
            durationMode: .fixed,
            fixedDurationSeconds: 45,
            resolutionPreset: .fullHD1080,
            videoBitRateMbps: 18
        )

        let arguments = ADBClient.scrcpyScreenRecordingArguments(
            serial: "device-serial",
            localURL: outputURL,
            options: options,
            audioSource: .deviceAudio
        )

        XCTAssertEqual(value(after: "--serial", in: arguments), "device-serial")
        XCTAssertTrue(arguments.contains("--record=/tmp/Recording with audio.mp4"))
        XCTAssertTrue(arguments.contains("--record-format=mp4"))
        XCTAssertTrue(arguments.contains("--video-codec=h264"))
        XCTAssertTrue(arguments.contains("--audio-codec=aac"))
        XCTAssertTrue(arguments.contains("--audio-source=output"))
        XCTAssertTrue(arguments.contains("--require-audio"))
        XCTAssertTrue(arguments.contains("--no-playback"))
        XCTAssertTrue(arguments.contains("--no-window"))
        XCTAssertTrue(arguments.contains("--no-control"))
        XCTAssertTrue(arguments.contains("--max-size=1920"))
        XCTAssertTrue(arguments.contains("--video-bit-rate=18M"))
        XCTAssertTrue(arguments.contains("--time-limit=45"))
    }

    func testScreenRecordingCanChoosePhoneMicrophoneOrCombinedPhoneAudio() {
        let baseOptions = ScreenRecordingOptions()
        let outputURL = URL(filePath: "/tmp/recording.mp4")

        let microphoneArguments = ADBClient.scrcpyScreenRecordingArguments(
            serial: "device",
            localURL: outputURL,
            options: baseOptions,
            audioSource: .phoneMicrophone
        )
        let combinedArguments = ADBClient.scrcpyScreenRecordingArguments(
            serial: "device",
            localURL: outputURL,
            options: baseOptions,
            audioSource: .deviceAndMicrophone
        )

        XCTAssertTrue(microphoneArguments.contains("--audio-source=mic"))
        XCTAssertTrue(combinedArguments.contains("--audio-source=voice-performance"))
        XCTAssertFalse(microphoneArguments.contains { $0.hasPrefix("--time-limit=") })
        XCTAssertTrue(ADBClient.scrcpyScreenRecordingArguments(
            serial: "device",
            localURL: outputURL,
            options: baseOptions,
            audioSource: .none
        ).isEmpty)
    }

    func testScreenRecordingAudioCapabilityParserAcceptsEveryUsedOptionAndSource() {
        let capabilities = ScrcpyScreenRecordingAudioCapabilities.parse(
            helpOutput: compatibleScreenRecordingHelp
        )

        XCTAssertTrue(capabilities.supports(audioSources: [.deviceAudio]))
        XCTAssertTrue(capabilities.supports(audioSources: [.phoneMicrophone]))
        XCTAssertTrue(capabilities.supports(audioSources: [.deviceAndMicrophone]))
        XCTAssertTrue(capabilities.supports(audioSources: [
            .deviceAudio,
            .phoneMicrophone,
            .deviceAndMicrophone
        ]))
    }

    func testScreenRecordingAudioCapabilityParserRejectsOldCombinedAudioSource() {
        let oldHelp = compatibleScreenRecordingHelp.replacingOccurrences(
            of: "         - \"voice-performance\": combined phone audio\n",
            with: ""
        )
        let capabilities = ScrcpyScreenRecordingAudioCapabilities.parse(helpOutput: oldHelp)

        XCTAssertTrue(capabilities.supports(audioSources: [.deviceAudio, .phoneMicrophone]))
        XCTAssertFalse(capabilities.supports(audioSources: [.deviceAndMicrophone]))
    }

    func testScreenRecordingAudioCapabilityParserRejectsIncompleteRecordingOptions() {
        let incompleteHelp = compatibleScreenRecordingHelp.replacingOccurrences(
            of: "    --require-audio\n",
            with: ""
        )
        let capabilities = ScrcpyScreenRecordingAudioCapabilities.parse(helpOutput: incompleteHelp)

        XCTAssertFalse(capabilities.supports(audioSources: [.deviceAudio]))
    }

    func testScreenRecordingAudioRequiresVerifiedScrcpyVersion() {
        XCTAssertTrue(ScrcpyScreenRecordingAudioCapabilities.supportsRequiredVersion(
            "scrcpy 4.1 <https://github.com/Genymobile/scrcpy>"
        ))
        XCTAssertTrue(ScrcpyScreenRecordingAudioCapabilities.supportsRequiredVersion(
            "scrcpy 5.0"
        ))
        XCTAssertFalse(ScrcpyScreenRecordingAudioCapabilities.supportsRequiredVersion(
            "scrcpy 4.0 <https://github.com/Genymobile/scrcpy>"
        ))
        XCTAssertFalse(ScrcpyScreenRecordingAudioCapabilities.supportsRequiredVersion(
            "scrcpy 3.2"
        ))
        XCTAssertFalse(ScrcpyScreenRecordingAudioCapabilities.supportsRequiredVersion(
            "not scrcpy"
        ))
    }

    func testSeparateSessionsReceiveSeparateInitialPlacements() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 40, width: 1512, height: 918)

        let first = PhoneControlWindowLayout.placement(
            screenFrame: screen,
            visibleFrame: visible,
            sessionIndex: 0
        )
        let second = PhoneControlWindowLayout.placement(
            screenFrame: screen,
            visibleFrame: visible,
            sessionIndex: 1
        )
        let fourth = PhoneControlWindowLayout.placement(
            screenFrame: screen,
            visibleFrame: visible,
            sessionIndex: 3
        )

        XCTAssertNotEqual(first.x, second.x)
        XCTAssertEqual(first.y, second.y)
        XCTAssertNotEqual(first.x, fourth.x)
        XCTAssertNotEqual(first.y, fourth.y)
        XCTAssertGreaterThanOrEqual(first.width, 300)
        XCTAssertGreaterThanOrEqual(first.height, 420)
        XCTAssertTrue(first.alwaysOnTop)
    }

    func testCompanionBarStaysInsideVisibleScreen() {
        let visible = CGRect(x: 0, y: 40, width: 900, height: 700)
        let phone = CGRect(x: 20, y: 45, width: 360, height: 640)

        let companion = PhoneControlWindowLayout.companionFrame(for: phone, visibleFrame: visible)

        XCTAssertGreaterThanOrEqual(companion.minX, visible.minX)
        XCTAssertLessThanOrEqual(companion.maxX, visible.maxX)
        XCTAssertGreaterThanOrEqual(companion.minY, visible.minY)
        XCTAssertLessThanOrEqual(companion.maxY, visible.maxY)
    }

    func testMovedCompanionBarIsClampedInsideVisibleScreen() {
        let visible = CGRect(x: 0, y: 40, width: 900, height: 700)
        let moved = CGRect(x: -500, y: 900, width: 520, height: 66)

        let companion = PhoneControlWindowLayout.clampedCompanionFrame(moved, visibleFrame: visible)

        XCTAssertGreaterThanOrEqual(companion.minX, visible.minX)
        XCTAssertLessThanOrEqual(companion.maxX, visible.maxX)
        XCTAssertGreaterThanOrEqual(companion.minY, visible.minY)
        XCTAssertLessThanOrEqual(companion.maxY, visible.maxY)
    }

    func testIntegratedControlsUseStandardAndroidInputCommands() {
        XCTAssertEqual(PhoneControlShortcut.back.adbCommand, "input keyevent 4")
        XCTAssertEqual(PhoneControlShortcut.home.adbCommand, "input keyevent 3")
        XCTAssertEqual(PhoneControlShortcut.recentApps.adbCommand, "input keyevent 187")
        XCTAssertEqual(PhoneControlShortcut.wake.adbCommand, "input keyevent KEYCODE_WAKEUP")
        XCTAssertEqual(PhoneControlShortcut.power.adbCommand, "input keyevent 26")
        XCTAssertEqual(
            PhoneControlShortcut.automaticRotation.adbCommand,
            "settings put system accelerometer_rotation 1"
        )
    }

    func testCapabilityProbeOnlyEnablesReportedControls() {
        let capabilities = PhoneControlCapabilities.detected(
            fromProbeOutput: "input\nscreencap\ndumpsys\n"
        )

        XCTAssertTrue(capabilities.supportsKeyEvents)
        XCTAssertFalse(capabilities.supportsRotation)
        XCTAssertTrue(capabilities.supportsScreenshots)
        XCTAssertFalse(capabilities.supportsScreenRecording)
        XCTAssertTrue(capabilities.supportsBatteryStatus)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private var compatibleScreenRecordingHelp: String {
        """
        Usage: scrcpy [options]
            -s, --serial=serial
            -r, --record=file
            --record-format=format
            -N, --no-playback
            --no-window
            --no-control
            --no-clipboard-autosync
            --video-codec=name
            --audio-codec=name
            --audio-bit-rate=value
            --audio-source=source
                 - "output": device output
                 - "mic": phone microphone
                 - "voice-performance": combined phone audio
            --require-audio
            --video-bit-rate=value
            -m, --max-size=value
            --time-limit=seconds
        """
    }
}
