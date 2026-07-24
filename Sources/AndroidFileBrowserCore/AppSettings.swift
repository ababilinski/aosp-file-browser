import Foundation
import AppKit
import SwiftUI

public enum PreviewCacheRetention: Int, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60
    case fourHours = 240
    case oneDay = 1_440

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .fourHours: "4 hours"
        case .oneDay: "1 day"
        }
    }
}

@MainActor
public final class AppSettings: ObservableObject {
    private enum Key {
        static let appearanceMode = "settings.appearanceMode"
        static let contentBackgroundStyle = "settings.contentBackgroundStyle"
        static let edgeToEdgeSidebar = "settings.edgeToEdgeSidebar"
        // AppKit reads this app-domain preference when it creates a sidebar split item.
        static let sidebarDefaultsToFloatingAppearance = "NSSplitViewItemSidebarDefaultsToFloatingAppearance"
        static let loadMediaThumbnails = "settings.loadMediaThumbnails"
        static let showDetailMediaPreviews = "settings.showDetailMediaPreviews"
        static let thumbnailMaxFileSizeMB = "settings.thumbnailMaxFileSizeMB"
        static let mediaCacheLimitMB = "settings.mediaCacheLimitMB"
        static let clearMediaCacheOnQuit = "settings.clearMediaCacheOnQuit"
        static let encryptPreviewCache = "settings.encryptPreviewCache"
        static let previewCacheEncryptionDefaultMigrated = "settings.previewCacheEncryptionDefaultMigratedV2"
        static let previewCacheRetentionMinutes = "settings.previewCacheRetentionMinutes"
        static let useFinderStyleIconColors = "settings.useFinderStyleIconColors"
        static let showPathBar = "settings.showPathBar"
        static let calculateFolderSizes = "settings.calculateFolderSizes"
        static let showUploadToolbarButton = "settings.showUploadToolbarButton"
        static let showDownloadToolbarButton = "settings.showDownloadToolbarButton"
        static let showBatchRenameToolbarButton = "settings.showBatchRenameToolbarButton"
        static let showCompressToolbarButton = "settings.showCompressToolbarButton"
        static let showUncompressToolbarButton = "settings.showUncompressToolbarButton"
        static let showConnectionStatusToolbarButton = "settings.showConnectionStatusToolbarButton"
        static let openPreviewOnDoubleClick = "settings.openPreviewOnDoubleClick"
        static let autoLoadAppDetails = "settings.autoLoadAppDetails"
        static let confirmBeforeUninstallingApps = "settings.confirmBeforeUninstallingApps"
        static let confirmEmptyTrashAtSessionEnd = "settings.confirmEmptyTrashAtSessionEnd"
        static let trashQuitBehavior = "settings.trashQuitBehavior"
        static let showTrashItemCount = "settings.showTrashItemCount"
        static let showDefaultQuickLocations = "settings.showDefaultQuickLocations"
        static let hiddenDefaultQuickLocationIDs = "settings.hiddenDefaultQuickLocationIDs"
        static let customQuickLocations = "settings.customQuickLocations"
        static let showUSBTransferWhenADBConnected = "settings.showUSBTransferWhenADBConnected"
        static let checkConnectionModesOnLaunch = "settings.checkConnectionModesOnLaunch"
        static let adbToolMode = ToolchainPreferences.adbModeKey
        static let adbToolPath = ToolchainPreferences.adbPathKey
        static let scrcpyToolMode = ToolchainPreferences.scrcpyModeKey
        static let scrcpyToolPath = ToolchainPreferences.scrcpyPathKey
        static let phoneCapturePresentation = "settings.phoneCapturePresentation"
        static let showScreenshotSetup = "settings.showScreenshotSetup"
        static let showRecordingSetup = "settings.showRecordingSetup"
        static let showPhoneControlSetup = "settings.showPhoneControlSetup"
        static let phoneControlDeviceOptions = "settings.phoneControlDeviceOptions"
    }

    private let defaults: UserDefaults

