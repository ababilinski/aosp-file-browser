import Foundation
import XCTest
@testable import AndroidFileBrowserCore

@MainActor
final class AppModelDeviceSessionTests: XCTestCase {
    func testAppRowsShowFallbackBeforePresentationMetadataArrives() async throws {
        let runner = SlowAppLoadingProcessRunner()
        let model = makeModel(runner: runner)
        let device = AndroidDevice(serial: "first-device", state: .device, model: "First", product: nil, transport: nil)
        model.devices = [device]
        model.selectedDeviceID = device.id

        let loadTask = Task { await model.loadPackages() }
        try await waitUntil(timeout: .seconds(2)) {
            model.packages.count == 1 && model.packages[0].appLabel == nil
        }

        XCTAssertEqual(model.packages[0].displayName, "Reader")
        XCTAssertEqual(model.packages[0].displayInitials, "RE")
        XCTAssertNil(model.packages[0].iconPNGData)

        try await waitUntil(timeout: .seconds(2)) {
            model.packages.first?.appLabel == "Reader Plus"
                && model.packages.first?.iconPNGData != nil
        }
        XCTAssertEqual(model.packages[0].displayName, "Reader Plus")

        loadTask.cancel()
        await loadTask.value
    }

    func testAppListAppearsBeforeDetailsAndDeviceSwitchCancelsOldLoad() async throws {
        let runner = SlowAppLoadingProcessRunner()
        let model = makeModel(runner: runner)
        let first = AndroidDevice(serial: "first-device", state: .device, model: "First", product: nil, transport: nil)
        let second = AndroidDevice(serial: "second-device", state: .device, model: "Second", product: nil, transport: nil)
        model.devices = [first, second]
        model.selectedDeviceID = first.id

        let loadTask = Task { await model.loadPackages() }
        try await waitUntil(timeout: .seconds(2)) {
            model.packages.map(\.packageName) == ["com.example.reader"]
        }
        try await waitUntil(timeout: .seconds(2)) {
            await runner.didStartSlowDetails()
        }

        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.canSwitchADBDevice)

        model.selectADBDevice(id: second.id)

