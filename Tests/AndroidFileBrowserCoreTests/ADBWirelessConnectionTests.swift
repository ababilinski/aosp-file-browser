import Foundation
import XCTest
@testable import AndroidFileBrowserCore

final class ADBWirelessConnectionTests: XCTestCase {
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
    private var pendingWirelessSettingReadSequence: [String] = []
    private var recordedCommands: [[String]] = []

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
        usbExitCode: Int32 = 0
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
    }

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        recordedCommands.append(arguments)
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
            return result(routeOutput)
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
        case ["devices", "-l"]:
            return result(
                """
                List of devices attached
                USB123 device usb:1-2 product:test model:Pixel transport_id:1
                192.168.1.42:5555 device product:test model:Pixel transport_id:2

                """
            )
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

    private func result(_ output: String, exitCode: Int32 = 0) -> ADBCommandResult {
        ADBCommandResult(stdoutData: Data(output.utf8), stderrData: Data(), exitCode: exitCode)
    }
}