    @Published public var appearanceMode: AppAppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Key.appearanceMode) }
    }

    @Published public var contentBackgroundStyle: AppContentBackgroundStyle {
        didSet { defaults.set(contentBackgroundStyle.rawValue, forKey: Key.contentBackgroundStyle) }
    }

    @Published public var edgeToEdgeSidebar: Bool {
        didSet {
            defaults.set(edgeToEdgeSidebar, forKey: Key.edgeToEdgeSidebar)
            defaults.set(!edgeToEdgeSidebar, forKey: Key.sidebarDefaultsToFloatingAppearance)
        }
    }

    @Published public var loadMediaThumbnails: Bool {
        didSet { defaults.set(loadMediaThumbnails, forKey: Key.loadMediaThumbnails) }
    }

    @Published public var showDetailMediaPreviews: Bool {
        didSet { defaults.set(showDetailMediaPreviews, forKey: Key.showDetailMediaPreviews) }
    }

    @Published public var thumbnailMaxFileSizeMB: Int {
        didSet { defaults.set(thumbnailMaxFileSizeMB, forKey: Key.thumbnailMaxFileSizeMB) }
    }

    @Published public var mediaCacheLimitMB: Int {
        didSet { defaults.set(mediaCacheLimitMB, forKey: Key.mediaCacheLimitMB) }
    }

    @Published public var clearMediaCacheOnQuit: Bool {
        didSet { defaults.set(clearMediaCacheOnQuit, forKey: Key.clearMediaCacheOnQuit) }
    }

    @Published public var encryptPreviewCache: Bool {
        didSet { defaults.set(encryptPreviewCache, forKey: Key.encryptPreviewCache) }
    }

    @Published public var previewCacheRetention: PreviewCacheRetention {
        didSet { defaults.set(previewCacheRetention.rawValue, forKey: Key.previewCacheRetentionMinutes) }
    }

    @Published public var useFinderStyleIconColors: Bool {
        didSet { defaults.set(useFinderStyleIconColors, forKey: Key.useFinderStyleIconColors) }
    }

    @Published public var showPathBar: Bool {
        didSet { defaults.set(showPathBar, forKey: Key.showPathBar) }
    }

    @Published public var calculateFolderSizes: Bool {
        didSet { defaults.set(calculateFolderSizes, forKey: Key.calculateFolderSizes) }
    }

    @Published public var showUploadToolbarButton: Bool {
        didSet { defaults.set(showUploadToolbarButton, forKey: Key.showUploadToolbarButton) }
    }

    @Published public var showDownloadToolbarButton: Bool {
        didSet { defaults.set(showDownloadToolbarButton, forKey: Key.showDownloadToolbarButton) }
    }

    @Published public var showBatchRenameToolbarButton: Bool {
        didSet { defaults.set(showBatchRenameToolbarButton, forKey: Key.showBatchRenameToolbarButton) }
    }

    @Published public var showCompressToolbarButton: Bool {
        didSet { defaults.set(showCompressToolbarButton, forKey: Key.showCompressToolbarButton) }
    }

    @Published public var showUncompressToolbarButton: Bool {
        didSet { defaults.set(showUncompressToolbarButton, forKey: Key.showUncompressToolbarButton) }
    }

    @Published public var showConnectionStatusToolbarButton: Bool {
        didSet {
            defaults.set(
                showConnectionStatusToolbarButton,
                forKey: Key.showConnectionStatusToolbarButton
            )
        }
    }

    @Published public var openPreviewOnDoubleClick: Bool {
        didSet { defaults.set(openPreviewOnDoubleClick, forKey: Key.openPreviewOnDoubleClick) }
    }

    @Published public var autoLoadAppDetails: Bool {
        didSet { defaults.set(autoLoadAppDetails, forKey: Key.autoLoadAppDetails) }
    }

    @Published public var confirmBeforeUninstallingApps: Bool {
        didSet { defaults.set(confirmBeforeUninstallingApps, forKey: Key.confirmBeforeUninstallingApps) }
    }

    @Published public var trashQuitBehavior: TrashQuitBehavior {
        didSet {
            defaults.set(trashQuitBehavior.rawValue, forKey: Key.trashQuitBehavior)
            defaults.set(trashQuitBehavior == .ask, forKey: Key.confirmEmptyTrashAtSessionEnd)
        }
    }

    public var confirmEmptyTrashAtSessionEnd: Bool {
        get { trashQuitBehavior == .ask }
        set { trashQuitBehavior = newValue ? .ask : .keep }
    }

    @Published public var showTrashItemCount: Bool {
        didSet { defaults.set(showTrashItemCount, forKey: Key.showTrashItemCount) }
    }

    @Published public var showDefaultQuickLocations: Bool {
        didSet { defaults.set(showDefaultQuickLocations, forKey: Key.showDefaultQuickLocations) }
    }

    @Published public var hiddenDefaultQuickLocationIDs: Set<String> {
        didSet { defaults.set(Array(hiddenDefaultQuickLocationIDs), forKey: Key.hiddenDefaultQuickLocationIDs) }
    }

    @Published public var customQuickLocations: [QuickLocation] {
        didSet {
            if let data = try? JSONEncoder().encode(customQuickLocations) {
                defaults.set(data, forKey: Key.customQuickLocations)
            }
        }
    }

    @Published public var showUSBTransferWhenADBConnected: Bool {
        didSet { defaults.set(showUSBTransferWhenADBConnected, forKey: Key.showUSBTransferWhenADBConnected) }
    }

    @Published public var checkConnectionModesOnLaunch: Bool {
        didSet { defaults.set(checkConnectionModesOnLaunch, forKey: Key.checkConnectionModesOnLaunch) }
    }

    @Published public var adbToolMode: ToolSelectionMode {
        didSet { defaults.set(adbToolMode.rawValue, forKey: Key.adbToolMode) }
    }

    @Published public var adbToolPath: String {
        didSet { defaults.set(adbToolPath, forKey: Key.adbToolPath) }
    }

    @Published public var scrcpyToolMode: ToolSelectionMode {
        didSet { defaults.set(scrcpyToolMode.rawValue, forKey: Key.scrcpyToolMode) }
    }

    @Published public var scrcpyToolPath: String {
        didSet { defaults.set(scrcpyToolPath, forKey: Key.scrcpyToolPath) }
    }

    @Published public var phoneCapturePresentation: PhoneCapturePresentationMode {
        didSet { defaults.set(phoneCapturePresentation.rawValue, forKey: Key.phoneCapturePresentation) }
    }

    @Published public var showScreenshotSetup: Bool {
        didSet { defaults.set(showScreenshotSetup, forKey: Key.showScreenshotSetup) }
    }

    @Published public var showRecordingSetup: Bool {
        didSet { defaults.set(showRecordingSetup, forKey: Key.showRecordingSetup) }
    }

    @Published public var showPhoneControlSetup: Bool {
        didSet { defaults.set(showPhoneControlSetup, forKey: Key.showPhoneControlSetup) }
    }

    @Published public var phoneControlDeviceOptions: [String: PhoneControlDeviceOptions] {
        didSet {
            if let data = try? JSONEncoder().encode(phoneControlDeviceOptions) {
                defaults.set(data, forKey: Key.phoneControlDeviceOptions)
            }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.appearanceMode = AppAppearanceMode(rawValue: defaults.string(forKey: Key.appearanceMode) ?? "") ?? .system
        self.contentBackgroundStyle = AppContentBackgroundStyle(
            rawValue: defaults.string(forKey: Key.contentBackgroundStyle) ?? ""
        ) ?? .glass
        self.edgeToEdgeSidebar = defaults.object(forKey: Key.edgeToEdgeSidebar) as? Bool ?? true
        self.loadMediaThumbnails = defaults.object(forKey: Key.loadMediaThumbnails) as? Bool ?? true
        self.showDetailMediaPreviews = defaults.object(forKey: Key.showDetailMediaPreviews) as? Bool ?? true
        self.thumbnailMaxFileSizeMB = defaults.object(forKey: Key.thumbnailMaxFileSizeMB) as? Int ?? 75
        self.mediaCacheLimitMB = defaults.object(forKey: Key.mediaCacheLimitMB) as? Int ?? 4096
        self.clearMediaCacheOnQuit = defaults.object(forKey: Key.clearMediaCacheOnQuit) as? Bool ?? false
        if defaults.bool(forKey: Key.previewCacheEncryptionDefaultMigrated) {
            self.encryptPreviewCache = defaults.object(forKey: Key.encryptPreviewCache) as? Bool ?? false
        } else {
            // Encryption originally shipped enabled by default. Move existing installs
            // to the new opt-in default once, then preserve the user's later choice.
            self.encryptPreviewCache = false
            defaults.set(false, forKey: Key.encryptPreviewCache)
            defaults.set(true, forKey: Key.previewCacheEncryptionDefaultMigrated)
        }
        self.previewCacheRetention = PreviewCacheRetention(
            rawValue: defaults.object(forKey: Key.previewCacheRetentionMinutes) as? Int ?? 30
        ) ?? .thirtyMinutes
        self.useFinderStyleIconColors = defaults.object(forKey: Key.useFinderStyleIconColors) as? Bool ?? true
        self.showPathBar = defaults.object(forKey: Key.showPathBar) as? Bool ?? true
        self.calculateFolderSizes = defaults.object(forKey: Key.calculateFolderSizes) as? Bool ?? true
        self.showUploadToolbarButton = defaults.object(forKey: Key.showUploadToolbarButton) as? Bool ?? false
        self.showDownloadToolbarButton = defaults.object(forKey: Key.showDownloadToolbarButton) as? Bool ?? false
        self.showBatchRenameToolbarButton = defaults.object(
            forKey: Key.showBatchRenameToolbarButton
        ) as? Bool ?? false
        self.showCompressToolbarButton = defaults.object(forKey: Key.showCompressToolbarButton) as? Bool ?? false
        self.showUncompressToolbarButton = defaults.object(
            forKey: Key.showUncompressToolbarButton
        ) as? Bool ?? false
        self.showConnectionStatusToolbarButton = defaults.object(
            forKey: Key.showConnectionStatusToolbarButton
        ) as? Bool ?? false
        self.openPreviewOnDoubleClick = defaults.object(forKey: Key.openPreviewOnDoubleClick) as? Bool ?? true
        self.autoLoadAppDetails = defaults.object(forKey: Key.autoLoadAppDetails) as? Bool ?? true
        self.confirmBeforeUninstallingApps = defaults.object(forKey: Key.confirmBeforeUninstallingApps) as? Bool ?? true
        if let storedBehavior = defaults.string(forKey: Key.trashQuitBehavior),
           let behavior = TrashQuitBehavior(rawValue: storedBehavior) {
            self.trashQuitBehavior = behavior
        } else {
            let legacyConfirmation = defaults.object(forKey: Key.confirmEmptyTrashAtSessionEnd) as? Bool ?? true
            self.trashQuitBehavior = legacyConfirmation ? .ask : .keep
        }
        self.showTrashItemCount = defaults.object(forKey: Key.showTrashItemCount) as? Bool ?? true
        self.showDefaultQuickLocations = defaults.object(forKey: Key.showDefaultQuickLocations) as? Bool ?? true
        self.hiddenDefaultQuickLocationIDs = Set(defaults.stringArray(forKey: Key.hiddenDefaultQuickLocationIDs) ?? [])
        self.showUSBTransferWhenADBConnected = defaults.object(forKey: Key.showUSBTransferWhenADBConnected) as? Bool ?? false
        self.checkConnectionModesOnLaunch = defaults.object(forKey: Key.checkConnectionModesOnLaunch) as? Bool ?? true
        self.adbToolMode = ToolSelectionMode(rawValue: defaults.string(forKey: Key.adbToolMode) ?? "") ?? .automatic
        self.adbToolPath = defaults.string(forKey: Key.adbToolPath) ?? ""
        self.scrcpyToolMode = ToolSelectionMode(rawValue: defaults.string(forKey: Key.scrcpyToolMode) ?? "") ?? .automatic
        self.scrcpyToolPath = defaults.string(forKey: Key.scrcpyToolPath) ?? ""
        self.phoneCapturePresentation = PhoneCapturePresentationMode(
            rawValue: defaults.string(forKey: Key.phoneCapturePresentation) ?? ""
        ) ?? .attachedPopover
        self.showScreenshotSetup = defaults.object(forKey: Key.showScreenshotSetup) as? Bool ?? true
        self.showRecordingSetup = defaults.object(forKey: Key.showRecordingSetup) as? Bool ?? true
        self.showPhoneControlSetup = defaults.object(forKey: Key.showPhoneControlSetup) as? Bool ?? true
        if let data = defaults.data(forKey: Key.phoneControlDeviceOptions),
           let storedOptions = try? JSONDecoder().decode([String: PhoneControlDeviceOptions].self, from: data) {
            self.phoneControlDeviceOptions = storedOptions
        } else {
            self.phoneControlDeviceOptions = [:]
        }
        if let data = defaults.data(forKey: Key.customQuickLocations),
           let locations = try? JSONDecoder().decode([QuickLocation].self, from: data) {
            self.customQuickLocations = locations
        } else {
            self.customQuickLocations = []
        }
        defaults.set(!edgeToEdgeSidebar, forKey: Key.sidebarDefaultsToFloatingAppearance)
    }

    public func reset() {
        appearanceMode = .system
        contentBackgroundStyle = .glass
        edgeToEdgeSidebar = true
        loadMediaThumbnails = true
        showDetailMediaPreviews = true
        thumbnailMaxFileSizeMB = 75
        mediaCacheLimitMB = 4096
        clearMediaCacheOnQuit = false
        encryptPreviewCache = false
        previewCacheRetention = .thirtyMinutes
        useFinderStyleIconColors = true
        showPathBar = true
        calculateFolderSizes = true
        showUploadToolbarButton = false
        showDownloadToolbarButton = false
        showBatchRenameToolbarButton = false
        showCompressToolbarButton = false
        showUncompressToolbarButton = false
        showConnectionStatusToolbarButton = false
        openPreviewOnDoubleClick = true
        autoLoadAppDetails = true
        confirmBeforeUninstallingApps = true
        trashQuitBehavior = .ask
        showTrashItemCount = true
        showDefaultQuickLocations = true
        hiddenDefaultQuickLocationIDs = []
        customQuickLocations = []
        showUSBTransferWhenADBConnected = false
        checkConnectionModesOnLaunch = true
        adbToolMode = .automatic
        adbToolPath = ""
        scrcpyToolMode = .automatic
        scrcpyToolPath = ""
        phoneCapturePresentation = .attachedPopover
        showScreenshotSetup = true
        showRecordingSetup = true
        showPhoneControlSetup = true
        phoneControlDeviceOptions = [:]
    }

    public func phoneControlOptions(for deviceSerial: String) -> PhoneControlDeviceOptions {
        phoneControlDeviceOptions[deviceSerial] ?? PhoneControlDeviceOptions()
    }

    public func setPhoneControlOption<Value>(
        _ value: Value,
        for deviceSerial: String,
        keyPath: WritableKeyPath<PhoneControlDeviceOptions, Value>
    ) {
        var options = phoneControlOptions(for: deviceSerial)
        options[keyPath: keyPath] = value
        phoneControlDeviceOptions[deviceSerial] = options
    }

    public func setDefaultQuickLocation(id: String, visible: Bool) {
        if visible {
            hiddenDefaultQuickLocationIDs.remove(id)
        } else {
            hiddenDefaultQuickLocationIDs.insert(id)
        }
    }
}