        XCTAssertEqual(model.selectedDeviceID, second.id)
        try await waitUntil(timeout: .seconds(2)) {
            await runner.slowDetailsCancellationCount() == 1
        }
        await loadTask.value
        XCTAssertTrue(model.packages.isEmpty)
    }

    func testDisconnectIsAppliedWhileAppDetailsAreStillLoading() async throws {
        let runner = SlowAppLoadingProcessRunner()
        let model = makeModel(runner: runner)
        let device = AndroidDevice(serial: "first-device", state: .device, model: "First", product: nil, transport: nil)
        model.devices = [device]
        model.selectedDeviceID = device.id

        let loadTask = Task { await model.loadPackages() }
        try await waitUntil(timeout: .seconds(2)) {
            await runner.didStartSlowDetails() && model.isBusy
        }
        await runner.setConnectedDeviceSerials([])

        await model.pollDeviceConnections()

        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertNil(model.selectedDeviceID)
        XCTAssertNil(model.selectedDevice)
        XCTAssertTrue(model.packages.isEmpty)
        try await waitUntil(timeout: .seconds(2)) {
            await runner.slowDetailsCancellationCount() == 1
        }
        await loadTask.value
        XCTAssertFalse(model.isLoadingApps)
    }

    func testDisconnectIsAppliedWhileAppInstallIsStillRunning() async throws {
        let runner = SlowAppLoadingProcessRunner()
        let model = makeModel(runner: runner)
        let device = AndroidDevice(serial: "first-device", state: .device, model: "First", product: nil, transport: nil)
        model.devices = [device]
        model.selectedDeviceID = device.id
        model.sidebarSelection = .apps

        let installTask = Task {
            await model.installAppPackages(urls: [URL(fileURLWithPath: "/tmp/test.apk")])
        }
        try await waitUntil(timeout: .seconds(2)) {
            await runner.didStartInstall() && model.isInstallingAppPackage
        }
        await runner.setConnectedDeviceSerials([])

        await model.pollDeviceConnections()

        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertNil(model.selectedDeviceID)
        XCTAssertNil(model.selectedDevice)
        XCTAssertNil(model.sidebarSelection)
        XCTAssertTrue(model.shouldShowADBSetupAfterConnectionModeSwitch)
        XCTAssertFalse(model.hasReadyADBDevice)

        installTask.cancel()
        await installTask.value
    }

    func testPollingRefreshesBatteryForEveryConnectedADBDevice() async throws {
        let runner = SlowAppLoadingProcessRunner()
        let model = makeModel(runner: runner)

        await model.pollDeviceConnections()

        try await waitUntil(timeout: .seconds(2)) {
            model.batteryStatuses.count == 2
        }
        XCTAssertEqual(model.batteryStatuses["first-device"]?.levelPercent, 61)
        XCTAssertEqual(model.batteryStatuses["second-device"]?.levelPercent, 84)
    }

    func testWirelessSetupRequestShowsEnablementGuidanceWhenSettingIsOff() async throws {
        let runner = SlowAppLoadingProcessRunner()
        let model = makeModel(runner: runner)
        let device = AndroidDevice(
            serial: "first-device",
            state: .device,
            model: "First",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )
        model.devices = [device]
        model.selectedDeviceID = device.id

        model.requestWirelessADBSetup(for: device.id)

        try await waitUntil(timeout: .seconds(2)) {
            model.wirelessADBSetupPresentation?.phase == .needsWirelessDebugging
        }
        XCTAssertEqual(model.wirelessADBSetupPresentation?.deviceName, "First")
    }

    func testWirelessSetupWaitsForConfirmationAndCanUseUSBHandoffWhenSettingIsOff() async throws {
        let runner = SlowAppLoadingProcessRunner()
        let model = makeModel(runner: runner)
        let device = AndroidDevice(
            serial: "first-device",
            state: .device,
            model: "First",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )
        model.devices = [device]
        model.selectedDeviceID = device.id

        model.requestWirelessADBSetup(for: device.id)

        try await waitUntil(timeout: .seconds(2)) {
            model.wirelessADBSetupPresentation?.phase == .needsWirelessDebugging
        }
        var commands = await runner.commands()
        XCTAssertFalse(commands.contains { $0.last?.contains("ip route get") == true })
        XCTAssertFalse(commands.contains(["-s", device.serial, "tcpip", "5555"]))

        model.confirmWirelessADBSetup()

        try await waitUntil(timeout: .seconds(2)) {
            let commands = await runner.commands()
            return commands.contains { $0.last?.contains("ip route get") == true }
        }
        commands = await runner.commands()
        XCTAssertTrue(commands.contains { $0.last?.contains("ip route get") == true })
    }

    func testWirelessSettingWriteRequiresSeparateExplicitConfirmation() async throws {
        let runner = SlowAppLoadingProcessRunner()
        let model = makeModel(runner: runner)
        let device = AndroidDevice(
            serial: "first-device",
            state: .device,
            model: "First",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )
        model.devices = [device]
        model.selectedDeviceID = device.id

        model.requestWirelessADBSetup(for: device.id)
        try await waitUntil(timeout: .seconds(2)) {
            model.wirelessADBSetupPresentation?.phase == .needsWirelessDebugging
        }

        model.requestWirelessDebuggingEnablement()

        XCTAssertEqual(
            model.wirelessADBSetupPresentation?.phase,
            .confirmWirelessDebuggingEnable
        )
        var commands = await runner.commands()
        XCTAssertFalse(commands.contains {
            $0.last == "settings put global adb_wifi_enabled 1"
        })

        model.confirmWirelessDebuggingEnablement()

        try await waitUntil(timeout: .seconds(2)) {
            let commands = await runner.commands()
            return commands.contains {
                $0.last == "settings put global adb_wifi_enabled 1"
            }
        }
        commands = await runner.commands()
        XCTAssertTrue(commands.contains {
            $0.last == "settings put global adb_wifi_enabled 1"
        })
        try await waitUntil(timeout: .seconds(2)) {
            model.wirelessADBSetupPresentation?.phase == .wirelessDebuggingApprovalRequired
        }
    }

    func testSecureWirelessDebuggingPathNeverStartsLegacyTCPIP() async throws {
        let runner = SlowAppLoadingProcessRunner(wirelessSettingOutputAfterEnable: "1\n")
        let model = makeModel(runner: runner)
        let device = AndroidDevice(
            serial: "first-device",
            state: .device,
            model: "First",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )
        model.devices = [device]

        model.requestWirelessADBSetup(for: device.id)
        try await waitUntil(timeout: .seconds(2)) {
            model.wirelessADBSetupPresentation?.phase == .needsWirelessDebugging
        }
        model.requestWirelessDebuggingEnablement()
        model.confirmWirelessDebuggingEnablement()
        try await waitUntil(timeout: .seconds(2)) {
            model.wirelessADBSetupPresentation?.phase == .wirelessDebuggingEnabled
        }

        let commands = await runner.commands()
        XCTAssertTrue(commands.contains {
            $0.last == "settings put global adb_wifi_enabled 1"
        })
        XCTAssertFalse(commands.contains(["-s", device.serial, "tcpip", "5555"]))
        XCTAssertFalse(commands.contains {
            $0.last?.contains("ip route get") == true
        })
    }

    func testUnsupportedWirelessDebuggingSkipsSettingWrite() async throws {
        let runner = SlowAppLoadingProcessRunner(wirelessCapabilityOutput: "false\n")
        let model = makeModel(runner: runner)
        let device = AndroidDevice(
            serial: "first-device",
            state: .device,
            model: "First",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )
        model.devices = [device]

        model.requestWirelessADBSetup(for: device.id)
        try await waitUntil(timeout: .seconds(2)) {
            model.wirelessADBSetupPresentation?.phase == .wirelessDebuggingUnsupported
        }

        let commands = await runner.commands()
        XCTAssertTrue(commands.contains {
            $0.last == "cmd adb is-wifi-supported 2>/dev/null"
        })
        XCTAssertFalse(commands.contains {
            $0.last == "settings put global adb_wifi_enabled 1"
        })
    }

    func testWirelessSettingConfirmationReportsUSBDisconnect() async throws {
        let runner = SlowAppLoadingProcessRunner()
        let model = makeModel(runner: runner)
        let device = AndroidDevice(
            serial: "first-device",
            state: .device,
            model: "First",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )
        model.devices = [device]

        model.requestWirelessADBSetup(for: device.id)
        try await waitUntil(timeout: .seconds(2)) {
            model.wirelessADBSetupPresentation?.phase == .needsWirelessDebugging
        }
        model.requestWirelessDebuggingEnablement()
        model.devices = []
        model.confirmWirelessDebuggingEnablement()

        guard case .wirelessDebuggingEnableFailed(let message) =
            model.wirelessADBSetupPresentation?.phase else {
            return XCTFail("Expected an actionable disconnect failure")
        }
        XCTAssertTrue(message.contains("USB device disconnected"))
        let commands = await runner.commands()
        XCTAssertFalse(commands.contains {
            $0.last == "settings put global adb_wifi_enabled 1"
        })
    }

    func testLegacyHandoffReportsUSBDisconnect() async throws {
        let runner = SlowAppLoadingProcessRunner()
        let model = makeModel(runner: runner)
        let device = AndroidDevice(
            serial: "first-device",
            state: .device,
            model: "First",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )
        model.devices = [device]

        model.requestWirelessADBSetup(for: device.id)
        try await waitUntil(timeout: .seconds(2)) {
            model.wirelessADBSetupPresentation?.phase == .needsWirelessDebugging
        }
        model.devices = []
        model.confirmWirelessADBSetup()

        guard case .failed(let message) = model.wirelessADBSetupPresentation?.phase else {
            return XCTFail("Expected an actionable disconnect failure")
        }
        XCTAssertTrue(message.contains("USB device disconnected"))
        let commands = await runner.commands()
        XCTAssertFalse(commands.contains(["-s", device.serial, "tcpip", "5555"]))
    }

    func testSecurePairingStartsAfterWirelessSetupSheetDismisses() async throws {
        let runner = SlowAppLoadingProcessRunner(wirelessSettingOutput: "1\n")
        let model = makeModel(runner: runner)
        let device = AndroidDevice(
            serial: "first-device",
            state: .device,
            model: "First",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )
        model.devices = [device]

        model.requestWirelessADBSetup(for: device.id)
        try await waitUntil(timeout: .seconds(2)) {
            model.wirelessADBSetupPresentation?.phase == .wirelessDebuggingEnabled
        }
        model.startSecureWirelessPairingFromSetup()

        XCTAssertNil(model.wirelessADBSetupPresentation)
        XCTAssertNil(model.adbQRPairingSession)

        model.wirelessADBSetupSheetDidDismiss()
        try await waitUntil(timeout: .seconds(2)) {
            model.adbQRPairingSession != nil || model.toolSetupRequest != nil
        }
    }

    private func makeModel(runner: SlowAppLoadingProcessRunner) -> AppModel {
        let suiteName = "AndroidFileBrowserCoreTests.AppModelDeviceSession.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let adb = ADBClient(
            locator: ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb")),
            runner: runner
        )
        return AppModel(
            adb: adb,
            settings: AppSettings(defaults: defaults),
            initialTrashRecords: []
        )
    }

    private func waitUntil(
        timeout: Duration,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor SlowAppLoadingProcessRunner: ProcessRunning {
    private let wirelessCapabilityOutput: String
    private var wirelessSettingOutput: String
    private let wirelessSettingOutputAfterEnable: String
    private var connectedDeviceSerials = ["first-device", "second-device"]
    private var slowDetailsStarted = false
    private var slowDetailsCancellations = 0
    private var installStarted = false
    private var recordedCommands: [[String]] = []

    init(
        wirelessCapabilityOutput: String = "true\n",
        wirelessSettingOutput: String = "0\n",
        wirelessSettingOutputAfterEnable: String = "0\n"
    ) {
        self.wirelessCapabilityOutput = wirelessCapabilityOutput
        self.wirelessSettingOutput = wirelessSettingOutput
        self.wirelessSettingOutputAfterEnable = wirelessSettingOutputAfterEnable
    }

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        recordedCommands.append(arguments)
        if arguments == ["version"] {
            return result("Android Debug Bridge version 1.0.41\nVersion 37.0.0-test\n")
        }
        if arguments == ["devices", "-l"] {
            let rows = connectedDeviceSerials.map { serial in
                "\(serial) device product:test model:Test_Device transport_id:1"
            }
            return result((["List of devices attached"] + rows).joined(separator: "\n") + "\n")
        }
        if arguments.contains("install") || arguments.contains("install-multiple") {
            installStarted = true
            try await Task.sleep(for: .seconds(10))
            return result("Success\n")
        }

        let serial = arguments.count > 1 && arguments[0] == "-s" ? arguments[1] : ""
        let command = arguments.last ?? ""
        if command == "pm list packages -f -s" {
            return result("")
        }
        if command == "pm list packages -f -3" {
            return result("package:/data/app/reader/base.apk=com.example.reader\n")
        }
        if command.contains("ps -A") {
            return result("com.example.reader\n")
        }
        if command.contains(" app_process ") {
            try await Task.sleep(for: .milliseconds(250))
            let icon = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            return result("com.example.reader\tReader Plus\t\(icon)\n")
        }
        if command == "dumpsys battery" {
            let level = serial == "first-device" ? 61 : 84
            return result(
                """
                Current Battery Service state:
                  AC powered: false
                  USB powered: false
                  Wireless powered: false
                  status: 3
                  present: true
                  level: \(level)
                  scale: 100
                """
            )
        }
        if command == "cmd adb is-wifi-supported 2>/dev/null" {
            return result(wirelessCapabilityOutput)
        }
        if command == "settings put global adb_wifi_enabled 1" {
            wirelessSettingOutput = wirelessSettingOutputAfterEnable
            return result("")
        }
        if command.contains("settings get global adb_wifi_enabled") {
            return result(wirelessSettingOutput)
        }
        if serial == "first-device", command.hasPrefix("stat -c %s ") {
            slowDetailsStarted = true
            do {
                try await Task.sleep(for: .seconds(10))
            } catch is CancellationError {
                slowDetailsCancellations += 1
                throw CancellationError()
            }
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

    func setConnectedDeviceSerials(_ serials: [String]) {
        connectedDeviceSerials = serials
    }

    func didStartSlowDetails() -> Bool {
        slowDetailsStarted
    }

    func didStartInstall() -> Bool {
        installStarted
    }

    func slowDetailsCancellationCount() -> Int {
        slowDetailsCancellations
    }

    func commands() -> [[String]] {
        recordedCommands
    }

    private func result(_ output: String) -> ADBCommandResult {
        ADBCommandResult(stdoutData: Data(output.utf8), stderrData: Data(), exitCode: 0)
    }
}
