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
        .interactiveDismissDisabled(isBusy)
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

    private var isBusy: Bool {
        switch phase {
        case .enablingWirelessDebugging, .connecting:
            true
        default:
            false
        }
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
                Text("Do you want to use the legacy USB ADB handoff?")
                    .font(.headline)
                Text("After you confirm, ASOP File Browser will ask this USB-authorized device to listen on unencrypted port 5555, connect to its Wi-Fi address, and verify the connection before you unplug the cable.")
                    .fixedSize(horizontal: false, vertical: true)
                Label("Keep the cable connected until the app says Wi-Fi is ready.", systemImage: "cable.connector")
                    .foregroundStyle(.secondary)
                if verificationUnavailable {
                    Label(
                        "Android did not report whether secure Wireless debugging is available. This legacy handoff can still be attempted after you confirm.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .needsWirelessDebugging:
            VStack(alignment: .leading, spacing: 12) {
                Text("Android’s paired Wireless debugging setting is off.")
                    .font(.headline)
                Text("Choose how you want to continue. Neither option runs until you confirm it.")
                    .foregroundStyle(.secondary)
                setupOption(
                    title: "Turn on Wireless debugging",
                    detail: "Ask Android to enable its encrypted, paired Wi-Fi ADB setting. Android may require approval on the phone for this Wi-Fi network.",
                    symbol: "lock.shield",
                    buttonTitle: "Turn On…",
                    action: model.requestWirelessDebuggingEnablement
                )
                setupOption(
                    title: "Use the USB handoff",
                    detail: "Temporarily ask this USB-authorized device to listen on port 5555. This legacy connection is not encrypted.",
                    symbol: "cable.connector",
                    buttonTitle: "Use USB Handoff",
                    action: model.confirmWirelessADBSetup
                )
                Link(
                    "Open Android’s Wireless debugging guide",
                    destination: URL(string: "https://developer.android.com/tools/adb#connect-to-a-device-over-wi-fi")!
                )
                .font(.callout)
            }

        case .wirelessDebuggingUnsupported:
            VStack(alignment: .leading, spacing: 12) {
                Text("Android reports that secure Wireless debugging is not supported on this device.")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("ASOP File Browser will not try to change the Wireless debugging setting. You can keep using USB or explicitly try the legacy USB-authorized handoff.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                setupOption(
                    title: "Use the USB handoff",
                    detail: "Temporarily ask this USB-authorized device to listen on port 5555. This legacy connection is not encrypted.",
                    symbol: "cable.connector",
                    buttonTitle: "Use USB Handoff",
                    action: model.confirmWirelessADBSetup
                )
            }

        case .confirmWirelessDebuggingEnable:
            VStack(alignment: .leading, spacing: 12) {
                Text("Do you want ASOP File Browser to ask Android to turn on Wireless debugging?")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This changes a security-sensitive Developer option. Android may display a confirmation on the phone for the current Wi-Fi network; Wireless debugging remains off until that approval is accepted.")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("adb -s \(deviceID) shell settings put global adb_wifi_enabled 1")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Label(
                    "This does not pair the Mac or start the legacy port 5555 handoff.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

        case .enablingWirelessDebugging:
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Asking Android to turn on Wireless debugging…")
                        .font(.headline)
                    Text("Keep the phone unlocked and watch for an Android network approval prompt.")
                        .foregroundStyle(.secondary)
                }
            }

        case .wirelessDebuggingEnabled:
            VStack(alignment: .leading, spacing: 12) {
                Label("Secure Wireless debugging is on.", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("Closing this window leaves the Android setting on. To use its encrypted connection, pair this Mac with the QR code shown by ASOP File Browser.")
                    .fixedSize(horizontal: false, vertical: true)
                setupOption(
                    title: "Pair securely",
                    detail: "Open Pair device with QR code on Android, then scan the code shown by this app.",
                    symbol: "qrcode.viewfinder",
                    buttonTitle: "Pair with QR Code…",
                    action: model.startSecureWirelessPairingFromSetup
                )
                setupOption(
                    title: "Use the USB handoff instead",
                    detail: "Temporarily listen on port 5555 without encryption. This is separate from secure Wireless debugging.",
                    symbol: "cable.connector",
                    buttonTitle: "Use USB Handoff",
                    action: model.confirmWirelessADBSetup
                )
            }

        case .wirelessDebuggingApprovalRequired:
            VStack(alignment: .leading, spacing: 12) {
                Text("Android still reports Wireless debugging as off.")
                    .font(.headline)
                Text("Unlock the phone and approve Wireless debugging on the current Wi-Fi network if Android displayed a prompt. Then check again.")
                    .fixedSize(horizontal: false, vertical: true)
                Label(
                    "If no prompt appeared, turn on Wireless debugging in Developer options manually.",
                    systemImage: "iphone.gen3"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

        case .wirelessDebuggingEnableFailed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text("Android could not turn on Wireless debugging through the authorized USB connection.")
                    .fixedSize(horizontal: false, vertical: true)
                technicalDetails(message)
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
                technicalDetails(message)
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
                Button("Use USB Handoff") {
                    model.confirmWirelessADBSetup()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .needsWirelessDebugging:
                Button("Cancel", role: .cancel) {
                    model.dismissWirelessADBSetup()
                }
                Button("Check Again") {
                    model.retryWirelessADBPreflight()
                }

            case .wirelessDebuggingUnsupported:
                Button("Cancel", role: .cancel) {
                    model.dismissWirelessADBSetup()
                }
                Button("Check Again") {
                    model.retryWirelessADBPreflight()
                }

            case .confirmWirelessDebuggingEnable:
                Button("Back", role: .cancel) {
                    model.cancelWirelessDebuggingEnablement()
                }
                Button("Turn On Wireless Debugging") {
                    model.confirmWirelessDebuggingEnablement()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .enablingWirelessDebugging, .connecting:
                EmptyView()

            case .wirelessDebuggingEnabled:
                Button("Done") {
                    model.dismissWirelessADBSetup()
                }
                .keyboardShortcut(.cancelAction)

            case .wirelessDebuggingApprovalRequired:
                Button("Cancel", role: .cancel) {
                    model.dismissWirelessADBSetup()
                }
                Button("Check Again") {
                    model.retryWirelessDebuggingEnablement()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .wirelessDebuggingEnableFailed:
                Button("Cancel", role: .cancel) {
                    model.dismissWirelessADBSetup()
                }
                Button("Try Again…") {
                    model.retryWirelessDebuggingEnablement()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

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
            "Checking Wi-Fi ADB"
        case .readyToConnect:
            "Use USB ADB Handoff?"
        case .needsWirelessDebugging:
            "Wireless Debugging Is Off"
        case .wirelessDebuggingUnsupported:
            "Wireless Debugging Isn’t Supported"
        case .confirmWirelessDebuggingEnable:
            "Turn On Wireless Debugging?"
        case .enablingWirelessDebugging:
            "Turning On Wireless Debugging"
        case .wirelessDebuggingEnabled:
            "Wireless Debugging Is On"
        case .wirelessDebuggingApprovalRequired:
            "Approval May Be Required"
        case .wirelessDebuggingEnableFailed:
            "Couldn’t Turn On Wireless Debugging"
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
        case .checking, .enablingWirelessDebugging, .connecting:
            "wifi"
        case .readyToConnect, .wirelessDebuggingEnabled:
            "wifi"
        case .needsWirelessDebugging,
             .wirelessDebuggingUnsupported,
             .confirmWirelessDebuggingEnable,
             .wirelessDebuggingApprovalRequired:
            "exclamationmark.triangle.fill"
        case .connected:
            "wifi.circle.fill"
        case .wirelessDebuggingEnableFailed, .failed:
            "xmark.circle.fill"
        }
    }

    private var headerColor: Color {
        switch phase {
        case .needsWirelessDebugging,
             .wirelessDebuggingUnsupported,
             .confirmWirelessDebuggingEnable,
             .wirelessDebuggingApprovalRequired:
            .orange
        case .wirelessDebuggingEnabled, .connected:
            .green
        case .wirelessDebuggingEnableFailed, .failed:
            .red
        default:
            .accentColor
        }
    }

    private func setupOption(
        title: String,
        detail: String,
        symbol: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(buttonTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func technicalDetails(_ message: String) -> some View {
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

    private func copyToPasteboard(_ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
    }
}