public enum PhoneCapturePresentationMode: String, CaseIterable, Identifiable, Sendable {
    case attachedPopover
    case separateWindow

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .attachedPopover: "Attached"
        case .separateWindow: "Window"
        }
    }

    public var symbol: String {
        switch self {
        case .attachedPopover: "macwindow.badge.plus"
        case .separateWindow: "macwindow"
        }
    }
}

public enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var detail: String {
        switch self {
        case .system: "Follow macOS"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

public enum AppContentBackgroundStyle: String, CaseIterable, Identifiable, Sendable {
    case glass
    case solid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .glass: "Glass"
        case .solid: "Solid"
        }
    }

    public var detail: String {
        switch self {
        case .glass: "Let the desktop show through the file browser."
        case .solid: "Use an opaque background behind files and connection setup."
        }
    }

    public var symbol: String {
        switch self {
        case .glass: "circle.lefthalf.filled"
        case .solid: "rectangle.fill"
        }
    }
}

public enum TrashQuitBehavior: String, CaseIterable, Identifiable, Sendable {
    case ask
    case emptyAutomatically
    case keep

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .emptyAutomatically: "Empty"
        case .keep: "Keep"
        }
    }

    var detail: String {
        switch self {
        case .ask: "Ask before emptying Trash when the app quits."
        case .emptyAutomatically: "Empty Trash automatically whenever the app quits."
        case .keep: "Leave Trash available for the next session."
        }
    }

    var symbol: String {
        switch self {
        case .ask: "questionmark.circle"
        case .emptyAutomatically: "trash"
        case .keep: "archivebox"
        }
    }
}

