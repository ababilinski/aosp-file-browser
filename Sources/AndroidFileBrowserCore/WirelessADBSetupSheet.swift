import AppKit
import SwiftUI

struct WirelessADBSetupSheet: View {
    @ObservedObject var model: AppModel
    let deviceID: AndroidDevice.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            phaseContent
            Divider()
            actions
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(isConnecting)
    }

    private var presentation: ADBWirelessSetupPresentation? {
        guard model.wirelessADBSetupPresentation?.deviceID == deviceID else { return nil }
        return model.wirelessADBSetupPresentation
    }

    private var phase: ADBWirelessSetupPresentation.Phase {
        presentation?.phase ?? .checking
    }

    private var deviceName: String {
        presentation?.deviceName ?? "Android device"
    }

    private var isConnecting: Bool {
        if case .connecting = phase { return true }
        return false
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: headerSymbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(headerColor)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(deviceName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .checking:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking Wireless debugging on your Android device…")
                    .foregroundStyle(.secondary)
            }

        case .readyToConnect(let verificationUnavailable):
            VStack(alignment: .leading, spacing: 12) {
                Text("ASOP File Browser will ask ADB to listen over Wi-Fi, connect to the phone’s Wi-Fi address, and confirm the connection before you unplug the cable.")
                    .fixedSize(horizontal: false, vertical: true)
                Label("Keep the cable connected until the app says Wi-Fi is ready.", systemImage: "cable.connector")
                    .foregroundStyle(.secondary)
                if verificationUnavailable {
                    Label(
                        "This Android version did not report the Wireless debugging setting. You can still try the standard USB-to-Wi-Fi handoff.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Wireless debugging is enabled.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

        case .needsWirelessDebugging:
            VStack(alignment: .leading, spacing: 12) {
                Text("Wireless debugging is off on this phone.")
                    .font(.headline)
                Text("On the Android device:")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    instructionRow(number: 1, text: "Open Settings.")
                    instructionRow(number: 2, text: "Open System › Developer options.")
                    instructionRow(number: 3, text: "Turn on Wireless debugging.")
                    instructionRow(number: 4, text: "Keep the phone unlocked and on the same Wi-Fi network as this Mac.")
                }
                Link(
                    "Open Android’s Wireless debugging guide",
                    destination: URL(string: "https://developer.android.com/tools/adb#connect-to-a-device-over-wi-fi")!
                )
                .font(.callout)
            }

        case .connecting:
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connecting via Wi-Fi…")
                        .font(.headline)
                    Text("Keep the cable connected. This can take a few seconds.")
                        .foregroundStyle(.secondary)
                }
            }

        case .connected(let endpoint):
            VStack(alignment: .leading, spacing: 10) {
                Label("Wi-Fi connection confirmed", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("You can unplug the USB cable. ASOP File Browser will continue using \(endpoint).")
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text("The phone did not accept the Wi-Fi connection. Keep the cable connected, confirm both devices are on the same Wi-Fi network, and try again.")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Technical details")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy Details") {
                            copyToPasteboard(message)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    ScrollView {
                        Text(message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            Spacer()
            switch phase {
            case .checking:
                Button("Cancel", role: .cancel) {
                    model.dismissWirelessADBSetup()
                }
                .keyboardShortcut(.cancelAction)

            case .readyToConnect:
                Button("Cancel", role: .cancel) {
                    model.dismissWirelessADBSetup()
                }
                Button("Connect via Wi-Fi") {
                    model.confirmWirelessADBSetup()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .needsWirelessDebugging:
                Button("Cancel", role: .cancel) {
                    model.dismissWirelessADBSetup()
                }
                Button("Retry") {
                    model.retryWirelessADBPreflight()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .connecting:
                EmptyView()

            case .connected:
                Button("Done") {
                    model.dismissWirelessADBSetup()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .failed:
                Button("Cancel", role: .cancel) {
                    model.dismissWirelessADBSetup()
                }
                Button("Retry") {
                    model.retryWirelessADBPreflight()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var title: String {
        switch phase {
        case .checking:
            "Connect via Wi-Fi"
        case .readyToConnect:
            "Connect via Wi-Fi"
        case .needsWirelessDebugging:
            "Turn On Wireless Debugging"
        case .connecting:
            "Connecting via Wi-Fi"
        case .connected:
            "Connected via Wi-Fi"
        case .failed:
            "Couldn’t Connect via Wi-Fi"
        }
    }

    private var headerSymbol: String {
        switch phase {
        case .checking, .connecting:
            "wifi"
        case .readyToConnect:
            "wifi"
        case .needsWirelessDebugging:
            "exclamationmark.triangle.fill"
        case .connected:
            "wifi.circle.fill"
        case .failed:
            "xmark.circle.fill"
        }
    }

    private var headerColor: Color {
        switch phase {
        case .needsWirelessDebugging:
            .orange
        case .connected:
            .green
        case .failed:
            .red
        default:
            .accentColor
        }
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(.quaternary, in: Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyToPasteboard(_ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }
}
