import Foundation
import XCTest
@testable import AndroidFileBrowserCore

final class ADBWirelessConnectionTests: XCTestCase {
    func testDeviceDiscoveryReconcilesUSBAndWiFiEndpointsByHardwareIdentity() async throws {
        let runner = WirelessADBProcessRunner()
        let manager = DeviceManager(adb: makeADB(runner: runner))

        let devices = try await manager.devices()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].physicalDeviceID, "android-hardware:HW123")
        XCTAssertEqual(devices[0].serial, "USB123")
        XCTAssertEqual(Set(devices[0].availableSerials), ["USB123", "192.168.1.42:5555"])
        XCTAssertEqual(devices[0].connectionKind, .usb)
    }

    func testDeviceDiscoveryPreservesPreferredUsableWiFiEndpoint() async throws {
        let runner = WirelessADBProcessRunner()
        let manager = DeviceManager(adb: makeADB(runner: runner))

        let devices = try await manager.devices(
            preferredSerialsByPhysicalDeviceID: [
                "android-hardware:HW123": "192.168.1.42:5555"
            ]
        )

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].physicalDeviceID, "android-hardware:HW123")
        XCTAssertEqual(devices[0].serial, "192.168.1.42:5555")
        XCTAssertEqual(devices[0].connectionKind, .wifi)
        XCTAssertEqual(devices[0].usbSerial, "USB123")
    }

    func testDeviceDiscoveryCachesHardwareIdentityWhileEndpointTransportIsStable() async throws {
        let runner = WirelessADBProcessRunner()
        let manager = DeviceManager(adb: makeADB(runner: runner))

        _ = try await manager.devices()
        _ = try await manager.devices()

        let commands = await runner.commands()
        XCTAssertEqual(
            commands.filter { $0.last == "getprop ro.serialno; getprop ro.boot.serialno" }.count,
            2,
            "Each of the two endpoints should resolve its identity only once."
        )
    }

    func testDeviceDiscoveryRechecksIdentityWhenEndpointTransportChanges() async throws {
        let runner = WirelessADBProcessRunner()
        let manager = DeviceManager(adb: makeADB(runner: runner))

        _ = try await manager.devices()
        await runner.setTransportIDs(usb: "3", wifi: "4")
        _ = try await manager.devices()

        let commands = await runner.commands()
        XCTAssertEqual(
            commands.filter { $0.last == "getprop ro.serialno; getprop ro.boot.serialno" }.count,
            4
        )
    }

    func testSameDisplayNameDoesNotMergeDifferentPhysicalDevices() {
        let first = AndroidDevice(
            serial: "USB-A",
            state: .device,
            model: "Pixel",
            product: "pixel",
            transport: "1"
        )
        let second = AndroidDevice(
            serial: "USB-B",
            state: .device,
            model: "Pixel",
            product: "pixel",
            transport: "2"
        )

        let devices = DeviceManager.reconcileDevices(
            [first, second],
            physicalDeviceIDsBySerial: [
                "USB-A": "android-hardware:HW-A",
                "USB-B": "android-hardware:HW-B"
            ]
        )

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(Set(devices.map(\.physicalDeviceID)), [
            "android-hardware:HW-A",
            "android-hardware:HW-B"
        ])
    }

    func testUSBDeviceIsPreparedAndConnectedOverWiFi() async throws {
        let runner = WirelessADBProcessRunner()
        let manager = DeviceManager(adb: makeADB(runner: runner))
        let device = AndroidDevice(
            serial: "USB123",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )

        let endpoint = try await manager.enableWirelessADB(device: device)

        XCTAssertEqual(endpoint, "192.168.1.42:5555")
        let commands = await runner.commands()
        XCTAssertTrue(commands.contains(["-s", "USB123", "tcpip", "5555"]))
        XCTAssertTrue(commands.contains(["connect", "192.168.1.42:5555"]))
    }

    func testMissingWiFiAddressHasActionableFailure() async throws {
        let runner = WirelessADBProcessRunner(routeOutput: "")
        let manager = DeviceManager(adb: makeADB(runner: runner))
        let device = AndroidDevice(
            serial: "USB123",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "1"
        )

        do {
            _ = try await manager.enableWirelessADB(device: device)
            XCTFail("Expected Wi-Fi address discovery to fail")
        } catch let error as ADBWirelessConnectionError {
            XCTAssertEqual(error, .noWiFiAddress)
            XCTAssertTrue(error.localizedDescription.contains("same Wi-Fi network"))
        }
    }

    func testFailedLegacyConnectionReturnsADBToUSBMode() async throws {
        let runner = WirelessADBProcessRunner(
            connectOutput: "failed to connect: No route to host\n",
            connectExitCode: 1
        )
        let manager = DeviceManager(adb: makeADB(runner: runner))
        let device = AndroidDevice(
            serial: "USB123",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )

        do {
            _ = try await manager.enableWirelessADB(device: device)
            XCTFail("Expected Wi-Fi connection to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("returned ADB to USB-only mode"))
        }
        let commands = await runner.commands()
        XCTAssertTrue(commands.contains(["-s", "USB123", "usb"]))
    }

    func testAmbiguousTCPIPFailureReturnsADBToUSBMode() async throws {
        let runner = WirelessADBProcessRunner(
            tcpIPOutput: "device offline\n",
            tcpIPExitCode: 1
        )
        let manager = DeviceManager(adb: makeADB(runner: runner))
        let device = AndroidDevice(
            serial: "USB123",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )

        do {
            _ = try await manager.enableWirelessADB(device: device)
            XCTFail("Expected TCP mode confirmation to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not confirm"))
            XCTAssertTrue(error.localizedDescription.contains("returned ADB to USB-only mode"))
        }
        let commands = await runner.commands()
        XCTAssertTrue(commands.contains(["-s", "USB123", "usb"]))
        XCTAssertFalse(commands.contains(["connect", "192.168.1.42:5555"]))
    }

    func testFailedLegacyRollbackWarnsWhenUSBModeCannotBeVerified() async throws {
        let runner = WirelessADBProcessRunner(
            connectOutput: "failed to connect: No route to host\n",
            connectExitCode: 1,
            usbOutput: "device offline\n",
            usbExitCode: 1
        )
        let manager = DeviceManager(adb: makeADB(runner: runner))
        let device = AndroidDevice(
            serial: "USB123",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )

        do {
            _ = try await manager.enableWirelessADB(device: device)
            XCTFail("Expected Wi-Fi connection to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not confirm"))
            XCTAssertTrue(error.localizedDescription.contains("port 5555"))
            XCTAssertTrue(error.localizedDescription.contains("device offline"))
        }
    }

    func testWiFiEndpointCanReturnADBToUSBMode() async throws {
        let runner = WirelessADBProcessRunner()
        let manager = DeviceManager(adb: makeADB(runner: runner))
        let device = AndroidDevice(
            serial: "192.168.1.42:5555",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "2",
            physicalDeviceID: "android-hardware:HW123"
        )

        try await manager.switchToUSB(device: device)

        let commands = await runner.commands()
        XCTAssertTrue(commands.contains(["-s", "192.168.1.42:5555", "usb"]))
    }

    func testDisconnectWiFiTargetsEveryWirelessEndpointButNotUSB() async throws {
        let runner = WirelessADBProcessRunner()
        let manager = DeviceManager(adb: makeADB(runner: runner))
        let device = AndroidDevice(
            serial: "192.168.1.42:5555",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "2",
            physicalDeviceID: "android-hardware:HW123",
            availableSerials: [
                "USB123",
                "192.168.1.42:5555",
                "pixel._adb-tls-connect._tcp"
            ]
        )

        try await manager.disconnectWirelessADB(device: device)

        let commands = await runner.commands()
        XCTAssertTrue(commands.contains(["disconnect", "192.168.1.42:5555"]))
        XCTAssertTrue(commands.contains(["disconnect", "pixel._adb-tls-connect._tcp"]))
        XCTAssertFalse(commands.contains(["disconnect", "USB123"]))
    }

    @MainActor
    func testAppModelSwitchesLegacyWiFiDeviceBackToUSBWithStableSelection() async throws {
        let runner = WirelessADBProcessRunner(startsInLegacyWiFiOnlyMode: true)
        let model = makeModel(runner: runner)
        let physicalDeviceID = "android-hardware:HW123"
        model.devices = [
            AndroidDevice(
                serial: "192.168.1.42:5555",
                state: .device,
                model: "Pixel",
                product: "test",
                transport: "2",
                physicalDeviceID: physicalDeviceID
            )
        ]
        model.selectedDeviceID = physicalDeviceID

        await model.switchADBConnectionToUSB(for: physicalDeviceID)

        XCTAssertEqual(model.devices.count, 1)
        XCTAssertEqual(model.selectedDeviceID, physicalDeviceID)
        XCTAssertEqual(model.selectedDevice?.serial, "USB123")
        XCTAssertEqual(model.selectedDevice?.connectionKind, .usb)
        let commands = await runner.commands()
        XCTAssertTrue(commands.contains(["-s", "192.168.1.42:5555", "usb"]))
    }

    @MainActor
    func testAppModelDisconnectsWiFiAndKeepsAvailableUSBDeviceSelected() async throws {
        let runner = WirelessADBProcessRunner()
        let model = makeModel(runner: runner)
        let physicalDeviceID = "android-hardware:HW123"
        model.devices = [
            AndroidDevice(
                serial: "192.168.1.42:5555",
                state: .device,
                model: "Pixel",
                product: "test",
                transport: "2",
                physicalDeviceID: physicalDeviceID,
                availableSerials: ["USB123", "192.168.1.42:5555"]
            )
        ]
        model.selectedDeviceID = physicalDeviceID

        await model.disconnectADBWiFi(for: physicalDeviceID)

        XCTAssertEqual(model.devices.count, 1)
        XCTAssertEqual(model.selectedDeviceID, physicalDeviceID)
        XCTAssertEqual(model.selectedDevice?.serial, "USB123")
        XCTAssertFalse(model.selectedDevice?.hasWirelessEndpoint ?? true)
        let commands = await runner.commands()
        XCTAssertTrue(commands.contains(["disconnect", "192.168.1.42:5555"]))
    }

    @MainActor
    func testFileHistorySurvivesLegacyWiFiToUSBEndpointChange() async throws {
        let runner = WirelessADBProcessRunner(startsInLegacyWiFiOnlyMode: true)
        let model = makeModel(runner: runner)
        let physicalDeviceID = "android-hardware:HW123"
        model.devices = [
            AndroidDevice(
                serial: "192.168.1.42:5555",
                state: .device,
                model: "Pixel",
                product: "test",
                transport: "2",
                physicalDeviceID: physicalDeviceID
            )
        ]
        model.selectedDeviceID = physicalDeviceID

        await model.createFolder(named: "History Test")
        XCTAssertTrue(model.canUndoFileOperation)

        await model.switchADBConnectionToUSB(for: physicalDeviceID)
        XCTAssertTrue(model.canUndoFileOperation)

        await model.undoLastFileOperation()

        XCTAssertTrue(model.canRedoFileOperation)
        let commands = await runner.commands()
        XCTAssertTrue(commands.contains { command in
            command.count == 4
                && Array(command.prefix(3)) == ["-s", "192.168.1.42:5555", "shell"]
                && command[3].hasPrefix("mkdir ")
        })
        XCTAssertTrue(commands.contains { command in
            command.count == 4
                && Array(command.prefix(3)) == ["-s", "USB123", "shell"]
                && command[3].hasPrefix("rm -rf ")
        })
    }

    func testWirelessDebuggingPreflightReportsEnabledAndDisabled() async throws {
        let enabledRunner = WirelessADBProcessRunner(wirelessSettingOutput: "1\n")
        let disabledRunner = WirelessADBProcessRunner(wirelessSettingOutput: "0\n")
        let device = AndroidDevice(
            serial: "USB123",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "1"
        )

        let enabled = try await DeviceManager(adb: makeADB(runner: enabledRunner))
            .wirelessDebuggingStatus(device: device)
        let disabled = try await DeviceManager(adb: makeADB(runner: disabledRunner))
            .wirelessDebuggingStatus(device: device)

        XCTAssertEqual(enabled, .enabled)
        XCTAssertEqual(disabled, .disabled)
    }

    func testWirelessDebuggingPreflightFallsBackWhenSettingIsUnavailable() async throws {
        let runner = WirelessADBProcessRunner(wirelessSettingOutput: "null\n")
        let manager = DeviceManager(adb: makeADB(runner: runner))
        let device = AndroidDevice(
            serial: "USB123",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "1"
        )

        let status = try await manager.wirelessDebuggingStatus(device: device)

        XCTAssertEqual(status, .unavailable)
    }

    func testUnsupportedWirelessDebuggingCapabilityPreventsSettingWrite() async throws {
        let runner = WirelessADBProcessRunner(wirelessCapabilityOutput: "false\n")
        let manager = DeviceManager(adb: makeADB(runner: runner))
        let device = AndroidDevice(
            serial: "USB123",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )

        let status = try await manager.requestWirelessDebuggingEnablement(device: device)

        XCTAssertEqual(status, .unsupported)
        let commands = await runner.commands()
        XCTAssertTrue(commands.contains {
            $0.last == "cmd adb is-wifi-supported 2>/dev/null"
        })
        XCTAssertFalse(commands.contains {
            $0.last == "settings put global adb_wifi_enabled 1"
        })
    }

    func testUSBADBCanRequestWirelessDebuggingSettingEnablement() async throws {
        let runner = WirelessADBProcessRunner(
            wirelessSettingOutput: "0\n",
            wirelessSettingOutputAfterEnable: "1\n"
        )
        let manager = DeviceManager(adb: makeADB(runner: runner))
        let device = AndroidDevice(
            serial: "USB123",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )

        let status = try await manager.requestWirelessDebuggingEnablement(device: device)

        XCTAssertEqual(status, .enabled)
        let commands = await runner.commands()
        XCTAssertTrue(commands.contains([
            "-s",
            "USB123",
            "shell",
            "settings put global adb_wifi_enabled 1"
        ]))
    }

    func testTransientEnabledSettingWaitsForAndroidTrustDecision() async throws {
        let runner = WirelessADBProcessRunner(
            wirelessSettingOutput: "0\n",
            wirelessSettingOutputAfterEnable: "0\n",
            wirelessSettingReadSequenceAfterEnable: ["1\n", "0\n"]
        )
        let manager = DeviceManager(adb: makeADB(runner: runner))
        let device = AndroidDevice(
            serial: "USB123",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )

        let status = try await manager.requestWirelessDebuggingEnablement(device: device)

        XCTAssertEqual(status, .disabled)
    }

    func testWirelessDebuggingSettingWriteFailureIsActionable() async throws {
        let runner = WirelessADBProcessRunner(
            wirelessSettingOutput: "0\n",
            wirelessSettingPutOutput: "Security exception",
            wirelessSettingPutExitCode: 1
        )
        let manager = DeviceManager(adb: makeADB(runner: runner))
        let device = AndroidDevice(
            serial: "USB123",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "1",
            usbLocation: "1-2"
        )

        do {
            _ = try await manager.requestWirelessDebuggingEnablement(device: device)
            XCTFail("Expected the setting write to fail")
        } catch let error as ADBWirelessConnectionError {
            XCTAssertEqual(error, .wirelessSettingFailed("Security exception"))
            XCTAssertTrue(error.localizedDescription.contains("did not allow"))
        }
    }

    private func makeADB(runner: WirelessADBProcessRunner) -> ADBClient {
        ADBClient(
            locator: ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb")),
            runner: runner
        )
    }

    @MainActor
    private func makeModel(runner: WirelessADBProcessRunner) -> AppModel {
        let suiteName = "AndroidFileBrowserCoreTests.ADBWirelessConnection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            adb: makeADB(runner: runner),
            settings: AppSettings(defaults: defaults),
            initialTrashRecords: []
        )
    }
}