public struct SettingsView: View {
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var model: AppModel
    @ObservedObject private var usbTransferManager: USBTransferManager
    @ObservedObject private var toolchainManager: ToolchainManager
    @State private var selectedCategory: SettingsCategory = .browser

    public init(settings: AppSettings, model: AppModel) {
        self.settings = settings
        self.model = model
        self.usbTransferManager = model.usbTransferManager
        self.toolchainManager = model.toolchainManager
    }

    public var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selectedCategory)
                .frame(width: 184)

            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsHeader(category: selectedCategory)

                    switch selectedCategory {
                    case .browser:
                        browserSettings
                    case .media:
                        mediaSettings
                    case .behavior:
                        behaviorSettings
                    case .tools:
                        toolsSettings
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.visible)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onValueChange(of: settings.phoneCapturePresentation) { _, _ in
            model.phoneCapturePresentationDidChange()
        }
    }

    private var showsADBOnlySettings: Bool {
        model.hasReadyADBDevice || usbTransferManager.devices.isEmpty
    }

    @ViewBuilder
    private var browserSettings: some View {
        SettingsSectionCard(title: "Appearance", symbol: "paintpalette") {
            SettingsThemeRow(selection: $settings.appearanceMode)

            Divider()
                .padding(.leading, 48)

            SettingsContentBackgroundRow(selection: $settings.contentBackgroundStyle)

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Edge-to-edge sidebar",
                detail: "Let the sidebar glass meet the left edge of the window.",
                symbol: "sidebar.left",
                isOn: $settings.edgeToEdgeSidebar
            )

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Finder-style icon colors",
                detail: "Tint folders and file-type fallback icons with Finder-like colors when thumbnails are not shown.",
                symbol: "folder.fill",
                isOn: $settings.useFinderStyleIconColors
            )
        }

        SettingsSectionCard(title: "File Browser", symbol: "list.bullet.rectangle") {
            SettingsToggleRow(
                title: "Show path bar",
                detail: "Shows the current folder or selection at the bottom of the browser.",
                symbol: "point.bottomleft.forward.to.point.topright.scurvepath",
                isOn: $settings.showPathBar
            )

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Calculate folder sizes",
                detail: "Shows folder sizes as they become available. This may slow browsing.",
                symbol: "folder.badge.gearshape",
                isOn: $settings.calculateFolderSizes
            )
            .onValueChange(of: settings.calculateFolderSizes) { _, isEnabled in
                model.folderSizeCalculationSettingDidChange(isEnabled: isEnabled)
            }
        }

        SettingsSectionCard(title: "Toolbar", symbol: "menubar.rectangle") {
            SettingsToggleRow(
                title: "Upload",
                detail: "Show the button for copying files from this Mac to the connected device.",
                symbol: "square.and.arrow.up",
                isOn: $settings.showUploadToolbarButton
            )

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Download",
                detail: "Show the button for copying selected files from the device to this Mac.",
                symbol: "square.and.arrow.down",
                isOn: $settings.showDownloadToolbarButton
            )

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Batch Rename",
                detail: "Show the button for renaming multiple selected files at once.",
                symbol: "textformat",
                isOn: $settings.showBatchRenameToolbarButton
            )

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Compress to ZIP",
                detail: "Show the button for creating a ZIP archive from selected items.",
                symbol: "doc.zipper",
                isOn: $settings.showCompressToolbarButton
            )

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Uncompress ZIP",
                detail: "Show the button for extracting the selected archive.",
                symbol: "archivebox",
                isOn: $settings.showUncompressToolbarButton
            )

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Connection Status",
                detail: "Show the button for Developer Options and File Transfer status.",
                symbol: "cable.connector",
                isOn: $settings.showConnectionStatusToolbarButton
            )
        }

        SettingsSectionCard(title: "Favorites", symbol: "sidebar.left") {
            SettingsToggleRow(
                title: "Default folders",
                detail: "Show default Favorites, Locations, and Apps shortcuts when the connection can see them.",
                symbol: "folder",
                isOn: $settings.showDefaultQuickLocations
            )

            if settings.showDefaultQuickLocations {
                Divider()
                    .padding(.leading, 48)

                QuickLocationVisibilityGrid(settings: settings)
            }

            if !settings.customQuickLocations.isEmpty {
                Divider()
                    .padding(.leading, 48)

                SettingsActionRow(
                    title: "Custom folders",
                    detail: "\(settings.customQuickLocations.count) sidebar shortcut\(settings.customQuickLocations.count == 1 ? "" : "s") added by drag and drop.",
                    symbol: "folder.badge.gearshape",
                    buttonTitle: "Remove All",
                    role: .destructive
                ) {
                    settings.customQuickLocations = []
                }
            }
        }

        SettingsSectionCard(title: "File Transfer", symbol: "externaldrive.connected.to.line.below") {
            SettingsToggleRow(
                title: "Check connections on launch",
                detail: "Check Developer Options first, then look for File Transfer when needed.",
                symbol: "bolt.horizontal.circle",
                isOn: $settings.checkConnectionModesOnLaunch
            )

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Show while debugging is connected",
                detail: "Keep File Transfer available when a debugging connection is active.",
                symbol: "cable.connector",
                isOn: $settings.showUSBTransferWhenADBConnected
            )
        }
    }

    @ViewBuilder
    private var mediaSettings: some View {
        SettingsSectionCard(title: "Previews", symbol: "photo.on.rectangle.angled") {
            SettingsToggleRow(
                title: "Media thumbnails",
                detail: "Show image and video thumbnails while browsing files.",
                symbol: "sparkles.rectangle.stack",
                isOn: $settings.loadMediaThumbnails
            )

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Detail previews",
                detail: "Show images and video frames in the details panel.",
                symbol: "sidebar.right",
                isOn: $settings.showDetailMediaPreviews
            )

            Divider()
                .padding(.leading, 48)

            SettingsStepperRow(
                title: "Thumbnail file limit",
                detail: "Skip thumbnails for individual files above this size.",
                symbol: "speedometer",
                value: $settings.thumbnailMaxFileSizeMB,
                range: 5...500,
                step: 5,
                suffix: "MB"
            )
            .disabled(!settings.loadMediaThumbnails && !settings.showDetailMediaPreviews)
            .opacity(settings.loadMediaThumbnails || settings.showDetailMediaPreviews ? 1 : 0.48)
        }

        SettingsSectionCard(title: "Cache", symbol: "internaldrive") {
            SettingsCacheActionRow(
                title: "Preview files",
                detail: "Temporary file copies, captures, app icons, and drag-and-drop files.",
                symbol: "doc.on.doc",
                bytes: model.cacheUsage.previewBytes,
                buttonTitle: "Clear"
            ) {
                Task { await model.clearPreviewCache() }
            }

            Divider()
                .padding(.leading, 48)

            SettingsCacheActionRow(
                title: "Thumbnails",
                detail: "Generated image and video thumbnails.",
                symbol: "photo.stack",
                bytes: model.cacheUsage.thumbnailBytes,
                buttonTitle: "Clear"
            ) {
                Task { await model.clearThumbnailCache() }
            }

            Divider()
                .padding(.leading, 48)

            SettingsCacheActionRow(
                title: "All cache",
                detail: "Clear every temporary file created by ASOP File Browser.",
                symbol: "trash",
                bytes: model.cacheUsage.totalBytes,
                buttonTitle: "Clear All",
                role: .destructive
            ) {
                Task { await model.clearAllCaches() }
            }
        }

        SettingsSectionCard(title: "Storage", symbol: "gauge.with.dots.needle.33percent") {
            SettingsCacheLimitRow(limitMB: $settings.mediaCacheLimitMB)

            Divider()
                .padding(.leading, 48)

            SettingsRowShell(
                title: "Remove unused previews",
                detail: "Delete full-size preview copies while the app is open and check again at launch.",
                symbol: "clock.arrow.circlepath"
            ) {
                Picker("Remove unused previews", selection: $settings.previewCacheRetention) {
                    ForEach(PreviewCacheRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Encrypt preview cache",
                detail: "Protect saved preview copies. Turning this off can make large previews open faster.",
                symbol: "lock",
                isOn: $settings.encryptPreviewCache
            )

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Clear all cache when quitting",
                detail: "Full-size previews are always removed. Also delete generated thumbnails when the app quits.",
                symbol: "power",
                isOn: $settings.clearMediaCacheOnQuit
            )
        }
        .task {
            await model.refreshCacheUsage()
        }
        .onValueChange(of: settings.encryptPreviewCache) { _, _ in
            Task { await model.updatePreviewCacheProtection() }
        }
        .onValueChange(of: settings.previewCacheRetention) { _, _ in
            Task { await model.performPreviewCacheMaintenance(force: true) }
        }
    }

    @ViewBuilder
    private var behaviorSettings: some View {
        SettingsSectionCard(title: "Phone Capture", symbol: "camera.viewfinder") {
            SettingsRowShell(
                title: "Controls",
                detail: "Open screenshot, recording, and Phone Control settings from the main toolbar or in a separate window.",
                symbol: settings.phoneCapturePresentation.symbol
            ) {
                Picker("Phone Capture controls", selection: $settings.phoneCapturePresentation) {
                    ForEach(PhoneCapturePresentationMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Screenshot options",
                detail: "Show appearance and demo options below the display selector.",
                symbol: "camera",
                isOn: $settings.showScreenshotSetup
            )

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Recording options",
                detail: "Show recording, video, appearance, touch, and demo options below the display selector.",
                symbol: "record.circle",
                isOn: $settings.showRecordingSetup
            )

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Phone Control setup",
                detail: "Show video, appearance, touch, and demo settings before opening Phone Control.",
                symbol: "rectangle.connected.to.line.below",
                isOn: $settings.showPhoneControlSetup
            )
        }

        SettingsSectionCard(title: "Files", symbol: "doc.on.doc") {
            SettingsToggleRow(
                title: "Preview on double-click",
                detail: "Open files in a separate preview window instead of changing the detail panel.",
                symbol: "eye",
                isOn: $settings.openPreviewOnDoubleClick
            )

        }

        SettingsSectionCard(title: "Trash", symbol: "trash") {
            SettingsTrashQuitRow(selection: $settings.trashQuitBehavior)

            Divider()
                .padding(.leading, 48)

            SettingsToggleRow(
                title: "Show item count in sidebar",
                detail: "Show the number of restorable Trash items beside the sidebar shortcut.",
                symbol: "number.circle",
                isOn: $settings.showTrashItemCount
            )
        }

        if showsADBOnlySettings {
            SettingsSectionCard(title: "Apps", symbol: "app.dashed") {
                SettingsToggleRow(
                    title: "Load details on selection",
                    detail: "Fetch permissions, activities, and package details when an app is selected.",
                    symbol: "list.bullet.rectangle",
                    isOn: $settings.autoLoadAppDetails
                )

                Divider()
                    .padding(.leading, 48)

                SettingsToggleRow(
                    title: "Confirm uninstall",
                    detail: "Ask before removing selected apps from the Android device.",
                    symbol: "exclamationmark.triangle",
                    isOn: $settings.confirmBeforeUninstallingApps
                )
            }
        }

        SettingsSectionCard(title: "Reset", symbol: "arrow.counterclockwise") {
            SettingsActionRow(
                title: "Restore defaults",
                detail: "Return browsing, behavior, and testing preferences to their original values.",
                symbol: "gearshape.arrow.triangle.2.circlepath",
                buttonTitle: "Reset",
                role: .destructive
            ) {
                settings.reset()
            }
        }
    }

    @ViewBuilder
    private var toolsSettings: some View {
        SettingsSectionCard(title: "Phone Tools", symbol: "wrench.and.screwdriver") {
            ManagedToolchainSettingsRow(
                manager: toolchainManager,
                settings: settings
            )
        }

        SettingsSectionCard(title: "ADB", symbol: ToolchainTool.adb.symbol) {
            ToolSelectionRow(
                tool: .adb,
                mode: $settings.adbToolMode,
                customPath: $settings.adbToolPath,
                manager: toolchainManager
            )
        }

        SettingsSectionCard(title: "scrcpy", symbol: ToolchainTool.scrcpy.symbol) {
            ToolSelectionRow(
                tool: .scrcpy,
                mode: $settings.scrcpyToolMode,
                customPath: $settings.scrcpyToolPath,
                manager: toolchainManager
            )
        }
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case browser
    case media
    case behavior
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser: "Browser"
        case .media: "Media"
        case .behavior: "Behavior"
        case .tools: "Tools"
        }
    }

    var subtitle: String {
        switch self {
        case .browser: "Browsing and connections"
        case .media: "Previews, thumbnails, and cache"
        case .behavior: "Files, apps, and reset"
        case .tools: "Connections and Phone Control"
        }
    }

    var symbol: String {
        switch self {
        case .browser: "sidebar.left"
        case .media: "photo.on.rectangle.angled"
        case .behavior: "switch.2"
        case .tools: "hammer"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.top, 20)

            VStack(spacing: 6) {
                ForEach(SettingsCategory.allCases) { category in
                    SettingsSidebarButton(
                        category: category,
                        isSelected: selection == category
                    ) {
                        selection = category
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()
        }
        .background(.thinMaterial)
    }
}

private struct SettingsSidebarButton: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: category.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 24, height: 24)

                Text(category.title)
                    .font(.callout.weight(.semibold))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
    }
}

