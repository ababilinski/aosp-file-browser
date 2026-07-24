import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

public struct RootView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var settings: AppSettings
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isAppPackageDropTargeted = false

    public init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    MainSurface(model: model)
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)

                    if model.shouldShowDetailInspector {
                        Divider()
                        DetailInspector(model: model)
                            .frame(minWidth: 320, idealWidth: 380, maxWidth: 480, maxHeight: .infinity)
                    }
                }

                TransferPanelView(queue: model.transferQueue)
            }
        }
        .id(settings.edgeToEdgeSidebar)
        .toolbar {
            AppToolbar(model: model)
        }
        .compatibleToolbarRemovingSidebarToggle()
        .overlay(alignment: .topTrailing) {
            PhoneCapturePopoverHost(model: model)
                .padding(.top, 8)
                .padding(.trailing, 24)
        }
        .compatibleWindowMaterialBackground()
        .overlay {
            if isAppPackageDropTargeted {
                AppPackageDropOverlay(deviceName: model.selectedDevice?.title)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .localFileDropTarget(
            isEnabled: !model.isAppPackageInstallInProgress,
            acceptsDrop: AppPackageInstaller.isSupportedSelection
        ) { targeted in
            withAnimation(.snappy(duration: 0.18)) {
                isAppPackageDropTargeted = targeted
            }
        } onDrop: { urls in
            Task { await model.installDroppedAppPackages(urls: urls) }
        }
        .fileImporter(
            isPresented: $model.showUploadImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                let targetPath = model.uploadTargetPath
                model.uploadTargetPath = nil
                Task { await model.upload(urls: urls, to: targetPath) }
            } else {
                model.uploadTargetPath = nil
            }
        }
        .fileImporter(
            isPresented: $model.showAPKImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "apk") ?? .data,
                UTType(filenameExtension: "xapk") ?? .data,
                UTType(filenameExtension: "apks") ?? .data,
                .zip
            ],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await model.installAppPackages(urls: urls) }
            }
        }
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"), action: { alert.onDismiss?() })
            )
        }
        .sheet(isPresented: $model.pendingNewFolder) {
            NameEntrySheet(title: "New Folder", defaultValue: "Untitled Folder") { name in
                Task { await model.createFolder(named: name) }
            }
        }
        .sheet(item: $model.pendingRename) { file in
            NameEntrySheet(title: "Rename", defaultValue: file.name) { name in
                Task { await model.rename(file: file, to: name) }
            }
        }
        .sheet(item: $model.pendingArchiveRequest) { request in
            NameEntrySheet(title: "Compress", defaultValue: request.defaultName) { name in
                Task { await model.compressSelected(as: name) }
            }
        }
        .sheet(item: $model.pendingBatchRenameRequest) { request in
            BatchRenameSheet(model: model, request: request)
        }
        .sheet(item: $model.pendingAppInstallRecovery) { request in
            AppInstallRecoverySheet(model: model, request: request)
        }
        .sheet(item: $model.wirelessADBSetupPresentation, onDismiss: {
            model.wirelessADBSetupSheetDidDismiss()
        }) { presentation in
            WirelessADBSetupSheet(model: model, deviceID: presentation.deviceID)
        }
        .sheet(item: $model.adbQRPairingSession, onDismiss: {
            model.adbQRPairingSheetDidDismiss()
        }) { session in
            ADBQRPairingSheet(model: model, session: session)
        }
        .sheet(item: $model.toolSetupRequest, onDismiss: {
            model.toolSetupSheetDidDismiss()
        }) { request in
            ToolSetupSheet(model: model, request: request)
        }
        .onAppear {
            model.startBackgroundRefreshLoop()
        }
        .onDisappear {
            model.stopBackgroundRefreshLoop()
        }
        .onReceive(model.usbTransferManager.$devices) { _ in
            DispatchQueue.main.async {
                model.updateForConnectionMode()
            }
        }
        .onReceive(model.settings.$showUSBTransferWhenADBConnected) { _ in
            DispatchQueue.main.async {
                model.updateForConnectionMode()
            }
        }
        .onReceive(model.settings.$mediaCacheLimitMB.dropFirst()) { _ in
            Task { await model.enforceMediaCacheLimit() }
        }
        .background {
            MainWindowKeyCapture(
                shouldHandleFileModeShortcuts: {
                    model.isActiveFileModeSelected
                },
                onQuickLook: {
                    model.toggleQuickLookPreview()
                },
                onDelete: {
                    Task { await model.deleteActiveFileSelection() }
                },
                onNewFolder: {
                    model.requestActiveFileModeNewFolder()
                },
                onCopy: {
                    model.copyActiveFileSelection()
                },
                onCopyToQueue: {
                    model.copyActiveFileSelectionToQueue()
                },
                onCut: {
                    if !model.isUSBTransferSelected {
                        model.cutSelected()
                    }
                },
                onPaste: {
                    Task { await model.pasteFromPasteboardOrClipboard() }
                },
                onRefresh: {
                    Task { await model.refreshCurrentSurfaceSafely() }
                },
                onFolderUp: {
                    model.navigateUp()
                },
                onSelectAll: {
                    model.selectAllActiveFileItems()
                },
                onRename: {
                    model.requestActiveFileModeRename()
                },
                onSwitchTab: {
                    model.switchActiveFileModeTab()
                },
                onOpen: {
                    model.openActiveFileSelection()
                },
                onMoveSelection: { delta, extending in
                    model.moveActiveFileSelection(by: delta, extending: extending)
                },
                onUndo: {
                    Task { await model.undoLastFileOperation() }
                },
                onRedo: {
                    Task { await model.redoLastFileOperation() }
                }
            )
            .frame(width: 0, height: 0)
        }
    }

}

private struct PhoneCapturePopoverHost: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            .popover(
                item: $model.activePhoneCapturePopoverMode,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) { mode in
                PhoneCaptureControlsView(model: model, presentation: .popover, mode: mode)
                    .accessibilityIdentifier("phone-capture-controls")
            }
    }
}

