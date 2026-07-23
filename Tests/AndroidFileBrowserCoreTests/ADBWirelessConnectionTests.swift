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

    private func makeADB(runner: WirelessADBProcessRunner) -> ADBClient {
        ADBClient(
            locator: ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb")),
            runner: runner
        )
    }
}

private actor WirelessADBProcessRunner: ProcessRunning {
    private let routeOutput: String
    private var recordedCommands: [[String]] = []

    init(routeOutput: String = "1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.42 uid 2000\n") {
        self.routeOutput = routeOutput
    }

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        recordedCommands.append(arguments)
        if arguments.count == 4,
           Array(arguments.prefix(3)) == ["-s", "USB123", "shell"] {
            return result(routeOutput)
        }
        switch arguments {
        case ["version"]:
            return result("Android Debug Bridge version 1.0.41\nVersion 37.0.0-test\n")
        case ["-s", "USB123", "tcpip", "5555"]:
            return result("restarting in TCP mode port: 5555\n")
        case ["connect", "192.168.1.42:5555"]:
            return result("connected to 192.168.1.42:5555\n")
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