private struct SettingsHeader: View {
    let category: SettingsCategory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: category.symbol)
                .font(.system(size: 26, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 42, height: 42)
                .liquidGlassPanel(in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(category.title)
                    .font(.title.weight(.semibold))
                Text(category.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(.headline)
                Spacer()
            }

            VStack(spacing: 0) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 16, style: .continuous), fallbackMaterial: .regularMaterial)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsRowShell(title: title, detail: detail, symbol: symbol) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

private struct SettingsThemeRow: View {
    @Binding var selection: AppAppearanceMode

    var body: some View {
        SettingsRowShell(
            title: "Theme",
            detail: "Choose a fixed appearance for screenshots, demos, and day-to-day browsing.",
            symbol: selection.symbol
        ) {
            Picker("Theme", selection: $selection) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 246)
            .labelsHidden()
        }
    }
}

private struct SettingsContentBackgroundRow: View {
    @Binding var selection: AppContentBackgroundStyle

    var body: some View {
        SettingsRowShell(
            title: "Content background",
            detail: selection.detail,
            symbol: selection.symbol
        ) {
            Picker("Content background", selection: $selection) {
                ForEach(AppContentBackgroundStyle.allCases) { style in
                    Label(style.title, systemImage: style.symbol)
                        .tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .labelsHidden()
        }
    }
}

private struct SettingsStepperRow: View {
    let title: String
    let detail: String
    let symbol: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let suffix: String

    var body: some View {
        SettingsRowShell(title: title, detail: detail, symbol: symbol) {
            HStack(spacing: 10) {
                Text("\(value) \(suffix)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .trailing)
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
            }
        }
    }
}

private struct SettingsActionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let buttonTitle: String
    let role: ButtonRole?
    let action: () -> Void

    var body: some View {
        SettingsRowShell(title: title, detail: detail, symbol: symbol) {
            Button(role: role, action: action) {
                Text(buttonTitle)
                    .frame(minWidth: 74)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }
}

private struct SettingsCacheActionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let bytes: Int64
    let buttonTitle: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        SettingsRowShell(title: title, detail: detail, symbol: symbol) {
            HStack(spacing: 10) {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Button(role: role, action: action) {
                    Text(buttonTitle)
                        .frame(minWidth: 64)
                }
                .buttonStyle(.bordered)
                .disabled(bytes == 0)
            }
        }
    }
}

private struct SettingsCacheLimitRow: View {
    @Binding var limitMB: Int

    private let limits = [512, 1024, 2048, 4096, 8192, 16384]

    var body: some View {
        SettingsRowShell(
            title: "Cache limit",
            detail: "Older temporary files are removed when the cache grows past this size.",
            symbol: "gauge.with.dots.needle.33percent"
        ) {
            Picker("Cache limit", selection: $limitMB) {
                ForEach(limits, id: \.self) { megabytes in
                    Text(label(for: megabytes)).tag(megabytes)
                }
            }
            .labelsHidden()
            .frame(width: 118)
        }
    }

    private func label(for megabytes: Int) -> String {
        if megabytes < 1024 {
            return "\(megabytes) MB"
        }
        return "\(megabytes / 1024) GB"
    }
}

private struct SettingsTrashQuitRow: View {
    @Binding var selection: TrashQuitBehavior

    var body: some View {
        SettingsRowShell(
            title: "When quitting",
            detail: selection.detail,
            symbol: selection.symbol
        ) {
            Picker("When quitting", selection: $selection) {
                ForEach(TrashQuitBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
        }
    }
}

private struct ManagedToolchainSettingsRow: View {
    @ObservedObject var manager: ToolchainManager
    @ObservedObject var settings: AppSettings

    private var isInstalling: Bool {
        ToolchainTool.allCases.contains { tool in
            if case .installing = manager.status(for: tool) { return true }
            return false
        }
    }

    private var needsRepair: Bool {
        ToolchainTool.allCases.contains { tool in
            if case .needsRepair = manager.status(for: tool) { return true }
            return false
        }
    }

    private var allToolsReady: Bool {
        ToolchainTool.allCases.allSatisfy { manager.status(for: $0).isReady }
    }

    private var managedDownloadIsSelected: Bool {
        settings.adbToolMode == .managed || settings.scrcpyToolMode == .managed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsRowShell(
                title: allToolsReady ? "Phone tools are ready" : "Phone tools need setup",
                detail: allToolsReady
                    ? "Using compatible tools already available on this Mac."
                    : "Download a verified managed copy, or choose tools already on this Mac.",
                symbol: allToolsReady ? "checkmark.circle" : "wrench.and.screwdriver"
            ) {
                if isInstalling {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 92)
                } else {
                    HStack(spacing: 8) {
                        if manager.hasManagedTools {
                            Button("Remove") {
                                Task { await removeManagedTools() }
                            }
                            .buttonStyle(.bordered)
                        }

                        if manager.hasManagedTools {
                            Button(needsRepair ? "Repair" : "Update") {
                                Task { await installManagedTools() }
                            }
                            .buttonStyle(.bordered)
                        } else if !allToolsReady, !managedDownloadIsSelected {
                            Button("Download") {
                                Task { await installManagedTools() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ToolHealthLine(tool: .adb, health: manager.status(for: .adb))
                ToolHealthLine(tool: .scrcpy, health: manager.status(for: .scrcpy))
            }
            .padding(.leading, 44)

            if let error = manager.lastInstallError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(.leading, 44)
            }
        }
        .padding(.vertical, 4)
        .task {
            await manager.refresh()
        }
    }

    private func installManagedTools() async {
        let oldADBMode = settings.adbToolMode
        let oldScrcpyMode = settings.scrcpyToolMode
        if shouldReplaceCurrentSelection(for: .adb) {
            settings.adbToolMode = .automatic
        }
        if shouldReplaceCurrentSelection(for: .scrcpy) {
            settings.scrcpyToolMode = .automatic
        }
        if !(await manager.installManagedTools()) {
            settings.adbToolMode = oldADBMode
            settings.scrcpyToolMode = oldScrcpyMode
            await manager.refresh()
        }
    }

    private func removeManagedTools() async {
        await manager.removeManagedTools()
    }

    private func shouldReplaceCurrentSelection(for tool: ToolchainTool) -> Bool {
        switch manager.status(for: tool) {
        case .missing, .needsRepair:
            true
        default:
            false
        }
    }
}

private struct ToolHealthLine: View {
    let tool: ToolchainTool
    let health: ToolchainHealth

    private var presentation: (symbol: String, color: Color, text: String) {
        switch health {
        case .unknown:
            ("circle.dotted", .secondary, "Not checked")
        case .checking:
            ("arrow.clockwise", .secondary, "Checking…")
        case .installing:
            ("arrow.down.circle", .accentColor, "Installing…")
        case .ready(let candidate, let version):
            ("checkmark.circle.fill", .green, "\(version) · \(candidate.sourceTitle)")
        case .missing:
            ("exclamationmark.triangle.fill", .orange, "Not found")
        case .needsRepair(let message):
            ("exclamationmark.triangle.fill", .orange, message)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: presentation.symbol)
                .foregroundStyle(presentation.color)
            Text(tool.title)
                .font(.caption.weight(.semibold))
                .frame(width: 52, alignment: .leading)
            Text(presentation.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct ToolSelectionRow: View {
    let tool: ToolchainTool
    @Binding var mode: ToolSelectionMode
    @Binding var customPath: String
    @ObservedObject var manager: ToolchainManager
    @State private var candidates: [ToolchainCandidate] = []

    private var selection: Binding<String> {
        Binding(
            get: {
                switch mode {
                case .automatic:
                    return Self.automaticTag
                case .managed:
                    return Self.managedTag
                case .bundled:
                    return Self.bundledTag
                case .custom:
                    return Self.pathTag(customPath)
                }
            },
            set: { tag in
                if tag == Self.automaticTag {
                    mode = .automatic
                } else if tag == Self.managedTag {
                    mode = .managed
                } else if tag == Self.bundledTag {
                    mode = .bundled
                } else if let path = Self.path(from: tag) {
                    customPath = path
                    mode = .custom
                }
                refresh()
            }
        )
    }

    private var detail: String {
        switch mode {
        case .automatic:
            "Uses the managed copy first, then compatible tools already installed on this Mac."
        case .managed:
            manager.hasManagedTools
                ? "Uses the verified copy managed by ASOP File Browser."
                : "Download a managed copy to use this option."
        case .custom:
            customPath.isEmpty ? "Choose a specific \(tool.executableName) executable." : customPath
        case .bundled:
            "Uses the copy supplied inside this app bundle."
        }
    }

    private var statusText: String {
        switch manager.status(for: tool) {
        case .ready(let candidate, let version):
            return "\(version) · \(candidate.sourceTitle)"
        case .needsRepair(let message):
            return message
        case .missing:
            return "\(tool.title) was not found."
        case .checking:
            return "Checking \(tool.title)…"
        case .installing:
            return "Installing \(tool.title)…"
        case .unknown:
            return "\(tool.title) has not been checked."
        }
    }

    private var statusIsReady: Bool {
        manager.status(for: tool).isReady
    }

    private var statusHelp: String {
        if case .ready(let candidate, _) = manager.status(for: tool) {
            return candidate.url.path
        }
        return statusText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRowShell(title: "\(tool.title) source", detail: detail, symbol: tool.symbol) {
                EmptyView()
            }

            HStack(spacing: 8) {
                Picker("\(tool.title) source", selection: selection) {
                    Text("Automatic").tag(Self.automaticTag)
                    Text(manager.hasManagedTools ? "Managed Copy" : "Managed Copy — Download Required")
                        .tag(Self.managedTag)
                    if candidates.contains(where: \.isBundled) || mode == .bundled {
                        Text(candidates.contains(where: \.isBundled) ? "Bundled Copy" : "Bundled Copy — Unavailable")
                            .tag(Self.bundledTag)
                    }

                    if !candidateOptions.isEmpty {
                        Divider()
                        ForEach(candidateOptions) { candidate in
                            Text(candidate.menuTitle).tag(Self.pathTag(candidate.url.path))
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .layoutPriority(1)

                if mode == .managed, !manager.hasManagedTools {
                    Button("Download") {
                        Task {
                            _ = await manager.installManagedTools()
                            refresh()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                }

                Button("Choose…") {
                    chooseExecutable()
                }
                .buttonStyle(.bordered)
                .fixedSize()

                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh detected \(tool.title) tools")
            }
            .padding(.leading, 44)

            HStack(spacing: 8) {
                Image(systemName: statusIsReady ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(statusIsReady ? Color.green : Color.orange)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(statusHelp)
                Spacer(minLength: 0)
            }
            .padding(.leading, 44)
        }
        .padding(.vertical, 4)
        .onAppear {
            candidates = ToolchainLocator.detectedCandidates(for: tool)
        }
    }

    private var candidateOptions: [ToolchainCandidate] {
        var options = candidates.filter { !$0.isManaged && !$0.isBundled }
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           !options.contains(where: { $0.url.path == trimmed }) {
            options.insert(
                ToolchainCandidate(tool: tool, url: URL(fileURLWithPath: trimmed), source: .selected, isRunning: false),
                at: 0
            )
        }
        return options
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose \(tool.title)"
        panel.prompt = "Use"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaultDirectoryURL
        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            mode = .custom
            refresh()
        }
    }

    private var defaultDirectoryURL: URL? {
        if !customPath.isEmpty {
            return URL(fileURLWithPath: customPath).deletingLastPathComponent()
        }
        return candidates.first?.url.deletingLastPathComponent()
    }

    private func refresh() {
        candidates = ToolchainLocator.detectedCandidates(for: tool)
        Task { await manager.refresh() }
    }

    private static let automaticTag = "mode:automatic"
    private static let managedTag = "mode:managed"
    private static let bundledTag = "mode:bundled"

    private static func pathTag(_ path: String) -> String {
        "path:\(path)"
    }

    private static func path(from tag: String) -> String? {
        guard tag.hasPrefix("path:") else { return nil }
        return String(tag.dropFirst("path:".count))
    }
}

private struct SettingsRowShell<Trailing: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            trailing
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuickLocationVisibilityGrid: View {
    @ObservedObject var settings: AppSettings

    private let columns = [
        GridItem(.adaptive(minimum: 164, maximum: 220), spacing: 10)
    ]

    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(AppModel.defaultQuickLocations) { location in
                    QuickLocationVisibilityButton(
                        location: location,
                        isVisible: Binding(
                            get: { !settings.hiddenDefaultQuickLocationIDs.contains(location.id) },
                            set: { visible in
                                settings.setDefaultQuickLocation(id: location.id, visible: visible)
                            }
                        )
                    )
                }
            }
            .padding(.trailing, 4)
        }
        .frame(maxHeight: 174)
        .scrollIndicators(.visible)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct QuickLocationVisibilityButton: View {
    let location: QuickLocation
    @Binding var isVisible: Bool

    var body: some View {
        Button {
            isVisible.toggle()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: location.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 22)

                Text(location.title)
                    .font(.callout)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: isVisible ? "eye.fill" : "eye.slash")
                    .foregroundStyle(isVisible ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(isVisible ? 1 : 0.56)
        .help(isVisible ? "Hide \(location.title)" : "Show \(location.title)")
    }
}