private struct ToolSetupSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var toolchainManager: ToolchainManager
    let request: ToolSetupRequest
    @State private var isChoosingExistingCopy = false

    init(model: AppModel, request: ToolSetupRequest) {
        self.model = model
        self.toolchainManager = model.toolchainManager
        self.request = request
    }

    private var currentRequest: ToolSetupRequest {
        model.toolSetupRequest ?? request
    }

    private var isInstalling: Bool {
        ToolchainTool.allCases.contains { tool in
            if case .installing = toolchainManager.status(for: tool) { return true }
            return false
        }
    }

    private var issueMessage: String? {
        toolchainManager.lastInstallError ?? currentRequest.issue
    }

    private var installButtonTitle: String {
        if shouldUseManagedCopy {
            return "Use Managed Copy"
        }
        return toolchainManager.hasManagedTools ? "Repair Phone Tools" : "Install Phone Tools"
    }

    private var shouldUseManagedCopy: Bool {
        guard toolchainManager.hasManagedTools else { return false }
        switch currentRequest.tool {
        case .adb:
            return model.settings.adbToolMode != .automatic
        case .scrcpy:
            return model.settings.scrcpyToolMode != .automatic
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(issueMessage == nil ? "Set Up Phone Tools" : "Phone Tools Need Attention")
                        .font(.title2.weight(.semibold))
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let issueMessage {
                Label(issueMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Downloads from the official scrcpy release", systemImage: "checkmark.shield")
                Label("Verified before anything is installed", systemImage: "checkmark.shield")
                Label("Kept in Application Support", systemImage: "folder")
                Label("No administrator password or phone app needed", systemImage: "person.crop.circle.badge.checkmark")
            }
            .font(.callout)

            Text("The download is about 13 MB and includes ADB, scrcpy, and the matching Phone Control files.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if isInstalling {
                    ProgressView()
                        .controlSize(.small)
                    Text("Setting up…")
                        .foregroundStyle(.secondary)
                } else {
                    if currentRequest.issue != nil || toolchainManager.lastInstallError != nil {
                        Button("Try Again") {
                            Task { await model.retryToolSetup() }
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(installButtonTitle) {
                        if shouldUseManagedCopy {
                            Task { await model.useManagedToolsForCurrentRequest() }
                        } else {
                            Task { await model.installManagedTools() }
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Choose Existing…") {
                        chooseExistingCopy()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isChoosingExistingCopy)
                }

                Spacer()

                Button("Not Now") {
                    model.dismissToolSetup()
                }
                .disabled(isInstalling)
            }

            HStack(spacing: 16) {
                Link("Official release", destination: URL(string: "https://github.com/Genymobile/scrcpy/releases/tag/v4.1")!)
                Link("Licenses", destination: URL(string: "https://github.com/Genymobile/scrcpy/blob/v4.1/LICENSE")!)
                Link("ADB terms", destination: URL(string: "https://developer.android.com/studio/terms")!)
            }
            .font(.caption)
        }
        .padding(28)
        .frame(width: 520)
        .interactiveDismissDisabled(isInstalling)
    }

    private var summary: String {
        switch currentRequest.tool {
        case .adb:
            "Debugging connections need ADB. The app can set it up, or you can choose a copy already on this Mac. File Transfer still works without it."
        case .scrcpy:
            "Phone Control needs scrcpy and its matching support files. The app can set them up, or you can choose an existing copy."
        }
    }

    private func chooseExistingCopy() {
        isChoosingExistingCopy = true
        defer { isChoosingExistingCopy = false }

        let panel = NSOpenPanel()
        panel.title = "Choose \(currentRequest.tool.title)"
        panel.prompt = "Use"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.useExistingTool(url, for: currentRequest.tool) }
    }
}

private struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var usbTransferManager: USBTransferManager
    @State private var showsFileTransferAppsInfo = false
    @State private var isConfirmingSidebarEmptyTrash = false

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
        self.usbTransferManager = model.usbTransferManager
    }

    var body: some View {
        List(selection: sidebarSelectionBinding) {
            Section("Devices") {
                ConnectionModeMenu(model: model)

                if showsUSBTransferDevices {
                    ForEach(usbTransferManager.devices) { device in
                        USBTransferDeviceRow(
                            device: device,
                            isSelected: usbTransferManager.selectedDeviceID == device.id,
                            onSelect: { usbTransferManager.selectDevice(id: device.id) }
                        )
                    }
                } else if isUSBTransferStatusMode {
                    Label(usbTransferStatus, systemImage: "iphone.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.devices.isEmpty {
                    Label(disconnectedSidebarTitle, systemImage: "iphone.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.devices) { device in
                        DeviceRow(
                            model: model,
                            device: device,
                            batteryStatus: model.batteryStatuses[device.id],
                            wirelessSetupState: model.wirelessADBSetupStates[device.id],
                            isSelected: model.selectedDeviceID == device.id
                        )
                    }
                }

                Divider()
                    .padding(.vertical, 2)
            }

            if showsStorageUsage {
                Section("Storage Usage") {
                    ForEach(model.storageSummaries) { summary in
                        StorageRow(
                            model: model,
                            summary: summary,
                            breakdown: model.storageBreakdowns[summary.id]
                        )
                        .tag(SidebarDestination.storage(summary.id))
                    }
                }
            }

            if showsADBOnlyOptions {
                if !adbFavoriteLocations.isEmpty {
                    Section("Favorites") {
                        ForEach(adbFavoriteLocations) { location in
                            QuickAccessRow(model: model, location: location, sectionName: "Favorites")
                                .tag(SidebarDestination.location(location))
                        }
                    }
                    .dropDestination(for: String.self) { paths, _ in
                        let didAdd = paths.reduce(false) { added, path in
                            model.addQuickAccess(path: path) || added
                        }
                        if !didAdd {
                            model.statusMessage = "Drop a folder here to add it to Favorites."
                        }
                        return didAdd
                    }
                }

                Section("Locations") {
                    if showsADBLocationsSection {
                        ForEach(adbLocationLocations) { location in
                            QuickAccessRow(
                                model: model,
                                location: location,
                                sectionName: "Locations",
                                hiddenDefaultID: location.id.hasPrefix("storage:") ? "sdcard" : nil
                            )
                            .tag(SidebarDestination.location(location))
                        }
                    }

                    Label("Trash", systemImage: "trash")
                        .badge(settings.showTrashItemCount ? model.trashRecords.count : 0)
                        .tag(SidebarDestination.trash)
                        .contextMenu {
                            Button("Empty Trash", role: .destructive) {
                                isConfirmingSidebarEmptyTrash = true
                            }
                            .disabled(model.trashRecords.isEmpty || model.isBusy)
                        }
                }

                if showsADBAppsSection {
                    Section("Apps") {
                        Label("Apps", systemImage: "app.dashed")
                            .tag(SidebarDestination.apps)

                        ForEach(adbAppLocations) { location in
                            QuickAccessRow(model: model, location: location, sectionName: "Apps")
                                .tag(SidebarDestination.location(location))
                        }
                    }
                }
            }

            if showsMTPFavorites {
                Section("Favorites") {
                    ForEach(mtpFavoriteLocations) { location in
                        MTPQuickAccessRow(
                            manager: usbTransferManager,
                            settings: settings,
                            location: location
                        )
                            .tag(SidebarDestination.usbTransferLocation(location))
                    }
                    if isLoadingMTPQuickLocations {
                        SidebarLoadingRow(title: "Finding favorites")
                    }
                }
            }

            if showsMTPLocationsSection {
                Section("Locations") {
                    ForEach(mtpLocationLocations) { location in
                        MTPQuickAccessRow(
                            manager: usbTransferManager,
                            settings: settings,
                            location: location
                        )
                            .tag(SidebarDestination.usbTransferLocation(location))
                    }
                    if isLoadingMTPQuickLocations {
                        SidebarLoadingRow(title: "Finding locations")
                    }
                }
            }

            if showsMTPAppsSection {
                Section("Apps") {
                    Button {
                        showsFileTransferAppsInfo = true
                    } label: {
                        HStack {
                            Label("Apps", systemImage: "app.dashed")
                            Spacer()
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                        }
                        .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Apps require Developer Options (ADB). Select to switch or start setup.")
                    .accessibilityHint("Shows why Developer Options are required and offers setup.")

                    ForEach(mtpAppLocations) { location in
                        MTPQuickAccessRow(
                            manager: usbTransferManager,
                            settings: settings,
                            location: location
                        )
                            .tag(SidebarDestination.usbTransferLocation(location))
                    }
                    if isLoadingMTPQuickLocations {
                        SidebarLoadingRow(title: "Finding app folders")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            StatusStrip(model: model)
        }
        .alert("Apps Need Developer Options", isPresented: $showsFileTransferAppsInfo) {
            Button(model.hasReadyADBDevice ? "Switch and Open Apps" : "Set Up Developer Options") {
                openADBApps()
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Installed apps are only available through Developer Options (ADB), not Android File Transfer. Switch connection methods to open Apps or start the guided Developer Options setup.")
        }
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $isConfirmingSidebarEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                emptyTrashFromSidebar()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every available item in Trash. Items on disconnected phones stay in Trash. This cannot be undone.")
        }
        .scrollContentBackground(settings.edgeToEdgeSidebar ? .hidden : .automatic)
    }

    private func emptyTrashFromSidebar() {
        Task {
            let result = await model.emptyTrash()
            guard !result.failures.isEmpty else { return }
            let details = result.failures.prefix(5).map { "\($0.record.name): \($0.message)" }
            let remaining = result.failures.count - details.count
            let suffix = remaining > 0 ? "\n\nAnd \(remaining) more." : ""
            model.alert = UserAlert(
                title: result.deletedCount == 0 ? "Trash Wasn't Emptied" : "Some Items Weren't Deleted",
                message: details.joined(separator: "\n") + suffix
            )
        }
    }

    private var isUSBTransferStatusMode: Bool {
        model.connectionMode == .usbTransfer
    }

    private var sidebarSelectionBinding: Binding<SidebarDestination?> {
        Binding(
            get: { displayedSidebarSelection },
            set: { destination in
                guard let destination, destination != model.sidebarSelection else { return }
                model.open(destination: destination)
            }
        )
    }

    private var displayedSidebarSelection: SidebarDestination? {
        switch model.sidebarSelection {
        case .storage, .apps, .trash:
            return model.sidebarSelection
        case .location, .usbTransferLocation, .usbTransfer, nil:
            break
        }

        if isMTPMode {
            let path = usbTransferManager.pathComponents.last?.path ?? "/"
            return closestMTPShortcut(containing: path).map(SidebarDestination.usbTransferLocation)
        }

        guard showsADBOnlyOptions else { return nil }
        return closestADBShortcut(containing: model.currentPath).map(SidebarDestination.location)
    }

    private func closestADBShortcut(containing path: String) -> QuickLocation? {
        (adbFavoriteLocations + adbLocationLocations + adbAppLocations)
            .filter { isPath($0.path, anAncestorOf: path) }
            .max { $0.path.count < $1.path.count }
    }

    private func closestMTPShortcut(containing path: String) -> MTPQuickLocation? {
        (mtpFavoriteLocations + mtpLocationLocations + mtpAppLocations)
            .filter { isPath($0.path, anAncestorOf: path) }
            .max { $0.path.count < $1.path.count }
    }

    private func isPath(_ candidate: String, anAncestorOf currentPath: String) -> Bool {
        let normalizedCandidate = candidate == "/" ? "/" : candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedCurrent = currentPath == "/" ? "/" : currentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard normalizedCandidate != "/" else { return true }
        return normalizedCurrent == normalizedCandidate || normalizedCurrent.hasPrefix("\(normalizedCandidate)/")
    }

    private var showsUSBTransferDevices: Bool {
        model.connectionMode == .usbTransfer && !usbTransferManager.devices.isEmpty
    }

    private var showsADBOnlyOptions: Bool {
        model.connectionMode == .adb && model.hasReadyADBDevice && !usbTransferManager.isADBReleasedForMTPSession
    }

    private var showsADBLocationsSection: Bool {
        !adbLocationLocations.isEmpty
    }

    private var showsADBAppsSection: Bool {
        !adbAppLocations.isEmpty || showsADBOnlyOptions
    }

    private var showsMTPFavorites: Bool {
        isMTPMode && (!mtpFavoriteLocations.isEmpty || isLoadingMTPQuickLocations)
    }

    private var showsMTPLocationsSection: Bool {
        isMTPMode && (!mtpLocationLocations.isEmpty || isLoadingMTPQuickLocations)
    }

    private var showsMTPAppsSection: Bool {
        isMTPMode
    }

    private var isMTPMode: Bool {
        !showsADBOnlyOptions && model.isUSBTransferSelected
    }

    private var isLoadingMTPQuickLocations: Bool {
        isMTPMode && settings.showDefaultQuickLocations && (
            usbTransferManager.isResolvingQuickLocations
                || (usbTransferManager.quickLocations.isEmpty
                    && (usbTransferManager.isBrowsing || usbTransferManager.isCataloging))
        )
    }

    private var showsStorageUsage: Bool {
        showsADBOnlyOptions && !model.storageSummaries.isEmpty
    }

    private var adbFavoriteLocations: [QuickLocation] {
        model.quickLocations.filter { $0.sidebarSection == .favorites }
    }

    private var adbAppLocations: [QuickLocation] {
        model.quickLocations.filter { $0.sidebarSection == .apps }
    }

    private var adbLocationLocations: [QuickLocation] {
        var locations: [QuickLocation] = []

        if let internalStorage = model.quickLocations.first(where: { $0.id == "home" }) {
            locations.append(internalStorage)
        }

        if !settings.hiddenDefaultQuickLocationIDs.contains("sdcard") {
            locations.append(contentsOf: model.storageSummaries.compactMap { summary in
                guard !isInternalStoragePath(summary.path) else { return nil }
                return QuickLocation(
                    id: "storage:\(summary.path)",
                    title: summary.title,
                    path: summary.path,
                    symbol: "sdcard",
                    subtitle: summary.subtitle
                )
            })
        }

        return locations
    }

    private var mtpFavoriteLocations: [MTPQuickLocation] {
        visibleMTPQuickLocations.filter { $0.sidebarSection == .favorites }
    }

    private var mtpLocationLocations: [MTPQuickLocation] {
        visibleMTPQuickLocations.filter { $0.sidebarSection == .locations }
    }

    private var mtpAppLocations: [MTPQuickLocation] {
        visibleMTPQuickLocations.filter { $0.sidebarSection == .apps }
    }

    private var visibleMTPQuickLocations: [MTPQuickLocation] {
        guard settings.showDefaultQuickLocations else { return [] }
        return usbTransferManager.quickLocations.filter { location in
            !settings.hiddenDefaultQuickLocationIDs.contains(location.id)
                && !settings.hiddenDefaultQuickLocationIDs.contains(location.baseID)
        }
    }

    private func isInternalStoragePath(_ path: String) -> Bool {
        path == "/storage/emulated/0" || path == "/storage/emulated" || path == "/sdcard"
    }

    private var usbTransferStatus: String {
        if let device = usbTransferManager.selectedDevice {
            return "\(device.name) · \(usbTransferManager.backend.displayName)"
        }
        if usbTransferManager.isADBReleasedForMTPSession {
            return usbTransferManager.statusMessage
        }
        if model.hasReadyADBDevice {
            return usbTransferManager.hasStartedBrowsing ? usbTransferManager.statusMessage : "File Transfer available"
        }
        return "Developer Options not connected"
    }

    private var disconnectedSidebarTitle: String {
        model.devices.isEmpty ? "No Debugging Connection" : "Debugging Not Ready"
    }

    private func openADBApps() {
        model.selectConnectionMode(.adb)
        if model.hasReadyADBDevice {
            model.sidebarSelection = .apps
        }
    }
}

private struct SidebarLoadingRow: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct QuickAccessRow: View {
    @ObservedObject var model: AppModel
    let location: QuickLocation
    let sectionName: String
    var hiddenDefaultID: String? = nil

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(location.title)
                if let subtitle = location.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } icon: {
            Image(systemName: location.symbol)
        }
        .contextMenu {
            Button("Show in Enclosing Folder") {
                model.showQuickLocationInEnclosingFolder(location)
            }

            Divider()

            Button("Remove from Sidebar") {
                model.hideOrRemoveQuickLocation(location, sectionName: sectionName, hiddenDefaultID: hiddenDefaultID)
            }

            Divider()

            Button("Get Info") {
                model.showQuickLocationInfo(location)
            }
        }
    }
}

private struct MTPQuickAccessRow: View {
    @ObservedObject var manager: USBTransferManager
    @ObservedObject var settings: AppSettings
    let location: MTPQuickLocation

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(location.title)
                if let subtitle = location.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } icon: {
            Image(systemName: location.symbol)
        }
        .contextMenu {
            Button("Show in Enclosing Folder") {
                manager.showQuickLocationInEnclosingFolder(location)
            }

            Divider()

            Button("Remove from Sidebar") {
                settings.hiddenDefaultQuickLocationIDs.insert(location.id)
            }

            Divider()

            Button("Get Info") {
                manager.showQuickLocationInfo(location)
            }
        }
    }
}

