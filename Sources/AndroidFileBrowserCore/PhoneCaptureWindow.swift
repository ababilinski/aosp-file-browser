import AppKit
import AVFoundation
import SwiftUI

@MainActor
enum PhoneCaptureWindowPresenter {
    private static var panel: NSWindow?

    static var activeScreen: NSScreen? {
        panel?.screen
    }

    static func show(model: AppModel, mode: PhoneCaptureMode) {
        if let panel {
            panel.title = mode.windowTitle
            panel.contentView = NSHostingView(
                rootView: PhoneCaptureControlsView(model: model, presentation: .window, mode: mode)
            )
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = mode.windowTitle
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titlebarAppearsTransparent = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.minSize = NSSize(width: 560, height: 580)
        panel.setFrameAutosaveName("PhoneCaptureControls")
        panel.center()
        panel.contentView = NSHostingView(
            rootView: PhoneCaptureControlsView(model: model, presentation: .window, mode: mode)
        )

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    static func close() {
        panel?.orderOut(nil)
    }

    static func preferredScrcpyPlacement() -> ScrcpyWindowPlacement? {
        guard let screen = panel?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main else { return nil }

        let visibleFrame = screen.visibleFrame
        let gap: CGFloat = 10
        let sidePadding: CGFloat = 12
        guard let panel, panel.isVisible else {
            let phoneWidth = min(430, visibleFrame.width - (sidePadding * 2))
            let phoneHeight = min(760, visibleFrame.height - (sidePadding * 2))
            let phoneX = visibleFrame.maxX - phoneWidth - sidePadding
            let phoneYFromBottom = visibleFrame.maxY - phoneHeight - sidePadding
            let phoneYFromTop = screen.frame.maxY - (phoneYFromBottom + phoneHeight)
            return ScrcpyWindowPlacement(
                x: Int(phoneX.rounded()),
                y: Int(phoneYFromTop.rounded()),
                width: Int(phoneWidth.rounded()),
                height: Int(phoneHeight.rounded())
            )
        }

        let availablePhoneWidth = visibleFrame.width - panel.frame.width - gap - (sidePadding * 2)
        let phoneWidth = min(430, max(260, availablePhoneWidth))
        let phoneHeight = min(760, visibleFrame.height - (sidePadding * 2))

        var panelFrame = panel.frame
        let rightSpace = visibleFrame.maxX - panelFrame.maxX - gap
        let leftSpace = panelFrame.minX - visibleFrame.minX - gap
        if rightSpace < phoneWidth, leftSpace < phoneWidth {
            let combinedWidth = panelFrame.width + gap + phoneWidth
            panelFrame.origin.x = max(
                visibleFrame.minX + sidePadding,
                visibleFrame.midX - (combinedWidth / 2)
            )
            panelFrame.origin.y = min(
                max(panelFrame.origin.y, visibleFrame.minY + sidePadding),
                visibleFrame.maxY - panelFrame.height - sidePadding
            )
            panel.setFrame(panelFrame, display: true, animate: true)
        }

        let refreshedFrame = panel.frame
        let canPlaceRight = visibleFrame.maxX - refreshedFrame.maxX - gap >= phoneWidth
        let phoneX = canPlaceRight
            ? refreshedFrame.maxX + gap
            : refreshedFrame.minX - gap - phoneWidth
        let phoneTop = min(refreshedFrame.maxY, visibleFrame.maxY - sidePadding)
        let phoneYFromBottom = max(visibleFrame.minY + sidePadding, phoneTop - phoneHeight)
        let phoneYFromTop = screen.frame.maxY - (phoneYFromBottom + phoneHeight)

        return ScrcpyWindowPlacement(
            x: Int(phoneX.rounded()),
            y: Int(phoneYFromTop.rounded()),
            width: Int(phoneWidth.rounded()),
            height: Int(phoneHeight.rounded())
        )
    }
}

enum PhoneCaptureControlsPresentation {
    case window
    case popover
}

enum PhoneCaptureMode: String, CaseIterable, Identifiable {
    case screenshot
    case recording
    case phoneControl

    var id: String { rawValue }

    var windowTitle: String {
        switch self {
        case .screenshot: "Screenshot"
        case .recording: "Screen Recording"
        case .phoneControl: "Phone Control"
        }
    }

    var setupTitle: String {
        switch self {
        case .screenshot: "Take a Screenshot"
        case .recording: "Record the Screen"
        case .phoneControl: "Open Phone Control"
        }
    }

    var setupDetail: String {
        switch self {
        case .screenshot: "Choose one or more displays, then capture."
        case .recording: "Choose one or more displays, then start recording."
        case .phoneControl: "Open one device or keep several device windows together."
        }
    }

    var systemImage: String {
        switch self {
        case .screenshot: "camera.fill"
        case .recording: "record.circle"
        case .phoneControl: "rectangle.connected.to.line.below"
        }
    }

    var tint: Color {
        switch self {
        case .screenshot: .blue
        case .recording: .red
        case .phoneControl: .purple
        }
    }
}

struct PhoneCaptureControlsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    let presentation: PhoneCaptureControlsPresentation
    let mode: PhoneCaptureMode
    @State private var now = Date()
    @State private var isRecordingSettingsExpanded = false
    @State private var isAudioSettingsExpanded: Bool
    @State private var isVideoSettingsExpanded = false
    @State private var macMicrophoneInputName: String?

    init(model: AppModel, presentation: PhoneCaptureControlsPresentation, mode: PhoneCaptureMode) {
        self.model = model
        self.settings = model.settings
        self.presentation = presentation
        self.mode = mode
        _isAudioSettingsExpanded = State(initialValue: mode == .recording)
        _macMicrophoneInputName = State(initialValue: MacMicrophoneCaptureService.defaultInputName)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let session = model.screenRecordingSession {
                        if mode == .recording {
                            activeRecordingCard(session)
                        }
                    } else if let activity = currentActivity {
                        captureActivityCard(activity)
                    } else if readyPhoneControlDevices.isEmpty {
                        disconnectedCard
                    }

                    if mode != .phoneControl, !readyPhoneControlDevices.isEmpty {
                        captureDevicesCard
                    }

                    if mode == .recording, !readyPhoneControlDevices.isEmpty {
                        audioSettings
                            .disabled(recordingSettingsAreLocked)
                            .opacity(recordingSettingsAreLocked ? 0.62 : 1)
                    }

                    if mode == .phoneControl, !readyPhoneControlDevices.isEmpty {
                        phoneControlDevicesCard
                    }

                    if showsOptionalCaptureSettings {
                        phoneDisplaySettings
                        selectedSettings
                    }
                    if mode == .phoneControl {
                        skipSetupControl
                    }
                    primaryAction
                }
                .padding(20)
            }
        }
        .frame(
            minWidth: presentation == .window ? 560 : 500,
            minHeight: presentation == .window ? 620 : 0
        )
        .frame(
            width: presentation == .popover ? 520 : nil,
            height: presentation == .popover ? popoverHeight : nil
        )
        .background(.ultraThinMaterial)
        .overlay {
            if presentation == .window {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.primary.opacity(0.24), lineWidth: 1)
                    .padding(0.5)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(settings.appearanceMode.colorScheme)
        .onReceive(Self.timer) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshMacMicrophoneInput()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            refreshMacMicrophoneInput()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            refreshMacMicrophoneInput()
        }
    }

    private var popoverHeight: CGFloat {
        switch mode {
        case .screenshot:
            settings.showScreenshotSetup ? 500 : 330
        case .recording:
            settings.showRecordingSetup ? 600 : 370
        case .phoneControl:
            410
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(mode.tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(mode.setupTitle)
                    .font(.title2.weight(.semibold))
                Text(mode.setupDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            deviceStatus
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var deviceStatus: some View {
        if mode != .phoneControl {
            let count = model.selectedCaptureDeviceSerials(for: mode).count
            Label(
                count == 1 ? "1 display" : "\(count) displays",
                systemImage: count > 1 ? "rectangle.on.rectangle" : "display"
            )
            .font(.callout.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .liquidGlassPanel(in: Capsule(), fallbackMaterial: .regularMaterial)
        } else if let device = model.selectedDevice, device.state == .device {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text(device.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .liquidGlassPanel(in: Capsule(), fallbackMaterial: .regularMaterial)
        } else {
            Label("Not connected", systemImage: "exclamationmark.circle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var selectedSettings: some View {
        if mode == .recording {
            recordingSettings
                .disabled(recordingSettingsAreLocked)
                .opacity(recordingSettingsAreLocked ? 0.62 : 1)
        }

        if mode != .screenshot {
            videoSettings
                .disabled(videoSettingsAreLocked)
                .opacity(videoSettingsAreLocked ? 0.62 : 1)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch mode {
        case .screenshot:
            Button {
                Task { await model.captureScreenshotWithOptions() }
            } label: {
                actionLabel(
                    title: model.isCapturingScreenshot ? "Capturing..." : "Capture Screenshot",
                    systemImage: "camera.fill",
                    isWorking: model.isCapturingScreenshot
                )
            }
            .liquidGlassProminentButton()
            .tint(.blue)
            .disabled(screenshotActionIsDisabled)
            .accessibilityIdentifier("phone-capture-primary-action")

        case .recording:
            if model.screenRecordingSession == nil {
                Button {
                    Task { await model.startScreenRecording() }
                } label: {
                    actionLabel(
                        title: model.isStartingScreenRecording ? "Starting..." : "Start Recording",
                        systemImage: "record.circle",
                        isWorking: model.isStartingScreenRecording
                    )
                }
                .liquidGlassProminentButton()
                .tint(.red)
                .disabled(recordingActionIsDisabled)
                .accessibilityIdentifier("phone-capture-primary-action")
            }

        case .phoneControl:
            HStack(spacing: 10) {
                Button {
                    Task { await model.launchScrcpy() }
                } label: {
                    actionLabel(
                        title: phoneControlActionTitle,
                        systemImage: "rectangle.connected.to.line.below",
                        isWorking: model.isLaunchingScrcpy
                    )
                }
                .liquidGlassProminentButton()
                .tint(.purple)
                .disabled(phoneControlActionIsDisabled)
                .accessibilityIdentifier("phone-capture-primary-action")

                if model.phoneControlSession != nil {
                    Button("Close", systemImage: "xmark") {
                        model.stopPhoneControl()
                    }
                    .liquidGlassButton()
                    .accessibilityIdentifier("phone-capture-close-action")
                }
            }
        }
    }

    private func actionLabel(title: String, systemImage: String, isWorking: Bool) -> some View {
        HStack(spacing: 8) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private func activeRecordingCard(_ session: ScreenRecordingSession) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.14))
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.red)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Recording \(session.deviceTitle)")
                        .font(.headline)
                    Text(elapsedText(startedAt: session.startedAt, now: now))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.red)
                }

                HStack(spacing: 14) {
                    Label(resolutionLabel(for: session.options), systemImage: "rectangle.inset.filled")
                    Label("\(session.options.effectiveVideoBitRateMbps) Mbps", systemImage: "speedometer")
                    if model.screenRecordingOptions.showTouches {
                        Label("Touches", systemImage: "hand.tap")
                    }
                    if model.phoneControlSession != nil {
                        Label("Phone Control", systemImage: "rectangle.connected.to.line.below")
                    }
                    let audioSourceCount = session.audioOptions.sourceCount(
                        for: Set(session.deviceSerials)
                    )
                    if audioSourceCount > 0 {
                        Label(
                            "\(audioSourceCount) audio source\(audioSourceCount == 1 ? "" : "s")",
                            systemImage: "waveform"
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                Task { await model.stopScreenRecording() }
            } label: {
                if model.isFinishingScreenRecording {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Saving...")
                    }
                } else {
                    Label("Stop", systemImage: "stop.fill")
                }
            }
            .liquidGlassProminentButton()
            .tint(.red)
            .disabled(model.isFinishingScreenRecording)
        }
        .padding(16)
        .liquidGlassTintedPanel(
            tint: .red,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            fallbackMaterial: .regularMaterial
        )
    }

    private var phoneControlDevicesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Device Windows", systemImage: "rectangle.on.rectangle.angled")
                    .font(.headline)
                Spacer()
                Text("\(model.phoneControlSessions.count) open")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(readyPhoneControlDevices) { device in
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.title)
                            .font(.callout.weight(.semibold))
                        if let battery = model.batteryStatuses[device.id] {
                            Label("\(battery.levelPercent)%", systemImage: battery.symbolName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Connected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    phoneControlSettingsMenu(for: device)
                    if model.phoneControlSession(for: device.serial) != nil {
                        Button("Show") {
                            model.showPhoneControl(deviceSerial: device.serial)
                        }
                        .liquidGlassButton()
                        Button {
                            model.stopPhoneControl(deviceSerial: device.serial)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .liquidGlassButton()
                        .help("Close Phone Control for \(device.title)")
                        .accessibilityLabel("Close Phone Control for \(device.title)")
                    } else {
                        Button("Open") {
                            Task { await model.launchScrcpy(deviceSerial: device.serial) }
                        }
                        .liquidGlassButton()
                        .disabled(model.isLaunchingScrcpy)
                    }
                }
            }
        }
        .padding(16)
        .liquidGlassPanel(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            fallbackMaterial: .regularMaterial
        )
    }

    private var captureDevicesCard: some View {
        let selectedSerials = model.selectedCaptureDeviceSerials(for: mode)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Displays", systemImage: "rectangle.on.rectangle")
                    .font(.headline)
                Spacer()
                Text("\(selectedSerials.count) selected")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(readyPhoneControlDevices) { device in
                Toggle(isOn: captureDeviceBinding(device.serial)) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.title)
                                .font(.callout.weight(.semibold))
                            if let battery = model.batteryStatuses[device.id] {
                                Label("\(battery.levelPercent)%", systemImage: battery.symbolName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Connected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(captureTransitionIsRunning || model.screenRecordingSession != nil)
            }

            if readyPhoneControlDevices.count > 1 {
                Text("Select more than one display to create a side-by-side capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .liquidGlassPanel(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            fallbackMaterial: .regularMaterial
        )
    }

    private func captureDeviceBinding(_ serial: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedCaptureDeviceSerials(for: mode).contains(serial) },
            set: { model.setCaptureDevice(serial, selected: $0, for: mode) }
        )
    }

    private func phoneControlSettingsMenu(for device: AndroidDevice) -> some View {
        let hasActiveSession = model.phoneControlSession(for: device.serial) != nil
        return Menu {
            Toggle(
                "Wake display when opening",
                isOn: phoneControlOptionBinding(for: device.serial, \.wakesDeviceOnOpen)
            )
            Toggle(
                "Device audio",
                isOn: phoneControlOptionBinding(for: device.serial, \.capturesAudio)
            )
            Toggle(
                "Mouse and keyboard input",
                isOn: phoneControlOptionBinding(for: device.serial, \.acceptsInput)
            )
            Toggle(
                "Clipboard sync",
                isOn: phoneControlOptionBinding(for: device.serial, \.synchronizesClipboard)
            )

            Divider()

            Toggle(
                "Keep device awake while connected",
                isOn: phoneControlOptionBinding(for: device.serial, \.staysAwake)
            )
            Toggle(
                "Turn device screen off while connected",
                isOn: phoneControlOptionBinding(for: device.serial, \.turnsDeviceScreenOff)
            )
            Toggle(
                "Keep window above others",
                isOn: phoneControlOptionBinding(for: device.serial, \.alwaysOnTop)
            )

            Divider()

            Picker(
                "Frame Rate",
                selection: phoneControlOptionBinding(for: device.serial, \.frameRateLimit)
            ) {
                ForEach(PhoneControlFrameRateLimit.allCases) { limit in
                    Text(limit.title).tag(limit)
                }
            }
            Picker(
                "Video Format",
                selection: phoneControlOptionBinding(for: device.serial, \.videoCodec)
            ) {
                ForEach(PhoneControlVideoCodec.allCases) { codec in
                    Text(codec.title).tag(codec)
                }
            }

            if hasActiveSession {
                Divider()
                Text("Changes apply the next time this window opens.")
            }
        } label: {
            Image(systemName: "gearshape")
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Phone Control settings for \(device.title)")
        .accessibilityLabel("Phone Control settings for \(device.title)")
    }

    private func phoneControlOptionBinding<Value>(
        for deviceSerial: String,
        _ keyPath: WritableKeyPath<PhoneControlDeviceOptions, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings.phoneControlOptions(for: deviceSerial)[keyPath: keyPath] },
            set: { settings.setPhoneControlOption($0, for: deviceSerial, keyPath: keyPath) }
        )
    }

    private var readyPhoneControlDevices: [AndroidDevice] {
        model.devices.filter { $0.state == .device }
    }

    private var showsOptionalCaptureSettings: Bool {
        switch mode {
        case .screenshot:
            settings.showScreenshotSetup
        case .recording:
            settings.showRecordingSetup
        case .phoneControl:
            true
        }
    }

    private func captureActivityCard(_ activity: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(activity)
                .font(.callout.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .liquidGlassPanel(
            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
            fallbackMaterial: .regularMaterial
        )
    }

    private var disconnectedCard: some View {
        Label("Connect a device with debugging to use these controls.", systemImage: "cable.connector.slash")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .liquidGlassPanel(
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                fallbackMaterial: .regularMaterial
            )
    }

    private var recordingSettings: some View {
        CaptureDisclosureSection(
            title: "Recording Settings",
            summary: recordingSettingsSummary,
            systemImage: "timer",
            isExpanded: $isRecordingSettingsExpanded
        ) {
            HStack(spacing: 18) {
                Picker("Duration", selection: optionBinding(\.durationMode)) {
                    ForEach(ScreenRecordingDurationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                if selectedOptions.durationMode == .fixed {
                    Stepper(value: optionBinding(\.fixedDurationSeconds), in: 5...180, step: 5) {
                        Text("\(selectedOptions.effectiveFixedDurationSeconds) seconds")
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: 4)
            }
        }
    }

    private var audioSettings: some View {
        CaptureDisclosureSection(
            title: "Audio",
            summary: audioSettingsSummary,
            systemImage: "waveform",
            isExpanded: $isAudioSettingsExpanded
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(selectedRecordingDevices) { device in
                    VStack(alignment: .leading, spacing: 9) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.title)
                                .fontWeight(.semibold)
                            Text(device.serial)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        HStack(spacing: 22) {
                            Toggle(
                                "System audio",
                                isOn: phoneSystemAudioBinding(for: device.serial)
                            )
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("System audio for \(device.title)")
                            .accessibilityIdentifier("screen-recording-system-audio-\(device.serial)")

                            Toggle(
                                "Microphone",
                                isOn: phoneMicrophoneBinding(for: device.serial)
                            )
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Phone microphone for \(device.title)")
                            .accessibilityIdentifier("screen-recording-phone-microphone-\(device.serial)")

                            Spacer(minLength: 0)
                        }

                        if phoneControlAudioConflict(for: device.serial) {
                            HStack(spacing: 10) {
                                Label(
                                    "Phone Control is using this phone's audio.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)

                                Spacer(minLength: 8)

                                Button {
                                    Task {
                                        await model.restartPhoneControlWithoutAudioForRecording(
                                            deviceSerial: device.serial
                                        )
                                    }
                                } label: {
                                    if model.phoneControlsRestartingWithoutAudio.contains(device.serial) {
                                        HStack(spacing: 6) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Restarting...")
                                        }
                                    } else {
                                        Text("Restart Without Audio")
                                    }
                                }
                                .controlSize(.small)
                                .disabled(model.hasPhoneControlTransitionInProgress)
                                .accessibilityLabel("Restart Phone Control for \(device.title) without audio")
                            }

                            Text("Phone Control will reopen without sound so the recording can use this source. Reopen it after recording to restore audio.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This Mac")
                            .fontWeight(.semibold)
                        Text(macMicrophoneInputDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Toggle(
                        "Microphone",
                        isOn: macMicrophoneBinding
                    )
                    .toggleStyle(.checkbox)
                    .disabled(macMicrophoneInputName == nil)
                    .accessibilityLabel("Mac microphone")
                    .accessibilityIdentifier("screen-recording-mac-microphone")
                }

                Text("System audio requires Android 11 or later and is muted on the phone while recording. Some phones may not support system audio and microphone together. The Mac uses the input selected in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var videoSettings: some View {
        CaptureDisclosureSection(
            title: "Video Settings",
            summary: videoSettingsSummary,
            systemImage: "slider.horizontal.3",
            isExpanded: $isVideoSettingsExpanded
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Resolution", selection: optionBinding(\.resolutionPreset)) {
                    ForEach(CaptureResolutionPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.menu)

                if selectedOptions.resolutionPreset == .custom {
                    Stepper(value: optionBinding(\.customWidth), in: 320...3840, step: 16) {
                        Text("Width: \(selectedOptions.effectiveCustomWidth) px")
                            .monospacedDigit()
                    }
                    Stepper(value: optionBinding(\.customHeight), in: 240...2160, step: 16) {
                        Text("Height: \(selectedOptions.effectiveCustomHeight) px")
                            .monospacedDigit()
                    }
                }

                Stepper(value: optionBinding(\.videoBitRateMbps), in: 1...80) {
                    Text("Bitrate: \(selectedOptions.effectiveVideoBitRateMbps) Mbps")
                        .monospacedDigit()
                }
            }
        }
    }

    private var phoneDisplaySettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(displaySettingsTitle, systemImage: displaySettingsSystemImage)
                    .font(.headline)
                Spacer()
                if model.isApplyingCapturePresentation {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Picker("Appearance", selection: liveOptionBinding(\.deviceAppearance)) {
                ForEach(ScreenRecordingDeviceAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 22) {
                Toggle("Demo mode", isOn: liveOptionBinding(\.demoMode))
                    .help("Use a clean status bar while this feature is active.")

                if mode != .screenshot {
                    Toggle("Show touches", isOn: liveOptionBinding(\.showTouches))
                        .help("Show touch indicators on the phone screen.")
                }
            }
            .toggleStyle(.checkbox)
        }
        .font(.callout)
        .padding(16)
        .liquidGlassPanel(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            fallbackMaterial: .regularMaterial
        )
        .disabled(captureTransitionIsRunning)
        .opacity(captureTransitionIsRunning ? 0.62 : 1)
    }

    private var skipSetupControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Skip this setup next time", isOn: skipSetupBinding)
                .toggleStyle(.checkbox)
                .font(.callout.weight(.medium))
            Text("You can show it again in Settings > Behavior.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
    }

    private var screenshotActionIsDisabled: Bool {
        model.selectedCaptureDeviceSerials(for: .screenshot).isEmpty
            || model.isCapturingScreenshot
            || model.isLaunchingScrcpy
            || model.isStartingScreenRecording
            || model.isFinishingScreenRecording
            || model.screenRecordingSession != nil
            || model.hasPhoneControlTransitionInProgress
    }

    private var recordingActionIsDisabled: Bool {
        model.selectedCaptureDeviceSerials(for: .recording).isEmpty
            || model.isCapturingScreenshot
            || model.isLaunchingScrcpy
            || model.isStartingScreenRecording
            || model.isFinishingScreenRecording
            || model.screenRecordingSession != nil
            || model.hasPhoneControlTransitionInProgress
            || hasPhoneControlAudioConflict
    }

    private var phoneControlActionIsDisabled: Bool {
        !model.hasReadyADBDevice
            || model.isCapturingScreenshot
            || model.isLaunchingScrcpy
            || model.isStartingScreenRecording
            || model.isFinishingScreenRecording
            || model.hasPhoneControlTransitionInProgress
    }

    private var captureTransitionIsRunning: Bool {
        model.isCapturingScreenshot
            || model.isLaunchingScrcpy
            || model.isStartingScreenRecording
            || model.isFinishingScreenRecording
            || model.hasPhoneControlTransitionInProgress
    }

    private var displaySettingsTitle: String {
        if mode == .phoneControl { return "Device Display" }
        return model.selectedCaptureDeviceSerials(for: mode).count > 1
            ? "Selected Displays"
            : "Device Display"
    }

    private var displaySettingsSystemImage: String {
        model.selectedCaptureDeviceSerials(for: mode).count > 1
            ? "rectangle.on.rectangle"
            : "display"
    }

    private var recordingSettingsAreLocked: Bool {
        captureTransitionIsRunning || model.screenRecordingSession != nil
    }

    private var videoSettingsAreLocked: Bool {
        if captureTransitionIsRunning { return true }
        switch mode {
        case .screenshot: return false
        case .recording: return model.screenRecordingSession != nil
        case .phoneControl: return model.phoneControlSession != nil
        }
    }

    private var currentActivity: String? {
        switch mode {
        case .screenshot:
            return model.isCapturingScreenshot ? "Capturing screenshot..." : nil
        case .recording:
            if model.isStartingScreenRecording { return "Starting the recording..." }
            if model.isFinishingScreenRecording { return "Saving the recording..." }
            return nil
        case .phoneControl:
            return model.isLaunchingScrcpy ? "Opening Phone Control..." : nil
        }
    }

    private var phoneControlActionTitle: String {
        if model.isLaunchingScrcpy { return "Opening..." }
        if model.phoneControlSession != nil { return "Show Phone Control" }
        return "Open Phone Control"
    }

    private var videoSettingsSummary: String {
        "\(selectedOptions.resolutionPreset.title), \(selectedOptions.effectiveVideoBitRateMbps) Mbps"
    }

    private var recordingSettingsSummary: String {
        if selectedOptions.durationMode == .fixed {
            return "\(selectedOptions.effectiveFixedDurationSeconds) seconds"
        }
        return "Until stopped"
    }

    private var selectedRecordingDevices: [AndroidDevice] {
        let selectedSerials = model.selectedCaptureDeviceSerials(for: .recording)
        return readyPhoneControlDevices.filter { selectedSerials.contains($0.serial) }
    }

    private var audioSettingsSummary: String {
        let selectedSerials = Set(selectedRecordingDevices.map(\.serial))
        let count = model.screenRecordingAudioOptions.sourceCount(for: selectedSerials)
        return count == 0 ? "Off" : "\(count) source\(count == 1 ? "" : "s")"
    }

    private func phoneSystemAudioBinding(for deviceSerial: String) -> Binding<Bool> {
        Binding(
            get: {
                model.screenRecordingPhoneAudioSource(for: deviceSerial).capturesSystemAudio
            },
            set: { capturesSystemAudio in
                let current = model.screenRecordingPhoneAudioSource(for: deviceSerial)
                model.setScreenRecordingPhoneAudioSource(
                    PhoneRecordingAudioSource(
                        capturesSystemAudio: capturesSystemAudio,
                        capturesPhoneMicrophone: current.capturesPhoneMicrophone
                    ),
                    for: deviceSerial
                )
            }
        )
    }

    private func phoneMicrophoneBinding(for deviceSerial: String) -> Binding<Bool> {
        Binding(
            get: {
                model.screenRecordingPhoneAudioSource(for: deviceSerial).capturesPhoneMicrophone
            },
            set: { capturesPhoneMicrophone in
                let current = model.screenRecordingPhoneAudioSource(for: deviceSerial)
                model.setScreenRecordingPhoneAudioSource(
                    PhoneRecordingAudioSource(
                        capturesSystemAudio: current.capturesSystemAudio,
                        capturesPhoneMicrophone: capturesPhoneMicrophone
                    ),
                    for: deviceSerial
                )
            }
        )
    }

    private var hasPhoneControlAudioConflict: Bool {
        selectedRecordingDevices.contains { device in
            phoneControlAudioConflict(for: device.serial)
        }
    }

    private func phoneControlAudioConflict(for deviceSerial: String) -> Bool {
        model.screenRecordingPhoneAudioSource(for: deviceSerial) != .none
            && model.phoneControlSession(for: deviceSerial)?.capturesAudio == true
    }

    private var macMicrophoneInputDetail: String {
        if let name = macMicrophoneInputName {
            return "System input: \(name)"
        }
        return "No microphone available"
    }

    private func refreshMacMicrophoneInput() {
        macMicrophoneInputName = MacMicrophoneCaptureService.defaultInputName
    }

    private var macMicrophoneBinding: Binding<Bool> {
        Binding(
            get: { model.screenRecordingAudioOptions.capturesMacMicrophone },
            set: { model.screenRecordingAudioOptions.capturesMacMicrophone = $0 }
        )
    }

    private var selectedOptions: ScreenRecordingOptions {
        options(for: mode)
    }

    private func options(for mode: PhoneCaptureMode) -> ScreenRecordingOptions {
        switch mode {
        case .screenshot: model.screenshotOptions
        case .recording: model.screenRecordingOptions
        case .phoneControl: model.phoneControlOptions
        }
    }

    private func setOptions(_ options: ScreenRecordingOptions, for mode: PhoneCaptureMode) {
        switch mode {
        case .screenshot: model.screenshotOptions = options
        case .recording: model.screenRecordingOptions = options
        case .phoneControl: model.phoneControlOptions = options
        }
    }

    private func optionBinding<Value>(_ keyPath: WritableKeyPath<ScreenRecordingOptions, Value>) -> Binding<Value> {
        Binding {
            selectedOptions[keyPath: keyPath]
        } set: { value in
            var options = selectedOptions
            options[keyPath: keyPath] = value
            setOptions(options, for: mode)
        }
    }

    private func liveOptionBinding<Value>(_ keyPath: WritableKeyPath<ScreenRecordingOptions, Value>) -> Binding<Value> {
        Binding {
            selectedOptions[keyPath: keyPath]
        } set: { value in
            var options = selectedOptions
            options[keyPath: keyPath] = value
            setOptions(options, for: mode)
            if modeIsActive {
                model.capturePresentationOptionDidChange(options: options)
            }
        }
    }

    private var skipSetupBinding: Binding<Bool> {
        Binding {
            switch mode {
            case .screenshot: !settings.showScreenshotSetup
            case .recording: !settings.showRecordingSetup
            case .phoneControl: !settings.showPhoneControlSetup
            }
        } set: { shouldSkip in
            switch mode {
            case .screenshot: settings.showScreenshotSetup = !shouldSkip
            case .recording: settings.showRecordingSetup = !shouldSkip
            case .phoneControl: settings.showPhoneControlSetup = !shouldSkip
            }
        }
    }

    private var modeIsActive: Bool {
        switch mode {
        case .screenshot: false
        case .recording: model.screenRecordingSession != nil
        case .phoneControl: model.phoneControlSession != nil
        }
    }

    private static let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
}

private struct CaptureDisclosureSection<Content: View>: View {
    let title: String
    let summary: String
    let systemImage: String
    @Binding var isExpanded: Bool
    var isWorking = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 24)
                    Text(title)
                        .font(.headline)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .liquidGlassButton()
            .buttonBorderShape(.roundedRectangle)

            if isExpanded {
                content()
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private func elapsedText(startedAt: Date, now: Date) -> String {
    let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
    return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
}

private func resolutionLabel(for options: ScreenRecordingOptions) -> String {
    switch options.resolutionPreset {
    case .native:
        return "Native"
    case .hd720:
        return "720p"
    case .fullHD1080:
        return "1080p"
    case .custom:
        return "\(options.effectiveCustomWidth)x\(options.effectiveCustomHeight)"
    }
}