private actor WirelessADBProcessRunner: ProcessRunning {
    private let routeOutput: String
    private let wirelessCapabilityOutput: String
    private var wirelessSettingOutput: String
    private let wirelessSettingOutputAfterEnable: String
    private let wirelessSettingReadSequenceAfterEnable: [String]
    private let wirelessSettingPutOutput: String
    private let wirelessSettingPutExitCode: Int32
    private let connectOutput: String
    private let connectExitCode: Int32
    private let tcpIPOutput: String
    private let tcpIPExitCode: Int32
    private let usbOutput: String
    private let usbExitCode: Int32
    private let startsInLegacyWiFiOnlyMode: Bool
    private var pendingWirelessSettingReadSequence: [String] = []
    private var recordedCommands: [[String]] = []
    private var usbTransportID = "1"
    private var wifiTransportID = "2"
    private var isUSBMode = false
    private var disconnectedEndpoints = Set<String>()

    init(
        routeOutput: String = "1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.42 uid 2000\n",
        wirelessCapabilityOutput: String = "true\n",
        wirelessSettingOutput: String = "1\n",
        wirelessSettingOutputAfterEnable: String = "1\n",
        wirelessSettingReadSequenceAfterEnable: [String] = [],
        wirelessSettingPutOutput: String = "",
        wirelessSettingPutExitCode: Int32 = 0,
        connectOutput: String = "connected to 192.168.1.42:5555\n",
        connectExitCode: Int32 = 0,
        tcpIPOutput: String = "restarting in TCP mode port: 5555\n",
        tcpIPExitCode: Int32 = 0,
        usbOutput: String = "restarting in USB mode\n",
        usbExitCode: Int32 = 0,
        startsInLegacyWiFiOnlyMode: Bool = false
    ) {
        self.routeOutput = routeOutput
        self.wirelessCapabilityOutput = wirelessCapabilityOutput
        self.wirelessSettingOutput = wirelessSettingOutput
        self.wirelessSettingOutputAfterEnable = wirelessSettingOutputAfterEnable
        self.wirelessSettingReadSequenceAfterEnable = wirelessSettingReadSequenceAfterEnable
        self.wirelessSettingPutOutput = wirelessSettingPutOutput
        self.wirelessSettingPutExitCode = wirelessSettingPutExitCode
        self.connectOutput = connectOutput
        self.connectExitCode = connectExitCode
        self.tcpIPOutput = tcpIPOutput
        self.tcpIPExitCode = tcpIPExitCode
        self.usbOutput = usbOutput
        self.usbExitCode = usbExitCode
        self.startsInLegacyWiFiOnlyMode = startsInLegacyWiFiOnlyMode
    }

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        recordedCommands.append(arguments)
        if arguments.count == 4,
           arguments[0] == "-s",
           arguments[2] == "shell",
           arguments[3] == "getprop ro.serialno; getprop ro.boot.serialno" {
            return result("HW123\nHW123\n")
        }
        if arguments.count == 4,
           arguments[0] == "-s",
           arguments[2] == "shell",
           arguments[3].hasPrefix("test -e ") {
            return result("1\n")
        }
        if arguments.count == 4,
           Array(arguments.prefix(3)) == ["-s", "USB123", "shell"] {
            if arguments[3] == "cmd adb is-wifi-supported 2>/dev/null" {
                return result(wirelessCapabilityOutput)
            }
            if arguments[3] == "settings put global adb_wifi_enabled 1" {
                if wirelessSettingPutExitCode == 0 {
                    wirelessSettingOutput = wirelessSettingOutputAfterEnable
                    pendingWirelessSettingReadSequence = wirelessSettingReadSequenceAfterEnable
                }
                return result(
                    wirelessSettingPutOutput,
                    exitCode: wirelessSettingPutExitCode
                )
            }
            if arguments[3].contains("settings get global adb_wifi_enabled") {
                if !pendingWirelessSettingReadSequence.isEmpty {
                    return result(pendingWirelessSettingReadSequence.removeFirst())
                }
                return result(wirelessSettingOutput)
            }
            if arguments[3].contains("ip route get") {
                return result(routeOutput)
            }
            return result("")
        }
        if arguments.count == 4,
           arguments[0] == "-s",
           arguments[2] == "shell" {
            return result("")
        }
        switch arguments {
        case ["version"]:
            return result("Android Debug Bridge version 1.0.41\nVersion 37.0.0-test\n")
        case ["-s", "USB123", "tcpip", "5555"]:
            return result(tcpIPOutput, exitCode: tcpIPExitCode)
        case ["connect", "192.168.1.42:5555"]:
            return result(connectOutput, exitCode: connectExitCode)
        case ["-s", "USB123", "usb"]:
            return result(usbOutput, exitCode: usbExitCode)
        case ["-s", "192.168.1.42:5555", "usb"]:
            if usbExitCode == 0 {
                isUSBMode = true
            }
            return result(usbOutput, exitCode: usbExitCode)
        case ["disconnect", "192.168.1.42:5555"],
             ["disconnect", "pixel._adb-tls-connect._tcp"]:
            disconnectedEndpoints.insert(arguments[1])
            return result("disconnected \(arguments[1])\n")
        case ["devices", "-l"]:
            var rows = ["List of devices attached"]
            if !startsInLegacyWiFiOnlyMode || isUSBMode {
                rows.append("USB123 device usb:1-2 product:test model:Pixel transport_id:\(usbTransportID)")
            }
            if (!startsInLegacyWiFiOnlyMode || !isUSBMode),
               !disconnectedEndpoints.contains("192.168.1.42:5555") {
                rows.append("192.168.1.42:5555 device product:test model:Pixel transport_id:\(wifiTransportID)")
            }
            return result(rows.joined(separator: "\n") + "\n")
        default:
            return result("", exitCode: 1)
        }
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

    func commands() -> [[String]] {
        recordedCommands
    }

    func setTransportIDs(usb: String, wifi: String) {
        usbTransportID = usb
        wifiTransportID = wifi
    }

    private func result(_ output: String, exitCode: Int32 = 0) -> ADBCommandResult {
        ADBCommandResult(stdoutData: Data(output.utf8), stderrData: Data(), exitCode: exitCode)
    }
}