private struct DeviceRow: View {
    @ObservedObject var model: AppModel
    let device: AndroidDevice
    let batteryStatus: BatteryStatus?
    let wirelessSetupState: ADBWirelessSetupState?
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .frame(width: 18)
                .foregroundStyle(device.state == .device ? .primary : adaptiveWarningColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(connectionDetail)
                        .lineLimit(1)
                    if let batteryStatus, wirelessSetupState == nil {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        BatteryStatusBadge(status: batteryStatus)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            connectionAccessory
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard model.canSwitchADBDevice else { return }
            model.selectADBDevice(id: device.id)
        }
        .help(device.subtitle)
        .contextMenu {
            if device.connectionKind == .usb, device.state == .device {
                Button {
                    model.requestWirelessADBSetup(for: device.id)
                } label: {
                    Label("Connect via Wi-Fi…", systemImage: "wifi")
                }
            } else if device.connectionKind == .wifi {
                Label("Connected via Wi-Fi", systemImage: "wifi")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(device.title), \(connectionDetail)")
    }

    private var connectionDetail: String {
        if let wirelessSetupState {
            return wirelessSetupState.detail
        }
        return "\(device.connectionKind.label) · \(device.state.displayName)"
    }

    @ViewBuilder
    private var connectionAccessory: some View {
        switch wirelessSetupState {
        case .preparing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
                .help("Preparing ADB over Wi-Fi")
        case .ready:
            Image(systemName: "wifi")
                .foregroundStyle(adaptiveSuccessColor)
                .frame(width: 24, height: 24)
                .help("Connected over Wi-Fi. You can unplug the cable.")
        case .failed(let message):
            Button {
                model.requestWirelessADBSetup(for: device.id)
            } label: {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(adaptiveWarningColor)
            .help("Wi-Fi setup failed: \(message) Select to try again.")
            .accessibilityLabel("Retry Wi-Fi setup")
        case nil where device.connectionKind == .usb && device.state == .device:
            Button {
                model.requestWirelessADBSetup(for: device.id)
            } label: {
                Image(systemName: device.connectionKind.symbol)
            }
            .buttonStyle(.borderless)
            .frame(width: 24, height: 24)
            .help("Switch this USB debugging connection to Wi-Fi")
            .accessibilityLabel("Switch \(device.title) to ADB over Wi-Fi")
        case nil:
            Image(systemName: device.connectionKind.symbol)
                .foregroundStyle(device.state == .device ? Color.secondary : adaptiveWarningColor)
                .frame(width: 24, height: 24)
                .help("\(device.connectionKind.label) connection")
        }
    }

    private var adaptiveSuccessColor: Color {
        colorScheme == .light ? Color(red: 0.0, green: 0.45, blue: 0.20) : .green
    }

    private var adaptiveWarningColor: Color {
        colorScheme == .light ? Color(red: 0.72, green: 0.36, blue: 0.0) : .orange
    }
}

private struct BatteryStatusBadge: View {
    let status: BatteryStatus
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.symbolName)
            if status.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
            }
            Text("\(status.levelPercent)%")
                .monospacedDigit()
        }
        .foregroundStyle(statusColor)
        .help("\(status.statusLabel), \(status.levelPercent)%")
    }

    private var statusColor: Color {
        if status.isCharging {
            return colorScheme == .light ? Color(red: 0.0, green: 0.45, blue: 0.20) : .green
        }
        if status.levelPercent <= 20 {
            return colorScheme == .light ? Color(red: 0.72, green: 0.36, blue: 0.0) : .orange
        }
        return .secondary
    }
}

private struct USBTransferDeviceRow: View {
    let device: USBTransferDevice
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .frame(width: 18)
                .foregroundStyle(device.isReady ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("USB · \(device.statusLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "cable.connector")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help(device.subtitle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

}

private struct StorageRow: View {
    @ObservedObject var model: AppModel
    let summary: StorageSummary
    let breakdown: StorageBreakdown?

    var body: some View {
        Button {
            model.sidebarSelection = .storage(summary.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(summary.title)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if model.isLoadingStorageBreakdown(summary) {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Text("\(Int(summary.fractionUsed * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                StorageSegmentedUsageBar(summary: summary, breakdown: breakdown, height: 6)
                Text(summary.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .help("Open storage breakdown for \(summary.title)")
    }
}

private struct StorageBreakdownView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            storageHeader
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            ZStack {
                if let breakdown = model.selectedStorageBreakdown {
                    storageContent(breakdown)
                } else if let summary = model.selectedStorageSummary {
                    StorageAnalysisPlaceholder(
                        title: summary.title,
                        isLoading: model.isLoadingStorageBreakdown(summary)
                    ) {
                        Task { await model.showStorageBreakdown(for: summary, forceRefresh: true) }
                    }
                } else {
                    CompatibleContentUnavailableView("Storage Not Available", systemImage: "internaldrive", description: Text("Select a storage volume from the sidebar."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var storageHeader: some View {
        LiquidGlassContainer(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "iphone")
                    .foregroundStyle(.secondary)

                if let summary = model.selectedStorageSummary {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Label(summary.title, systemImage: "internaldrive")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                    Text(summary.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Storage")
                        .font(.callout.weight(.medium))
                }

                Spacer()

                if let selectedSummary = model.selectedStorageSummary {
                    if model.isLoadingStorageBreakdown(selectedSummary) {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        Task { await model.showStorageBreakdown(for: selectedSummary, forceRefresh: true) }
                    } label: {
                        Label("Refresh Storage Breakdown", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .liquidGlassButton()
                    .help("Refresh storage breakdown")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func storageContent(_ breakdown: StorageBreakdown) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "internaldrive")
                        .font(.largeTitle)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(breakdown.summary.title)
                            .font(.largeTitle.weight(.semibold))
                        Text(breakdown.summary.subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(breakdown.summary.fractionUsed * 100))%")
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                StorageSegmentedUsageBar(summary: breakdown.summary, breakdown: breakdown, height: 16)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(breakdown.visibleCategories) { category in
                        StorageCategoryRow(
                            category: category,
                            totalBytes: breakdown.summary.totalBytes,
                            isSelected: model.selectedStorageCategoryID == category.id,
                            isLoading: model.isLoadingStorageCategory(category, in: breakdown.summary)
                        ) {
                            Task { await model.selectStorageCategory(category, in: breakdown.summary) }
                        }
                    }
                }

                if let category = model.selectedStorageCategory {
                    StorageCategoryFilesPanel(
                        model: model,
                        category: category,
                        fileList: model.selectedStorageCategoryFileList,
                        isLoading: model.isLoadingSelectedStorageCategory
                    )
                }

                Text("Estimated from ADB-visible storage. Private app data and Android system areas are inferred from the volume total when Android does not expose exact folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StorageAnalysisPlaceholder: View {
    let title: String
    let isLoading: Bool
    let retry: () -> Void

    var body: some View {
        CompatibleContentUnavailableView {
            Label(isLoading ? "Analyzing \(title)" : "Storage Breakdown Not Loaded", systemImage: "internaldrive")
        } description: {
            Text(isLoading ? "Reading storage categories from the Android device." : "Click Refresh to analyze this storage volume.")
        } actions: {
            if isLoading {
                ProgressView()
                    .controlSize(.large)
            } else {
                Button("Refresh", action: retry)
                    .liquidGlassProminentButton()
            }
        }
    }
}

private struct StorageCategoryRow: View {
    let category: StorageBreakdownCategory
    let totalBytes: Int64
    let isSelected: Bool
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: category.kind.symbol)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(category.kind.displayColor)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(category.displayTitle)
                            .font(.headline)
                        Spacer()
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(category.displaySize)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: category.kind.canBrowseFiles ? "chevron.right" : "info.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.quaternary)
                            Capsule()
                                .fill(category.kind.displayColor)
                                .frame(width: max(3, proxy.size.width * category.fraction(of: totalBytes)))
                        }
                    }
                    .frame(height: 6)
                }
            }
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(category.kind.canBrowseFiles ? "Show largest \(category.displayTitle.lowercased()) files" : "Show information about \(category.displayTitle)")
    }
}

private struct StorageCategoryFilesPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    let category: StorageBreakdownCategory
    let fileList: StorageCategoryFileList?
    let isLoading: Bool
    @State private var sortColumn: StorageCategoryFileColumn = .size
    @State private var sortAscending = false
    @State private var columnWidths: [StorageCategoryFileColumn: CGFloat] = [:]
    @State private var resizeStartWidths: [StorageCategoryFileColumn: CGFloat]?
    @State private var visibleColumns = Set(StorageCategoryFileColumn.allCases.filter { $0 != .created })

    init(
        model: AppModel,
        category: StorageBreakdownCategory,
        fileList: StorageCategoryFileList?,
        isLoading: Bool
    ) {
        self.model = model
        self.settings = model.settings
        self.category = category
        self.fileList = fileList
        self.isLoading = isLoading
    }

    private var sortedFiles: [AndroidFile] {
        let files = fileList?.files ?? []
        return files.sorted { lhs, rhs in
            let result = compare(lhs, rhs, by: sortColumn)
            if result != .orderedSame {
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(category.displayTitle, systemImage: category.kind.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(category.kind.displayColor)
                Spacer()
                Text(category.displaySize)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if category.kind == .apps {
                ZStack {
                    StorageCategoryAppsPanel(model: model)
                        .opacity(model.isLoadingApps && model.packages.isEmpty ? 0 : 1)

                    if model.isLoadingApps {
                        StorageCategoryLoadingView(
                            title: model.packages.isEmpty ? "Loading apps..." : "Refreshing apps...",
                            detail: "Reading the app list and storage details from your Android device."
                        )
                        .transition(.opacity)
                    }
                }
            } else if isLoading {
                StorageCategoryLoadingView(
                    title: "Loading \(category.displayTitle.lowercased()) files...",
                    detail: "Finding the largest accessible files in this storage category."
                )
            } else if let files = fileList?.files, !files.isEmpty {
                Text("Largest accessible files. Select a row to see details, thumbnails, preview, and download actions in the inspector.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                GeometryReader { proxy in
                    let layout = StorageCategoryFileColumnMetrics.layout(
                        for: displayedColumns,
                        availableWidth: proxy.size.width,
                        preferredWidths: columnWidths
                    )
                    VStack(spacing: 0) {
                        StorageCategoryFileHeader(
                            layout: layout,
                            sortColumn: sortColumn,
                            sortAscending: sortAscending
                        ) { column in
                            if sortColumn == column {
                                sortAscending.toggle()
                            } else {
                                sortColumn = column
                                sortAscending = column == .size || column == .modified || column == .created ? false : true
                            }
                        } resize: { column, translation in
                            resizeColumn(column, translation: translation, layout: layout)
                        } onResizeEnded: {
                            resizeStartWidths = nil
                        }
                        .contextMenu {
                            ForEach(StorageCategoryFileColumn.allCases) { column in
                                Button {
                                    toggleStorageColumn(column)
                                } label: {
                                    if visibleColumns.contains(column) {
                                        Label(column.title, systemImage: "checkmark")
                                    } else {
                                        Text(column.title)
                                    }
                                }
                                .disabled(column == .name)
                            }
                        }
                        Divider()
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(sortedFiles) { file in
                                    StorageCategoryFileRow(
                                        model: model,
                                        file: file,
                                        visibleFiles: sortedFiles,
                                        layout: layout
                                    )
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(width: proxy.size.width, alignment: .leading)
                }
                .frame(minHeight: CGFloat(min(sortedFiles.count, 8)) * 42 + 34)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if fileList != nil {
                CompatibleContentUnavailableView(
                    "No Accessible Files",
                    systemImage: category.kind.symbol,
                    description: Text("Android did not expose individual files for this category.")
                )
                .frame(minHeight: 160)
            } else {
                Text("Click \(category.displayTitle) again to load the largest accessible files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: thumbnailPriorityKey) {
            await prepareThumbnailsInDisplayOrder()
        }
    }

    private func resizeColumn(_ column: StorageCategoryFileColumn, translation: CGFloat, layout: StorageCategoryFileColumnLayout) {
        guard let nextColumn = layout.nextColumn(after: column) else { return }
        let start: [StorageCategoryFileColumn: CGFloat]
        if let resizeStartWidths {
            start = resizeStartWidths
        } else {
            start = layout.widths
            resizeStartWidths = start
            columnWidths = start
        }

        let currentStart = start[column] ?? layout.width(for: column)
        let nextStart = start[nextColumn] ?? layout.width(for: nextColumn)
        let currentMinimum = StorageCategoryFileColumnMetrics.minimumWidth(for: column)
        let nextMinimum = StorageCategoryFileColumnMetrics.minimumWidth(for: nextColumn)
        let clampedTranslation = min(max(translation, currentMinimum - currentStart), nextStart - nextMinimum)
        columnWidths[column] = currentStart + clampedTranslation
        columnWidths[nextColumn] = nextStart - clampedTranslation
    }

    private func compare(_ lhs: AndroidFile, _ rhs: AndroidFile, by column: StorageCategoryFileColumn) -> ComparisonResult {
        switch column {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .location:
            return storageLocationLabel(for: lhs).localizedStandardCompare(storageLocationLabel(for: rhs))
        case .size:
            return compareOptionalInt64(lhs.size, rhs.size)
        case .modified:
            return compareOptionalDates(lhs.modified, rhs.modified)
        case .created:
            return compareOptionalDates(lhs.created, rhs.created)
        }
    }

    private func compareOptionalInt64(_ lhs: Int64?, _ rhs: Int64?) -> ComparisonResult {
        let left = lhs ?? -1
        let right = rhs ?? -1
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }

    private func compareOptionalDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        let left = lhs ?? .distantPast
        let right = rhs ?? .distantPast
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }

    private var thumbnailPriorityKey: String {
        let files = sortedFiles.map { $0.id }.joined(separator: "|")
        return "\(fileList?.id ?? "none")|\(sortColumn)|\(sortAscending)|\(settings.loadMediaThumbnails)|\(settings.thumbnailMaxFileSizeMB)|\(files)"
    }

    private func prepareThumbnailsInDisplayOrder() async {
        guard settings.loadMediaThumbnails else { return }
        for file in sortedFiles.lazy.filter({ $0.mediaKind != nil }).prefix(24) {
            guard !Task.isCancelled else { return }
            await model.prepareThumbnail(for: file, purpose: .browser)
        }
    }

    private var displayedColumns: [StorageCategoryFileColumn] {
        StorageCategoryFileColumn.allCases.filter(visibleColumns.contains)
    }

    private func toggleStorageColumn(_ column: StorageCategoryFileColumn) {
        guard column != .name else { return }
        if visibleColumns.contains(column) {
            visibleColumns.remove(column)
        } else {
            visibleColumns.insert(column)
        }
    }
}

private struct StorageCategoryLoadingView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(22)
        .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct StorageCategoryFileHeader: View {
    let layout: StorageCategoryFileColumnLayout
    let sortColumn: StorageCategoryFileColumn
    let sortAscending: Bool
    let sort: (StorageCategoryFileColumn) -> Void
    let resize: (StorageCategoryFileColumn, CGFloat) -> Void
    let onResizeEnded: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(layout.columns) { column in
                headerButton(column)
                    .frame(width: layout.width(for: column), alignment: column == .size ? .trailing : .leading)
                    .overlay(alignment: .trailing) {
                        if layout.nextColumn(after: column) != nil {
                            ColumnResizeHandle {
                                resize(column, $0)
                            } onEnded: {
                                onResizeEnded()
                            }
                        }
                    }
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 7)
        .background(.regularMaterial)
    }

    private func headerButton(_ column: StorageCategoryFileColumn) -> some View {
        Button {
            sort(column)
        } label: {
            HStack(spacing: 4) {
                Text(column.title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: column == .size ? .trailing : .leading)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .help("Sort by \(column.title)")
    }
}

private struct StorageCategoryFileRow: View {
    @ObservedObject var model: AppModel
    let file: AndroidFile
    let visibleFiles: [AndroidFile]
    let layout: StorageCategoryFileColumnLayout

    private var isSelected: Bool {
        model.selectedFileIDs.contains(file.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(layout.columns) { column in
                cell(column)
                    .frame(width: layout.width(for: column), alignment: column == .size ? .trailing : .leading)
            }
        }
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.open(file: file)
        })
        .onMouseUpSelect {
            model.selectFile(file, from: visibleFiles)
        }
        .contextMenu {
            Button {
                model.showFileInfo(file: file)
            } label: {
                Label("File Info", systemImage: "info.circle")
            }
            Button {
                Task { await model.preview(file: file) }
            } label: {
                Label("Preview", systemImage: "eye")
            }
            Button {
                Task { await model.download(file: file) }
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            if !isTrashCategoryFile {
                Divider()
                Button(role: .destructive) {
                    if !model.selectedFileIDs.contains(file.id) {
                        model.selectedFileIDs = [file.id]
                    }
                    Task { await model.deleteSelectedToTrash() }
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
            Divider()
            Button {
                if !model.selectedFileIDs.contains(file.id) {
                    model.selectedFileIDs = [file.id]
                }
                model.copySelectedRemotePathsToPasteboard()
            } label: {
                Label("Copy File Path", systemImage: "doc.on.clipboard")
            }
        }
    }

    private var isTrashCategoryFile: Bool {
        file.path.contains("/.AndroidFileBrowserTrash/") || file.path.contains("/.Trash/")
    }

    @ViewBuilder
    private func cell(_ column: StorageCategoryFileColumn) -> some View {
        switch column {
        case .name:
            HStack(spacing: 8) {
                MediaThumbnailView(
                    model: model,
                    file: file,
                    size: 26,
                    purpose: .browser,
                    automaticallyPrepares: false
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
        case .location:
            Text(storageLocationLabel(for: file))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
        case .size:
            Text(file.displaySize)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
        case .modified:
            Text(adaptiveDateString(file.modified, width: layout.width(for: .modified)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
        case .created:
            Text(adaptiveDateString(file.created, width: layout.width(for: .created)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
        }
    }
}

private struct StorageCategoryAppsPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("App Type", selection: $model.appKind) {
                    ForEach(AppKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                .onValueChange(of: model.appKind) { _, _ in
                    Task { await model.loadPackages() }
                }

                InlineSearchField(text: $model.searchText, prompt: "Search")
                    .frame(maxWidth: 320)

                Spacer()

                Button {
                    Task { await model.loadPackages() }
                } label: {
                    Label("Refresh Apps", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Refresh apps")
            }

            AppPackageList(model: model, showsStorageDisclosure: true)
                .frame(minHeight: 260)
        }
        .task {
            model.sortStorageAppsByLargest()
            if model.packages.isEmpty {
                await model.loadPackages()
            }
        }
    }
}

private enum StorageCategoryFileColumn: CaseIterable, Identifiable {
    case name
    case location
    case size
    case modified
    case created

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .location: "Location"
        case .size: "Size"
        case .modified: "Modified"
        case .created: "Created"
        }
    }
}

private struct StorageCategoryFileColumnLayout {
    let columns: [StorageCategoryFileColumn]
    let widths: [StorageCategoryFileColumn: CGFloat]
    let totalWidth: CGFloat

    func width(for column: StorageCategoryFileColumn) -> CGFloat {
        widths[column] ?? StorageCategoryFileColumnMetrics.idealWidth(for: column)
    }

    func nextColumn(after column: StorageCategoryFileColumn) -> StorageCategoryFileColumn? {
        guard let index = columns.firstIndex(of: column),
              index < columns.index(before: columns.endIndex) else {
            return nil
        }
        return columns[columns.index(after: index)]
    }
}

private enum StorageCategoryFileColumnMetrics {
    static func layout(
        for columns: [StorageCategoryFileColumn],
        availableWidth: CGFloat,
        preferredWidths: [StorageCategoryFileColumn: CGFloat]
    ) -> StorageCategoryFileColumnLayout {
        let columns = columns.isEmpty ? [.name] : columns
        var widths = Dictionary(uniqueKeysWithValues: columns.map { column in
            (column, preferredWidths[column] ?? idealWidth(for: column))
        })
        let targetWidth = max(1, availableWidth)
        let currentTotal = columns.reduce(CGFloat(0)) { $0 + (widths[$1] ?? idealWidth(for: $1)) }

        if currentTotal < targetWidth {
            let extra = targetWidth - currentTotal
            let totalWeight = columns.reduce(CGFloat(0)) { $0 + expansionWeight(for: $1) }
            for column in columns where totalWeight > 0 {
                widths[column, default: idealWidth(for: column)] += extra * expansionWeight(for: column) / totalWeight
            }
        } else if currentTotal > targetWidth {
            let shrink = currentTotal - targetWidth
            let capacity = columns.reduce(CGFloat(0)) { total, column in
                total + max(0, (widths[column] ?? idealWidth(for: column)) - minimumWidth(for: column))
            }
            if capacity > 0 {
                for column in columns {
                    let width = widths[column] ?? idealWidth(for: column)
                    let availableShrink = max(0, width - minimumWidth(for: column))
                    widths[column] = max(minimumWidth(for: column), width - shrink * availableShrink / capacity)
                }
            } else {
                let scale = targetWidth / max(1, currentTotal)
                for column in columns {
                    widths[column, default: idealWidth(for: column)] *= scale
                }
            }
        }

        let totalWidth = columns.reduce(CGFloat(0)) { $0 + (widths[$1] ?? idealWidth(for: $1)) }
        return StorageCategoryFileColumnLayout(columns: columns, widths: widths, totalWidth: totalWidth)
    }

    static func idealWidth(for column: StorageCategoryFileColumn) -> CGFloat {
        switch column {
        case .name: 360
        case .location: 170
        case .size: 108
        case .modified: 180
        case .created: 180
        }
    }

    static func minimumWidth(for column: StorageCategoryFileColumn) -> CGFloat {
        switch column {
        case .name: 180
        case .location: 92
        case .size: 76
        case .modified: 86
        case .created: 86
        }
    }

    private static func expansionWeight(for column: StorageCategoryFileColumn) -> CGFloat {
        switch column {
        case .name: 1
        case .location: 0.35
        case .modified, .created: 0.25
        case .size: 0.12
        }
    }
}

private func adaptiveDateString(_ date: Date?, width: CGFloat) -> String {
    guard let date else { return "—" }
    if width < 100 {
        return shortDateFormatter.string(from: date)
    }
    if width < 160 {
        return numericDateTimeFormatter.string(from: date)
    }
    return fullDateTimeFormatter.string(from: date)
}

private let fullDateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .short
    return formatter
}()

private let numericDateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
}()

private let shortDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter
}()

private func storageLocationLabel(for file: AndroidFile) -> String {
    let normalized = file.path
        .replacingOccurrences(of: "/storage/emulated/0/", with: "")
        .replacingOccurrences(of: "/sdcard/", with: "")
    let components = normalized.split(separator: "/").map(String.init)
    guard !components.isEmpty else { return "Storage" }

    if components.count >= 2, components[0] == "DCIM", components[1].localizedCaseInsensitiveCompare("Camera") == .orderedSame {
        return "Camera"
    }
    if components.count >= 2, components[0] == "Android" {
        switch components[1] {
        case "data": return "App Data"
        case "media": return "App Media"
        case "obb": return "App OBB"
        default: break
        }
    }
    return components[0]
}

private struct StorageSegmentedUsageBar: View {
    let summary: StorageSummary
    let breakdown: StorageBreakdown?
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                if let breakdown, !breakdown.visibleCategories.isEmpty {
                    ForEach(segments(width: proxy.size.width, categories: breakdown.visibleCategories)) { segment in
                        Capsule()
                            .fill(segment.color)
                            .frame(width: segment.width)
                            .offset(x: segment.offset)
                    }
                } else {
                    Capsule()
                        .fill(.blue)
                        .frame(width: proxy.size.width * summary.fractionUsed)
                }
            }
        }
        .frame(height: height)
    }

    private func segments(width: CGFloat, categories: [StorageBreakdownCategory]) -> [StorageBarSegment] {
        var offset: CGFloat = 0
        return categories.compactMap { category in
            let remainingWidth = max(0, width - offset)
            let segmentWidth = min(remainingWidth, width * category.fraction(of: summary.totalBytes))
            guard segmentWidth > 0 else { return nil }
            defer { offset += segmentWidth }
            return StorageBarSegment(id: category.id, offset: offset, width: segmentWidth, color: category.kind.displayColor)
        }
    }
}

private struct StorageBarSegment: Identifiable {
    let id: String
    let offset: CGFloat
    let width: CGFloat
    let color: Color
}

private extension StorageBreakdownCategoryKind {
    var displayColor: Color {
        switch self {
        case .apps: .blue
        case .videos: .purple
        case .images: .green
        case .audio: .pink
        case .trash: .orange
        case .documents: .cyan
        case .other: .yellow
        case .games: .indigo
        case .androidSystem: .gray
        case .temporarySystemFiles: .mint
        }
    }
}

private struct MainSurface: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var usbTransferManager: USBTransferManager

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
        self.usbTransferManager = model.usbTransferManager
    }

    var body: some View {
        Group {
            if showsConnectionHome {
                ConnectionHomeView(model: model)
            } else {
                switch model.sidebarSelection {
                case .apps:
                    AppManagerView(model: model)
                case .trash:
                    TrashView(model: model)
                case .storage:
                    StorageBreakdownView(model: model)
                case .usbTransfer, .usbTransferLocation:
                    USBTransferView(
                        manager: model.usbTransferManager,
                        settings: model.settings,
                        layout: $model.browserLayout,
                        isADBConnected: model.hasReadyADBDevice && !usbTransferManager.isADBReleasedForMTPSession,
                        pasteIntoCurrentFolder: {
                            Task { await model.pasteFromPasteboardOrClipboard() }
                        }
                    )
                case .location, nil:
                    FileBrowserView(model: model)
                }
            }
        }
        .background(contentBackground)
    }

    private var contentBackground: Color {
        switch settings.contentBackgroundStyle {
        case .glass:
            .clear
        case .solid:
            Color(nsColor: .windowBackgroundColor)
        }
    }

    private var showsConnectionHome: Bool {
        model.connectionMode == .adb && !model.hasReadyADBDevice
    }
}

private struct ConnectionHomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var usbTransferManager: USBTransferManager
    @ObservedObject private var toolchainManager: ToolchainManager
    @State private var activeSetupMode: ConnectionSetupMode?
    @State private var setupStepIndex = 0
    @State private var showsConnectionChoices = false
    @State private var didRequestFileTransferScan = false

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
        self.usbTransferManager = model.usbTransferManager
        self.toolchainManager = model.toolchainManager
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                connectionSummary

                if let activeSetupMode {
                    setupTutorial(for: activeSetupMode, isModeSwitchPrompt: false)
                } else if shouldShowADBSetupAfterModeSwitch && !showsConnectionChoices {
                    setupTutorial(for: .adb, isModeSwitchPrompt: true)
                } else {
                    connectionMethodChooser
                }
            }
            .frame(maxWidth: 980)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(contentBackground)
    }

    private var contentBackground: Color {
        switch settings.contentBackgroundStyle {
        case .glass:
            .clear
        case .solid:
            Color(nsColor: .windowBackgroundColor)
        }
    }

    private var connectionSummary: some View {
        VStack(spacing: 14) {
            Image(systemName: summarySymbol)
                .font(.system(size: 48, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(summaryColor)

            VStack(spacing: 6) {
                Text(summaryTitle)
                    .font(.title2.weight(.semibold))
                Text(summaryDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            if needsPhoneTools {
                Button {
                    model.requestPhoneToolsSetup()
                } label: {
                    Label("Set Up Phone Tools", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 10) {
                Image(systemName: summarySymbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(summaryColor)
                    .frame(width: 20)
                Text(summaryStatusTitle)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(summaryStatusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: 520)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var connectionMethodChooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a Connection Method")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 14) {
                ConnectionMethodCard(mode: .adb) {
                    beginSetup(.adb)
                }

                ConnectionMethodCard(mode: .usbTransfer) {
                    beginSetup(.usbTransfer)
                }
            }
        }
    }

    private func setupTutorial(for mode: ConnectionSetupMode, isModeSwitchPrompt: Bool) -> some View {
        let steps = mode.steps
        let currentIndex = min(setupStepIndex, max(steps.count - 1, 0))
        let currentStep = steps[currentIndex]

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(mode.color)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(isModeSwitchPrompt ? "Connect with Developer Options" : mode.setupTitle)
                        .font(.title3.weight(.semibold))
                    Text(isModeSwitchPrompt ? mode.modeSwitchDetail : mode.setupDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    exitSetupToChoices()
                } label: {
                    Label("Choose Other Method", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == currentIndex ? mode.color : Color.secondary.opacity(0.22))
                        .frame(width: index == currentIndex ? 34 : 16, height: 5)
                }
                Spacer()
                Text("Step \(currentIndex + 1) of \(steps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if mode == .usbTransfer && isLastFileTransferStep(currentIndex) && didRequestFileTransferScan {
                fileTransferScanResult
            } else {
                ConnectionStepCard(step: currentStep, color: mode.color)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    tutorialBackButton(currentIndex: currentIndex)
                    Spacer()
                    tutorialPrimaryActions(mode: mode, isLastStep: currentIndex == steps.count - 1)
                }

                VStack(alignment: .leading, spacing: 10) {
                    tutorialBackButton(currentIndex: currentIndex)
                    tutorialPrimaryActions(mode: mode, isLastStep: currentIndex == steps.count - 1)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.35))
        }
    }

    private func tutorialBackButton(currentIndex: Int) -> some View {
        Button {
            if currentIndex == 0 {
                exitSetupToChoices()
            } else {
                setupStepIndex = max(setupStepIndex - 1, 0)
            }
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .buttonStyle(.bordered)
    }

    private func tutorialPrimaryActions(mode: ConnectionSetupMode, isLastStep: Bool) -> some View {
        HStack(spacing: 10) {
            if isLastStep {
                switch mode {
                case .adb:
                    Button {
                        Task { await model.refreshDevices() }
                    } label: {
                        Label("Refresh USB Connection", systemImage: "cable.connector")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        model.startADBQRPairing()
                    } label: {
                        Label("Pair with Wi-Fi QR Code", systemImage: "qrcode")
                    }
                    .buttonStyle(.bordered)
                case .usbTransfer:
                    Button {
                        startFileTransferScan()
                    } label: {
                        Label("Scan Phone", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button {
                    setupStepIndex += 1
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var fileTransferScanResult: some View {
        switch fileTransferScanStatus {
        case .scanning:
            ConnectionScanStateCard(
                title: "Scanning for phone access",
                detail: "Keep the phone unlocked and leave File transfer / Android Auto selected.",
                symbol: "magnifyingglass",
                color: .green
            ) {
                ProgressView()
                    .controlSize(.small)
            }
        case .success:
            ConnectionScanStateCard(
                title: "Phone access ready",
                detail: "The phone is available for file transfer.",
                symbol: "checkmark.circle.fill",
                color: .green
            ) {
                Button {
                    model.open(destination: .usbTransfer)
                } label: {
                    Label("Open File Transfer", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
            }
        case .failure:
            ConnectionScanFailureCard(
                message: usbTransferManager.mtpAccessIssue?.statusMessage ?? "The phone was not available for file transfer.",
                retry: startFileTransferScan
            )
        }
    }

    private var fileTransferScanStatus: FileTransferScanStatus {
        if !usbTransferManager.devices.isEmpty {
            return .success
        }
        if usbTransferManager.isBrowsing || usbTransferManager.isCataloging || usbTransferManager.backend == .checking {
            return .scanning
        }
        if usbTransferManager.didEnumerateLocalDevices || usbTransferManager.mtpAccessIssue != nil {
            return .failure
        }
        return .scanning
    }

    private func isLastFileTransferStep(_ index: Int) -> Bool {
        index == ConnectionSetupMode.usbTransfer.steps.count - 1
    }

    private func startFileTransferScan() {
        didRequestFileTransferScan = true
        usbTransferManager.startBrowsingForFileTransfer()
    }

    private var shouldShowADBSetupAfterModeSwitch: Bool {
        model.connectionMode == .adb
            && !model.hasReadyADBDevice
            && model.shouldShowADBSetupAfterConnectionModeSwitch
    }

    private var summaryTitle: String {
        if needsPhoneTools {
            return "Phone Tools Need Setup"
        }
        if model.devices.contains(where: { $0.state == .unauthorized }) {
            return "Device Permission Needed"
        }
        if model.devices.contains(where: { $0.state == .offline }) {
            return "Device Offline"
        }
        if shouldShowADBSetupAfterModeSwitch && !showsConnectionChoices {
            return "Connect with Developer Options"
        }
        return "Device Not Connected"
    }

    private var summaryDetail: String {
        if let issue = model.adbRuntimeIssue {
            return issue
        }
        if needsPhoneTools {
            return "Install them once, then connect with USB debugging or Wi-Fi. File Transfer still works without them."
        }
        if model.devices.contains(where: { $0.state == .unauthorized }) {
            return "Approve the permission prompt on your phone, then refresh the connection."
        }
        if model.devices.contains(where: { $0.state == .offline }) {
            return "Reconnect the phone or restart the connection service, then refresh."
        }
        if shouldShowADBSetupAfterModeSwitch && !showsConnectionChoices {
            return "Follow the steps below, then connect by cable or Wi-Fi."
        }
        return "Choose a setup path below to connect your Android phone."
    }

    private var summaryStatusTitle: String {
        if needsPhoneTools {
            return "Phone tools unavailable"
        }
        if model.devices.contains(where: { $0.state == .unauthorized }) {
            return "Waiting for permission"
        }
        if model.devices.contains(where: { $0.state == .offline }) {
            return "Device offline"
        }
        if shouldShowADBSetupAfterModeSwitch && !showsConnectionChoices {
            return "Developer Options not connected"
        }
        return "Device not connected"
    }

    private var summaryStatusDetail: String {
        needsPhoneTools ? "File Transfer still works" : "Setup required"
    }

    private var summarySymbol: String {
        if needsPhoneTools {
            return "wrench.and.screwdriver"
        }
        if model.devices.contains(where: { $0.state == .unauthorized || $0.state == .offline }) {
            return "exclamationmark.triangle"
        }
        return shouldShowADBSetupAfterModeSwitch && !showsConnectionChoices ? "terminal" : "cable.connector.slash"
    }

    private var summaryColor: Color {
        if needsPhoneTools {
            return .orange
        }
        if model.devices.contains(where: { $0.state == .unauthorized || $0.state == .offline }) {
            return .orange
        }
        return shouldShowADBSetupAfterModeSwitch && !showsConnectionChoices ? .blue : .secondary
    }

    private var needsPhoneTools: Bool {
        if model.adbRuntimeIssue != nil {
            return true
        }
        switch toolchainManager.status(for: .adb) {
        case .missing, .needsRepair:
            return true
        default:
            return false
        }
    }

    private func beginSetup(_ mode: ConnectionSetupMode) {
        activeSetupMode = mode
        setupStepIndex = 0
        showsConnectionChoices = false
        didRequestFileTransferScan = false
    }

    private func exitSetupToChoices() {
        model.dismissADBConnectionSetupPrompt()
        activeSetupMode = nil
        setupStepIndex = 0
        showsConnectionChoices = true
        didRequestFileTransferScan = false
    }
}

private enum FileTransferScanStatus {
    case scanning
    case success
    case failure
}

private enum ConnectionSetupMode: Hashable {
    case adb
    case usbTransfer

    var chooserTitle: String {
        switch self {
        case .adb: "Developer Options"
        case .usbTransfer: "File Transfer Mode"
        }
    }

    var setupTitle: String {
        switch self {
        case .adb: "Connect with Developer Options"
        case .usbTransfer: "Set Up File Transfer Mode"
        }
    }

    var symbol: String {
        switch self {
        case .adb: "terminal"
        case .usbTransfer: "externaldrive.connected.to.line.below"
        }
    }

    var color: Color {
        switch self {
        case .adb: .blue
        case .usbTransfer: .green
        }
    }

    var chooserDetail: String {
        switch self {
        case .adb:
            return "Connect by cable or Wi-Fi for app tools, storage details, screenshots, and phone control."
        case .usbTransfer:
            return "Connect by cable to browse, copy, and organize files. No phone app needed."
        }
    }

    var setupDetail: String {
        switch self {
        case .adb:
            return "Turn on Developer Options once, then connect by cable or Wi-Fi."
        case .usbTransfer:
            return "Use a cable, choose File transfer on the phone, then check the connection."
        }
    }

    var modeSwitchDetail: String {
        "Turn on Developer Options once, then connect by cable or Wi-Fi."
    }

    var processSummary: [String] {
        switch self {
        case .adb:
            return [
                "Turn on Developer Options",
                "Allow USB debugging",
                "Connect by cable or Wi-Fi"
            ]
        case .usbTransfer:
            return [
                "Connect by USB cable",
                "Choose File transfer on the phone",
                "Scan for phone access"
            ]
        }
    }

    var buttonTitle: String {
        switch self {
        case .adb: "Show Developer Steps"
        case .usbTransfer: "Show File Transfer Steps"
        }
    }

    var buttonSymbol: String {
        switch self {
        case .adb: "terminal"
        case .usbTransfer: "folder"
        }
    }

    var steps: [ConnectionSetupStep] {
        switch self {
        case .adb:
            return [
                ConnectionSetupStep(
                    title: "Enable Developer options",
                    symbol: "gearshape",
                    guideItems: [
                        ConnectionGuideItem(action: "Open Settings.", detail: "Use the Settings app on your Android phone."),
                        ConnectionGuideItem(action: "Open About phone.", detail: "On some phones, it is under System."),
                        ConnectionGuideItem(action: "Find Build number.", detail: "It may be inside Software information."),
                        ConnectionGuideItem(action: "Tap Build number 7 times.", detail: "Confirm your screen lock if Android asks.")
                    ]
                ),
                ConnectionSetupStep(
                    title: "Turn on USB debugging",
                    symbol: "switch.2",
                    guideItems: [
                        ConnectionGuideItem(action: "Open Developer options.", detail: "Go to Settings > System > Developer options."),
                        ConnectionGuideItem(action: "Find Debugging.", detail: "Scroll until you see the Debugging section."),
                        ConnectionGuideItem(action: "Turn on USB debugging.", detail: "Confirm the Android warning."),
                        ConnectionGuideItem(action: "Reconnect the cable.", detail: "Unplug and plug the phone back in if no prompt appears.")
                    ]
                ),
                ConnectionSetupStep(
                    title: "Connect with USB or Wi-Fi",
                    symbol: "cable.connector",
                    guideItems: [
                        ConnectionGuideItem(action: "For USB, plug in the phone.", detail: "Keep the phone unlocked."),
                        ConnectionGuideItem(action: "Approve this Mac.", detail: "Accept the USB debugging prompt on the phone."),
                        ConnectionGuideItem(action: "Refresh here.", detail: "Click Refresh USB Connection."),
                        ConnectionGuideItem(action: "For Wi-Fi, pair by QR code.", detail: "Use Pair with Wi-Fi QR Code instead of a cable.")
                    ]
                )
            ]
        case .usbTransfer:
            return [
                ConnectionSetupStep(
                    title: "Connect the phone",
                    symbol: "cable.connector",
                    guideItems: [
                        ConnectionGuideItem(action: "Use a data cable.", detail: "Charging-only cables will not work for file access."),
                        ConnectionGuideItem(action: "Unlock the phone.", detail: "Stay on the home screen or notification shade."),
                        ConnectionGuideItem(action: "Keep it awake.", detail: "Do not let the screen lock during setup."),
                        ConnectionGuideItem(action: "Try another cable if needed.", detail: "If nothing appears, switch cables or USB ports.")
                    ]
                ),
                ConnectionSetupStep(
                    title: "Choose File transfer mode",
                    symbol: "iphone.gen3.radiowaves.left.and.right",
                    guideItems: [
                        ConnectionGuideItem(action: "Open the USB notification.", detail: "Pull down Android notifications after plugging in."),
                        ConnectionGuideItem(action: "Choose File transfer / Android Auto.", detail: "Use this for files and folders."),
                        ConnectionGuideItem(action: "Leave the phone unlocked.", detail: "The Mac may ask for access next."),
                        ConnectionGuideItem(action: "Stay on this mode.", detail: "Do not switch to charging-only mode.")
                    ]
                ),
                ConnectionSetupStep(
                    title: "Scan and check access",
                    symbol: "magnifyingglass",
                    guideItems: [
                        ConnectionGuideItem(action: "Click Scan Phone.", detail: "The app will check if the phone can be accessed."),
                        ConnectionGuideItem(action: "Allow macOS access.", detail: "Approve removable media access if macOS asks."),
                        ConnectionGuideItem(action: "Wait for the result.", detail: "A success or troubleshooting screen will appear here."),
                        ConnectionGuideItem(action: "Retry if needed.", detail: "Keep the phone unlocked and try the scan again.")
                    ]
                )
            ]
        }
    }
}

private struct ConnectionMethodCard: View {
    let mode: ConnectionSetupMode
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode.symbol)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(mode.color)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.chooserTitle)
                        .font(.headline)
                    Text(mode.chooserDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(mode.processSummary.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 9) {
                        Text("\(index + 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 19, height: 19)
                            .background(mode.color, in: Circle())
                        Text(item)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            Button(action: action) {
                Label(mode.buttonTitle, systemImage: mode.buttonSymbol)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 232, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator.opacity(0.35))
        }
    }
}

private struct ConnectionStepCard: View {
    let step: ConnectionSetupStep
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: step.symbol)
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(.headline)
                ConnectionStepGuide(items: step.guideItems, color: color)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.35))
        }
    }
}

private struct ConnectionScanStateCard<Accessory: View>: View {
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            accessory
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.35))
        }
    }
}

private struct ConnectionScanFailureCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                    .frame(width: 42, height: 42)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Phone access failed")
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ConnectionStepGuide(
                items: [
                    ConnectionGuideItem(action: "Check the cable.", detail: "Use a data cable, not a charging-only cable."),
                    ConnectionGuideItem(action: "Unlock the phone.", detail: "Leave it awake while scanning."),
                    ConnectionGuideItem(action: "Choose File transfer / Android Auto.", detail: "Use the Android USB notification."),
                    ConnectionGuideItem(action: "Allow macOS access.", detail: "Approve removable media access if prompted.")
                ],
                color: .orange
            )

            Button(action: retry) {
                Label("Retry Scan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.35))
        }
    }
}

private struct ConnectionSetupStep {
    let title: String
    let symbol: String
    let guideItems: [ConnectionGuideItem]
}

private struct ConnectionGuideItem: Hashable {
    let action: String
    let detail: String
}

private struct ConnectionStepGuide: View {
    let items: [ConnectionGuideItem]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 9) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(color, in: Circle())

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.action)
                            .font(.callout.weight(.bold))
                            .foregroundStyle(.primary)
                        Text(item.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.top, 2)
    }
}

private struct ADBQRPairingSheet: View {
    @ObservedObject var model: AppModel
    let session: ADBQRPairingSession

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                Text("Pair ADB with QR Code")
                    .font(.title2.weight(.semibold))
                Text(model.adbQRPairingStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            QRCodeImage(payload: session.payload)
                .frame(width: 260, height: 260)
                .padding(16)
                .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                QRPairingInstruction(
                    title: "Turn on Wireless debugging",
                    detail: "On Android: Settings > System > Developer options > Wireless debugging. Turn it on and confirm the warning."
                )
                QRPairingInstruction(
                    title: "Open the QR pairing screen",
                    detail: "Tap Pair device with QR code. Do not use Pair with pairing code for this button."
                )
                QRPairingInstruction(
                    title: "Keep both devices together",
                    detail: "The Mac and phone must be on the same Wi-Fi network. Keep the phone on the QR pairing screen until this app reports connected."
                )
            }
            .frame(maxWidth: 460, alignment: .leading)

            HStack {
                Button {
                    model.startADBQRPairing()
                } label: {
                    Label("New Code", systemImage: "arrow.clockwise")
                }

                Spacer()

                Button {
                    Task { await model.refreshDevicesAndRequestUSBTransferIfNoADB() }
                } label: {
                    Label("Refresh ADB", systemImage: "cable.connector")
                }

                Button("Done") {
                    model.stopADBQRPairing()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct QRPairingInstruction: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct QRCodeImage: View {
    let payload: String
    private static let context = CIContext()
    private static let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let image = makeImage() {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: 120))
                .foregroundStyle(.secondary)
        }
    }

    private func makeImage() -> NSImage? {
        Self.filter.message = Data(payload.utf8)
        Self.filter.correctionLevel = "M"
        guard let output = Self.filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = Self.context.createCGImage(output, from: output.extent)
        else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

private struct AppToolbar: ToolbarContent {
    @ObservedObject var model: AppModel
    @ObservedObject private var usbTransferManager: USBTransferManager

    init(model: AppModel) {
        self.model = model
        self.usbTransferManager = model.usbTransferManager
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.navigateBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!model.canNavigateBack)
            .accessibilityHint("Return to the previous folder.")
            .toolbarHoverHelp("Back: return to the previous folder.")

            Button {
                model.navigateForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!model.canNavigateForward)
            .accessibilityHint("Open the next folder in navigation history.")
            .toolbarHoverHelp("Forward: open the next folder in navigation history.")

            if model.isUSBTransferSelected {
                Button {
                    model.usbTransferManager.navigateUp()
                } label: {
                    Label("Up", systemImage: "chevron.up")
                }
                .disabled(!model.usbTransferManager.canNavigateUp)
                .accessibilityLabel("Go Up")
                .accessibilityHint("Go to the parent folder in File Transfer.")
                .toolbarHoverHelp("Go Up: open the parent folder in File Transfer.")

                Button {
                    model.usbTransferManager.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
                .accessibilityHint("Refresh the files shown through File Transfer.")
                .toolbarHoverHelp("Refresh: reload the files currently shown by File Transfer.")
            } else {
                Button {
                    model.navigateUp()
                } label: {
                    Label("Up", systemImage: "chevron.up")
                }
                .accessibilityLabel("Go Up")
                .accessibilityHint("Go to the parent folder.")
                .toolbarHoverHelp("Go Up: open the parent folder.")

                Button {
                    Task { await model.refreshCurrentSurfaceSafely() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
                .accessibilityHint("Refresh the current folder or tool.")
                .toolbarHoverHelp("Refresh: reload the current folder or selected tool.")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if model.isUSBTransferSelected {
                Button {
                    usbTransferManager.uploadToCurrentMTPFolder()
                } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
                .disabled(!usbTransferManager.canWriteCurrentMTPFolder)
                .accessibilityLabel("Upload")
                .toolbarHoverHelp("Upload: copy files or folders from this Mac into the current phone folder.")

                Button {
                    usbTransferManager.downloadSelected()
                } label: {
                    Label("Download", systemImage: "square.and.arrow.down")
                }
                .disabled(usbTransferManager.selectedDownloadableItems.isEmpty)
                .accessibilityLabel("Download")
                .toolbarHoverHelp("Download: copy the selected File Transfer items to this Mac.")

                Button {
                    usbTransferManager.requestMTPNewFolder()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(!usbTransferManager.canWriteCurrentMTPFolder)
                .accessibilityLabel("New Folder")
                .toolbarHoverHelp("New Folder: create a folder in the current phone folder.")

                Button {
                    usbTransferManager.requestMTPCompressSelected()
                } label: {
                    Label("Compress", systemImage: "doc.zipper")
                }
                .disabled(!usbTransferManager.canCompressSelectedMTPItems)
                .accessibilityLabel("Compress")
                .toolbarHoverHelp("Compress: create a zip archive from the selected files or folders.")

                Button {
                    if let archive = usbTransferManager.selectedMTPExtractableArchive {
                        usbTransferManager.confirmAndExtractMTPArchive(archive)
                    }
                } label: {
                    Label("Uncompress", systemImage: "archivebox")
                }
                .disabled(usbTransferManager.selectedMTPExtractableArchive == nil)
                .accessibilityLabel("Uncompress")
                .toolbarHoverHelp("Uncompress: extract the selected archive into a folder next to it.")

                Button(role: .destructive) {
                    usbTransferManager.deleteSelectedMTPItems()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!usbTransferManager.canDeleteSelectedMTPItems)
                .accessibilityLabel("Delete Permanently")
                .toolbarHoverHelp("Delete: permanently remove the selected File Transfer items from the phone.")
            } else if model.hasReadyADBDevice {
                Button {
                    model.beginUpload()
                } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Upload")
                .accessibilityHint("Upload files from this Mac to the current Android folder.")
                .toolbarHoverHelp("Upload: copy files from this Mac into the current Android folder.")

                Button {
                    Task { await model.downloadSelected() }
                } label: {
                    Label("Download", systemImage: "square.and.arrow.down")
                }
                .disabled(model.selectedFiles.isEmpty)
                .accessibilityLabel("Download")
                .accessibilityHint("Download the selected Android files to this Mac.")
                .toolbarHoverHelp("Download: copy the selected Android files to this Mac.")

                Button {
                    model.requestBatchRenameSelected()
                } label: {
                    Label("Batch Rename", systemImage: "textformat")
                }
                .disabled(model.selectedFiles.count < 2)
                .accessibilityLabel("Batch Rename")
                .accessibilityHint("Rename multiple selected Android files.")
                .toolbarHoverHelp("Batch Rename: rename selected files with find and replace, numbering, prefixes, suffixes, or extension changes.")

                Button {
                    model.requestNewFolder()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .accessibilityLabel("New Folder")
                .accessibilityHint("Create a new folder in the current Android folder.")
                .toolbarHoverHelp("New Folder: create a folder in the current Android location.")

                Button {
                    model.requestCompressSelected()
                } label: {
                    Label("Compress", systemImage: "doc.zipper")
                }
                .disabled(!model.canCompressSelection)
                .accessibilityLabel("Compress")
                .accessibilityHint("Compress the selected Android files into a zip archive.")
                .toolbarHoverHelp("Compress: create a zip archive from the selected files or folders.")

                Button {
                    if let archive = model.selectedExtractableArchive {
                        model.confirmAndExtractArchive(archive)
                    }
                } label: {
                    Label("Uncompress", systemImage: "archivebox")
                }
                .disabled(model.selectedExtractableArchive == nil)
                .accessibilityLabel("Uncompress")
                .accessibilityHint("Extract the selected archive into a folder on the Android device.")
                .toolbarHoverHelp("Uncompress: extract the selected archive into a folder next to it.")

                Button {
                    Task { await model.deleteSelectedToTrash() }
                } label: {
                    Label("Trash", systemImage: "trash")
                }
                .disabled(model.selectedFiles.isEmpty)
                .accessibilityLabel("Move to Trash")
                .accessibilityHint("Move the selected Android files to the app trash.")
                .toolbarHoverHelp("Trash: move the selected Android files into the app trash so they can be restored.")
            }
        }

        ToolbarItemGroup {
            Button {
                model.showConnectionStatus()
            } label: {
                Label("Connection Status", systemImage: "cable.connector")
            }
            .accessibilityLabel("Connection Status")
            .accessibilityHint("Show Developer Options and File Transfer status.")
            .toolbarHoverHelp("Connection Status: check both connection methods and see setup help.")

            if model.isActiveFileModeSelected {
                Picker("Layout", selection: $model.browserLayout) {
                    ForEach(BrowserLayout.allCases) { layout in
                        Label(layout.label, systemImage: layout.symbol).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 112)
                .help("View Layout: switch between List and Icons.")
                .accessibilityLabel("File Layout")
                .accessibilityHint("Switch between list and icon file layouts.")
            }

            if model.showsPhoneCaptureToolbarControls {
                Button {
                    model.requestScreenshot()
                } label: {
                    Label(
                        model.isCapturingScreenshot ? "Capturing Screenshot" : "Screenshot",
                        systemImage: "camera.viewfinder"
                    )
                }
                .accessibilityLabel("Screenshot")
                .accessibilityIdentifier("toolbar-screenshot")
                .accessibilityHint("Choose screenshot settings and capture the connected phone.")
                .toolbarHoverHelp("Screenshot: choose appearance and demo mode, then capture the phone.")
                .contextMenu {
                    Button("Screenshot Settings...") {
                        model.showScreenshotSettings()
                    }
                }

                Button {
                    model.requestScreenRecording()
                } label: {
                    if model.screenRecordingSession != nil || model.isStartingScreenRecording || model.isFinishingScreenRecording {
                        Label("Recording", systemImage: "record.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.red, .primary)
                    } else {
                        Label("Record", systemImage: "record.circle")
                    }
                }
                .accessibilityLabel("Screen Recording")
                .accessibilityIdentifier("toolbar-record")
                .accessibilityHint("Choose recording settings, start recording, or stop the current recording.")
                .toolbarHoverHelp("Record: configure and record the connected phone until you stop.")
                .contextMenu {
                    Button("Recording Settings...") {
                        model.showRecordingSettings()
                    }
                }

                Button {
                    model.requestPhoneControl()
                } label: {
                    Label(
                        model.isLaunchingScrcpy ? "Opening Phone Control" : "Phone Control",
                        systemImage: "rectangle.connected.to.line.below"
                    )
                }
                .accessibilityLabel("Phone Control")
                .accessibilityIdentifier("toolbar-phone-control")
                .accessibilityHint("Choose Phone Control settings and open the connected device.")
                .toolbarHoverHelp("Phone Control: open and control the connected device in its own window.")
                .contextMenu {
                    Button("Phone Control Settings...") {
                        model.showPhoneControlSettings()
                    }
                }
            }

            if model.hasInspectableDeviceSurface {
                Button {
                    model.showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .accessibilityLabel(model.showInspector ? "Hide Inspector" : "Show Inspector")
                .accessibilityIdentifier("toolbar-inspector")
                .accessibilityHint("Show or hide the details panel on the right side of the window.")
                .toolbarHoverHelp(model.showInspector ? "Inspector: hide the details panel on the right." : "Inspector: show details for the selected file, preview, or app.")
            }
        }
    }
}

private struct ConnectionModeMenu: View {
    @ObservedObject var model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        Picker("Connection", selection: Binding(
            get: { model.connectionMode },
            set: { model.selectConnectionMode($0) }
        )) {
            ForEach(ConnectionMode.allCases) { mode in
                Label(mode.label, systemImage: mode.symbol)
                    .tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Connection Method: choose Developer Options for USB or Wi-Fi debugging, or File Transfer for a cable connection.")
        .accessibilityLabel("Connection Method")
        .accessibilityHint("Choose Developer Options or File Transfer for the selected Android device.")
    }
}

private struct StatusStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var usbTransferManager: USBTransferManager
    @State private var showsDetails = false

    init(model: AppModel) {
        self.model = model
        self.usbTransferManager = model.usbTransferManager
    }

    var body: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(statusMessage)
                .lineLimit(2)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(statusMessage)
            Spacer()
            Button {
                showsDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Show status details: \(statusMessage)")
            .accessibilityLabel("Show Status Details")
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                statusDetails
            }
        }
        .padding(10)
        .background(.regularMaterial)
    }

    private var statusDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Current Status", systemImage: "info.circle.fill")
                .font(.headline)

            Text(statusMessage)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Connection")
                        .foregroundStyle(.secondary)
                    Text(model.connectionMode.label)
                }
                GridRow {
                    Text("Device")
                        .foregroundStyle(.secondary)
                    Text(statusDeviceName)
                }
                if !model.isUSBTransferSelected, model.selectedDevice != nil {
                    GridRow {
                        Text("Location")
                            .foregroundStyle(.secondary)
                        Text(model.currentPath)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    GridRow {
                        Text("Items")
                            .foregroundStyle(.secondary)
                        Text("\(model.files.count)")
                    }
                }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
    }

    private var statusDeviceName: String {
        if model.isUSBTransferSelected {
            return usbTransferManager.selectedDevice?.name ?? "No device selected"
        }
        return model.selectedDevice?.title ?? "No device selected"
    }

    private var isBusy: Bool {
        if model.isUSBTransferSelected {
            return usbTransferManager.isReleasingADBForMTP
                || usbTransferManager.isDownloading
                || (usbTransferManager.isCataloging && usbTransferManager.items.isEmpty)
        }
        return model.isBusy
    }

    private var statusMessage: String {
        if model.isUSBTransferSelected {
            return usbTransferManager.statusMessage
        }

        if model.devices.isEmpty {
            if !usbTransferManager.devices.isEmpty {
                return "Developer Options not connected. File Transfer is available."
            }
            if usbTransferManager.didEnumerateLocalDevices {
                return "No phone connection found. Open Connection Status for setup steps."
            }
            return "No debugging connection found."
        }

        return model.statusMessage
    }
}
