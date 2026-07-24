import AppKit
import Combine
import Darwin
import Foundation
import MTPKit
import SwiftUI
import UniformTypeIdentifiers

private struct LocalUploadFile: Sendable {
    let url: URL
    let relativeDirectory: String
    let remoteName: String
    let size: Int64?
}

private struct LocalUploadRequest: Sendable {
    let url: URL
    var remoteName: String
    var replace: Bool
    let isDirectory: Bool
    let directories: [String]
    let files: [LocalUploadFile]

    var totalBytes: Int64? {
        let knownSizes = files.compactMap(\.size)
        guard knownSizes.count == files.count else { return nil }
        return knownSizes.reduce(0, +)
    }
}

private struct PreparedCaptureDevice {
    let device: AndroidDevice
    let restorePlan: ScreenRecordingRestorePlan
    let shouldRestoreAfterCapture: Bool
}

private struct ScreenRecordingLaunchOutcome: @unchecked Sendable {
    let device: AndroidDevice
    let handle: ADBScreenRecordingProcess?
    let errorMessage: String?
}

private struct FileHistoryFolder {
    let parent: String
    let name: String

    var path: String {
        ADBClient.joinRemote(parent, name)
    }
}

private struct FileHistoryRenameStep {
    let sourcePath: String
    let destinationName: String
}

private struct FileHistoryMoveStep {
    let sourcePath: String
    let destinationDirectory: String
    let destinationName: String
    let replace: Bool
}

private struct OptimisticRemoteMovePlan {
    let item: RemoteBrowserDragItem
    let originalFile: AndroidFile
    let sourceParent: String
    let destinationName: String
    let destinationPath: String
    let replacedDestination: AndroidFile?
    let sourceWasInSearchResults: Bool
    let replacedDestinationSearchResults: [AndroidFile]
}

private enum TrashRecordsStorage {
    case applicationSupport
    case file(URL)
    case memoryOnly
}

private indirect enum FileHistoryOperation {
    case createFolders(deviceSerial: String, folders: [FileHistoryFolder], actionName: String)
    case deletePaths(deviceSerial: String, paths: [String], redo: FileHistoryOperation, actionName: String)
    case rename(deviceSerial: String, steps: [FileHistoryRenameStep], actionName: String)
    case trashItems(deviceSerial: String, items: [RemoteClipboardItem], actionName: String)
    case restoreTrash(deviceSerial: String, records: [TrashRecord], actionName: String)
    case copyItems(deviceSerial: String, items: [RemoteClipboardItem], destination: String, destinationNames: [String], actionName: String)
    case moveItems(deviceSerial: String, steps: [FileHistoryMoveStep], actionName: String)
    case queuedTransfer(jobID: UUID, completedUndo: FileHistoryOperation, redo: FileHistoryOperation, actionName: String)
    case group(operations: [FileHistoryOperation], actionName: String)

    var actionName: String {
        switch self {
        case .createFolders(_, _, let actionName),
             .deletePaths(_, _, _, let actionName),
             .rename(_, _, let actionName),
             .trashItems(_, _, let actionName),
             .restoreTrash(_, _, let actionName),
             .copyItems(_, _, _, _, let actionName),
             .moveItems(_, _, let actionName),
             .queuedTransfer(_, _, _, let actionName),
             .group(_, let actionName):
            actionName
        }
    }
}

struct UploadFilePresentation: Hashable {
    let state: TransferJobState
    let progressFraction: Double?
    let sourceURL: URL?
    let statusText: String
    let errorMessage: String?
    let isSynthetic: Bool

    var isGhosted: Bool {
        isSynthetic && state == .queued || isSynthetic && state == .running
    }

    var detailText: String {
        switch state {
        case .queued:
            "Queued"
        case .running:
            if let progressFraction {
                "Uploading \(Int(progressFraction * 100))%"
            } else {
                "Uploading"
            }
        case .completed:
            "Done"
        case .failed:
            errorMessage ?? "Upload failed"
        case .canceled:
            "Canceled"
        }
    }
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public var devices: [AndroidDevice] = []
    @Published public var selectedDeviceID: AndroidDevice.ID? {
        didSet {
            guard oldValue != selectedDeviceID else { return }
            invalidateADBDeviceSession()
        }
    }
    @Published public var sidebarSelection: SidebarDestination? {
        didSet { scheduleFullDeviceSearchIfNeeded() }
    }
    @Published public var currentPath = "/storage/emulated/0"
    @Published public var files: [AndroidFile] = []
    @Published public var selectedFileIDs = Set<AndroidFile.ID>()
    @Published public var browserLayout: BrowserLayout = .list
    @Published public var sort: FileSort = .name
    @Published public var sortAscending = true
    @Published public var fileSortDescriptors: [FileSortDescriptor] = [
        FileSortDescriptor(sort: .name, ascending: true)
    ]
    @Published public var visibleFileColumns = Set(FileColumn.allCases.filter { $0 != .created })
    @Published public var searchText = "" {
        didSet { scheduleFullDeviceSearchIfNeeded() }
    }
    @Published public var searchScope: FileSearchScope = .currentFolder {
        didSet { scheduleFullDeviceSearchIfNeeded() }
    }
    @Published public var searchKindFilter: FileSearchKindFilter = .any {
        didSet { scheduleFullDeviceSearchIfNeeded() }
    }
    @Published public var searchDateFilter: FileSearchDateFilter = .any {
        didSet { scheduleFullDeviceSearchIfNeeded() }
    }
    @Published public private(set) var searchResults: [AndroidFile] = []
    @Published public private(set) var isSearchingFullDevice = false
    @Published public var showInspector = true
    @Published public var statusMessage = "Connect an Android device over USB or Wi-Fi."
    @Published public private(set) var adbRuntimeIssue: String?
    @Published public private(set) var isBusy = false
    @Published public private(set) var isPreparingForTermination = false
    @Published public private(set) var isCapturingScreenshot = false
    @Published public private(set) var isLaunchingScrcpy = false
    @Published public private(set) var isStartingScreenRecording = false
    @Published public private(set) var screenRecordingRequestDeviceSerial: String?
    @Published public private(set) var isFinishingScreenRecording = false
    @Published public private(set) var isApplyingCapturePresentation = false
    @Published public var screenshotOptions = ScreenRecordingOptions()
    @Published public var screenRecordingOptions = ScreenRecordingOptions()
    @Published public var phoneControlOptions = ScreenRecordingOptions()
    @Published public var screenshotCaptureDeviceSerials: Set<String> = []
    @Published public var recordingCaptureDeviceSerials: Set<String> = []
    @Published public private(set) var screenRecordingSession: ScreenRecordingSession?
    @Published public private(set) var phoneControlSessions: [PhoneControlSession] = []
    @Published public private(set) var phoneControlCapabilityStates: [String: PhoneControlCapabilityState] = [:]
    @Published public private(set) var captureAppChoices: [AndroidPackage] = []
    @Published public private(set) var isLoadingCaptureApps = false
    @Published var activePhoneCapturePopoverMode: PhoneCaptureMode?
    @Published var connectionMode: ConnectionMode = .adb
    @Published public private(set) var shouldShowADBSetupAfterConnectionModeSwitch = false
    @Published public var showUploadImporter = false
    @Published public var uploadTargetPath: String?
    @Published public var showAPKImporter = false
    @Published public private(set) var isInstallingAppPackage = false
    @Published public var pendingAppInstallRecovery: AppInstallRecoveryRequest?
    @Published public var previewURL: URL?
    @Published public var thumbnailURLs: [AndroidFile.ID: URL] = [:]
    @Published public private(set) var cacheUsage = AppCacheUsage.zero
    @Published public private(set) var isRefreshingCacheUsage = false
    @Published public private(set) var mediaMetadataByFileID: [AndroidFile.ID: RemoteFileMetadata] = [:]
    @Published public private(set) var loadingMediaMetadataFileIDs = Set<AndroidFile.ID>()
    @Published public private(set) var failedMediaMetadataFileMessages: [AndroidFile.ID: String] = [:]
    @Published public private(set) var folderSizeBytesByPath: [AndroidFile.ID: Int64] = [:]
    @Published public private(set) var loadingFolderSizePaths = Set<AndroidFile.ID>()
    @Published public private(set) var failedFolderSizePaths = Set<AndroidFile.ID>()
    @Published public private(set) var isLoadingCurrentFolder = false
    @Published public private(set) var isSwitchingADBDevice = false
    @Published public var trashRecords: [TrashRecord] = []
    @Published public private(set) var fileHistoryRevision = 0
    @Published public private(set) var isRunningFileHistoryOperation = false
    @Published public var packages: [AndroidPackage] = []
    @Published public var selectedPackageIDs = Set<AndroidPackage.ID>()
    @Published public var appSort: AppColumn = .status
    @Published public var appSortAscending = true
    @Published public var appSortDescriptors: [AppSortDescriptor] = [
        AppSortDescriptor(column: .status, ascending: true)
    ]
    @Published public var visibleAppColumns = Set(AppColumn.allCases)
    @Published public var appKind: AppKind = .user {
        didSet {
            guard oldValue != appKind else { return }
            packages.removeAll()
            selectedPackageIDs.removeAll()
            lastSelectedPackageID = nil
        }
    }
    @Published public var storageSummaries: [StorageSummary] = []
    @Published public private(set) var storageBreakdowns: [StorageSummary.ID: StorageBreakdown] = [:]
    @Published public private(set) var storageCategoryFileLists: [StorageCategoryFileList.ID: StorageCategoryFileList] = [:]
    @Published public var selectedStorageCategoryID: StorageBreakdownCategory.ID?
    @Published public var expandedStorageAppPackageIDs = Set<AndroidPackage.ID>()
    @Published public private(set) var loadingStorageAppPackageIDs = Set<AndroidPackage.ID>()
    @Published public private(set) var loadingStorageBreakdownID: StorageSummary.ID?
    @Published public private(set) var loadingStorageCategoryID: StorageCategoryFileList.ID?
    @Published public private(set) var prefetchingStorageBreakdownIDs = Set<StorageSummary.ID>()
    @Published public private(set) var prefetchingStorageCategoryIDs = Set<StorageCategoryFileList.ID>()
    @Published public private(set) var isPrefetchingStorageCategories = false
    @Published public private(set) var batteryStatuses: [AndroidDevice.ID: BatteryStatus] = [:]
    @Published public private(set) var wirelessADBSetupStates: [AndroidDevice.ID: ADBWirelessSetupState] = [:]
    @Published public var wirelessADBSetupPresentation: ADBWirelessSetupPresentation?
    @Published public var pendingRename: AndroidFile?
    @Published public var inlineRenameFileID: AndroidFile.ID?
    @Published var pendingBatchRenameRequest: BatchRenameRequest?
    @Published public var pendingNewFolder = false
    private var pendingNewFolderParentPath: String?
    @Published var pendingArchiveRequest: ArchiveCreationRequest?
    @Published public var adbQRPairingSession: ADBQRPairingSession?
    @Published public var adbQRPairingStatus = "Scan this QR code from Android Wireless debugging."
    @Published var appFolderContext: AppFolderContext?
    @Published var selectedAppStorageLocation: SelectedAppStorageLocation?
    @Published public var alert: UserAlert?
    @Published public var toolSetupRequest: ToolSetupRequest?

    public static let defaultQuickLocations: [QuickLocation] = [
        QuickLocation(id: "home", title: "Internal Storage", path: "/storage/emulated/0", symbol: "internaldrive"),
        QuickLocation(id: "downloads", title: "Downloads", path: "/storage/emulated/0/Download", symbol: "arrow.down.circle"),
        QuickLocation(id: "music", title: "Music", path: "/storage/emulated/0/Music", symbol: "music.note"),
        QuickLocation(id: "pictures", title: "Pictures", path: "/storage/emulated/0/Pictures", symbol: "photo"),
        QuickLocation(id: "dcim", title: "Camera", path: "/storage/emulated/0/DCIM", symbol: "camera"),
        QuickLocation(id: "movies", title: "Movies", path: "/storage/emulated/0/Movies", symbol: "film"),
        QuickLocation(id: "android-media", title: "App Media", path: "/storage/emulated/0/Android/media", symbol: "square.stack.3d.up"),
        QuickLocation(id: "android-data", title: "App Data", path: "/storage/emulated/0/Android/data", symbol: "app.badge"),
        QuickLocation(id: "android-obb", title: "App OBB", path: "/storage/emulated/0/Android/obb", symbol: "shippingbox"),
        QuickLocation(id: "sdcard", title: "SD Cards", path: "/storage", symbol: "sdcard", subtitle: "External volumes", requiresProbe: true)
    ]

    private let deviceManager: DeviceManager
    private let fileRepository: AndroidFileRepository
    private let appManager: AppManagerService
    private let captureService: DeviceCaptureService
    private let captureCompositionService: CaptureCompositionService
    private let thumbnailService: ThumbnailService
    private let thumbnailRequestScheduler = ADBThumbnailRequestScheduler(maximumConcurrentRequests: 1)
    private let cacheStore: AppCacheStore
    private let adb: ADBClient
    private var remoteClipboard: RemoteClipboard?
    private var loadingThumbnailIDs = Set<AndroidFile.ID>()
    private var thumbnailCacheKeysByFileID: [AndroidFile.ID: String] = [:]
    private var requestedThumbnailCacheKeysByFileID: [AndroidFile.ID: String] = [:]
    private var cacheMaintenanceTask: Task<Void, Never>?
    private var lastPreviewCacheMaintenanceAt: Date?
    private var lastSelectedFileID: AndroidFile.ID?
    private var keyboardSelectionAnchorFileID: AndroidFile.ID?
    private var lastSelectedPackageID: AndroidPackage.ID?
    private var packageLoadRevision = 0
    private var searchTask: Task<Void, Never>?
    private var pendingInlineRenameWorkItem: DispatchWorkItem?
    private var inlineRenameBlockedBySelectionFileID: AndroidFile.ID?
    private var lastSelectionFileOrder: [AndroidFile] = []
    private var storageCategoryPrefetchTask: Task<Void, Never>?
    private var storageCategoryPrefetchSignature: String?
    private var transferQueueJobsCancellable: AnyCancellable?
    private var usbTransferManagerCancellable: AnyCancellable?
    private var delayedTransferPresentationTasks: [UUID: Task<Void, Never>] = [:]
    private var presentedDelayedTransferJobIDs = Set<UUID>()
    private var screenRecordingHandles: [String: ADBScreenRecordingProcess] = [:]
    private var screenRecordingRestorePlans: [String: ScreenRecordingRestorePlan] = [:]
    private var screenRecordingMonitorTask: Task<Void, Never>?
    private var phoneControlRestorePlans: [String: ScreenRecordingRestorePlan] = [:]
    private var phoneControlMonitorTasks: [String: Task<Void, Never>] = [:]
    private var phoneControlStopRequests = Set<String>()
    private var capturePresentationUpdateTask: Task<Void, Never>?
    private var capturePresentationRevision = 0
    private var captureAppChoicesDeviceSerial: String?
    private var fileUndoStack: [FileHistoryOperation] = []
    private var fileRedoStack: [FileHistoryOperation] = []
    private var operationActivity = OperationActivityTracker()
    private var cancellableReadTasks: [UUID: Task<Void, Never>] = [:]
    private var deviceScopedReadTaskIDs = Set<UUID>()
    private var adbDeviceSessionRevision = 0
    private var isPollingDeviceConnections = false
    private var adbNavigationTask: Task<Void, Never>?
    private var browserReconciliationTask: Task<Void, Never>?
    private var browserReconciliationRequestID: UUID?
    private var pendingBrowserReconciliationPaths = Set<String>()
    private var browserMutationRevisionsByPath: [String: Int] = [:]
    private var activeBrowserMutationCountsByPath: [String: Int] = [:]
    private var adbNavigationRevision = 0
    private var adbBackHistory: [String] = []
    private var adbForwardHistory: [String] = []
    private var adbFolderListingsByPath: [String: [AndroidFile]] = [:]
    private var treeLoadTasks: [String: Task<Void, Never>] = [:]
    private var treeLoadRequestIDs: [String: UUID] = [:]
    private var backgroundRefreshTask: Task<Void, Never>?
    private var folderSizeQueue: [AndroidFile] = []
    private var queuedFolderSizePaths = Set<String>()
    private var folderSizeWorkerTask: Task<Void, Never>?
    private var folderSizeWorkerGeneration = 0
    private let trashSessionSnapshot: TrashSessionSnapshot
    @Published public var expandedTreePaths = Set<String>()
    @Published public private(set) var treeChildrenByPath: [String: [AndroidFile]] = [:]
    @Published public private(set) var loadingTreePaths = Set<String>()
    private var adbDiscovery: ADBDiscovery?
    private var adbQRPairingTask: Task<Void, Never>?
    private var wirelessADBPreflightTask: Task<Void, Never>?
    private var pendingSecureWirelessPairingAfterSetupDismissal = false
    private var wirelessADBSetupTasks: [AndroidDevice.ID: Task<Void, Never>] = [:]
    private var adbQRPairedHost: String?
    private var pendingToolSetupAfterQR: (tool: ToolchainTool, issue: String?)?
    private var suppressedToolSetup = Set<ToolchainTool>()
    private var lastPresentedToolSetup: (id: UUID, tool: ToolchainTool)?
    private var programmaticToolSetupDismissalID: UUID?
    private var pendingToolSetupResume: (id: UUID, action: ToolSetupResumeAction)?
    public let settings: AppSettings
    public let toolchainManager: ToolchainManager
    public let usbTransferManager: USBTransferManager
    public let transferQueue: TransferQueue
    private let trashRecordsStorage: TrashRecordsStorage

    public init(
        adb: ADBClient = ADBClient(),
        settings: AppSettings = AppSettings(),
        toolchainManager: ToolchainManager = ToolchainManager(),
        usbTransferManager: USBTransferManager = USBTransferManager(),
        transferQueue: TransferQueue = TransferQueue(),
        cacheStore: AppCacheStore = AppCacheStore(),
        initialTrashRecords: [TrashRecord]? = nil,
        trashRecordsFileURL: URL? = nil
    ) {
        let trashRecordsStorage: TrashRecordsStorage
        if let trashRecordsFileURL {
            trashRecordsStorage = .file(trashRecordsFileURL)
        } else if initialTrashRecords != nil {
            // Injected records are used by previews and tests. Keep them isolated
            // unless the caller explicitly supplies a file URL.
            trashRecordsStorage = .memoryOnly
        } else {
            trashRecordsStorage = .applicationSupport
        }
        let existingTrashRecords = initialTrashRecords ?? Self.loadTrashRecords(from: trashRecordsStorage)
        self.adb = adb
        self.settings = settings
        self.toolchainManager = toolchainManager
        self.usbTransferManager = usbTransferManager
        self.transferQueue = transferQueue
        self.cacheStore = cacheStore
        self.trashRecordsStorage = trashRecordsStorage
        self.trashSessionSnapshot = TrashSessionSnapshot(recordsAtStart: existingTrashRecords)
        let scanner = MediaStoreScanner(adb: adb)
        self.deviceManager = DeviceManager(adb: adb)
        self.fileRepository = AndroidFileRepository(adb: adb, scanner: scanner)
        self.appManager = AppManagerService(adb: adb)
        self.captureService = DeviceCaptureService(adb: adb)
        self.captureCompositionService = CaptureCompositionService()
        self.thumbnailService = ThumbnailService()
        self.sidebarSelection = .location(Self.defaultQuickLocations[0])
        self.trashRecords = existingTrashRecords
        self.usbTransferManager.configureADBReleaseHandler { [adb] in
            do {
                try await adb.killServer()
                return true
            } catch {
                return false
            }
        }
        self.usbTransferManager.configureTransferQueue(transferQueue)
        self.usbTransferManager.configurePreviewCache(
            cacheStore: cacheStore,
            encryptionEnabled: { [weak settings] in settings?.encryptPreviewCache ?? false }
        )
        self.usbTransferManager.folderSizeCalculationSettingDidChange(isEnabled: settings.calculateFolderSizes)
        self.transferQueue.configureFailureHandler { [weak self] error in
            guard let self else { return }
            switch error {
            case FileOperationError.missingTool(let name):
                self.presentToolSetup(tool: ToolchainTool(rawValue: name.lowercased()) ?? .adb, force: true)
            case FileOperationError.toolUnavailable(let tool, let reason):
                if self.isTransientToolTimeout(tool: tool, reason: reason) {
                    self.presentTransientToolTimeout(reason)
                } else {
                    self.presentToolSetup(tool: tool, issue: reason, force: true)
                }
            default:
                break
            }
        }
        self.transferQueueJobsCancellable = transferQueue.$jobs.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.usbTransferManagerCancellable = usbTransferManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var selectedDevice: AndroidDevice? {
        guard let selectedDeviceID else { return nil }
        return devices.first { $0.id == selectedDeviceID }
    }

    public var phoneControlSession: PhoneControlSession? {
        guard let serial = selectedDevice?.serial else { return phoneControlSessions.first }
        return phoneControlSession(for: serial)
    }

    public func phoneControlSession(for deviceSerial: String) -> PhoneControlSession? {
        phoneControlSessions.first { $0.deviceSerial == deviceSerial }
    }

    public func phoneControlCapabilityState(for deviceSerial: String) -> PhoneControlCapabilityState? {
        phoneControlCapabilityStates[deviceSerial]
    }

    public func isScreenRecording(deviceSerial: String) -> Bool {
        screenRecordingSession?.deviceSerials.contains(deviceSerial) == true
    }

    public var hasReadyADBDevice: Bool {
        selectedDevice?.state == .device
    }

    public var isAppPackageInstallInProgress: Bool {
        isInstallingAppPackage || transferQueue.unfinishedJobs.contains { $0.kind == .appInstall }
    }

    public var trashItemsAddedThisSessionCount: Int {
        trashSessionSnapshot.addedRecords(in: trashRecords).count
    }

    public var shouldConfirmEmptyTrashAtSessionEnd: Bool {
        settings.trashQuitBehavior == .ask && !trashRecords.isEmpty
    }

    public var shouldAutomaticallyEmptyTrashAtSessionEnd: Bool {
        settings.trashQuitBehavior == .emptyAutomatically && !trashRecords.isEmpty
    }

    public func beginTerminationRequest() -> Bool {
        let hasActiveTransfer = transferQueue.unfinishedJobs.contains { $0.kind != .preview }
        guard !isPreparingForTermination,
              !operationActivity.hasTerminationBlockingActivity,
              !isRunningFileHistoryOperation,
              !usbTransferManager.hasTerminationBlockingActivity,
              !hasActiveTransfer else { return false }
        isPreparingForTermination = true
        stopBackgroundRefreshLoop()
        cancelReadWorkForTermination()
        return true
    }

    public func cancelTerminationRequest() {
        isPreparingForTermination = false
        startBackgroundRefreshLoop()
    }

    public func startBackgroundRefreshLoop() {
        guard backgroundRefreshTask == nil, !isPreparingForTermination else { return }
        backgroundRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await performPreviewCacheMaintenance(force: true)
            await enforceMediaCacheLimit()
            guard !Task.isCancelled else { return }
            await toolchainManager.refresh()
            guard !Task.isCancelled else { return }
            await refreshLaunchConnections()
            guard !Task.isCancelled else { return }
            updateForConnectionMode()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await pollDeviceConnections()
                guard !Task.isCancelled else { return }
                updateForConnectionMode()
                await performPreviewCacheMaintenance()
            }
        }
    }

    public func stopBackgroundRefreshLoop() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
    }

    public var hasInspectableDeviceSurface: Bool {
        hasReadyADBDevice || !usbTransferManager.devices.isEmpty
    }

    var showsPhoneCaptureToolbarControls: Bool {
        connectionMode == .adb
            && hasReadyADBDevice
            && !usbTransferManager.isADBReleasedForMTPSession
    }

    public var shouldShowDetailInspector: Bool {
        showInspector && hasInspectableDeviceSurface
    }

    public var isUSBTransferOnlyMode: Bool {
        !hasReadyADBDevice && !usbTransferManager.devices.isEmpty
    }

    public var isUSBTransferSelected: Bool {
        switch sidebarSelection {
        case .usbTransfer, .usbTransferLocation:
            return true
        case .apps, .trash, .storage, .location, nil:
            return false
        }
    }

    public var isActiveFileModeSelected: Bool {
        isUSBTransferSelected || canUseActiveADBFileCommands
    }

    public var showsAppManagementToolbarControls: Bool {
        sidebarSelection == .apps && hasReadyADBDevice
    }

    public var showsNewFolderToolbarControl: Bool {
        isActiveFileModeSelected
    }

    public var canCreateFolderInActiveFileMode: Bool {
        if isUSBTransferSelected {
            return usbTransferManager.canWriteCurrentMTPFolder
        }
        return canUseActiveADBFileCommands
    }

    public var canCopyActiveFileSelection: Bool {
        if isUSBTransferSelected {
            return !usbTransferManager.selectedDownloadableItems.isEmpty
        }
        return canUseActiveADBFileCommands && !selectedFiles.isEmpty
    }

    public var canCopyActiveFileSelectionToQueue: Bool {
        canCopyActiveFileSelection
    }

    public var canCopyActiveFilePath: Bool {
        if isUSBTransferSelected {
            return !usbTransferManager.selectedItems.isEmpty
        }
        return canUseActiveADBFileCommands && !selectedFiles.isEmpty
    }

    public var canPasteInActiveFileMode: Bool {
        isUSBTransferSelected || canUseActiveADBFileCommands
    }

    public var canDeleteActiveFileSelection: Bool {
        if isUSBTransferSelected {
            return usbTransferManager.canDeleteSelectedMTPItems
        }
        return canUseActiveADBFileCommands && !selectedFiles.isEmpty
    }

    public var canRenameActiveFileSelection: Bool {
        if isUSBTransferSelected {
            return usbTransferManager.canRenameSelectedMTPItem
        }
        return canUseActiveADBFileCommands && selectedFiles.count == 1
    }

    public var canOpenActiveFileSelection: Bool {
        if isUSBTransferSelected {
            return usbTransferManager.selectedItem != nil
        }
        return canUseActiveADBFileCommands && selectedFile != nil
    }

    public var canNavigateActiveFileModeUp: Bool {
        if isUSBTransferSelected {
            return usbTransferManager.canNavigateUp
        }
        return canUseActiveADBFileCommands && currentPath != "/"
    }

    public var canRefreshActiveFileMode: Bool {
        isUSBTransferSelected || canUseActiveADBFileCommands
    }

    public var canSelectAllActiveFileItems: Bool {
        if isUSBTransferSelected {
            return !usbTransferManager.visibleItemsIncludingExpandedChildren.isEmpty
        }
        return canUseActiveADBFileCommands && !visibleFilesIncludingExpandedChildren.isEmpty
    }

    public var canUseADBMode: Bool {
        hasReadyADBDevice
    }

    public var canUndoFileOperation: Bool {
        !isRunningFileHistoryOperation && !fileUndoStack.isEmpty
    }

    public var canRedoFileOperation: Bool {
        !isRunningFileHistoryOperation && !fileRedoStack.isEmpty
    }

    public var undoFileCommandTitle: String {
        guard let action = fileUndoStack.last else { return "Undo File Operation" }
        return "Undo \(action.actionName)"
    }

    public var redoFileCommandTitle: String {
        guard let action = fileRedoStack.last else { return "Redo File Operation" }
        return "Redo \(action.actionName)"
    }

    public func undoLastFileOperation() async {
        guard !isRunningFileHistoryOperation, let operation = fileUndoStack.popLast() else {
            statusMessage = "Nothing to undo."
            return
        }

        markFileHistoryChanged()
        isRunningFileHistoryOperation = true
        let inverse = await performFileHistoryOperation("Undoing \(operation.actionName)...") {
            try await executeFileHistoryOperation(operation)
        }
        isRunningFileHistoryOperation = false

        if let inverse {
            fileRedoStack.append(inverse)
        } else {
            fileUndoStack.append(operation)
        }
        markFileHistoryChanged()
    }

    public func redoLastFileOperation() async {
        guard !isRunningFileHistoryOperation, let operation = fileRedoStack.popLast() else {
            statusMessage = "Nothing to redo."
            return
        }

        markFileHistoryChanged()
        isRunningFileHistoryOperation = true
        let inverse = await performFileHistoryOperation("Redoing \(operation.actionName)...") {
            try await executeFileHistoryOperation(operation)
        }
        isRunningFileHistoryOperation = false

        if let inverse {
            fileUndoStack.append(inverse)
        } else {
            fileRedoStack.append(operation)
        }
        markFileHistoryChanged()
    }

    private func recordFileHistory(_ operation: FileHistoryOperation) {
        fileUndoStack.append(operation)
        fileRedoStack.removeAll()
        markFileHistoryChanged()
    }

    private func markFileHistoryChanged() {
        fileHistoryRevision &+= 1
    }

    private func performFileHistoryOperation(
        _ message: String,
        operation: () async throws -> FileHistoryOperation
    ) async -> FileHistoryOperation? {
        guard !isPreparingForTermination else {
            statusMessage = "Quit is in progress."
            return nil
        }
        beginTrackedOperation()
        defer { endTrackedOperation() }
        statusMessage = message
        do {
            let inverse = try await operation()
            statusMessage = "\(message.replacingOccurrences(of: "...", with: "")) done."
            return inverse
        } catch {
            handleOperationError(error)
            return nil
        }
    }

    private func executeFileHistoryOperation(_ operation: FileHistoryOperation) async throws -> FileHistoryOperation {
        switch operation {
        case .createFolders(let deviceSerial, let folders, let actionName):
            let device = try deviceForFileHistory(serial: deviceSerial)
            for folder in folders {
                try await fileRepository.createFolder(device: device, parent: folder.parent, name: folder.name)
            }
            try? await refreshFilesThrowing()
            return .deletePaths(
                deviceSerial: deviceSerial,
                paths: folders.map(\.path),
                redo: operation,
                actionName: actionName
            )

        case .deletePaths(let deviceSerial, let paths, let redo, _):
            let device = try deviceForFileHistory(serial: deviceSerial)
            for path in paths {
                try await fileRepository.deletePermanently(device: device, remotePath: path)
            }
            try? await refreshFilesThrowing()
            return redo

        case .rename(let deviceSerial, let steps, let actionName):
            let device = try deviceForFileHistory(serial: deviceSerial)
            var inverseSteps: [FileHistoryRenameStep] = []
            for step in steps {
                let originalName = (step.sourcePath as NSString).lastPathComponent
                let destinationPath = try await fileRepository.rename(
                    device: device,
                    source: step.sourcePath,
                    newName: step.destinationName
                )
                inverseSteps.append(
                    FileHistoryRenameStep(sourcePath: destinationPath, destinationName: originalName)
                )
            }
            try? await refreshFilesThrowing()
            return .rename(deviceSerial: deviceSerial, steps: inverseSteps.reversed(), actionName: actionName)

        case .trashItems(let deviceSerial, let items, let actionName):
            let device = try deviceForFileHistory(serial: deviceSerial)
            var createdRecords: [TrashRecord] = []
            for item in items {
                let file = AndroidFile(
                    name: item.name,
                    path: item.path,
                    kind: item.kind,
                    size: item.size,
                    modified: nil,
                    permissions: nil
                )
                let record = try await trashAndRecord(device: device, file: file)
                createdRecords.append(record)
            }
            selectedFileIDs.subtract(items.map(\.path))
            try? await refreshFilesThrowing()
            return .restoreTrash(deviceSerial: deviceSerial, records: createdRecords, actionName: actionName)

        case .restoreTrash(let deviceSerial, let records, let actionName):
            let device = try deviceForFileHistory(serial: deviceSerial)
            for record in records {
                try await fileRepository.restore(device: device, record: record, replace: false)
            }
            let restoredIDs = Set(records.map(\.id))
            try replaceTrashRecords(trashRecords.filter { !restoredIDs.contains($0.id) })
            try? await refreshFilesThrowing()
            let items = records.map {
                RemoteClipboardItem(
                    path: $0.originalPath,
                    name: $0.name,
                    kind: $0.kind ?? .file,
                    size: $0.size
                )
            }
            return .trashItems(deviceSerial: deviceSerial, items: items, actionName: actionName)

        case .copyItems(let deviceSerial, let items, let destination, let destinationNames, let actionName):
            let device = try deviceForFileHistory(serial: deviceSerial)
            var destinationPaths: [String] = []
            for (index, item) in items.enumerated() {
                let destinationName = destinationNames.indices.contains(index) ? destinationNames[index] : item.name
                let path = try await fileRepository.copy(
                    device: device,
                    source: item.path,
                    to: destination,
                    destinationName: destinationName,
                    replace: false
                )
                destinationPaths.append(path)
            }
            try? await refreshFilesThrowing()
            return .deletePaths(deviceSerial: deviceSerial, paths: destinationPaths, redo: operation, actionName: actionName)

        case .moveItems(let deviceSerial, let steps, let actionName):
            let device = try deviceForFileHistory(serial: deviceSerial)
            var inverseSteps: [FileHistoryMoveStep] = []
            for step in steps {
                let originalParent = (step.sourcePath as NSString).deletingLastPathComponent
                let originalName = (step.sourcePath as NSString).lastPathComponent
                let destinationPath: String
                do {
                    destinationPath = try await fileRepository.move(
                        device: device,
                        source: step.sourcePath,
                        to: step.destinationDirectory,
                        destinationName: step.destinationName,
                        replace: step.replace
                    )
                } catch FileOperationError.moveCompletedWithRecoveryCopy(
                    let completedDestination,
                    let recoveryPath,
                    let reason
                ) {
                    destinationPath = completedDestination
                    alert = UserAlert(
                        title: "Move Finished with a Recovery Copy",
                        message: "The replaced item is safe at \(recoveryPath). \(reason)"
                    )
                }
                inverseSteps.append(
                    FileHistoryMoveStep(
                        sourcePath: destinationPath,
                        destinationDirectory: originalParent,
                        destinationName: originalName,
                        replace: false
                    )
                )
            }
            try? await refreshFilesThrowing()
            return .moveItems(deviceSerial: deviceSerial, steps: inverseSteps.reversed(), actionName: actionName)

        case .queuedTransfer(let jobID, let completedUndo, let redo, let actionName):
            if let job = transferQueue.job(id: jobID) {
                if !job.isFinished {
                    transferQueue.cancel(jobID: jobID)
                    statusMessage = "Canceled \(actionName)."
                    return redo
                }
                guard job.state == .completed else {
                    statusMessage = "\(actionName) did not finish."
                    return redo
                }
            }
            return try await executeFileHistoryOperation(completedUndo)

        case .group(let operations, let actionName):
            var inverseOperations: [FileHistoryOperation] = []
            for operation in operations.reversed() {
                inverseOperations.append(try await executeFileHistoryOperation(operation))
            }
            return .group(operations: inverseOperations.reversed(), actionName: actionName)
        }
    }

    private func deviceForFileHistory(serial: String) throws -> AndroidDevice {
        if let device = devices.first(where: { $0.serial == serial && $0.state == .device }) {
            return device
        }
        throw FileOperationError.commandFailed("Reconnect device \(serial) before undoing or redoing this file operation.")
    }

    public var selectedFiles: [AndroidFile] {
        var seen = Set<AndroidFile.ID>()
        let storageFiles = storageCategoryFileLists.values.flatMap(\.files)
        let knownFiles = files + searchResults + treeChildrenByPath.values.flatMap { $0 } + storageFiles
        return knownFiles.filter { file in
            selectedFileIDs.contains(file.id) && seen.insert(file.id).inserted
        }
    }

    public var selectedFile: AndroidFile? {
        selectedFiles.first
    }

    public var breadcrumbPath: String {
        if let selectedAppStorageLocation {
            return selectedAppStorageLocation.location.path
        }
        return currentPath
    }

    public var pathBarPath: String {
        if selectedFileIDs.count == 1, let selectedFile {
            return selectedFile.path
        }
        if let selectedAppStorageLocation {
            return selectedAppStorageLocation.location.path
        }
        return currentPath
    }

    public var pathBarShowsFolder: Bool {
        guard selectedFileIDs.count == 1 else { return true }
        return selectedFile?.isDirectory ?? true
    }

    public var canCompressSelection: Bool {
        isADBFileBrowserSurface && !selectedFiles.isEmpty && selectedFiles.allSatisfy(\.canCompress) && hasReadyADBDevice && connectionMode == .adb
    }

    public var selectedExtractableArchive: AndroidFile? {
        guard isADBFileBrowserSurface else { return nil }
        guard selectedFiles.count == 1, let file = selectedFiles.first, file.isExtractableArchive else {
            return nil
        }
        return file
    }

    public func displaySize(for file: AndroidFile) -> String {
        if let presentation = uploadPresentation(for: file),
           presentation.isSynthetic || !presentation.state.isFinished {
            return presentation.detailText
        }
        guard file.isDirectory else { return file.displaySize }
        if let bytes = folderSizeBytesByPath[file.path] {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        if loadingFolderSizePaths.contains(file.path) {
            return "Calculating..."
        }
        if failedFolderSizePaths.contains(file.path) {
            return "Unavailable"
        }
        return "—"
    }

    public var automaticallyPreparesFolderSizes: Bool {
        settings.calculateFolderSizes
    }

    public var canNavigateBack: Bool {
        isUSBTransferSelected ? usbTransferManager.canNavigateBack : !adbBackHistory.isEmpty
    }

    public var canNavigateForward: Bool {
        isUSBTransferSelected ? usbTransferManager.canNavigateForward : !adbForwardHistory.isEmpty
    }

    public var selectedPackage: AndroidPackage? {
        guard let id = selectedPackageIDs.first else { return nil }
        return packages.first { $0.id == id }
    }

    public var visibleFiles: [AndroidFile] {
        let source = isFullDeviceSearchActive
            ? activeFileSource
            : fileSourceWithPendingUploads(activeFileSource, parentPath: currentPath)
        return filteredAndSortedFiles(from: source)
    }

    public var visibleFilesIncludingExpandedChildren: [AndroidFile] {
        flattenedVisibleFiles(from: visibleFiles)
    }

    public var selectedStorageSummary: StorageSummary? {
        guard case .storage(let summaryID) = sidebarSelection else { return nil }
        return storageSummaries.first { $0.id == summaryID }
    }

    public var selectedStorageBreakdown: StorageBreakdown? {
        guard let selectedStorageSummary else { return nil }
        return storageBreakdowns[selectedStorageSummary.id]
    }

    public var selectedStorageCategory: StorageBreakdownCategory? {
        guard let selectedStorageCategoryID else { return nil }
        return selectedStorageBreakdown?.visibleCategories.first { $0.id == selectedStorageCategoryID }
    }

    public var selectedStorageCategoryFileList: StorageCategoryFileList? {
        guard let selectedStorageSummary,
              let selectedStorageCategory else {
            return nil
        }
        return storageCategoryFileLists[storageCategoryFileListID(summaryID: selectedStorageSummary.id, categoryID: selectedStorageCategory.id)]
    }

    public var isLoadingSelectedStorageCategory: Bool {
        guard let selectedStorageSummary,
              let selectedStorageCategory else {
            return false
        }
        return isLoadingStorageCategory(selectedStorageCategory, in: selectedStorageSummary)
    }

    public func isLoadingStorageBreakdown(_ summary: StorageSummary) -> Bool {
        loadingStorageBreakdownID == summary.id || prefetchingStorageBreakdownIDs.contains(summary.id)
    }

    public func isLoadingStorageCategory(_ category: StorageBreakdownCategory, in summary: StorageSummary) -> Bool {
        let listID = storageCategoryFileListID(summaryID: summary.id, categoryID: category.id)
        return loadingStorageCategoryID == listID || prefetchingStorageCategoryIDs.contains(listID)
    }

    public var parsedSearchQuery: ParsedSearchQuery {
        SearchQueryParser.parse(searchText)
    }

    public var effectiveSearchKindFilter: FileSearchKindFilter {
        parsedSearchQuery.kindFilter ?? searchKindFilter
    }

    public var effectiveSearchText: String {
        parsedSearchQuery.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isFullDeviceSearchActive: Bool {
        isADBFileBrowserSurface && searchScope == .fullDevice && hasEffectiveSearchCriteria
    }

    public var shouldShowSearchOptions: Bool {
        !searchText.isEmpty || searchScope != .currentFolder || searchKindFilter != .any || searchDateFilter != .any
    }

    public var hasSearchFiltersApplied: Bool {
        effectiveSearchKindFilter != .any || searchDateFilter != .any
    }

    private var hasEffectiveSearchCriteria: Bool {
        !effectiveSearchText.isEmpty || effectiveSearchKindFilter != .any || searchDateFilter != .any
    }

    private var activeFileSource: [AndroidFile] {
        isFullDeviceSearchActive ? searchResults : files
    }

    private var isADBFileBrowserSurface: Bool {
        switch sidebarSelection {
        case .location, nil:
            return true
        case .apps, .trash, .storage, .usbTransfer, .usbTransferLocation:
            return false
        }
    }

    private var canUseActiveADBFileCommands: Bool {
        isADBFileBrowserSurface && hasReadyADBDevice && connectionMode == .adb
    }

    public func filteredTreeChildren(for path: String) -> [AndroidFile] {
        filteredAndSortedFiles(from: fileSourceWithPendingUploads(treeChildrenByPath[path] ?? [], parentPath: path))
    }

    private func flattenedVisibleFiles(from source: [AndroidFile]) -> [AndroidFile] {
        source.flatMap { file -> [AndroidFile] in
            guard file.isDirectory, expandedTreePaths.contains(file.path) else {
                return [file]
            }
            return [file] + flattenedVisibleFiles(from: filteredTreeChildren(for: file.path))
        }
    }

    private func filteredAndSortedFiles(from source: [AndroidFile]) -> [AndroidFile] {
        let trimmedSearch = effectiveSearchText
        let searched: [AndroidFile]
        if trimmedSearch.isEmpty || isFullDeviceSearchActive {
            searched = source
        } else {
            searched = source.filter {
                $0.name.localizedCaseInsensitiveContains(trimmedSearch) || $0.path.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }

        let filtered = searched.filter { file in
            matchesKindFilter(file) && matchesDateFilter(file)
        }

        return filtered.sorted { lhs, rhs in
            if lhs.kind == .directory, rhs.kind != .directory { return true }
            if lhs.kind != .directory, rhs.kind == .directory { return false }

            for descriptor in activeFileSortDescriptors {
                let result = compareFiles(lhs, rhs, by: descriptor.sort)
                if result != .orderedSame {
                    return descriptor.ascending ? result == .orderedAscending : result == .orderedDescending
                }
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var activeFileSortDescriptors: [FileSortDescriptor] {
        fileSortDescriptors.isEmpty
            ? [FileSortDescriptor(sort: sort, ascending: sortAscending)]
            : fileSortDescriptors
    }

    private func compareFiles(_ lhs: AndroidFile, _ rhs: AndroidFile, by fileSort: FileSort) -> ComparisonResult {
        switch fileSort {
        case .name:
            lhs.name.localizedStandardCompare(rhs.name)
        case .kind:
            lhs.kind.displayName.localizedStandardCompare(rhs.kind.displayName)
        case .size:
            compareOptionalInt64(sortSize(for: lhs), sortSize(for: rhs), missingValue: -1)
        case .modified:
            compareOptionalDates(lhs.modified, rhs.modified)
        case .created:
            compareOptionalDates(lhs.created, rhs.created)
        case .permissions:
            (lhs.permissions ?? "").localizedStandardCompare(rhs.permissions ?? "")
        }
    }

    private func sortSize(for file: AndroidFile) -> Int64? {
        file.isDirectory ? folderSizeBytesByPath[file.path] : file.size
    }

    private func matchesKindFilter(_ file: AndroidFile) -> Bool {
        effectiveSearchKindFilter.matches(file: file)
    }

    private func matchesDateFilter(_ file: AndroidFile) -> Bool {
        searchDateFilter.matches(file.modified)
    }

    private func storageCategoryFileListID(summaryID: StorageSummary.ID, categoryID: StorageBreakdownCategory.ID) -> StorageCategoryFileList.ID {
        "\(summaryID):\(categoryID)"
    }

    private func showStorageCategoryInfo(_ category: StorageBreakdownCategory) {
        switch category.kind {
        case .temporarySystemFiles:
            alert = UserAlert(
                title: category.displayTitle,
                message: "This includes cache and other temporary files that are needed by your operating system. You may notice changes to the amount of storage used over time."
            )
        case .androidSystem:
            alert = UserAlert(
                title: category.displayTitle,
                message: "This includes your operating system and the files that are needed to keep your phone running smoothly. To protect their integrity, these files can't be accessed. The size shown here is an ADB-visible estimate from mounted system partitions, so it can differ from Android Settings."
            )
        case .apps, .videos, .images, .audio, .trash, .documents, .other, .games:
            break
        }
    }

    private func compareOptionalInt64(_ lhs: Int64?, _ rhs: Int64?, missingValue: Int64) -> ComparisonResult {
        let left = lhs ?? missingValue
        let right = rhs ?? missingValue
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }

    private func compareOptionalDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        let left = lhs ?? .distantPast
        let right = rhs ?? .distantPast
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }

    private func fileSourceWithPendingUploads(_ source: [AndroidFile], parentPath: String) -> [AndroidFile] {
        let existingPaths = Set(source.map(\.path))
        let pendingFiles = pendingUploadFiles(parentPath: parentPath, existingPaths: existingPaths)
        guard !pendingFiles.isEmpty else { return source }
        return source + pendingFiles
    }

    private func pendingUploadFiles(parentPath: String, existingPaths: Set<AndroidFile.ID>) -> [AndroidFile] {
        transferQueue.jobs
            .filter(isBrowserUploadPlaceholderJob)
            .filter { remoteParentPath(for: $0.destination.path) == parentPath }
            .filter { !existingPaths.contains($0.destination.path) }
            .sorted { $0.createdAt < $1.createdAt }
            .map { job in
                AndroidFile(
                    name: uploadDisplayName(for: job),
                    path: job.destination.path,
                    kind: job.itemKind == .folder ? .directory : .file,
                    size: job.itemKind == .file ? job.progress.totalBytes : nil,
                    modified: job.createdAt,
                    permissions: nil
                )
            }
    }

    func uploadPresentation(for file: AndroidFile) -> UploadFilePresentation? {
        guard let job = uploadJob(forRemotePath: file.path) else { return nil }
        let isSynthetic = !knownRemoteFilePaths.contains(file.path)
        if job.state == .completed, !isSynthetic {
            return nil
        }
        return UploadFilePresentation(
            state: job.state,
            progressFraction: job.progressFraction,
            sourceURL: URL(fileURLWithPath: job.source.path),
            statusText: uploadStatusText(for: job),
            errorMessage: job.errorMessage,
            isSynthetic: isSynthetic
        )
    }

    private func uploadJob(forRemotePath path: String) -> TransferJob? {
        transferQueue.jobs
            .filter(isBrowserUploadPlaceholderJob)
            .filter { $0.destination.path == path }
            .sorted { lhs, rhs in
                let lhsPriority = uploadJobDisplayPriority(lhs)
                let rhsPriority = uploadJobDisplayPriority(rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }
                if lhs.isAggregate != rhs.isAggregate {
                    return lhs.isAggregate
                }
                return lhs.createdAt > rhs.createdAt
            }
            .first
    }

    private func isBrowserUploadPlaceholderJob(_ job: TransferJob) -> Bool {
        job.kind == .upload
            && job.destination.kind == .adb
            && (job.isAggregate || job.itemKind == .file || job.itemKind == .folder)
    }

    private var knownRemoteFilePaths: Set<AndroidFile.ID> {
        Set((files + treeChildrenByPath.values.flatMap { $0 }).map(\.path))
    }

    private func uploadJobDisplayPriority(_ job: TransferJob) -> Int {
        switch job.state {
        case .running:
            5
        case .queued:
            4
        case .failed:
            3
        case .canceled:
            2
        case .completed:
            1
        }
    }

    private func uploadStatusText(for job: TransferJob) -> String {
        if job.cancelRequested, !job.isFinished {
            return "Canceling"
        }
        switch job.state {
        case .queued:
            return "Queued"
        case .running:
            return job.progress.message ?? "Uploading"
        case .completed:
            return "Done"
        case .failed:
            return job.errorMessage ?? "Upload failed"
        case .canceled:
            return "Canceled"
        }
    }

    private func uploadDisplayName(for job: TransferJob) -> String {
        let name = (job.destination.path as NSString).lastPathComponent
        return name.isEmpty ? job.title : name
    }

    private func remoteParentPath(for path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    public var filteredPackages: [AndroidPackage] {
        let parsed = parsedSearchQuery
        if let kindFilter = parsed.kindFilter,
           kindFilter != .any,
           kindFilter != .applications {
            return []
        }

        let trimmedSearch = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else { return sortedPackagesForDisplay(packages) }

        let matched = packages.filter {
            $0.packageName.localizedCaseInsensitiveContains(trimmedSearch)
                || ($0.apkPath?.localizedCaseInsensitiveContains(trimmedSearch) ?? false)
        }
        return sortedPackagesForDisplay(matched)
    }

    private var activeAppSortDescriptors: [AppSortDescriptor] {
        appSortDescriptors.isEmpty
            ? [AppSortDescriptor(column: appSort, ascending: appSortAscending)]
            : appSortDescriptors
    }

    private func updateFileSortDescriptors(sort requestedSort: FileSort, defaultAscending: Bool) {
        var descriptors = activeFileSortDescriptors
        if let index = descriptors.firstIndex(where: { $0.sort == requestedSort }) {
            descriptors[index].ascending.toggle()
        } else {
            descriptors.append(FileSortDescriptor(sort: requestedSort, ascending: defaultAscending))
        }
        fileSortDescriptors = descriptors
    }

    private func syncPrimaryFileSortFromDescriptors() {
        guard let primary = activeFileSortDescriptors.first else { return }
        sort = primary.sort
        sortAscending = primary.ascending
    }

    private func updateAppSortDescriptors(column: AppColumn, defaultAscending: Bool) {
        var descriptors = activeAppSortDescriptors
        if let index = descriptors.firstIndex(where: { $0.column == column }) {
            descriptors[index].ascending.toggle()
        } else {
            descriptors.append(AppSortDescriptor(column: column, ascending: defaultAscending))
        }
        appSortDescriptors = descriptors
    }

    private func syncPrimaryAppSortFromDescriptors() {
        guard let primary = activeAppSortDescriptors.first else { return }
        appSort = primary.column
        appSortAscending = primary.ascending
    }

    public func sortBy(appColumn column: AppColumn) {
        sortBy(appColumn: column, modifiers: NSEvent.modifierFlags)
    }

    public func sortBy(appColumn column: AppColumn, modifiers: NSEvent.ModifierFlags) {
        let command = modifiers.contains(.command)
        let defaultAscending = true

        if command {
            updateAppSortDescriptors(column: column, defaultAscending: defaultAscending)
        } else if appSort == column {
            appSortAscending.toggle()
            appSortDescriptors = [AppSortDescriptor(column: column, ascending: appSortAscending)]
        } else {
            appSort = column
            appSortAscending = defaultAscending
            appSortDescriptors = [AppSortDescriptor(column: column, ascending: defaultAscending)]
        }
        syncPrimaryAppSortFromDescriptors()
    }

    public func appSortIndicator(for column: AppColumn) -> (priority: Int, ascending: Bool)? {
        guard let index = activeAppSortDescriptors.firstIndex(where: { $0.column == column }) else { return nil }
        return (index + 1, activeAppSortDescriptors[index].ascending)
    }

    public func toggleAppColumn(_ column: AppColumn) {
        if visibleAppColumns.contains(column), column.isHideable {
            visibleAppColumns.remove(column)
        } else {
            visibleAppColumns.insert(column)
        }
    }

    public var quickLocations: [QuickLocation] {
        let defaults = settings.showDefaultQuickLocations
            ? Self.defaultQuickLocations.filter { !settings.hiddenDefaultQuickLocationIDs.contains($0.id) }
            : []
        return defaults + settings.customQuickLocations
    }

    public var isLoadingApps: Bool {
        isBusy && (statusMessage == "Loading apps..." || statusMessage == "Refreshing apps...")
    }

    public var canSwitchADBDevice: Bool {
        !isSwitchingADBDevice
            && !operationActivity.hasTerminationBlockingActivity
            && !isRunningFileHistoryOperation
    }

    public func refreshLaunchConnections() async {
        if settings.checkConnectionModesOnLaunch {
            await refreshDevices(requestUSBTransferIfADBUnavailable: true)
        } else {
            await refreshDevices()
        }
    }

    public func selectADBDevice(id: AndroidDevice.ID?) {
        guard selectedDeviceID != id else { return }
        guard canSwitchADBDevice else {
            statusMessage = "Wait for the current file operation to finish."
            return
        }
        isSwitchingADBDevice = true
        selectedDeviceID = id
        isSwitchingADBDevice = false
        guard selectedDevice?.state == .device else {
            statusMessage = "Select a connected device."
            return
        }
        loadSelectedADBDeviceInBackground()
    }

    public func requestWirelessADBSetup(for deviceID: AndroidDevice.ID) {
        guard let device = devices.first(where: { $0.id == deviceID }),
              device.state == .device,
              device.connectionKind == .usb else {
            statusMessage = "Connect and authorize this device over USB first."
            return
        }

        wirelessADBPreflightTask?.cancel()
        pendingSecureWirelessPairingAfterSetupDismissal = false
        wirelessADBSetupPresentation = ADBWirelessSetupPresentation(
            deviceID: device.id,
            deviceName: device.title,
            phase: .checking
        )
        wirelessADBPreflightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.wirelessADBPreflightTask = nil }
            do {
                let status = try await self.deviceManager.wirelessDebuggingStatus(device: device)
                guard self.wirelessADBSetupPresentation?.deviceID == device.id else { return }
                switch status {
                case .enabled:
                    self.wirelessADBSetupPresentation?.phase = .wirelessDebuggingEnabled
                case .disabled:
                    self.wirelessADBSetupPresentation?.phase = .needsWirelessDebugging
                case .unsupported:
                    self.wirelessADBSetupPresentation?.phase = .wirelessDebuggingUnsupported
                case .unavailable:
                    self.wirelessADBSetupPresentation?.phase = .readyToConnect(
                        verificationUnavailable: true
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.wirelessADBSetupPresentation?.deviceID == device.id else { return }
                self.wirelessADBSetupPresentation?.phase = .readyToConnect(
                    verificationUnavailable: true
                )
            }
        }
    }

    public func retryWirelessADBPreflight() {
        guard let deviceID = wirelessADBSetupPresentation?.deviceID else { return }
        requestWirelessADBSetup(for: deviceID)
    }

    public func requestWirelessDebuggingEnablement() {
        guard wirelessADBSetupPresentation?.phase == .needsWirelessDebugging else { return }
        wirelessADBSetupPresentation?.phase = .confirmWirelessDebuggingEnable
    }

    public func cancelWirelessDebuggingEnablement() {
        guard wirelessADBSetupPresentation?.phase == .confirmWirelessDebuggingEnable else { return }
        wirelessADBSetupPresentation?.phase = .needsWirelessDebugging
    }

    public func confirmWirelessDebuggingEnablement() {
        guard let presentation = wirelessADBSetupPresentation,
              presentation.phase == .confirmWirelessDebuggingEnable else {
            return
        }
        guard let device = devices.first(where: { $0.id == presentation.deviceID }),
              device.state == .device,
              device.connectionKind == .usb else {
            wirelessADBSetupPresentation?.phase = .wirelessDebuggingEnableFailed(
                message: "The USB device disconnected before Wireless debugging could be changed. Reconnect and authorize it, then try again."
            )
            return
        }

        wirelessADBPreflightTask?.cancel()
        wirelessADBSetupPresentation?.phase = .enablingWirelessDebugging
        wirelessADBPreflightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.wirelessADBPreflightTask = nil }
            do {
                let status = try await self.deviceManager.requestWirelessDebuggingEnablement(
                    device: device
                )
                guard self.wirelessADBSetupPresentation?.deviceID == device.id else { return }
                switch status {
                case .enabled:
                    self.wirelessADBSetupPresentation?.phase = .wirelessDebuggingEnabled
                case .disabled:
                    self.wirelessADBSetupPresentation?.phase = .wirelessDebuggingApprovalRequired
                case .unsupported:
                    self.wirelessADBSetupPresentation?.phase = .wirelessDebuggingUnsupported
                case .unavailable:
                    self.wirelessADBSetupPresentation?.phase = .wirelessDebuggingEnableFailed(
                        message: "Android accepted the command, but did not report whether Wireless debugging is enabled."
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.wirelessADBSetupPresentation?.deviceID == device.id else { return }
                self.wirelessADBSetupPresentation?.phase = .wirelessDebuggingEnableFailed(
                    message: error.localizedDescription
                )
            }
        }
    }

    public func retryWirelessDebuggingEnablement() {
        guard let presentation = wirelessADBSetupPresentation else { return }
        switch presentation.phase {
        case .wirelessDebuggingApprovalRequired:
            requestWirelessADBSetup(for: presentation.deviceID)
        case .wirelessDebuggingEnableFailed:
            wirelessADBSetupPresentation?.phase = .confirmWirelessDebuggingEnable
        default:
            return
        }
    }

    public func startSecureWirelessPairingFromSetup() {
        guard wirelessADBSetupPresentation?.phase == .wirelessDebuggingEnabled else { return }
        pendingSecureWirelessPairingAfterSetupDismissal = true
        dismissWirelessADBSetup()
    }

    public func confirmWirelessADBSetup() {
        guard let presentation = wirelessADBSetupPresentation else { return }
        switch presentation.phase {
        case .readyToConnect,
             .needsWirelessDebugging,
             .wirelessDebuggingUnsupported,
             .wirelessDebuggingEnabled:
            break
        case .checking,
             .confirmWirelessDebuggingEnable,
             .enablingWirelessDebugging,
             .wirelessDebuggingApprovalRequired,
             .wirelessDebuggingEnableFailed,
             .connecting,
             .connected,
             .failed:
            return
        }
        let deviceID = presentation.deviceID
        startWirelessADBSetup(for: deviceID)
    }

    public func dismissWirelessADBSetup() {
        wirelessADBPreflightTask?.cancel()
        wirelessADBPreflightTask = nil
        wirelessADBSetupPresentation = nil
    }

    public func wirelessADBSetupSheetDidDismiss() {
        wirelessADBPreflightTask?.cancel()
        wirelessADBPreflightTask = nil
        guard pendingSecureWirelessPairingAfterSetupDismissal else { return }
        pendingSecureWirelessPairingAfterSetupDismissal = false
        startADBQRPairing()
    }

    private func startWirelessADBSetup(for deviceID: AndroidDevice.ID) {
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            let message = "The USB device disconnected before the handoff could start. Reconnect and authorize it, then try again."
            wirelessADBSetupPresentation?.phase = .failed(message: message)
            statusMessage = "Reconnect the USB device before using the Wi-Fi handoff."
            return
        }
        guard device.state == .device, device.connectionKind == .usb else {
            let message = "The device is no longer connected and authorized over USB. Reconnect it, then try the handoff again."
            wirelessADBSetupPresentation?.phase = .failed(message: message)
            statusMessage = "Connect and authorize this device over USB first."
            return
        }
        guard wirelessADBSetupTasks[deviceID] == nil else { return }

        wirelessADBSetupStates[deviceID] = .preparing
        wirelessADBSetupPresentation?.phase = .connecting
        statusMessage = "Preparing \(device.title) for Wi-Fi…"
        wirelessADBSetupTasks[deviceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.wirelessADBSetupTasks[deviceID] = nil }

            do {
                let endpoint = try await self.deviceManager.enableWirelessADB(device: device)
                self.wirelessADBSetupStates[deviceID] = .ready(endpoint: endpoint)
                let found = try await self.deviceManager.devices()
                _ = self.applyADBDeviceSnapshot(found)
                if found.contains(where: { $0.id == endpoint && $0.state == .device }) {
                    self.selectADBDevice(id: endpoint)
                }
                if self.wirelessADBSetupPresentation?.deviceID == device.id {
                    self.wirelessADBSetupPresentation?.phase = .connected(endpoint: endpoint)
                }
                self.statusMessage = "\(device.title) is connected over Wi-Fi. You can unplug the cable."
            } catch is CancellationError {
                return
            } catch {
                let message = error.localizedDescription
                self.wirelessADBSetupStates[deviceID] = .failed(message: message)
                if self.wirelessADBSetupPresentation?.deviceID == device.id {
                    self.wirelessADBSetupPresentation?.phase = .failed(message: message)
                }
                self.statusMessage = "Couldn’t enable Wi-Fi for \(device.title)."
            }
        }
    }

    private func loadSelectedADBDeviceInBackground() {
        guard let deviceID = selectedDeviceID,
              selectedDevice?.state == .device else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCancellableRead("Loading device...") {
                guard self.selectedDeviceID == deviceID else { throw CancellationError() }
                try await self.refreshStorage()
                guard self.selectedDeviceID == deviceID else { throw CancellationError() }
                await self.refreshBatteryStatus()
                guard self.selectedDeviceID == deviceID else { throw CancellationError() }
                if self.connectionMode == .adb {
                    try await self.refreshCurrentSurface()
                }
                guard self.selectedDeviceID == deviceID else { throw CancellationError() }
                self.statusMessage = "Ready."
            }
        }
    }

    public func refreshDevices(requestUSBTransferIfADBUnavailable: Bool = false) async {
        await performCancellableRead("Refreshing devices...", deviceScoped: false) { [self] in
            let found: [AndroidDevice]
            do {
                found = try await deviceManager.devices()
            } catch FileOperationError.missingTool {
                clearADBOnlyState(clearDevices: true)
                adbRuntimeIssue = "Phone tools are not installed."
                if requestUSBTransferIfADBUnavailable {
                    requestUSBTransferAccessAfterMissingADBDevice()
                } else {
                    presentToolSetup(tool: .adb, resumeAction: .refreshDevices)
                }
                return
            } catch FileOperationError.toolUnavailable(let tool, let reason) {
                clearADBOnlyState(clearDevices: true)
                if tool == .adb {
                    adbRuntimeIssue = reason
                }
                if requestUSBTransferIfADBUnavailable {
                    requestUSBTransferAccessAfterMissingADBDevice()
                } else {
                    presentToolSetup(tool: tool, issue: reason, resumeAction: .refreshDevices)
                }
                return
            }

            adbRuntimeIssue = nil
            let adbBecameReady = applyADBDeviceSnapshot(found)
            suppressedToolSetup.remove(.adb)
            if let device = selectedDevice, device.state == .device {
                if adbBecameReady, connectionMode == .adb {
                    prepareADBReadySurfaceForTransition()
                }
                try await refreshStorage()
                await refreshConnectedADBBatteryStatuses()
                if connectionMode == .adb {
                    try await refreshCurrentSurface()
                }
            }
            statusMessage = adbBecameReady
                ? "ADB connected. Full device browsing is available."
                : connectionStatusMessage(adbDevices: found)

            if requestUSBTransferIfADBUnavailable, !hasReadyADBDevice {
                requestUSBTransferAccessAfterMissingADBDevice()
            }
        }
    }

    public func refreshDevicesAndRequestUSBTransferIfNoADB() async {
        await refreshDevices(requestUSBTransferIfADBUnavailable: true)
    }

    public func pollDeviceConnections() async {
        guard !isPreparingForTermination,
              !isPollingDeviceConnections else { return }
        if isUSBTransferSelected, usbTransferManager.isADBReleasedForMTPSession {
            statusMessage = usbTransferManager.statusMessage
            return
        }

        isPollingDeviceConnections = true
        defer { isPollingDeviceConnections = false }
        let wasBusy = isBusy

        do {
            let found = try await deviceManager.devices()
            adbRuntimeIssue = nil
            suppressedToolSetup.remove(.adb)
            let previousSelectedDeviceID = selectedDeviceID
            let adbBecameReady = applyADBDeviceSnapshot(found)
            let selectedDeviceChanged = previousSelectedDeviceID != selectedDeviceID
            if (adbBecameReady || selectedDeviceChanged),
               connectionMode == .adb,
               selectedDevice?.state == .device {
                if adbBecameReady {
                    prepareADBReadySurfaceForTransition()
                }
                loadSelectedADBDeviceInBackground()
            }
            if !wasBusy {
                await refreshConnectedADBBatteryStatuses()
            }

            if !wasBusy || selectedDeviceChanged || found.isEmpty {
                statusMessage = adbBecameReady
                    ? "ADB connected. Full device browsing is available."
                    : connectionStatusMessage(adbDevices: found)
            }
        } catch FileOperationError.missingTool {
            clearADBOnlyState(clearDevices: true)
            adbRuntimeIssue = "Phone tools are not installed."
            statusMessage = "Phone tools are not set up. File Transfer is still available."
        } catch FileOperationError.toolUnavailable(let tool, let reason) {
            clearADBOnlyState(clearDevices: true)
            if tool == .adb {
                adbRuntimeIssue = reason
            }
            statusMessage = tool == .adb
                ? "Phone tools need attention. File Transfer is still available."
                : reason
        } catch {
            if devices.isEmpty {
                statusMessage = "No ADB device found."
            }
        }
    }

    public func open(destination: SidebarDestination) {
        sidebarSelection = destination
        selectedAppStorageLocation = nil
        switch destination {
        case .location(let location):
            connectionMode = .adb
            guard canUseADBFileBrowser() else { return }
            selectedStorageCategoryID = nil
            let isAppFolderLocation = appFolderContext?.contains(path: location.path) == true
            if !isAppFolderLocation {
                appFolderContext = nil
                selectedPackageIDs.removeAll()
            }
            selectedFileIDs.removeAll()
            beginADBFolderNavigation(to: location.path)
        case .usbTransferLocation(let location):
            cancelADBFolderLoading()
            connectionMode = .usbTransfer
            shouldShowADBSetupAfterConnectionModeSwitch = false
            selectedStorageCategoryID = nil
            appFolderContext = nil
            selectedFileIDs.removeAll()
            selectedPackageIDs.removeAll()
            usbTransferManager.openQuickLocation(location)
        case .storage(let summaryID):
            connectionMode = .adb
            guard canUseADBDestination(named: "Storage") else { return }
            appFolderContext = nil
            selectedFileIDs.removeAll()
            selectedPackageIDs.removeAll()
            guard let summary = storageSummaries.first(where: { $0.id == summaryID }) else {
                statusMessage = "Storage volume is no longer available."
                return
            }
            Task { await showStorageBreakdown(for: summary) }
        case .apps:
            connectionMode = .adb
            guard canUseADBDestination(named: "Apps") else { return }
            selectedStorageCategoryID = nil
            appFolderContext = nil
            selectedFileIDs.removeAll()
            Task { await loadPackages() }
        case .trash:
            connectionMode = .adb
            guard canUseADBDestination(named: "Trash") else { return }
            selectedStorageCategoryID = nil
            appFolderContext = nil
            selectedFileIDs.removeAll()
            selectedPackageIDs.removeAll()
        case .usbTransfer:
            cancelADBFolderLoading()
            connectionMode = .usbTransfer
            shouldShowADBSetupAfterConnectionModeSwitch = false
            selectedStorageCategoryID = nil
            appFolderContext = nil
            selectedFileIDs.removeAll()
            selectedPackageIDs.removeAll()
            usbTransferManager.startBrowsingForFileTransfer()
        }
    }

    public func selectConnectionMode(_ mode: ConnectionMode) {
        connectionMode = mode
        selectedFileIDs.removeAll()
        selectedPackageIDs.removeAll()
        selectedAppStorageLocation = nil

        switch mode {
        case .adb:
            guard hasReadyADBDevice else {
                shouldShowADBSetupAfterConnectionModeSwitch = true
                clearADBOnlyState()
                sidebarSelection = nil
                statusMessage = "Follow the connection steps for USB debugging or Wi-Fi."
                return
            }
            shouldShowADBSetupAfterConnectionModeSwitch = false
            prepareADBReadySurfaceForTransition()
        case .usbTransfer:
            cancelADBFolderLoading()
            shouldShowADBSetupAfterConnectionModeSwitch = false
            sidebarSelection = .usbTransfer
            usbTransferManager.startBrowsingForFileTransfer()
            statusMessage = "Opening File Transfer mode..."
        }
    }

    public func dismissADBConnectionSetupPrompt() {
        shouldShowADBSetupAfterConnectionModeSwitch = false
    }

    public func updateForConnectionMode() {
        guard isUSBTransferOnlyMode else {
            if hasReadyADBDevice, connectionMode == .adb, isUSBTransferSelected, !settings.showUSBTransferWhenADBConnected {
                prepareADBReadySurfaceForTransition()
            }
            return
        }
        if connectionMode == .usbTransfer {
            if !isUSBTransferSelected {
                sidebarSelection = .usbTransfer
            }
            usbTransferManager.startBrowsingForFileTransfer()
        } else {
            clearADBOnlyState()
            sidebarSelection = nil
            statusMessage = "ADB setup needed. File Transfer is available from the connection mode menu."
        }
    }

    public func refreshCurrentSurface() async throws {
        switch sidebarSelection {
        case .apps:
            try await loadPackagesThrowing()
        case .trash:
            break
        case .storage(let summaryID):
            guard let summary = storageSummaries.first(where: { $0.id == summaryID }) else { return }
            await showStorageBreakdown(for: summary, forceRefresh: true)
        case .usbTransfer, .usbTransferLocation:
            usbTransferManager.refresh()
        case .location, nil:
            guard canUseADBFileBrowser() else { return }
            try await refreshFilesThrowing()
        }
    }

    public func refreshCurrentSurfaceSafely() async {
        await performCancellableRead("Refreshing...") { [self] in
            try await refreshCurrentSurface()
        }
    }

    public func requestActiveFileModeNewFolder() {
        if isUSBTransferSelected {
            usbTransferManager.requestMTPNewFolder()
            return
        }

        guard canUseActiveADBFileCommands else { return }
        requestNewFolder()
    }

    public func beginActiveFileModeUpload() {
        if isUSBTransferSelected {
            usbTransferManager.uploadToCurrentMTPFolder()
            return
        }
        guard canUseActiveADBFileCommands else { return }
        beginUpload()
    }

    public func copyActiveFileSelection() {
        if isUSBTransferSelected {
            usbTransferManager.copySelectedForPasteboard()
            return
        }

        guard canUseActiveADBFileCommands else { return }
        copySelected()
    }

    public func copyActiveFileSelectionToQueue() {
        if isUSBTransferSelected {
            usbTransferManager.downloadSelected()
            return
        }

        guard canUseActiveADBFileCommands else { return }
        Task { await downloadSelected() }
    }

    public func copyActiveFilePathsToPasteboard() {
        if isUSBTransferSelected {
            usbTransferManager.copySelectedFilePathsToPasteboard()
            return
        }
        guard canUseActiveADBFileCommands else { return }
        copySelectedRemotePathsToPasteboard()
    }

    public func deleteActiveFileSelection() async {
        if isUSBTransferSelected {
            usbTransferManager.deleteSelectedMTPItems()
            return
        }

        guard canUseActiveADBFileCommands else { return }
        await deleteSelectedToTrash()
    }

    public func requestActiveFileModeRename() {
        if isUSBTransferSelected {
            usbTransferManager.requestRenameSelectedMTPItem()
            return
        }

        guard canUseActiveADBFileCommands,
              selectedFiles.count == 1,
              let file = selectedFile else {
            return
        }
        pendingRename = file
    }

    public func openActiveFileSelection() {
        if isUSBTransferSelected {
            guard let item = usbTransferManager.selectedItem else { return }
            usbTransferManager.open(item: item)
            return
        }

        guard canUseActiveADBFileCommands,
              let file = selectedFile else {
            return
        }
        open(file: file)
    }

    public func selectAllActiveFileItems() {
        if isUSBTransferSelected {
            usbTransferManager.selectAllVisibleItems()
            return
        }

        guard canUseActiveADBFileCommands else { return }
        let visible = visibleFilesIncludingExpandedChildren
        guard !visible.isEmpty else { return }
        cancelInlineRename()
        selectedFileIDs = Set(visible.map(\.id))
        lastSelectionFileOrder = visible
        keyboardSelectionAnchorFileID = visible.first?.id
        lastSelectedFileID = visible.last?.id
    }

    public func moveActiveFileSelection(by delta: Int, extending: Bool) {
        if isUSBTransferSelected {
            usbTransferManager.moveSelection(by: delta, extending: extending)
            return
        }

        moveADBFileSelection(by: delta, extending: extending)
    }

    public func switchActiveFileModeTab() {
        if isUSBTransferSelected {
            selectConnectionMode(.adb)
        } else {
            selectConnectionMode(.usbTransfer)
        }
    }

    public func refreshFiles() async {
        guard canUseADBFileBrowser() else { return }
        let task = beginADBFolderLoad(at: currentPath, clearExistingFiles: false)
        await task?.value
    }

    @discardableResult
    private func beginADBFolderNavigation(
        to path: String,
        recordsHistory: Bool = true
    ) -> Task<Void, Never>? {
        let destination = path.isEmpty ? "/" : normalizedFolderCachePath(path)
        if recordsHistory, destination != currentPath {
            adbBackHistory.append(currentPath)
            if adbBackHistory.count > 100 {
                adbBackHistory.removeFirst(adbBackHistory.count - 100)
            }
            adbForwardHistory.removeAll()
        }
        return beginADBFolderLoad(at: destination, clearExistingFiles: true)
    }

    @discardableResult
    private func beginADBFolderLoad(
        at path: String,
        clearExistingFiles: Bool
    ) -> Task<Void, Never>? {
        guard canUseADBFileBrowser(),
              let device = selectedDevice,
              device.state == .device else {
            return nil
        }

        if isLoadingCurrentFolder, currentPath == path {
            return adbNavigationTask
        }

        let previousPath = currentPath
        if !files.isEmpty || adbFolderListingsByPath[previousPath] == nil {
            adbFolderListingsByPath[normalizedFolderCachePath(previousPath)] = files
        }
        let normalizedPath = normalizedFolderCachePath(path)
        let cachedFiles = adbFolderListingsByPath[normalizedPath] ?? treeChildrenByPath[normalizedPath]
        let mutationRevision = browserMutationRevision(for: normalizedPath)

        adbNavigationRevision &+= 1
        let revision = adbNavigationRevision
        adbNavigationTask?.cancel()
        cancelFolderSizeWorker(clearQueue: true)
        cancelAllTreeLoads()

        currentPath = normalizedPath
        selectedFileIDs.removeAll()
        cancelInlineRename()
        if let cachedFiles {
            files = cachedFiles
        } else if clearExistingFiles {
            // Removing the previous rows also cancels their thumbnail and folder-size work.
            files.removeAll(keepingCapacity: true)
        }
        isLoadingCurrentFolder = true
        statusMessage = cachedFiles == nil ? "Loading \(normalizedPath)..." : "Updating \(normalizedPath)..."
        beginTrackedOperation(blocksTermination: false)

        let repository = fileRepository
        let task = Task { @MainActor [weak self, repository, device, normalizedPath] in
            guard let self else { return }
            defer {
                self.endTrackedOperation(blocksTermination: false)
                if self.adbNavigationRevision == revision {
                    self.isLoadingCurrentFolder = false
                    self.adbNavigationTask = nil
                    self.scheduleFolderSizeCalculations(for: self.visibleFilesIncludingExpandedChildren)
                }
            }

            do {
                let loadedFiles = try await repository.listFiles(device: device, path: normalizedPath)
                try Task.checkCancellation()
                guard self.adbNavigationRevision == revision,
                      self.currentPath == normalizedPath,
                      self.selectedDevice?.id == device.id,
                      self.browserMutationRevision(for: normalizedPath) == mutationRevision else {
                    return
                }
                self.applyCurrentFolderFiles(loadedFiles)
                self.statusMessage = "\(loadedFiles.count) item\(loadedFiles.count == 1 ? "" : "s") available."
            } catch is CancellationError {
                return
            } catch {
                guard self.adbNavigationRevision == revision else { return }
                self.handleOperationError(error)
            }
        }
        adbNavigationTask = task
        return task
    }

    public func showStorageBreakdown(for summary: StorageSummary, forceRefresh: Bool = false) async {
        guard let device = selectedDevice, device.state == .device else {
            alert = UserAlert(title: "ADB Not Connected", message: "Storage breakdowns require ADB because macOS File Transfer does not expose Android storage accounting.")
            return
        }

        sidebarSelection = .storage(summary.id)
        if forceRefresh {
            cancelStorageCategoryPrefetch()
        } else if prefetchingStorageBreakdownIDs.contains(summary.id) {
            statusMessage = "Storage breakdown is loading in the background."
            return
        }

        if storageBreakdowns[summary.id] != nil, !forceRefresh {
            statusMessage = "Storage breakdown ready."
            return
        }

        loadingStorageBreakdownID = summary.id
        statusMessage = "Analyzing \(summary.title)..."
        defer { loadingStorageBreakdownID = nil }

        do {
            let breakdown = try await fileRepository.storageBreakdown(device: device, summary: summary)
            storageBreakdowns[summary.id] = breakdown
            if forceRefresh {
                storageCategoryFileLists = storageCategoryFileLists.filter { !$0.key.hasPrefix("\(summary.id):") }
            }
            statusMessage = "Storage breakdown ready."
        } catch {
            alert = UserAlert(error: error)
            statusMessage = "Storage breakdown failed."
        }
    }

    public func selectStorageCategory(_ category: StorageBreakdownCategory, in summary: StorageSummary) async {
        selectedAppStorageLocation = nil
        guard category.kind.canBrowseFiles else {
            showStorageCategoryInfo(category)
            return
        }

        selectedStorageCategoryID = category.id
        guard let device = selectedDevice, device.state == .device else {
            alert = UserAlert(title: "ADB Not Connected", message: "Storage category details require ADB.")
            return
        }

        let listID = storageCategoryFileListID(summaryID: summary.id, categoryID: category.id)
        if prefetchingStorageCategoryIDs.contains(listID) {
            statusMessage = "Loading \(category.displayTitle.lowercased()) files in the background..."
            return
        }

        if category.kind == .apps {
            sortStorageAppsByLargest()
            if packages.isEmpty {
                loadingStorageCategoryID = listID
                defer { loadingStorageCategoryID = nil }
                await loadPackages()
            } else {
                statusMessage = "Apps storage details ready."
            }
            return
        }

        if storageCategoryFileLists[listID] != nil {
            statusMessage = "\(category.displayTitle) details ready."
            return
        }

        loadingStorageCategoryID = listID
        statusMessage = "Loading largest \(category.displayTitle.lowercased()) files..."
        defer { loadingStorageCategoryID = nil }

        do {
            let files = try await fileRepository.storageCategoryFiles(device: device, summary: summary, category: category)
            storageCategoryFileLists[listID] = StorageCategoryFileList(summaryID: summary.id, category: category, files: files)
            statusMessage = files.isEmpty
                ? "No accessible \(category.displayTitle.lowercased()) files found."
                : "Loaded \(files.count) \(category.displayTitle.lowercased()) file\(files.count == 1 ? "" : "s")."
        } catch {
            alert = UserAlert(error: error)
            statusMessage = "Could not load \(category.displayTitle.lowercased()) files."
        }
    }

    public func setTreeExpanded(_ file: AndroidFile, expanded: Bool) {
        guard file.isDirectory else { return }
        cancelFolderSizeWorker(clearQueue: true)
        if expanded {
            expandedTreePaths.insert(file.path)
            if treeChildrenByPath[file.path] != nil {
                scheduleFolderSizeCalculations(for: visibleFilesIncludingExpandedChildren)
            }
            // Cached children remain visible while this refresh reconciles the folder.
            startTreeChildrenLoad(for: file)
        } else {
            expandedTreePaths.remove(file.path)
            cancelTreeLoad(for: file.path)
            scheduleFolderSizeCalculations(for: visibleFilesIncludingExpandedChildren)
        }
    }

    public func loadTreeChildren(for file: AndroidFile) async {
        startTreeChildrenLoad(for: file)
        await treeLoadTasks[file.path]?.value
    }

    private func startTreeChildrenLoad(for file: AndroidFile) {
        guard file.isDirectory,
              canUseADBFileBrowser(),
              treeLoadTasks[file.path] == nil,
              let device = selectedDevice,
              device.state == .device else {
            return
        }

        let path = file.path
        let hadCachedChildren = treeChildrenByPath[path] != nil
        let requestID = UUID()
        let navigationRevision = adbNavigationRevision
        let mutationRevision = browserMutationRevision(for: path)
        let repository = fileRepository
        loadingTreePaths.insert(path)
        treeLoadRequestIDs[path] = requestID

        let task = Task { @MainActor [weak self, repository, device, path] in
            guard let self else { return }
            defer {
                if self.treeLoadRequestIDs[path] == requestID {
                    self.loadingTreePaths.remove(path)
                    self.treeLoadRequestIDs[path] = nil
                    self.treeLoadTasks[path] = nil
                    if self.loadingTreePaths.isEmpty {
                        self.scheduleFolderSizeCalculations(for: self.visibleFilesIncludingExpandedChildren)
                    }
                }
            }

            do {
                let children = try await repository.listFiles(device: device, path: path)
                try Task.checkCancellation()
                guard self.treeLoadRequestIDs[path] == requestID,
                      self.adbNavigationRevision == navigationRevision,
                      self.selectedDevice?.id == device.id,
                      self.browserMutationRevision(for: path) == mutationRevision,
                      self.expandedTreePaths.contains(path) else {
                    return
                }
                self.treeChildrenByPath[path] = children
                self.adbFolderListingsByPath[self.normalizedFolderCachePath(path)] = children
            } catch is CancellationError {
                return
            } catch {
                guard self.treeLoadRequestIDs[path] == requestID,
                      self.expandedTreePaths.contains(path) else {
                    return
                }
                if !hadCachedChildren {
                    self.treeChildrenByPath[path] = []
                    self.statusMessage = "Could not load \(file.name): \(error.localizedDescription)"
                } else {
                    self.statusMessage = "Could not update \(file.name). Showing the last folder contents."
                }
            }
        }
        treeLoadTasks[path] = task
    }

    private func cancelTreeLoad(for path: String) {
        treeLoadTasks[path]?.cancel()
        treeLoadTasks[path] = nil
        treeLoadRequestIDs[path] = nil
        loadingTreePaths.remove(path)
    }

    private func cancelAllTreeLoads() {
        for task in treeLoadTasks.values {
            task.cancel()
        }
        treeLoadTasks.removeAll()
        treeLoadRequestIDs.removeAll()
        loadingTreePaths.removeAll()
    }

    private func cancelADBFolderLoading() {
        adbNavigationRevision &+= 1
        adbNavigationTask?.cancel()
        adbNavigationTask = nil
        isLoadingCurrentFolder = false
        cancelAllTreeLoads()
        cancelFolderSizeWorker(clearQueue: true)
    }

    public func prepareFolderSize(for file: AndroidFile) async {
        guard file.isDirectory,
              settings.calculateFolderSizes,
              isADBFileBrowserSurface,
              connectionMode == .adb,
              uploadPresentation(for: file)?.isSynthetic != true,
              !loadingFolderSizePaths.contains(file.path),
              folderSizeBytesByPath[file.path] == nil,
              !failedFolderSizePaths.contains(file.path),
              let device = selectedDevice,
              device.state == .device else {
            return
        }

        loadingFolderSizePaths.insert(file.path)
        defer { loadingFolderSizePaths.remove(file.path) }

        do {
            let bytes = try await fileRepository.folderSizeBytes(device: device, path: file.path)
            try Task.checkCancellation()
            guard selectedDevice?.id == device.id else { return }
            folderSizeBytesByPath[file.path] = bytes
            failedFolderSizePaths.remove(file.path)
        } catch is CancellationError {
            return
        } catch {
            failedFolderSizePaths.insert(file.path)
        }
    }

    public func enqueueFolderSizeCalculation(for file: AndroidFile) {
        scheduleFolderSizeCalculations(for: [file])
    }

    public func folderSizeCalculationSettingDidChange(isEnabled: Bool) {
        usbTransferManager.folderSizeCalculationSettingDidChange(isEnabled: isEnabled)
        if isEnabled {
            scheduleFolderSizeCalculations(for: visibleFilesIncludingExpandedChildren)
        } else {
            cancelFolderSizeWorker(clearQueue: true)
            folderSizeBytesByPath.removeAll()
            loadingFolderSizePaths.removeAll()
            failedFolderSizePaths.removeAll()
        }
    }

    private func scheduleFolderSizeCalculations(for candidates: [AndroidFile]) {
        guard settings.calculateFolderSizes,
              isADBFileBrowserSurface,
              connectionMode == .adb,
              !isLoadingCurrentFolder,
              loadingTreePaths.isEmpty,
              selectedDevice?.state == .device else {
            return
        }

        for file in candidates where file.isDirectory {
            guard uploadPresentation(for: file)?.isSynthetic != true,
                  folderSizeBytesByPath[file.path] == nil,
                  !failedFolderSizePaths.contains(file.path),
                  !loadingFolderSizePaths.contains(file.path),
                  queuedFolderSizePaths.insert(file.path).inserted else {
                continue
            }
            folderSizeQueue.append(file)
        }
        startFolderSizeWorkerIfNeeded()
    }

    private func startFolderSizeWorkerIfNeeded() {
        guard folderSizeWorkerTask == nil, !folderSizeQueue.isEmpty else { return }
        folderSizeWorkerGeneration &+= 1
        let generation = folderSizeWorkerGeneration
        folderSizeWorkerTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.folderSizeWorkerGeneration == generation {
                    self.folderSizeWorkerTask = nil
                }
            }

            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }

            while self.folderSizeWorkerGeneration == generation,
                  self.settings.calculateFolderSizes,
                  !self.isLoadingCurrentFolder,
                  self.loadingTreePaths.isEmpty,
                  !self.folderSizeQueue.isEmpty {
                let file = self.folderSizeQueue.removeFirst()
                self.queuedFolderSizePaths.remove(file.path)
                await self.prepareFolderSize(for: file)
                guard !Task.isCancelled else { return }
                do {
                    try await Task.sleep(for: .milliseconds(80))
                } catch {
                    return
                }
            }
        }
    }

    private func cancelFolderSizeWorker(clearQueue: Bool) {
        folderSizeWorkerGeneration &+= 1
        folderSizeWorkerTask?.cancel()
        folderSizeWorkerTask = nil
        loadingFolderSizePaths.removeAll()
        if clearQueue {
            folderSizeQueue.removeAll()
            queuedFolderSizePaths.removeAll()
        }
    }

    public func resetSearchFilters() {
        searchKindFilter = .any
        searchDateFilter = .any
    }

    public func clearSearchKindFilter() {
        if parsedSearchQuery.kindFilter != nil {
            searchText = SearchQueryParser.removingKindFilters(from: searchText)
        }
        searchKindFilter = .any
    }

    private func scheduleFullDeviceSearchIfNeeded() {
        searchTask?.cancel()
        let rawSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = effectiveSearchText
        let kindFilter = effectiveSearchKindFilter
        let dateFilter = searchDateFilter
        guard isADBFileBrowserSurface,
              searchScope == .fullDevice,
              (!query.isEmpty || kindFilter != .any || dateFilter != .any) else {
            searchResults = []
            isSearchingFullDevice = false
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.runFullDeviceSearch(
                query: query,
                rawSearch: rawSearch,
                kindFilter: kindFilter,
                dateFilter: dateFilter
            )
        }
    }

    private func runFullDeviceSearch(
        query: String,
        rawSearch: String,
        kindFilter: FileSearchKindFilter,
        dateFilter: FileSearchDateFilter
    ) async {
        guard let device = selectedDevice, device.state == .device else { return }
        isSearchingFullDevice = true
        statusMessage = "Searching phone storage..."
        do {
            let results = try await fileRepository.searchFiles(
                device: device,
                query: query,
                root: "/storage/emulated/0",
                kindFilter: kindFilter,
                dateFilter: dateFilter
            )
            guard searchScope == .fullDevice,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines) == rawSearch,
                  effectiveSearchKindFilter == kindFilter,
                  searchDateFilter == dateFilter else { return }
            searchResults = results
            selectedFileIDs = selectedFileIDs.intersection(Set(results.map(\.id)))
            statusMessage = results.isEmpty ? "No full-system search results." : "\(results.count) full-system search result\(results.count == 1 ? "" : "s")."
        } catch {
            searchResults = []
            statusMessage = "Search failed: \(error.localizedDescription)"
            alert = UserAlert(error: error)
        }
        isSearchingFullDevice = false
    }

    public func navigateUp() {
        if isUSBTransferSelected {
            usbTransferManager.navigateUp()
            return
        }

        selectedAppStorageLocation = nil
        guard canUseADBFileBrowser() else { return }
        guard currentPath != "/" else { return }
        let parentPath = (currentPath as NSString).deletingLastPathComponent
        beginADBFolderNavigation(to: parentPath.isEmpty ? "/" : parentPath)
    }

    public func navigateBack() {
        if isUSBTransferSelected {
            usbTransferManager.navigateBack()
            return
        }
        guard canUseADBFileBrowser(), let destination = adbBackHistory.popLast() else { return }
        if destination != currentPath {
            adbForwardHistory.append(currentPath)
        }
        selectedAppStorageLocation = nil
        sidebarSelection = .location(QuickLocation(
            id: destination,
            title: (destination as NSString).lastPathComponent,
            path: destination,
            symbol: "folder"
        ))
        beginADBFolderNavigation(to: destination, recordsHistory: false)
    }

    public func navigateForward() {
        if isUSBTransferSelected {
            usbTransferManager.navigateForward()
            return
        }
        guard canUseADBFileBrowser(), let destination = adbForwardHistory.popLast() else { return }
        if destination != currentPath {
            adbBackHistory.append(currentPath)
        }
        selectedAppStorageLocation = nil
        sidebarSelection = .location(QuickLocation(
            id: destination,
            title: (destination as NSString).lastPathComponent,
            path: destination,
            symbol: "folder"
        ))
        beginADBFolderNavigation(to: destination, recordsHistory: false)
    }

    public func navigate(to path: String) {
        selectedAppStorageLocation = nil
        guard canUseADBFileBrowser() else { return }
        if appFolderContext?.contains(path: path) != true {
            appFolderContext = nil
            selectedPackageIDs.removeAll()
        }
        let destinationPath = path.isEmpty ? "/" : path
        sidebarSelection = .location(QuickLocation(id: destinationPath, title: (destinationPath as NSString).lastPathComponent, path: destinationPath, symbol: "folder"))
        selectedFileIDs.removeAll()
        beginADBFolderNavigation(to: destinationPath)
    }

    public func addQuickAccess(path: String) -> Bool {
        guard let file = files.first(where: { $0.path == path }), file.kind == .directory else {
            return false
        }
        guard !quickLocations.contains(where: { $0.path == path }) else {
            statusMessage = "\(file.name) is already in Favorites."
            return true
        }

        let location = QuickLocation(
            id: "custom:\(path)",
            title: file.name,
            path: path,
            symbol: "folder",
            subtitle: path
        )
        settings.customQuickLocations.append(location)
        statusMessage = "Added \(file.name) to Favorites."
        return true
    }

    public func hideOrRemoveQuickLocation(_ location: QuickLocation, sectionName: String = "Favorites", hiddenDefaultID: String? = nil) {
        if let hiddenDefaultID {
            settings.hiddenDefaultQuickLocationIDs.insert(hiddenDefaultID)
            statusMessage = "Hidden \(location.title) from \(sectionName)."
        } else if Self.defaultQuickLocations.contains(where: { $0.id == location.id }) {
            settings.hiddenDefaultQuickLocationIDs.insert(location.id)
            statusMessage = "Hidden \(location.title) from \(sectionName)."
        } else {
            settings.customQuickLocations.removeAll { $0.id == location.id }
            statusMessage = "Removed \(location.title) from \(sectionName)."
        }
    }

    public func isDefaultQuickLocation(_ location: QuickLocation) -> Bool {
        Self.defaultQuickLocations.contains { $0.id == location.id }
    }

    public func showQuickLocationInEnclosingFolder(_ location: QuickLocation) {
        guard canUseADBFileBrowser() else { return }

        let parentPath = (location.path as NSString).deletingLastPathComponent
        let destinationPath = parentPath.isEmpty ? "/" : parentPath
        selectedAppStorageLocation = nil
        selectedStorageCategoryID = nil
        appFolderContext = nil
        selectedPackageIDs.removeAll()
        sidebarSelection = nil

        guard let navigationTask = beginADBFolderNavigation(to: destinationPath) else { return }
        Task { @MainActor [weak self] in
            await navigationTask.value
            guard let self,
                  self.currentPath == destinationPath,
                  self.files.contains(where: { $0.path == location.path }) else {
                return
            }
            self.selectedFileIDs = [location.path]
            self.statusMessage = "Selected \(location.title)."
        }
    }

    public func showQuickLocationInfo(_ location: QuickLocation) {
        let folderName = (location.path as NSString).lastPathComponent
        showFileInfo(file: AndroidFile(
            name: folderName.isEmpty ? location.title : folderName,
            path: location.path,
            kind: .directory,
            size: nil,
            modified: nil,
            permissions: nil
        ))
    }

    public func showConnectionStatus() {
        ConnectionStatusWindowPresenter.show(model: self)
    }

    public func open(file: AndroidFile) {
        selectedAppStorageLocation = nil
        cancelInlineRename()
        if let presentation = uploadPresentation(for: file),
           presentation.isSynthetic || !presentation.state.isFinished {
            statusMessage = presentation.statusText
            return
        }
        guard file.kind == .directory else {
            if file.isExtractableArchive {
                confirmAndExtractArchive(file)
                return
            }
            if settings.openPreviewOnDoubleClick {
                Task { await preview(file: file) }
            }
            return
        }
        guard canUseADBFileBrowser() else { return }
        sidebarSelection = .location(QuickLocation(id: file.path, title: file.name, path: file.path, symbol: "folder"))
        selectedFileIDs.removeAll()
        beginADBFolderNavigation(to: file.path)
    }

    public func toggleQuickLookPreview() {
        if PreviewWindowPresenter.isSessionVisible {
            PreviewWindowPresenter.closeSession()
            return
        }

        if isUSBTransferSelected {
            usbTransferManager.showQuickLookPreviewForSelection()
        } else if let selectedAppStorageLocation {
            showQuickLookPreview(for: selectedAppStorageLocation)
        } else {
            showQuickLookPreviewForSelection()
        }
    }

    private func showQuickLookPreview(for selection: SelectedAppStorageLocation) {
        let entry = PreviewWindowPresenter.SessionEntry(
            id: selection.id,
            title: selection.location.title,
            kind: .folder,
            symbol: selection.location.symbol,
            details: [
                ("App", selection.packageName),
                ("Version", selection.versionName ?? "Unknown"),
                ("Kind", selection.isProtected ? "Protected app storage" : "App storage folder"),
                ("Size", selection.displaySize),
                ("Path", selection.location.path)
            ]
        )

        PreviewWindowPresenter.showSession(
            title: "Preview",
            entries: [entry],
            selectedID: entry.id,
            loadURL: { _ in URL(fileURLWithPath: "/") },
            releaseURL: { _ in },
            onSelect: { _ in }
        )
    }

    private func showQuickLookPreviewForSelection() {
        cancelInlineRename()
        guard let selected = selectedFile else {
            statusMessage = "Select an item to preview."
            return
        }

        let files = quickLookItemOrder(for: selected)
        guard !files.isEmpty else {
            statusMessage = "Select an item to preview."
            return
        }

        let entries = files.map(quickLookEntry)

        PreviewWindowPresenter.showSession(
            title: "Preview",
            entries: entries,
            selectedID: selected.id,
            loadURL: { [weak self, files] entry in
                guard let self,
                      let file = files.first(where: { $0.id == entry.id }) else {
                    throw FileOperationError.commandFailed("\(entry.title) is no longer available.")
                }
                return try await self.cachedPreviewURL(for: file)
            },
            releaseURL: { [weak self] url in
                self?.releaseCachedPreviewURL(url)
            },
            onSelect: { [weak self, files] entry in
                guard let self,
                      let file = files.first(where: { $0.id == entry.id }) else { return }
                self.selectFile(file, from: files, modifiers: [])
            }
        )
    }

    private func quickLookItemOrder(for selected: AndroidFile) -> [AndroidFile] {
        let storedOrder = lastSelectionFileOrder.filter(\.canQuickLook)
        if storedOrder.contains(where: { $0.id == selected.id }) {
            return storedOrder
        }

        if let storageFiles = selectedStorageCategoryFileList?.files.filter(\.canQuickLook),
           storageFiles.contains(where: { $0.id == selected.id }) {
            return storageFiles
        }

        let visibleOrder = visibleFilesIncludingExpandedChildren.filter(\.canQuickLook)
        if visibleOrder.contains(where: { $0.id == selected.id }) {
            return visibleOrder
        }

        return [selected]
    }

    private func quickLookEntry(for file: AndroidFile) -> PreviewWindowPresenter.SessionEntry {
        PreviewWindowPresenter.SessionEntry(
            id: file.id,
            title: file.name,
            kind: file.isDirectory ? .folder : .file,
            symbol: file.fallbackSymbol,
            details: quickLookDetails(for: file)
        )
    }

    private func quickLookDetails(for file: AndroidFile) -> [(String, String)] {
        var details: [(String, String)] = [
            ("Kind", file.kind.displayName),
            ("Size", displaySize(for: file)),
            ("Modified", file.displayModified),
            ("Created", file.displayCreated),
            ("Path", file.path)
        ]
        if let permissions = file.permissions {
            details.insert(("Permissions", permissions), at: 3)
        }
        return details
    }

    public func handleNameClickForInlineRename(_ file: AndroidFile) {
        guard inlineRenameFileID != file.id else { return }
        let modifiers = NSEvent.modifierFlags
        guard !modifiers.contains(.command),
              !modifiers.contains(.shift),
              selectedFileIDs == [file.id],
              inlineRenameBlockedBySelectionFileID != file.id else {
            return
        }
        scheduleInlineRename(for: file)
    }

    public func cancelInlineRename() {
        pendingInlineRenameWorkItem?.cancel()
        pendingInlineRenameWorkItem = nil
        inlineRenameFileID = nil
    }

    public func commitInlineRename(file: AndroidFile, newName: String) {
        cancelInlineRename()
        Task { await rename(file: file, to: newName) }
    }

    private func scheduleInlineRename(for file: AndroidFile) {
        pendingInlineRenameWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.selectedFileIDs == [file.id],
                  self.selectedFiles.contains(where: { $0.id == file.id }) else {
                return
            }
            self.inlineRenameFileID = file.id
            self.pendingInlineRenameWorkItem = nil
        }
        pendingInlineRenameWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    public func selectFile(_ file: AndroidFile, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        selectFile(file, from: visibleFiles, modifiers: modifiers)
    }

    public func selectFile(
        _ file: AndroidFile,
        from visibleSource: [AndroidFile],
        modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {
        selectedAppStorageLocation = nil
        lastSelectionFileOrder = visibleSource
        let wasSingleSelectedItem = selectedFileIDs == [file.id]
        if !wasSingleSelectedItem {
            cancelInlineRename()
        }

        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        let visibleIDs = visibleSource.map(\.id)

        if shift,
           let anchor = lastSelectedFileID,
           let anchorIndex = visibleIDs.firstIndex(of: anchor),
           let selectedIndex = visibleIDs.firstIndex(of: file.id) {
            let range = anchorIndex <= selectedIndex ? anchorIndex...selectedIndex : selectedIndex...anchorIndex
            let rangeIDs = Set(range.map { visibleIDs[$0] })
            if command {
                selectedFileIDs.formUnion(rangeIDs)
            } else {
                selectedFileIDs = rangeIDs
            }
        } else if command {
            if selectedFileIDs.contains(file.id) {
                selectedFileIDs.remove(file.id)
            } else {
                selectedFileIDs.insert(file.id)
            }
        } else {
            selectedFileIDs = [file.id]
        }

        lastSelectedFileID = file.id
        if !shift {
            keyboardSelectionAnchorFileID = file.id
        }
        if !wasSingleSelectedItem, selectedFileIDs == [file.id] {
            blockInlineRenameForCurrentSelectionEvent(fileID: file.id)
        }
        if let inlineRenameFileID, !selectedFileIDs.contains(inlineRenameFileID) {
            cancelInlineRename()
        }
        if PreviewWindowPresenter.isSessionVisible, selectedFileIDs == [file.id] {
            let didUpdateSession = PreviewWindowPresenter.updateSessionSelection(selectedID: file.id)
            if !didUpdateSession, file.canQuickLook {
                showQuickLookPreviewForSelection()
            }
        }
    }

    public func clearFileSelection() {
        cancelInlineRename()
        selectedFileIDs.removeAll()
        selectedAppStorageLocation = nil
        lastSelectedFileID = nil
        keyboardSelectionAnchorFileID = nil
        lastSelectionFileOrder.removeAll()
    }

    public func prepareFileSelectionForContextMenu(_ file: AndroidFile) {
        guard !selectedFileIDs.contains(file.id) else { return }
        selectFile(file, from: visibleFilesIncludingExpandedChildren, modifiers: [])
    }

    private func moveADBFileSelection(by delta: Int, extending: Bool) {
        guard canUseActiveADBFileCommands else { return }
        let visible = visibleFilesIncludingExpandedChildren
        guard !visible.isEmpty else { return }

        let currentID = lastSelectedFileID.flatMap { id in
            selectedFileIDs.contains(id) ? id : nil
        } ?? visible.first(where: { selectedFileIDs.contains($0.id) })?.id

        let targetIndex: Int
        if let currentID,
           let currentIndex = visible.firstIndex(where: { $0.id == currentID }) {
            targetIndex = min(max(currentIndex + delta, 0), visible.count - 1)
        } else {
            targetIndex = delta < 0 ? visible.count - 1 : 0
        }

        let target = visible[targetIndex]
        if !extending || selectedFileIDs.isEmpty {
            selectFile(target, from: visible, modifiers: [])
            keyboardSelectionAnchorFileID = target.id
            return
        }

        cancelInlineRename()
        let anchorID = keyboardSelectionAnchorFileID
            ?? lastSelectedFileID
            ?? selectedFileIDs.first
            ?? target.id
        guard let anchorIndex = visible.firstIndex(where: { $0.id == anchorID }) else {
            selectFile(target, from: visible, modifiers: [])
            keyboardSelectionAnchorFileID = target.id
            return
        }

        let lowerBound = min(anchorIndex, targetIndex)
        let upperBound = max(anchorIndex, targetIndex)
        selectedFileIDs = Set(visible[lowerBound...upperBound].map(\.id))
        lastSelectionFileOrder = visible
        lastSelectedFileID = target.id
        keyboardSelectionAnchorFileID = anchorID
    }

    private func blockInlineRenameForCurrentSelectionEvent(fileID: AndroidFile.ID) {
        inlineRenameBlockedBySelectionFileID = fileID
        DispatchQueue.main.async { [weak self] in
            guard self?.inlineRenameBlockedBySelectionFileID == fileID else { return }
            self?.inlineRenameBlockedBySelectionFileID = nil
        }
    }

    public func toggleColumn(_ column: FileColumn) {
        guard column.isHideable else { return }
        if visibleFileColumns.contains(column) {
            visibleFileColumns.remove(column)
        } else {
            visibleFileColumns.insert(column)
        }
    }

    public func sortBy(column: FileColumn) {
        sortBy(column: column, modifiers: NSEvent.modifierFlags)
    }

    public func sortBy(column: FileColumn, modifiers: NSEvent.ModifierFlags) {
        let requestedSort = column.sort
        let defaultAscending = column == .modified || column == .created ? false : true
        let command = modifiers.contains(.command)

        if command {
            updateFileSortDescriptors(sort: requestedSort, defaultAscending: defaultAscending)
        } else if sort == requestedSort {
            sortAscending.toggle()
            fileSortDescriptors = [FileSortDescriptor(sort: requestedSort, ascending: sortAscending)]
        } else {
            sort = requestedSort
            sortAscending = defaultAscending
            fileSortDescriptors = [FileSortDescriptor(sort: requestedSort, ascending: defaultAscending)]
        }
        syncPrimaryFileSortFromDescriptors()
    }

    public func fileSortIndicator(for column: FileColumn) -> (priority: Int, ascending: Bool)? {
        guard let index = activeFileSortDescriptors.firstIndex(where: { $0.sort == column.sort }) else { return nil }
        return (index + 1, activeFileSortDescriptors[index].ascending)
    }

    public func upload(urls: [URL], to targetPath: String? = nil, replace: Bool = false) async {
        let destination = targetPath ?? currentPath
        await perform("Queueing \(urls.count) upload\(urls.count == 1 ? "" : "s")...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            if targetPath != nil {
                let parent = (destination as NSString).deletingLastPathComponent
                let name = (destination as NSString).lastPathComponent
                if !parent.isEmpty, !name.isEmpty {
                    try await fileRepository.createFolder(device: device, parent: parent, name: name)
                }
            }

            var uploadRequests: [LocalUploadRequest] = []
            var duplicateNames: [String] = []
            for url in urls {
                let name = url.lastPathComponent
                if try await fileRepository.fileExists(device: device, path: ADBClient.joinRemote(destination, name)), !replace {
                    duplicateNames.append(name)
                }
                uploadRequests.append(try localUploadRequest(for: url, remoteName: name, replace: replace))
            }

            if !duplicateNames.isEmpty, !replace {
                guard let resolution = promptDuplicateResolution(itemNames: duplicateNames, destination: destination) else {
                    statusMessage = "Upload canceled."
                    return
                }

                var resolvedRequests: [(url: URL, remoteName: String, replace: Bool)] = []
                for request in uploadRequests {
                    if duplicateNames.contains(request.remoteName) {
                        switch resolution {
                        case .skip:
                            continue
                        case .replace:
                            var resolved = request
                            resolved.replace = true
                            resolvedRequests.append((resolved.url, resolved.remoteName, resolved.replace))
                        case .keep:
                            let availableName = try await fileRepository.availableRemoteName(
                                device: device,
                                directory: destination,
                                preferredName: request.remoteName
                            )
                            resolvedRequests.append((request.url, availableName, false))
                        }
                    } else {
                        resolvedRequests.append((request.url, request.remoteName, request.replace))
                    }
                }
                uploadRequests = try resolvedRequests.map { request in
                    try localUploadRequest(for: request.url, remoteName: request.remoteName, replace: request.replace)
                }
            }

            guard !uploadRequests.isEmpty else {
                statusMessage = "Upload skipped."
                return
            }

            for request in uploadRequests {
                if request.isDirectory {
                    enqueueFolderUpload(request, destination: destination, device: device)
                } else if let file = request.files.first {
                    enqueueFileUpload(
                        file,
                        sourceTitle: request.url.lastPathComponent,
                        remoteName: request.remoteName,
                        destination: destination,
                        device: device,
                        replace: request.replace,
                        parentID: nil,
                        exclusiveGroup: nil
                    )
                }
            }
            statusMessage = "Queued \(uploadRequests.count) upload\(uploadRequests.count == 1 ? "" : "s")."
        }
    }

    public func beginUpload(to targetPath: String? = nil) {
        uploadTargetPath = targetPath
        showUploadImporter = true
    }

    public func upload(urls: [URL], into folder: AndroidFile) async {
        guard folder.kind == .directory else { return }
        await upload(urls: urls, to: folder.path)
    }

    private func enqueueFolderUpload(_ request: LocalUploadRequest, destination: String, device: AndroidDevice) {
        let source = TransferEndpoint(kind: .mac, path: request.url.path, displayName: request.url.lastPathComponent)
        let remoteRoot = ADBClient.joinRemote(destination, request.remoteName)
        let target = TransferEndpoint(kind: .adb, deviceID: device.serial, path: remoteRoot, displayName: remoteRoot)
        let groupID = transferQueue.enqueueGroup(
            kind: .upload,
            title: request.url.lastPathComponent,
            subtitle: "Uploading folder to \(destination)",
            source: source,
            destination: target,
            totalBytes: request.totalBytes
        )
        let exclusiveGroup = "adb-folder-upload:\(groupID.uuidString)"

        transferQueue.enqueue(
            kind: .upload,
            title: request.remoteName,
            subtitle: "Creating folder in \(destination)",
            source: source,
            destination: target,
            itemKind: .folder,
            parentID: groupID,
            totalBytes: 0,
            exclusiveGroup: exclusiveGroup
        ) { [fileRepository, weak self] controller in
            controller.updateProgress(fractionCompleted: 0)
            try controller.checkCancellation()
            if request.replace {
                try await fileRepository.deletePermanently(device: device, remotePath: remoteRoot)
                try controller.checkCancellation()
            }
            try await fileRepository.createFolder(device: device, parent: destination, name: request.remoteName)
            try controller.checkCancellation()
            for relativeDirectory in request.directories {
                try controller.checkCancellation()
                let remoteDirectory = ADBClient.joinRemote(remoteRoot, relativeDirectory)
                let parent = (remoteDirectory as NSString).deletingLastPathComponent
                let name = (remoteDirectory as NSString).lastPathComponent
                if !parent.isEmpty, !name.isEmpty {
                    try await fileRepository.createFolder(device: device, parent: parent, name: name)
                }
            }
            try controller.checkCancellation()
            controller.updateProgress(fractionCompleted: 1)
            if destination == self?.currentPath {
                try? await self?.refreshFilesThrowing()
            }
            return TransferJobResult(message: "Created")
        }

        for file in request.files {
            let remoteParent = file.relativeDirectory.isEmpty
                ? remoteRoot
                : ADBClient.joinRemote(remoteRoot, file.relativeDirectory)
            enqueueFileUpload(
                file,
                sourceTitle: file.remoteName,
                remoteName: file.remoteName,
                destination: remoteParent,
                device: device,
                replace: request.replace,
                parentID: groupID,
                exclusiveGroup: exclusiveGroup
            )
        }
    }

    private func enqueueFileUpload(
        _ file: LocalUploadFile,
        sourceTitle: String,
        remoteName: String,
        destination: String,
        device: AndroidDevice,
        replace: Bool,
        parentID: UUID?,
        exclusiveGroup: String?
    ) {
        let source = TransferEndpoint(kind: .mac, path: file.url.path, displayName: sourceTitle)
        let remotePath = ADBClient.joinRemote(destination, remoteName)
        let target = TransferEndpoint(kind: .adb, deviceID: device.serial, path: remotePath, displayName: remotePath)
        transferQueue.enqueue(
            kind: .upload,
            title: sourceTitle,
            subtitle: "Uploading to \(destination)",
            source: source,
            destination: target,
            itemKind: .file,
            parentID: parentID,
            totalBytes: file.size,
            exclusiveGroup: exclusiveGroup
        ) { [fileRepository, weak self] controller in
            try controller.checkCancellation()
            if parentID != nil {
                let parent = (destination as NSString).deletingLastPathComponent
                let name = (destination as NSString).lastPathComponent
                if !parent.isEmpty, !name.isEmpty {
                    try await fileRepository.createFolder(device: device, parent: parent, name: name)
                }
            }
            try controller.checkCancellation()
            _ = try await fileRepository.push(
                device: device,
                localURL: file.url,
                to: destination,
                remoteName: remoteName,
                replace: replace
            ) { fraction in
                Task { @MainActor in
                    controller.updateProgress(fractionCompleted: fraction)
                }
            }
            try controller.checkCancellation()
            if destination == self?.currentPath || parentID != nil {
                try? await self?.refreshFilesThrowing()
            }
            return TransferJobResult(message: "Uploaded")
        }
    }

    public func downloadSelected() async {
        guard !selectedFiles.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        await perform("Queueing \(selectedFiles.count) download\(selectedFiles.count == 1 ? "" : "s")...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            let filesToDownload = selectedFiles
            let duplicateNames = filesToDownload
                .map(\.name)
                .filter { FileManager.default.fileExists(atPath: destination.appending(path: $0).path) }
            let resolution = duplicateNames.isEmpty
                ? nil
                : promptDuplicateResolution(itemNames: duplicateNames, destination: destination.path)

            if !duplicateNames.isEmpty, resolution == nil {
                statusMessage = "Download canceled."
                return
            }

            var queuedCount = 0
            for file in filesToDownload {
                var localName = file.name
                var shouldReplace = false
                if duplicateNames.contains(file.name), let resolution {
                    switch resolution {
                    case .skip:
                        continue
                    case .replace:
                        shouldReplace = true
                    case .keep:
                        localName = TransferConflictResolver.enumeratedName(
                            for: file.name,
                            existingNames: localDirectoryNames(destination)
                        )
                    }
                }

                let queuedLocalName = localName
                let queuedShouldReplace = shouldReplace
                transferQueue.enqueue(
                    kind: .download,
                    title: file.name,
                    subtitle: "Downloading to \(destination.path)",
                    source: TransferEndpoint(kind: .adb, deviceID: device.serial, path: file.path, displayName: file.path),
                    destination: TransferEndpoint(kind: .mac, path: destination.appending(path: queuedLocalName).path, displayName: queuedLocalName),
                    totalBytes: file.size
                ) { [fileRepository] controller in
                    try controller.checkCancellation()
                    let output = try await fileRepository.pull(
                        device: device,
                        remotePath: file.path,
                        to: destination,
                        localName: queuedLocalName,
                        replace: queuedShouldReplace
                    ) { fraction in
                        Task { @MainActor in
                            controller.updateProgress(fractionCompleted: fraction)
                        }
                    }
                    try controller.checkCancellation()
                    return TransferJobResult(outputURL: output, message: "Downloaded")
                }
                queuedCount += 1
            }
            transferQueue.isPanelExpanded = true
            statusMessage = queuedCount == 0 ? "Download skipped." : "Queued \(queuedCount) download\(queuedCount == 1 ? "" : "s")."
        }
    }

    public func download(file: AndroidFile) async {
        selectedFileIDs = [file.id]
        await downloadSelected()
    }

    public func requestCompressSelected() {
        guard canCompressSelection else { return }
        pendingArchiveRequest = ArchiveCreationRequest(defaultName: defaultArchiveName())
    }

    public func requestCompress(file: AndroidFile) {
        guard file.canCompress else { return }
        selectedFileIDs = [file.id]
        pendingArchiveRequest = ArchiveCreationRequest(defaultName: defaultArchiveName(for: [file]))
    }

    public func compressSelected(as rawName: String) async {
        let filesToArchive = selectedFiles.filter(\.canCompress)
        guard !filesToArchive.isEmpty else { return }
        pendingArchiveRequest = nil

        await perform("Compressing \(filesToArchive.count) item\(filesToArchive.count == 1 ? "" : "s")...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            _ = try await fileRepository.compressToZip(
                device: device,
                files: filesToArchive,
                baseDirectory: currentPath,
                archiveName: rawName
            )
            try await refreshFilesThrowing()
            statusMessage = "Created archive in \(currentPath)."
        }
    }

    public func extractArchive(_ file: AndroidFile) async {
        guard file.isExtractableArchive else { return }
        selectedFileIDs = [file.id]
        await perform("Uncompressing \(file.name)...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            let parent = (file.path as NSString).deletingLastPathComponent
            _ = try await fileRepository.extractArchive(device: device, archive: file, toParent: parent)
            if parent == currentPath {
                try await refreshFilesThrowing()
            }
            statusMessage = "Uncompressed \(file.name)."
        }
    }

    public func confirmAndExtractArchive(_ file: AndroidFile) {
        guard file.isExtractableArchive,
              ArchiveExtractionConfirmation.confirm(fileName: file.name) else {
            return
        }
        Task { await extractArchive(file) }
    }

    public func dragItemProvider(for file: AndroidFile) -> NSItemProvider? {
        guard canExportToFinder(file) else { return nil }
        let typeIdentifier = finderTypeIdentifier(for: file)
        return RemoteFileDragProvider.provider(fileName: file.name, typeIdentifier: typeIdentifier) { [weak self] in
            guard let self else { throw FileOperationError.noDevice }
            return try await self.exportFileForDrag(file)
        }
    }

    private func filePromiseProvider(
        for file: AndroidFile,
        remoteDragPayload: RemoteBrowserDragPayload
    ) -> FinderFilePromiseDragItem? {
        guard canExportToFinder(file) else { return nil }
        let typeIdentifier = finderTypeIdentifier(for: file)
        let provider = RemoteFileDragProvider.filePromiseProvider(fileName: file.name, typeIdentifier: typeIdentifier) { [weak self] destinationURL in
            guard let self else { throw FileOperationError.noDevice }
            _ = try await self.exportFile(file, to: destinationURL, subtitle: "Copying to Finder")
        }
        return FinderFilePromiseDragItem(
            provider: provider,
            fileName: file.name,
            typeIdentifier: typeIdentifier,
            isFolder: file.kind == .directory,
            remoteDragPayload: remoteDragPayload
        )
    }

    func filePromiseProvidersForDrag(startingWith file: AndroidFile) -> [FinderFilePromiseDragItem] {
        guard canExportToFinder(file) else { return [] }
        let draggedFiles = selectedFileIDs.contains(file.id)
            ? selectedFiles.filter(canExportToFinder)
            : [file]
        guard let device = selectedDevice else { return [] }
        let payload = RemoteBrowserDragPayload(
            backend: .adb,
            deviceID: device.serial,
            items: draggedFiles.map {
                RemoteBrowserDragItem(
                    id: $0.id,
                    path: $0.path,
                    name: $0.name,
                    isFolder: $0.isDirectory,
                    size: $0.size
                )
            }
        )
        let providers = draggedFiles.compactMap { filePromiseProvider(for: $0, remoteDragPayload: payload) }
        return providers.isEmpty
            ? [file].compactMap { filePromiseProvider(for: $0, remoteDragPayload: payload) }
            : providers
    }

    private func canExportToFinder(_ file: AndroidFile) -> Bool {
        file.kind == .file || file.kind == .directory
    }

    func canAcceptRemoteDrop(_ payload: RemoteBrowserDragPayload, into folder: AndroidFile) -> Bool {
        guard folder.kind == .directory,
              payload.backend == .adb,
              payload.deviceID == selectedDevice?.serial,
              !payload.items.isEmpty else {
            return false
        }

        return payload.items.allSatisfy { item in
            let sourceParent = (item.path as NSString).deletingLastPathComponent
            guard sourceParent != folder.path,
                  item.path != folder.path else {
                return false
            }
            return !item.isFolder || !folder.path.hasPrefix("\(item.path)/")
        }
    }

    func moveRemoteDrop(_ payload: RemoteBrowserDragPayload, into folder: AndroidFile) {
        guard canAcceptRemoteDrop(payload, into: folder) else {
            statusMessage = "That item can't be moved there."
            return
        }
        Task { @MainActor [weak self] in
            await self?.moveRemoteDropItems(payload, into: folder)
        }
    }

    private func moveRemoteDropItems(_ payload: RemoteBrowserDragPayload, into folder: AndroidFile) async {
        await perform("Moving to \(folder.name)...") {
            guard let device = selectedDevice, device.serial == payload.deviceID else {
                throw FileOperationError.noDevice
            }

            let draggedItems = normalizedRemoteDragItems(payload.items)
            guard !draggedItems.isEmpty else {
                statusMessage = "Move skipped."
                return
            }

            let cachedDestination = cachedFolderListing(at: folder.path) ?? []
            let existingDestinationNames = Set(cachedDestination.map { $0.name.lowercased() })
            var claimedNamesForPrompt = existingDestinationNames
            var duplicates: [String] = []
            for item in draggedItems where !claimedNamesForPrompt.insert(item.name.lowercased()).inserted {
                duplicates.append(item.name)
            }
            let resolution = duplicates.isEmpty
                ? nil
                : promptDuplicateResolution(itemNames: duplicates, destination: folder.path)
            if !duplicates.isEmpty, resolution == nil {
                statusMessage = "Move canceled."
                return
            }

            var claimedNames = existingDestinationNames
            var namesClaimedByThisDrop = Set<String>()
            var plans: [OptimisticRemoteMovePlan] = []
            for item in draggedItems {
                let originalLowercasedName = item.name.lowercased()
                var destinationName = item.name
                var replacesExistingDestination = false
                if claimedNames.contains(originalLowercasedName), let resolution {
                    switch resolution {
                    case .skip:
                        continue
                    case .replace:
                        if existingDestinationNames.contains(originalLowercasedName),
                           !namesClaimedByThisDrop.contains(originalLowercasedName) {
                            replacesExistingDestination = true
                        } else {
                            // Two selected items can share a name when they come from
                            // different expanded folders. Never let the later move
                            // overwrite an item moved earlier in this same drop.
                            destinationName = TransferConflictResolver.enumeratedName(
                                for: item.name,
                                existingNames: claimedNames
                            )
                        }
                    case .keep:
                        destinationName = TransferConflictResolver.enumeratedName(
                            for: item.name,
                            existingNames: claimedNames
                        )
                    }
                }

                let sourceParent = (item.path as NSString).deletingLastPathComponent
                let destinationPath = ADBClient.joinRemote(folder.path, destinationName)
                let replacedDestination = replacesExistingDestination
                    ? cachedDestination.first {
                        $0.path == destinationPath
                            || $0.name.localizedCaseInsensitiveCompare(destinationName) == .orderedSame
                    }
                    : nil
                let originalFile = cachedBrowserFile(at: item.path) ?? AndroidFile(
                    name: item.name,
                    path: item.path,
                    kind: item.isFolder ? .directory : .file,
                    size: item.size,
                    modified: nil,
                    permissions: nil
                )
                plans.append(
                    OptimisticRemoteMovePlan(
                        item: item,
                        originalFile: originalFile,
                        sourceParent: sourceParent,
                        destinationName: destinationName,
                        destinationPath: destinationPath,
                        replacedDestination: replacedDestination,
                        sourceWasInSearchResults: searchResults.contains { $0.path == item.path },
                        replacedDestinationSearchResults: replacedDestination.map { replaced in
                            searchResults.filter {
                                $0.path == replaced.path || $0.path.hasPrefix("\(replaced.path)/")
                            }
                        } ?? []
                    )
                )
                claimedNames.insert(destinationName.lowercased())
                namesClaimedByThisDrop.insert(destinationName.lowercased())
            }

            guard !plans.isEmpty else {
                statusMessage = "Move skipped."
                return
            }

            let affectedTreePaths = Set(plans.map(\.sourceParent)).union([folder.path])
            beginBrowserMutation(at: affectedTreePaths)
            for path in Array(treeLoadTasks.keys) where affectedTreePaths.contains(path)
                || plans.contains(where: { path == $0.item.path || path.hasPrefix("\($0.item.path)/") }) {
                cancelTreeLoad(for: path)
            }
            cancelFolderSizeWorker(clearQueue: true)

            // Mirror Finder: update the browser before asking the phone to do the work.
            for plan in plans {
                optimisticallyMoveRemoteItem(plan, into: folder)
            }
            var expectedOperationSelection = Set(plans.map(\.destinationPath))
            var operationStillOwnsSelection = true
            selectedFileIDs = expectedOperationSelection

            var completedPlans: [OptimisticRemoteMovePlan] = []
            var firstFailure: Error?
            var recoveryWarnings: [String] = []
            for plan in plans {
                if operationStillOwnsSelection, selectedFileIDs != expectedOperationSelection {
                    operationStillOwnsSelection = false
                }
                var jobID: UUID?
                do {
                    _ = try await transferQueue.enqueueAndWait(
                        kind: .move,
                        title: plan.item.name,
                        subtitle: "Moving to \(folder.name)",
                        source: TransferEndpoint(
                            kind: .adb,
                            deviceID: device.serial,
                            path: plan.item.path,
                            displayName: plan.item.name
                        ),
                        destination: TransferEndpoint(
                            kind: .adb,
                            deviceID: device.serial,
                            path: plan.destinationPath,
                            displayName: folder.name
                        ),
                        itemKind: plan.item.isFolder ? .folder : .file,
                        totalBytes: plan.item.isFolder ? folderSizeBytesByPath[plan.item.path] : plan.item.size,
                        exclusiveGroup: "adb:\(device.serial)",
                        defersPresentation: true,
                        onEnqueued: { queuedID in
                            jobID = queuedID
                            self.scheduleDelayedTransferPresentation(for: queuedID)
                        }
                    ) { [fileRepository] controller in
                        try controller.checkCancellation()
                        _ = try await fileRepository.move(
                            device: device,
                            source: plan.item.path,
                            to: folder.path,
                            destinationName: plan.destinationName,
                            replace: plan.replacedDestination != nil
                        )
                        return TransferJobResult(message: "Moved")
                    }
                    completedPlans.append(plan)
                } catch FileOperationError.moveCompletedWithRecoveryCopy(
                    let destination,
                    let recoveryPath,
                    let reason
                ) {
                    completedPlans.append(plan)
                    recoveryWarnings.append(
                        "The move to \(destination) finished. The replaced item is safe at \(recoveryPath). \(reason)"
                    )
                    if let queuedID = jobID {
                        delayedTransferPresentationTasks.removeValue(forKey: queuedID)?.cancel()
                        presentedDelayedTransferJobIDs.remove(queuedID)
                        _ = transferQueue.discardFinishedJob(id: queuedID)
                        jobID = nil
                    }
                } catch {
                    rollbackOptimisticRemoteMove(plan, from: folder.path)
                    expectedOperationSelection.remove(plan.destinationPath)
                    expectedOperationSelection.insert(plan.originalFile.id)
                    if operationStillOwnsSelection {
                        selectedFileIDs = expectedOperationSelection
                    }
                    firstFailure = firstFailure ?? error
                }
                if let jobID {
                    finishDelayedTransferPresentation(for: jobID)
                }
            }

            if !completedPlans.isEmpty {
                let undoSteps = completedPlans.map {
                    FileHistoryMoveStep(
                        sourcePath: $0.destinationPath,
                        destinationDirectory: $0.sourceParent,
                        destinationName: $0.item.name,
                        replace: false
                    )
                }
                recordFileHistory(.moveItems(deviceSerial: device.serial, steps: undoSteps, actionName: "Move"))
            }

            let refreshPaths = Set(plans.map(\.sourceParent)).union([folder.path])
            let reconciliationPaths = finishBrowserMutation(at: refreshPaths)
            scheduleFolderReconciliation(at: reconciliationPaths, device: device)

            if let firstFailure {
                if completedPlans.isEmpty {
                    throw firstFailure
                }
                throw FileOperationError.commandFailed(
                    "Moved \(completedPlans.count) item\(completedPlans.count == 1 ? "" : "s"), but \(plans.count - completedPlans.count) could not be moved. \(firstFailure.localizedDescription)"
                )
            }
            if recoveryWarnings.isEmpty {
                statusMessage = "Moved \(completedPlans.count) item\(completedPlans.count == 1 ? "" : "s") to \(folder.name)."
            } else {
                alert = UserAlert(
                    title: "Move Finished with a Recovery Copy",
                    message: recoveryWarnings.joined(separator: "\n\n")
                )
                statusMessage = "Move finished. A replaced item was kept as a recovery copy."
            }
        }
    }

    private func optimisticallyMoveRemoteItem(_ plan: OptimisticRemoteMovePlan, into folder: AndroidFile) {
        removeBrowserFileFromCachedListings(at: plan.item.path)
        if plan.replacedDestination != nil {
            // The replaced folder's descendants belong to a different subtree.
            // Drop that cache rather than merging it with the moved folder.
            purgeCachedBrowserSubtree(at: plan.destinationPath)
        }
        removeBrowserFileFromCachedListings(at: plan.destinationPath)
        if plan.item.isFolder {
            remapCachedBrowserSubtree(from: plan.item.path, to: plan.destinationPath)
        }
        let moved = AndroidFile(
            name: plan.destinationName,
            path: plan.destinationPath,
            kind: plan.originalFile.kind,
            size: plan.originalFile.size,
            modified: plan.originalFile.modified,
            permissions: plan.originalFile.permissions,
            created: plan.originalFile.created
        )
        if plan.replacedDestination != nil {
            searchResults.removeAll {
                $0.path == plan.destinationPath || $0.path.hasPrefix("\(plan.destinationPath)/")
            }
        }
        remapSearchResultSubtree(
            from: plan.item.path,
            to: plan.destinationPath,
            includeRoot: plan.sourceWasInSearchResults
        )
        if plan.sourceWasInSearchResults,
           !searchResults.contains(where: { $0.path == moved.path }) {
            searchResults.append(moved)
        }
        expandedTreePaths.insert(folder.path)
        insertBrowserFileIntoCachedListing(moved, parentPath: folder.path, createTreeListing: true)
    }

    private func normalizedRemoteDragItems(_ items: [RemoteBrowserDragItem]) -> [RemoteBrowserDragItem] {
        items.filter { candidate in
            !items.contains { possibleAncestor in
                possibleAncestor.id != candidate.id
                    && possibleAncestor.isFolder
                    && candidate.path.hasPrefix("\(possibleAncestor.path)/")
            }
        }
    }

    private func rollbackOptimisticRemoteMove(_ plan: OptimisticRemoteMovePlan, from destinationParent: String) {
        removeBrowserFileFromCachedListings(at: plan.destinationPath)
        if plan.item.isFolder {
            remapCachedBrowserSubtree(from: plan.destinationPath, to: plan.item.path)
        }
        remapSearchResultSubtree(
            from: plan.destinationPath,
            to: plan.item.path,
            includeRoot: plan.sourceWasInSearchResults
        )
        if plan.sourceWasInSearchResults,
           !searchResults.contains(where: { $0.path == plan.originalFile.path }) {
            searchResults.append(plan.originalFile)
        }
        insertBrowserFileIntoCachedListing(plan.originalFile, parentPath: plan.sourceParent, createTreeListing: true)
        if let replacedDestination = plan.replacedDestination {
            insertBrowserFileIntoCachedListing(replacedDestination, parentPath: destinationParent, createTreeListing: true)
            let existingPaths = Set(searchResults.map(\.path))
            searchResults.append(contentsOf: plan.replacedDestinationSearchResults.filter {
                !existingPaths.contains($0.path)
            })
        }
    }

    private func remapSearchResultSubtree(from sourcePath: String, to destinationPath: String, includeRoot: Bool) {
        guard sourcePath != destinationPath else { return }
        searchResults = searchResults.compactMap { file in
            let isRoot = file.path == sourcePath
            guard (includeRoot && isRoot) || file.path.hasPrefix("\(sourcePath)/") else {
                return file
            }
            let remappedPath = destinationPath + file.path.dropFirst(sourcePath.count)
            return AndroidFile(
                name: (remappedPath as NSString).lastPathComponent,
                path: remappedPath,
                kind: file.kind,
                size: file.size,
                modified: file.modified,
                permissions: file.permissions,
                created: file.created
            )
        }
    }

    private func cachedFolderListing(at path: String) -> [AndroidFile]? {
        let normalizedPath = normalizedFolderCachePath(path)
        if normalizedPath == currentPath {
            return files
        }
        if let children = treeChildrenByPath[normalizedPath] {
            return children
        }
        return adbFolderListingsByPath[normalizedPath]
    }

    private func cachedBrowserFile(at path: String) -> AndroidFile? {
        if let file = files.first(where: { $0.path == path }) {
            return file
        }
        if let file = treeChildrenByPath.values.lazy.flatMap({ $0 }).first(where: { $0.path == path }) {
            return file
        }
        return adbFolderListingsByPath.values.lazy.flatMap({ $0 }).first(where: { $0.path == path })
    }

    private func removeBrowserFileFromCachedListings(at path: String) {
        files.removeAll { $0.path == path }
        for parentPath in Array(treeChildrenByPath.keys) {
            treeChildrenByPath[parentPath]?.removeAll { $0.path == path }
        }
        for parentPath in Array(adbFolderListingsByPath.keys) {
            adbFolderListingsByPath[parentPath]?.removeAll { $0.path == path }
        }
        selectedFileIDs.remove(path)
    }

    private func insertBrowserFileIntoCachedListing(
        _ file: AndroidFile,
        parentPath: String,
        createTreeListing: Bool
    ) {
        let normalizedParent = normalizedFolderCachePath(parentPath)
        func inserting(_ file: AndroidFile, into source: [AndroidFile]) -> [AndroidFile] {
            var updated = source.filter { $0.path != file.path }
            updated.append(file)
            return updated
        }

        if normalizedParent == currentPath {
            files = inserting(file, into: files)
            adbFolderListingsByPath[normalizedParent] = files
        } else if adbFolderListingsByPath[normalizedParent] != nil {
            adbFolderListingsByPath[normalizedParent] = inserting(
                file,
                into: adbFolderListingsByPath[normalizedParent] ?? []
            )
        }

        if treeChildrenByPath[normalizedParent] != nil || createTreeListing {
            treeChildrenByPath[normalizedParent] = inserting(
                file,
                into: treeChildrenByPath[normalizedParent] ?? []
            )
        }
    }

    private func remapCachedBrowserSubtree(from sourcePath: String, to destinationPath: String) {
        guard sourcePath != destinationPath else { return }

        func remappedPath(_ path: String) -> String {
            guard path == sourcePath || path.hasPrefix("\(sourcePath)/") else { return path }
            return destinationPath + path.dropFirst(sourcePath.count)
        }

        func remappedFile(_ file: AndroidFile) -> AndroidFile {
            let path = remappedPath(file.path)
            guard path != file.path else { return file }
            return AndroidFile(
                name: (path as NSString).lastPathComponent,
                path: path,
                kind: file.kind,
                size: file.size,
                modified: file.modified,
                permissions: file.permissions,
                created: file.created
            )
        }

        let treeKeys = treeChildrenByPath.keys.filter {
            $0 == sourcePath || $0.hasPrefix("\(sourcePath)/")
        }
        for oldKey in treeKeys {
            guard let children = treeChildrenByPath.removeValue(forKey: oldKey) else { continue }
            treeChildrenByPath[remappedPath(oldKey)] = children.map(remappedFile)
        }

        let folderCacheKeys = adbFolderListingsByPath.keys.filter {
            $0 == sourcePath || $0.hasPrefix("\(sourcePath)/")
        }
        for oldKey in folderCacheKeys {
            guard let children = adbFolderListingsByPath.removeValue(forKey: oldKey) else { continue }
            adbFolderListingsByPath[remappedPath(oldKey)] = children.map(remappedFile)
        }

        expandedTreePaths = Set(expandedTreePaths.map(remappedPath))

        for oldPath in Array(folderSizeBytesByPath.keys) where oldPath == sourcePath || oldPath.hasPrefix("\(sourcePath)/") {
            folderSizeBytesByPath[remappedPath(oldPath)] = folderSizeBytesByPath.removeValue(forKey: oldPath)
        }
        for oldPath in Array(thumbnailURLs.keys) where oldPath == sourcePath || oldPath.hasPrefix("\(sourcePath)/") {
            thumbnailURLs[remappedPath(oldPath)] = thumbnailURLs.removeValue(forKey: oldPath)
        }
        for oldPath in Array(thumbnailCacheKeysByFileID.keys) where oldPath == sourcePath || oldPath.hasPrefix("\(sourcePath)/") {
            thumbnailCacheKeysByFileID[remappedPath(oldPath)] = thumbnailCacheKeysByFileID.removeValue(forKey: oldPath)
        }
        for oldPath in Array(mediaMetadataByFileID.keys) where oldPath == sourcePath || oldPath.hasPrefix("\(sourcePath)/") {
            mediaMetadataByFileID[remappedPath(oldPath)] = mediaMetadataByFileID.removeValue(forKey: oldPath)
        }
    }

    private func scheduleDelayedTransferPresentation(for jobID: UUID) {
        delayedTransferPresentationTasks[jobID]?.cancel()
        delayedTransferPresentationTasks[jobID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self,
                  let job = self.transferQueue.job(id: jobID),
                  !job.state.isFinished else {
                return
            }
            self.presentedDelayedTransferJobIDs.insert(jobID)
            _ = self.transferQueue.revealDeferredJob(id: jobID)
            self.delayedTransferPresentationTasks[jobID] = nil
        }
    }

    private func finishDelayedTransferPresentation(for jobID: UUID) {
        delayedTransferPresentationTasks.removeValue(forKey: jobID)?.cancel()
        let wasPresented = presentedDelayedTransferJobIDs.remove(jobID) != nil
        guard let job = transferQueue.job(id: jobID) else { return }
        if job.state == .failed {
            _ = transferQueue.revealDeferredJob(id: jobID)
        } else if !wasPresented {
            _ = transferQueue.discardFinishedJob(id: jobID)
        }
    }

    private func finderTypeIdentifier(for file: AndroidFile) -> String {
        if file.kind == .directory {
            return UTType.folder.identifier
        }
        return UTType(filenameExtension: file.fileExtension)?.identifier ?? UTType.data.identifier
    }

    private func exportFileForDrag(_ file: AndroidFile) async throws -> URL {
        let destination = try RemoteFileDragProvider.destinationURL(fileName: file.name)
        return try await exportFile(file, to: destination, subtitle: "Copying for drag export")
    }

    @discardableResult
    private func exportFile(_ file: AndroidFile, to destinationURL: URL, subtitle: String) async throws -> URL {
        guard let device = selectedDevice else { throw FileOperationError.noDevice }

        statusMessage = "Copying \(file.name) to this Mac..."
        let result = try await transferQueue.enqueueAndWait(
            kind: .export,
            title: file.name,
            subtitle: subtitle,
            source: TransferEndpoint(kind: .adb, deviceID: device.serial, path: file.path, displayName: file.path),
            destination: TransferEndpoint(kind: .mac, path: destinationURL.path, displayName: destinationURL.lastPathComponent),
            itemKind: file.kind == .directory ? .folder : .file,
            totalBytes: file.kind == .directory ? folderSizeBytesByPath[file.path] : file.size
        ) { [fileRepository] controller in
            try controller.checkCancellation()
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try controller.checkCancellation()
            let localURL = try await fileRepository.pull(
                device: device,
                remotePath: file.path,
                to: destinationURL.deletingLastPathComponent(),
                localName: destinationURL.lastPathComponent,
                replace: true
            ) { fraction in
                Task { @MainActor in
                    controller.updateProgress(fractionCompleted: fraction)
                }
            }
            try controller.checkCancellation()
            return TransferJobResult(outputURL: localURL, message: "Copied")
        }
        guard let localURL = result?.outputURL else {
            throw FileOperationError.commandFailed("The copy finished without a local file.")
        }
        statusMessage = "Copied \(file.name) to this Mac."
        return localURL
    }

    private func defaultArchiveName(for files: [AndroidFile]? = nil) -> String {
        let source = files ?? selectedFiles
        if source.count == 1, let name = source.first?.name {
            let baseName = (name as NSString).deletingPathExtension
            return baseName.isEmpty ? "Archive.zip" : "\(baseName).zip"
        }
        return "Archive.zip"
    }

    public func deleteSelectedToTrash() async {
        let filesToTrash = selectedFiles
        guard !filesToTrash.isEmpty else { return }
        guard !isPreparingForTermination else {
            statusMessage = "Quit is in progress."
            return
        }
        guard let operationDevice = selectedDevice, operationDevice.state == .device else {
            handleOperationError(FileOperationError.noDevice)
            return
        }
        let storageSummary = selectedStorageSummary
        let storageCategory = selectedStorageCategory
        let storageListsBeforeDeletion = storageCategoryFileLists
        let searchResultPaths = Set(searchResults.map(\.path))
        let sourceParents = Set(filesToTrash.map { ($0.path as NSString).deletingLastPathComponent })

        if storageSummary != nil {
            let deletedPaths = Set(filesToTrash.map(\.path))
            for (id, list) in storageCategoryFileLists {
                let remainingFiles = list.files.filter { !deletedPaths.contains($0.path) }
                if remainingFiles.count != list.files.count {
                    storageCategoryFileLists[id] = StorageCategoryFileList(
                        summaryID: list.summaryID,
                        category: list.category,
                        files: remainingFiles
                    )
                }
            }
        } else {
            beginBrowserMutation(at: sourceParents)
            cancelFolderSizeWorker(clearQueue: true)
            for file in filesToTrash {
                removeBrowserFileFromCachedListings(at: file.path)
                searchResults.removeAll { $0.path == file.path }
            }
        }
        selectedFileIDs.removeAll()

        await perform("Moving to Trash...") {
            guard selectedDevice?.id == operationDevice.id else { throw FileOperationError.noDevice }
            let device = operationDevice
            var createdRecords: [TrashRecord] = []
            var failedFiles: [(file: AndroidFile, error: Error)] = []
            for file in filesToTrash {
                do {
                    let record = try await trashAndRecord(device: device, file: file)
                    createdRecords.append(record)
                    purgeCachedBrowserSubtree(at: file.path)
                } catch {
                    failedFiles.append((file, error))
                    if storageSummary != nil {
                        for (id, originalList) in storageListsBeforeDeletion {
                            guard let originalFile = originalList.files.first(where: { $0.path == file.path }) else { continue }
                            let currentList = storageCategoryFileLists[id] ?? StorageCategoryFileList(
                                summaryID: originalList.summaryID,
                                category: originalList.category,
                                files: []
                            )
                            guard !currentList.files.contains(where: { $0.path == originalFile.path }) else { continue }
                            storageCategoryFileLists[id] = StorageCategoryFileList(
                                summaryID: currentList.summaryID,
                                category: currentList.category,
                                files: currentList.files + [originalFile]
                            )
                        }
                    } else {
                        let parent = (file.path as NSString).deletingLastPathComponent
                        insertBrowserFileIntoCachedListing(file, parentPath: parent, createTreeListing: true)
                        if searchResultPaths.contains(file.path), !searchResults.contains(where: { $0.path == file.path }) {
                            searchResults.append(file)
                        }
                        selectedFileIDs.insert(file.id)
                    }
                }
            }

            if let storageSummary, let storageCategory {
                if let refreshedBreakdown = try? await fileRepository.storageBreakdown(
                    device: device,
                    summary: storageSummary
                ) {
                    storageBreakdowns[storageSummary.id] = refreshedBreakdown
                    if let refreshedCategory = refreshedBreakdown.visibleCategories.first(where: { $0.id == storageCategory.id }) {
                        selectedStorageCategoryID = refreshedCategory.id
                        if refreshedCategory.kind.canBrowseFiles,
                           let refreshedFiles = try? await fileRepository.storageCategoryFiles(
                            device: device,
                            summary: storageSummary,
                            category: refreshedCategory
                           ) {
                            let listID = storageCategoryFileListID(
                                summaryID: storageSummary.id,
                                categoryID: refreshedCategory.id
                            )
                            storageCategoryFileLists[listID] = StorageCategoryFileList(
                                summaryID: storageSummary.id,
                                category: refreshedCategory,
                                files: refreshedFiles
                            )
                        }
                    }
                }
            } else {
                let reconciliationPaths = finishBrowserMutation(at: sourceParents)
                scheduleFolderReconciliation(at: reconciliationPaths, device: device)
            }

            if !createdRecords.isEmpty {
                recordFileHistory(
                    .restoreTrash(deviceSerial: device.serial, records: createdRecords, actionName: "Move to Trash")
                )
            }

            if let failure = failedFiles.first {
                if createdRecords.isEmpty {
                    throw failure.error
                }
                throw FileOperationError.commandFailed(
                    "Moved \(createdRecords.count) item\(createdRecords.count == 1 ? "" : "s") to Trash, but \(failedFiles.count) could not be moved. \(failure.error.localizedDescription)"
                )
            }
            statusMessage = "Moved \(createdRecords.count) item\(createdRecords.count == 1 ? "" : "s") to Trash."
        }
    }

    private func purgeCachedBrowserSubtree(at path: String) {
        func isInsidePurgedSubtree(_ candidate: String) -> Bool {
            candidate == path || candidate.hasPrefix("\(path)/")
        }

        for cachedPath in Array(treeChildrenByPath.keys) where cachedPath == path || cachedPath.hasPrefix("\(path)/") {
            treeChildrenByPath[cachedPath] = nil
        }
        for cachedPath in Array(adbFolderListingsByPath.keys) where cachedPath == path || cachedPath.hasPrefix("\(path)/") {
            adbFolderListingsByPath[cachedPath] = nil
        }
        expandedTreePaths = expandedTreePaths.filter { $0 != path && !$0.hasPrefix("\(path)/") }
        folderSizeBytesByPath = folderSizeBytesByPath.filter { $0.key != path && !$0.key.hasPrefix("\(path)/") }
        loadingFolderSizePaths = loadingFolderSizePaths.filter { $0 != path && !$0.hasPrefix("\(path)/") }
        failedFolderSizePaths = failedFolderSizePaths.filter { $0 != path && !$0.hasPrefix("\(path)/") }
        thumbnailURLs = thumbnailURLs.filter { !isInsidePurgedSubtree($0.key) }
        thumbnailCacheKeysByFileID = thumbnailCacheKeysByFileID.filter { !isInsidePurgedSubtree($0.key) }
        loadingThumbnailIDs = loadingThumbnailIDs.filter { !isInsidePurgedSubtree($0) }
        mediaMetadataByFileID = mediaMetadataByFileID.filter { !isInsidePurgedSubtree($0.key) }
        loadingMediaMetadataFileIDs = loadingMediaMetadataFileIDs.filter { !isInsidePurgedSubtree($0) }
        failedMediaMetadataFileMessages = failedMediaMetadataFileMessages.filter { !isInsidePurgedSubtree($0.key) }
    }

    func trashFile(for record: TrashRecord) -> AndroidFile {
        AndroidFile(
            name: record.name,
            path: record.trashPath,
            kind: record.kind ?? .file,
            size: record.size,
            modified: nil,
            permissions: nil
        )
    }

    func prepareTrashThumbnail(for record: TrashRecord) async {
        guard selectedDevice?.serial == record.deviceSerial else { return }
        await prepareThumbnail(for: trashFile(for: record), purpose: .browser)
    }

    func quickLookTrash(record: TrashRecord) {
        let file = trashFile(for: record)
        let entry = PreviewWindowPresenter.SessionEntry(
            id: record.id.uuidString,
            title: record.name,
            kind: file.isDirectory ? .folder : .file,
            symbol: file.fallbackSymbol,
            details: [
                ("Kind", file.kind.displayName),
                ("Size", file.displaySize),
                ("Deleted", record.deletedAt.formatted(date: .abbreviated, time: .shortened)),
                ("Original Location", record.originalPath)
            ]
        )

        PreviewWindowPresenter.showSession(
            title: "Quick Look",
            entries: [entry],
            selectedID: entry.id,
            loadURL: { [weak self] _ in
                guard let self else { throw FileOperationError.noDevice }
                try self.requireSelectedDevice(for: record)
                return try await self.cachedPreviewURL(for: file, reportsActivity: false)
            },
            releaseURL: { [weak self] url in
                self?.releaseCachedPreviewURL(url)
            },
            onSelect: { _ in }
        )
    }

    func openTrash(record: TrashRecord, with applicationURL: URL? = nil) async {
        let file = trashFile(for: record)
        if file.isDirectory {
            quickLookTrash(record: record)
            return
        }

        await performCancellableRead("Opening \(record.name)...") { [self] in
            try requireSelectedDevice(for: record)
            let localURL = try await cachedPreviewURL(for: file, reportsActivity: false)
            if let applicationURL {
                NSWorkspace.shared.open(
                    [localURL],
                    withApplicationAt: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil
                )
            } else if !NSWorkspace.shared.open(localURL) {
                releaseCachedPreviewURL(localURL)
                throw FileOperationError.commandFailed("No app is available to open \(record.name).")
            }
            statusMessage = "Opened \(record.name)."
            releaseOpenedTrashURLLater(localURL)
        }
    }

    func chooseApplicationAndOpenTrash(record: TrashRecord) {
        guard trashFile(for: record).kind == .file else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let applicationURL = panel.url else { return }
        Task { await openTrash(record: record, with: applicationURL) }
    }

    func showTrashInfo(record: TrashRecord) {
        guard selectedDevice?.serial == record.deviceSerial else {
            alert = UserAlert(
                title: "Connect the Right Phone",
                message: "Select device \(record.deviceSerial) before viewing info for \(record.name)."
            )
            return
        }
        showFileInfo(file: trashFile(for: record))
    }

    func copyTrash(record: TrashRecord) async {
        do {
            try requireSelectedDevice(for: record)
        } catch {
            handleOperationError(error)
            return
        }
        await copyFilesForFinderPaste([trashFile(for: record)])
    }

    func renameTrash(record: TrashRecord, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != record.name else { return }
        guard trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            alert = UserAlert(title: "Choose Another Name", message: "File names cannot contain a slash or be named . or ..")
            return
        }

        await perform("Renaming \(record.name)...") {
            let device = try requireSelectedDevice(for: record)
            guard trashRecords.contains(where: { $0.id == record.id }) else {
                throw FileOperationError.commandFailed("That item is no longer in Trash.")
            }

            let trashDirectory = (record.trashPath as NSString).deletingLastPathComponent
            let safeName = trimmed.replacingOccurrences(of: "/", with: "_")
            let preferredTrashName = "\(Int(record.deletedAt.timeIntervalSince1970))-\(safeName)"
            let availableTrashName = try await fileRepository.availableRemoteName(
                device: device,
                directory: trashDirectory,
                preferredName: preferredTrashName
            )
            let renamedTrashPath = try await fileRepository.rename(
                device: device,
                source: record.trashPath,
                newName: availableTrashName
            )
            let originalDirectory = (record.originalPath as NSString).deletingLastPathComponent
            let updatedRecord = TrashRecord(
                id: record.id,
                deviceSerial: record.deviceSerial,
                originalPath: ADBClient.joinRemote(originalDirectory, trimmed),
                trashPath: renamedTrashPath,
                name: trimmed,
                deletedAt: record.deletedAt,
                size: record.size,
                kind: record.kind
            )
            guard let index = trashRecords.firstIndex(where: { $0.id == record.id }) else {
                throw FileOperationError.commandFailed("That item is no longer in Trash.")
            }
            var updatedRecords = trashRecords
            updatedRecords[index] = updatedRecord
            do {
                try replaceTrashRecords(updatedRecords)
            } catch {
                do {
                    _ = try await fileRepository.rename(
                        device: device,
                        source: renamedTrashPath,
                        newName: (record.trashPath as NSString).lastPathComponent
                    )
                } catch let rollbackError {
                    throw FileOperationError.commandFailed(
                        "\(record.name) is still in Trash at \(renamedTrashPath), but its new name could not be saved on this Mac. \(rollbackError.localizedDescription)"
                    )
                }
                throw error
            }
            statusMessage = "Renamed \(record.name) to \(trimmed)."
        }
    }

    @discardableResult
    private func requireSelectedDevice(for record: TrashRecord) throws -> AndroidDevice {
        guard let device = selectedDevice,
              device.state == .device,
              device.serial == record.deviceSerial else {
            throw FileOperationError.commandFailed("Connect and select device \(record.deviceSerial) to use \(record.name).")
        }
        return device
    }

    private func releaseOpenedTrashURLLater(_ url: URL) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.releaseCachedPreviewURL(url)
        }
    }

    public func restoreTrash(record: TrashRecord, replace: Bool = false) async {
        await perform("Restoring \(record.name)...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            guard device.serial == record.deviceSerial else {
                throw FileOperationError.commandFailed("This Trash item belongs to device \(record.deviceSerial). Select that device before restoring it.")
            }
            try await fileRepository.restore(device: device, record: record, replace: replace)
            do {
                try replaceTrashRecords(trashRecords.filter { $0.id != record.id })
            } catch {
                do {
                    _ = try await fileRepository.move(
                        device: device,
                        source: record.originalPath,
                        to: (record.trashPath as NSString).deletingLastPathComponent,
                        destinationName: (record.trashPath as NSString).lastPathComponent,
                        replace: false
                    )
                } catch let rollbackError {
                    throw FileOperationError.commandFailed(
                        "\(record.name) was restored, but its Trash record could not be updated. It remains at \(record.originalPath). \(rollbackError.localizedDescription)"
                    )
                }
                throw error
            }
            recordFileHistory(
                .trashItems(
                    deviceSerial: device.serial,
                    items: [
                        RemoteClipboardItem(
                            path: record.originalPath,
                            name: record.name,
                            kind: record.kind ?? .file,
                            size: record.size
                        )
                    ],
                    actionName: "Restore"
                )
            )
            statusMessage = "Restored \(record.name)."
        }
    }

    public func permanentlyDeleteTrash(record: TrashRecord) async {
        guard confirmPermanentTrashDeletion(record: record) else { return }
        await perform("Deleting \(record.name) permanently...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            guard device.serial == record.deviceSerial else {
                throw FileOperationError.commandFailed("This Trash item belongs to device \(record.deviceSerial). Select that device before deleting it.")
            }
            try await fileRepository.deletePermanently(device: device, remotePath: record.trashPath)
            try replaceTrashRecords(trashRecords.filter { $0.id != record.id })
            statusMessage = "Deleted \(record.name) permanently."
        }
    }

    public func emptyTrash() async -> TrashEmptyResult {
        let recordsToDelete = trashRecords
        guard !recordsToDelete.isEmpty else {
            return TrashEmptyResult(deletedCount: 0, failures: [])
        }

        beginTrackedOperation()
        statusMessage = "Emptying Trash..."
        defer { endTrackedOperation() }

        var deletedCount = 0
        var failures: [TrashEmptyFailure] = []

        for record in recordsToDelete {
            guard let device = devices.first(where: { $0.serial == record.deviceSerial && $0.state == .device }) else {
                failures.append(
                    TrashEmptyFailure(
                        record: record,
                        message: "Reconnect device \(record.deviceSerial) before deleting this item."
                    )
                )
                continue
            }

            do {
                try await fileRepository.deletePermanently(device: device, remotePath: record.trashPath)
                try replaceTrashRecords(trashRecords.filter { $0.id != record.id })
                deletedCount += 1
            } catch {
                failures.append(TrashEmptyFailure(record: record, message: error.localizedDescription))
            }
        }

        if failures.isEmpty {
            statusMessage = "Trash emptied."
        } else if deletedCount == 0 {
            statusMessage = "Trash could not be emptied."
        } else {
            statusMessage = "Deleted \(deletedCount) item\(deletedCount == 1 ? "" : "s"); \(failures.count) remain in Trash."
        }

        return TrashEmptyResult(deletedCount: deletedCount, failures: failures)
    }

    private func confirmPermanentTrashDeletion(record: TrashRecord) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete \(record.name) permanently?"
        alert.informativeText = "This removes the file from the phone's Trash folder. This cannot be undone."
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func preview(file: AndroidFile? = nil) async {
        guard let file = file ?? selectedFile, file.kind == .file else { return }
        if let presentation = uploadPresentation(for: file),
           presentation.isSynthetic || !presentation.state.isFinished {
            statusMessage = presentation.statusText
            return
        }
        selectedFileIDs = [file.id]
        await performCancellableRead("Preparing preview...") { [self] in
            let url = try await cachedPreviewURL(for: file)
            PreviewWindowPresenter.show(url: url) { [weak self] in
                self?.releaseCachedPreviewURL(url)
            }
            statusMessage = "Previewing \(file.name)."
        }
    }

    private func cachedPreviewURL(for file: AndroidFile, reportsActivity: Bool = true) async throws -> URL {
        guard let device = selectedDevice else { throw FileOperationError.noDevice }
        if reportsActivity {
            statusMessage = "Preparing preview for \(file.name)..."
        }
        let cacheDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "AndroidFileBrowserPreviews", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cacheKey = "\(device.serial)|\(file.path)|\(file.size ?? 0)|\(file.modified?.timeIntervalSince1970 ?? 0)"
        let cacheName = await thumbnailService.sourceCacheFileName(cacheKey: cacheKey, originalName: file.name)
        let cacheURL = cacheDirectory.appending(path: cacheName)
        if let cachedURL = try await cacheStore.readablePreviewURL(
            for: cacheURL,
            encrypt: settings.encryptPreviewCache
        ) {
            if reportsActivity {
                previewURL = cachedURL
                statusMessage = "Previewing \(file.name)."
            }
            return cachedURL
        }

        let stagingDirectory = try await cacheStore.makePreviewStagingDirectory()
        let downloadedURL = try await fileRepository.pull(
            device: device,
            remotePath: file.path,
            to: stagingDirectory,
            replace: true
        ) { fraction in
            guard reportsActivity else { return }
            Task { @MainActor in
                self.statusMessage = "Preparing preview for \(file.name) \(Int(fraction * 100))%..."
            }
        }
        try await cacheStore.storePreview(
            from: downloadedURL,
            at: cacheURL,
            encrypt: settings.encryptPreviewCache
        )
        guard let url = try await cacheStore.readablePreviewURL(
            for: cacheURL,
            encrypt: settings.encryptPreviewCache
        ) else {
            throw FileOperationError.commandFailed("The preview cache could not be prepared.")
        }
        if reportsActivity {
            previewURL = url
            statusMessage = "Previewing \(file.name)."
        }
        scheduleCacheMaintenance()
        return url
    }

    public func openPreviewLocally() {
        guard let previewURL else { return }
        NSWorkspace.shared.open(previewURL)
        statusMessage = "Opened \(previewURL.lastPathComponent) on this Mac."
    }

    public func prepareMediaMetadata(for file: AndroidFile) async {
        guard file.kind == .file,
              file.mediaKind != nil,
              mediaMetadataByFileID[file.id] == nil,
              !loadingMediaMetadataFileIDs.contains(file.id) else {
            return
        }

        loadingMediaMetadataFileIDs.insert(file.id)
        failedMediaMetadataFileMessages[file.id] = nil
        defer { loadingMediaMetadataFileIDs.remove(file.id) }

        do {
            let localURL = try await cachedPreviewURL(for: file, reportsActivity: false)
            let metadata = await MediaMetadataService.readMetadata(for: localURL, originalName: file.name)
            await cacheStore.releaseReadablePreview(localURL)
            if let metadata {
                mediaMetadataByFileID[file.id] = metadata
            } else {
                failedMediaMetadataFileMessages[file.id] = "No readable media metadata was found."
            }
        } catch {
            failedMediaMetadataFileMessages[file.id] = error.localizedDescription
        }
    }

    public func showFileInfo(file: AndroidFile) {
        FileInfoWindowPresenter.show(model: self, file: file)
    }

    public func prepareThumbnail(for file: AndroidFile, purpose: MediaThumbnailPurpose = .browser) async {
        let maxBytes = Int64(settings.thumbnailMaxFileSizeMB) * 1024 * 1024
        guard !isPreparingForTermination,
              shouldPrepareThumbnail(for: purpose),
              uploadPresentation(for: file)?.isSynthetic != true,
              file.kind == .file,
              file.mediaKind != nil,
              (file.size ?? 0) <= maxBytes,
              let device = selectedDevice,
              device.state == .device else {
            return
        }

        let cacheKey = thumbnailCacheKey(for: file, deviceSerial: device.serial)
        requestedThumbnailCacheKeysByFileID[file.id] = cacheKey
        if thumbnailCacheKeysByFileID[file.id] == cacheKey,
           let thumbnailURL = thumbnailURLs[file.id] {
            if FileManager.default.fileExists(atPath: thumbnailURL.path) {
                return
            }
            thumbnailURLs[file.id] = nil
            thumbnailCacheKeysByFileID[file.id] = nil
        }

        if thumbnailCacheKeysByFileID[file.id] != cacheKey {
            thumbnailURLs[file.id] = nil
            thumbnailCacheKeysByFileID[file.id] = nil
        }

        if let cachedURL = await thumbnailService.cachedThumbnailURL(cacheKey: cacheKey) {
            applyThumbnailURLIfCurrent(
                cachedURL,
                file: file,
                purpose: purpose,
                device: device,
                cacheKey: cacheKey
            )
            return
        }

        if let migratedURL = await thumbnailService.migrateLegacyThumbnailIfAvailable(
            legacyCacheKey: "\(device.serial)-\(file.path)",
            cacheKey: cacheKey,
            sourceModified: file.modified
        ) {
            applyThumbnailURLIfCurrent(
                migratedURL,
                file: file,
                purpose: purpose,
                device: device,
                cacheKey: cacheKey
            )
            return
        }

        let priority: ADBThumbnailRequestScheduler.Priority = purpose == .detail ? .detail : .browser
        let permit: ADBThumbnailRequestScheduler.Permit
        do {
            permit = try await thumbnailRequestScheduler.acquire(priority: priority)
        } catch {
            return
        }

        await prepareUncachedThumbnail(
            for: file,
            purpose: purpose,
            device: device,
            cacheKey: cacheKey
        )
        await thumbnailRequestScheduler.release(permit)
    }

    private func prepareUncachedThumbnail(
        for file: AndroidFile,
        purpose: MediaThumbnailPurpose,
        device: AndroidDevice,
        cacheKey: String
    ) async {
        guard isCurrentThumbnailRequest(
            file: file,
            purpose: purpose,
            device: device,
            cacheKey: cacheKey
        ), !loadingThumbnailIDs.contains(file.id) else {
            return
        }

        // Another queued request may have filled the disk cache while this one
        // was waiting for the single ADB thumbnail lane.
        if let cachedURL = await thumbnailService.cachedThumbnailURL(cacheKey: cacheKey) {
            applyThumbnailURLIfCurrent(
                cachedURL,
                file: file,
                purpose: purpose,
                device: device,
                cacheKey: cacheKey
            )
            return
        }

        guard isCurrentThumbnailRequest(
            file: file,
            purpose: purpose,
            device: device,
            cacheKey: cacheKey
        ) else {
            return
        }

        loadingThumbnailIDs.insert(file.id)
        defer { loadingThumbnailIDs.remove(file.id) }

        do {
            let sourceName = await thumbnailService.sourceCacheFileName(cacheKey: cacheKey, originalName: file.name)
            try Task.checkCancellation()
            let localURL = try await fileRepository.pullToCache(
                device: device,
                remotePath: file.path,
                localName: sourceName
            )
            defer { try? FileManager.default.removeItem(at: localURL) }
            try Task.checkCancellation()
            let thumbnailURL = try await thumbnailService.generateThumbnail(localURL: localURL, cacheKey: cacheKey)
            if applyThumbnailURLIfCurrent(
                thumbnailURL,
                file: file,
                purpose: purpose,
                device: device,
                cacheKey: cacheKey
            ) {
                scheduleCacheMaintenance()
            }
        } catch {
            // Thumbnail generation is opportunistic; failing here should not interrupt browsing.
        }
    }

    @discardableResult
    private func applyThumbnailURLIfCurrent(
        _ thumbnailURL: URL,
        file: AndroidFile,
        purpose: MediaThumbnailPurpose,
        device: AndroidDevice,
        cacheKey: String
    ) -> Bool {
        guard isCurrentThumbnailRequest(
            file: file,
            purpose: purpose,
            device: device,
            cacheKey: cacheKey
        ) else {
            return false
        }
        thumbnailURLs[file.id] = thumbnailURL
        thumbnailCacheKeysByFileID[file.id] = cacheKey
        return true
    }

    private func isCurrentThumbnailRequest(
        file: AndroidFile,
        purpose: MediaThumbnailPurpose,
        device: AndroidDevice,
        cacheKey: String
    ) -> Bool {
        let maxBytes = Int64(settings.thumbnailMaxFileSizeMB) * 1024 * 1024
        return !Task.isCancelled
            && !isPreparingForTermination
            && selectedDevice?.id == device.id
            && selectedDevice?.state == .device
            && requestedThumbnailCacheKeysByFileID[file.id] == cacheKey
            && shouldPrepareThumbnail(for: purpose)
            && uploadPresentation(for: file)?.isSynthetic != true
            && (file.size ?? 0) <= maxBytes
    }

    private func thumbnailCacheKey(for file: AndroidFile, deviceSerial: String) -> String {
        let size = file.size.map(String.init) ?? "unknown-size"
        let modified = file.modified
            .map { String(Int64($0.timeIntervalSince1970 * 1_000)) }
            ?? "unknown-date"
        return "\(deviceSerial)|\(file.path)|\(size)|\(modified)"
    }

    private func shouldPrepareThumbnail(for purpose: MediaThumbnailPurpose) -> Bool {
        switch purpose {
        case .browser:
            settings.loadMediaThumbnails
        case .detail:
            settings.showDetailMediaPreviews
        }
    }

    public func requestNewFolder(in folder: AndroidFile? = nil) {
        pendingNewFolderParentPath = folder?.isDirectory == true ? folder?.path : currentPath
        if let folder, folder.isDirectory {
            expandedTreePaths.insert(folder.path)
            if treeChildrenByPath[folder.path] == nil {
                startTreeChildrenLoad(for: folder)
            }
        }
        pendingNewFolder = true
    }

    public func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validationMessage = RemoteFileNameValidator.validationMessage(for: trimmed) {
            alert = UserAlert(title: "That Name Can't Be Used", message: validationMessage)
            return
        }
        let requestedParent = pendingNewFolderParentPath ?? currentPath
        pendingNewFolderParentPath = nil
        await perform("Creating folder...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            let parent = requestedParent
            let folder = FileHistoryFolder(parent: parent, name: trimmed)
            let cachedSiblings = cachedFolderListing(at: parent) ?? []
            let hasCachedDuplicate = cachedSiblings.contains(where: {
                $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            })
            if hasCachedDuplicate {
                throw FileOperationError.duplicateExists(folder.path)
            }
            let newFolder = AndroidFile(
                name: trimmed,
                path: folder.path,
                kind: .directory,
                size: nil,
                modified: Date(),
                permissions: nil,
                created: Date()
            )
            cancelTreeLoad(for: parent)
            insertCreatedFolder(newFolder, in: parent)
            do {
                try await fileRepository.createFolder(device: device, parent: parent, name: trimmed)
            } catch {
                removeProvisionalFolder(newFolder, from: parent)
                throw error
            }
            recordFileHistory(
                .deletePaths(
                    deviceSerial: device.serial,
                    paths: [folder.path],
                    redo: .createFolders(deviceSerial: device.serial, folders: [folder], actionName: "New Folder"),
                    actionName: "New Folder"
                )
            )
            statusMessage = "Created \(trimmed)."
            await refreshFolderContentsPreservingNavigation(at: parent, device: device)
        }
    }

    private func insertCreatedFolder(_ folder: AndroidFile, in parentPath: String) {
        if parentPath == currentPath {
            files.removeAll { $0.path == folder.path }
            files.append(folder)
        } else {
            expandedTreePaths.insert(parentPath)
            var children = treeChildrenByPath[parentPath] ?? []
            children.removeAll { $0.path == folder.path }
            children.append(folder)
            treeChildrenByPath[parentPath] = children
        }
        selectedFileIDs = [folder.id]
        lastSelectedFileID = folder.id
        keyboardSelectionAnchorFileID = folder.id
    }

    private func removeProvisionalFolder(_ folder: AndroidFile, from parentPath: String) {
        if parentPath == currentPath {
            files.removeAll { $0.path == folder.path }
        }
        treeChildrenByPath[parentPath]?.removeAll { $0.path == folder.path }
        if selectedFileIDs.contains(folder.id) {
            selectedFileIDs.remove(folder.id)
            if lastSelectedFileID == folder.id { lastSelectedFileID = nil }
            if keyboardSelectionAnchorFileID == folder.id { keyboardSelectionAnchorFileID = nil }
        }
    }

    private func refreshFolderContentsPreservingNavigation(at path: String, device: AndroidDevice) async {
        let normalizedPath = normalizedFolderCachePath(path)
        let mutationRevision = browserMutationRevision(for: normalizedPath)
        guard !hasActiveBrowserMutation(at: normalizedPath) else { return }
        let showsTreeRefresh = expandedTreePaths.contains(normalizedPath)
            && treeLoadTasks[normalizedPath] == nil
            && !loadingTreePaths.contains(normalizedPath)
        if showsTreeRefresh {
            loadingTreePaths.insert(normalizedPath)
        }
        defer {
            if showsTreeRefresh {
                loadingTreePaths.remove(normalizedPath)
            }
        }

        do {
            let refreshed = try await fileRepository.listFiles(device: device, path: normalizedPath)
            try Task.checkCancellation()
            guard selectedDevice?.id == device.id,
                  browserMutationRevision(for: normalizedPath) == mutationRevision,
                  !hasActiveBrowserMutation(at: normalizedPath) else { return }
            adbFolderListingsByPath[normalizedPath] = refreshed
            if normalizedPath == currentPath {
                files = refreshed
            }
            if expandedTreePaths.contains(normalizedPath) {
                treeChildrenByPath[normalizedPath] = refreshed
            }
            selectedFileIDs = selectedFileIDs.intersection(Set(visibleFilesIncludingExpandedChildren.map(\.id)))
            scheduleFolderSizeCalculations(for: visibleFilesIncludingExpandedChildren)
        } catch {
            // The optimistic folder remains visible. A later refresh can reconcile metadata.
        }
    }

    private func scheduleFolderReconciliation(at paths: Set<String>, device: AndroidDevice) {
        pendingBrowserReconciliationPaths.formUnion(paths.map(normalizedFolderCachePath))
        let normalizedPaths = pendingBrowserReconciliationPaths
            .filter { !hasActiveBrowserMutation(at: $0) }
            .sorted()
        guard !normalizedPaths.isEmpty else { return }

        let requestID = UUID()
        browserReconciliationTask?.cancel()
        browserReconciliationRequestID = requestID
        browserReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.browserReconciliationRequestID == requestID {
                    self.browserReconciliationTask = nil
                    self.browserReconciliationRequestID = nil
                }
            }
            for path in normalizedPaths {
                guard !Task.isCancelled,
                      self.browserReconciliationRequestID == requestID,
                      self.selectedDevice?.id == device.id,
                      !self.hasActiveBrowserMutation(at: path) else {
                    return
                }
                await self.refreshFolderContentsPreservingNavigation(at: path, device: device)
                guard !Task.isCancelled,
                      self.browserReconciliationRequestID == requestID,
                      !self.hasActiveBrowserMutation(at: path) else { return }
                self.pendingBrowserReconciliationPaths.remove(path)
            }
        }
    }

    private func browserMutationRevision(for path: String) -> Int {
        browserMutationRevisionsByPath[normalizedFolderCachePath(path)] ?? 0
    }

    private func hasActiveBrowserMutation(at path: String) -> Bool {
        (activeBrowserMutationCountsByPath[normalizedFolderCachePath(path)] ?? 0) > 0
    }

    private func beginBrowserMutation(at paths: Set<String>) {
        browserReconciliationTask?.cancel()
        browserReconciliationTask = nil
        browserReconciliationRequestID = nil

        let normalizedPaths = Set(paths.map(normalizedFolderCachePath))
        for path in normalizedPaths {
            browserMutationRevisionsByPath[path, default: 0] &+= 1
            activeBrowserMutationCountsByPath[path, default: 0] &+= 1
            cancelTreeLoad(for: path)
        }

        if normalizedPaths.contains(currentPath) {
            adbNavigationRevision &+= 1
            adbNavigationTask?.cancel()
            adbNavigationTask = nil
            isLoadingCurrentFolder = false
        }
    }

    @discardableResult
    private func finishBrowserMutation(at paths: Set<String>) -> Set<String> {
        var pathsReadyToReconcile = Set<String>()
        for path in Set(paths.map(normalizedFolderCachePath)) {
            browserMutationRevisionsByPath[path, default: 0] &+= 1
            let remainingCount = max((activeBrowserMutationCountsByPath[path] ?? 1) - 1, 0)
            if remainingCount == 0 {
                activeBrowserMutationCountsByPath[path] = nil
                pathsReadyToReconcile.insert(path)
            } else {
                activeBrowserMutationCountsByPath[path] = remainingCount
            }
        }
        return pathsReadyToReconcile
    }

    public func rename(file: AndroidFile, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validationMessage = RemoteFileNameValidator.validationMessage(for: trimmed) {
            alert = UserAlert(title: "That Name Can't Be Used", message: validationMessage)
            return
        }
        guard trimmed != file.name else { return }
        await perform("Renaming \(file.name)...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            let parent = (file.path as NSString).deletingLastPathComponent
            let destinationPath = ADBClient.joinRemote(parent, trimmed)
            let cachedSiblings = cachedFolderListing(at: parent) ?? []
            let hasCachedDuplicate = cachedSiblings.contains(where: {
                $0.path != file.path && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            })
            if hasCachedDuplicate {
                throw FileOperationError.duplicateExists(destinationPath)
            }

            let renamedFile = AndroidFile(
                name: trimmed,
                path: destinationPath,
                kind: file.kind,
                size: file.size,
                modified: file.modified,
                permissions: file.permissions,
                created: file.created
            )
            let sourceWasInSearchResults = searchResults.contains { $0.path == file.path }
            beginBrowserMutation(at: [parent])
            removeBrowserFileFromCachedListings(at: file.path)
            if file.isDirectory {
                remapCachedBrowserSubtree(from: file.path, to: destinationPath)
            }
            remapSearchResultSubtree(
                from: file.path,
                to: destinationPath,
                includeRoot: sourceWasInSearchResults
            )
            insertBrowserFileIntoCachedListing(renamedFile, parentPath: parent, createTreeListing: true)
            selectedFileIDs = [destinationPath]
            lastSelectedFileID = destinationPath
            keyboardSelectionAnchorFileID = destinationPath

            do {
                _ = try await fileRepository.rename(device: device, source: file.path, newName: trimmed)
            } catch {
                removeBrowserFileFromCachedListings(at: destinationPath)
                if file.isDirectory {
                    remapCachedBrowserSubtree(from: destinationPath, to: file.path)
                }
                remapSearchResultSubtree(
                    from: destinationPath,
                    to: file.path,
                    includeRoot: sourceWasInSearchResults
                )
                insertBrowserFileIntoCachedListing(file, parentPath: parent, createTreeListing: true)
                if selectedFileIDs == [destinationPath] {
                    selectedFileIDs = [file.id]
                    lastSelectedFileID = file.id
                    keyboardSelectionAnchorFileID = file.id
                }
                let reconciliationPaths = finishBrowserMutation(at: [parent])
                scheduleFolderReconciliation(at: reconciliationPaths, device: device)
                throw error
            }

            let reconciliationPaths = finishBrowserMutation(at: [parent])
            scheduleFolderReconciliation(at: reconciliationPaths, device: device)
            recordFileHistory(
                .rename(
                    deviceSerial: device.serial,
                    steps: [FileHistoryRenameStep(sourcePath: destinationPath, destinationName: file.name)],
                    actionName: "Rename"
                )
            )
            statusMessage = "Renamed \(file.name) to \(trimmed)."
        }
    }

    public func requestBatchRenameSelected() {
        let selected = selectedFiles
        guard selected.count > 1 else { return }
        let siblingNames = Set(files.map { $0.name.lowercased() })
        pendingBatchRenameRequest = BatchRenameRequest(files: selected, siblingNames: siblingNames)
    }

    func batchRenamePreviews(for request: BatchRenameRequest, options: BatchRenameOptions) -> [BatchRenamePreview] {
        BatchRenamePlanner.previews(for: request.files, options: options, siblingNames: request.siblingNames)
    }

    func applyBatchRename(request: BatchRenameRequest, options: BatchRenameOptions) async {
        let previews = batchRenamePreviews(for: request, options: options)
        guard !previews.isEmpty, previews.allSatisfy({ !$0.collision }) else {
            alert = UserAlert(
                title: "Rename Conflicts",
                message: "Fix empty names or duplicate names before applying this batch rename."
            )
            return
        }

        pendingBatchRenameRequest = nil
        await perform("Renaming \(previews.count) item\(previews.count == 1 ? "" : "s")...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            var undoSteps: [FileHistoryRenameStep] = []
            for preview in previews where preview.originalName != preview.proposedName {
                let destinationPath = try await fileRepository.rename(device: device, source: preview.originalPath, newName: preview.proposedName)
                undoSteps.append(FileHistoryRenameStep(sourcePath: destinationPath, destinationName: preview.originalName))
            }
            try await refreshFilesThrowing()
            if !undoSteps.isEmpty {
                recordFileHistory(
                    .rename(deviceSerial: device.serial, steps: undoSteps.reversed(), actionName: "Batch Rename")
                )
            }
            statusMessage = "Renamed \(previews.count) item\(previews.count == 1 ? "" : "s")."
        }
    }

    public func copySelected() {
        remoteClipboard = makeRemoteClipboard(mode: .copy)
        let itemsForFinder = selectedFiles.filter(canExportToFinder)
        if !itemsForFinder.isEmpty {
            Task { @MainActor [weak self, itemsForFinder] in
                await self?.copyFilesForFinderPaste(itemsForFinder)
            }
        }

        if itemsForFinder.isEmpty {
            statusMessage = "Copied \(selectedFiles.count) item\(selectedFiles.count == 1 ? "" : "s") for in-app paste."
        } else {
            statusMessage = "Preparing \(itemsForFinder.count) item\(itemsForFinder.count == 1 ? "" : "s") for Finder paste and copied \(selectedFiles.count) item\(selectedFiles.count == 1 ? "" : "s") for in-app paste."
        }
    }

    private func copyFilesForFinderPaste(_ files: [AndroidFile]) async {
        do {
            var localURLs: [URL] = []
            for file in files {
                let destination = try RemoteFileDragProvider.destinationURL(fileName: file.name)
                let localURL = try await exportFile(file, to: destination, subtitle: "Copying for Finder paste")
                localURLs.append(localURL)
            }

            guard RemoteFileDragProvider.writeFileURLsToPasteboard(localURLs) else {
                throw FileOperationError.commandFailed("Could not place copied files on the pasteboard.")
            }
            statusMessage = "Copied \(localURLs.count) item\(localURLs.count == 1 ? "" : "s") for Finder paste."
        } catch {
            alert = UserAlert(error: error)
            statusMessage = "Copy for Finder paste failed."
        }
    }

    public func cutSelected() {
        remoteClipboard = makeRemoteClipboard(mode: .cut)
        statusMessage = "Cut \(selectedFiles.count) remote path\(selectedFiles.count == 1 ? "" : "s")."
    }

    public func pasteClipboardItems(into destinationPath: String? = nil) async {
        guard let remoteClipboard, !remoteClipboard.items.isEmpty else { return }
        let pasteDestination = destinationPath ?? currentPath
        await perform("Pasting remote item\(remoteClipboard.items.count == 1 ? "" : "s")...") {
            guard let targetDevice = selectedDevice else { throw FileOperationError.noDevice }
            guard let sourceSerial = remoteClipboard.sourceDeviceSerial else { throw FileOperationError.noDevice }

            if sourceSerial == targetDevice.serial {
                try await enqueueSameDevicePaste(
                    clipboard: remoteClipboard,
                    device: targetDevice,
                    destination: pasteDestination
                )
            } else {
                try await runCrossDevicePaste(
                    clipboard: remoteClipboard,
                    sourceSerial: sourceSerial,
                    targetDevice: targetDevice,
                    destination: pasteDestination
                )
            }

            if remoteClipboard.mode == .cut {
                self.remoteClipboard = nil
            }
        }
    }

    public func pasteFromPasteboardOrClipboard(into folder: AndroidFile? = nil) async {
        let localURLs = Self.localFileURLsFromPasteboard()
        if !localURLs.isEmpty {
            if isUSBTransferSelected {
                _ = usbTransferManager.acceptLocalFileDrop(localURLs)
            } else if let folder, folder.isDirectory {
                await upload(urls: localURLs, into: folder)
            } else {
                await upload(urls: localURLs)
            }
            return
        }

        guard remoteClipboard?.items.isEmpty == false else {
            statusMessage = "Nothing to paste."
            return
        }
        await pasteClipboardItems(into: folder?.path)
    }

    public func copySelectedRemotePathsToPasteboard() {
        let text = selectedFiles.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied remote path\(selectedFiles.count == 1 ? "" : "s") to pasteboard."
    }

    private func makeRemoteClipboard(mode: RemoteClipboardMode) -> RemoteClipboard? {
        guard let sourceDeviceSerial = selectedDevice?.serial else { return nil }
        let items = selectedFiles.map {
            RemoteClipboardItem(path: $0.path, name: $0.name, kind: $0.kind, size: $0.size)
        }
        return RemoteClipboard(mode: mode, sourceDeviceSerial: sourceDeviceSerial, items: items)
    }

    private func enqueueSameDevicePaste(
        clipboard: RemoteClipboard,
        device: AndroidDevice,
        destination pasteDestination: String
    ) async throws {
        let duplicateNames = try await duplicateNames(for: clipboard.items, device: device, destination: pasteDestination)
        let resolution = duplicateNames.isEmpty
            ? nil
            : promptDuplicateResolution(itemNames: duplicateNames, destination: pasteDestination)

        if !duplicateNames.isEmpty, resolution == nil {
            statusMessage = "Paste canceled."
            return
        }

        var queuedCount = 0
        var historyOperations: [FileHistoryOperation] = []
        for item in clipboard.items {
            var destinationName = item.name
            var shouldReplace = false
            if duplicateNames.contains(item.name), let resolution {
                switch resolution {
                case .skip:
                    continue
                case .replace:
                    shouldReplace = true
                case .keep:
                    destinationName = try await fileRepository.availableRemoteName(
                        device: device,
                        directory: pasteDestination,
                        preferredName: item.name
                    )
                }
            }

            let queuedDestinationName = destinationName
            let queuedShouldReplace = shouldReplace
            let destinationPath = ADBClient.joinRemote(pasteDestination, queuedDestinationName)
            let jobID = transferQueue.enqueue(
                kind: .paste,
                title: item.name,
                subtitle: clipboard.mode == .copy ? "Copying in \(pasteDestination)" : "Moving to \(pasteDestination)",
                source: TransferEndpoint(kind: .adb, deviceID: device.serial, path: item.path, displayName: item.path),
                destination: TransferEndpoint(kind: .adb, deviceID: device.serial, path: destinationPath, displayName: queuedDestinationName),
                totalBytes: item.size
            ) { [fileRepository, weak self] controller in
                controller.updateProgress(fractionCompleted: 0.1)
                try controller.checkCancellation()
                switch clipboard.mode {
                case .copy:
                    _ = try await fileRepository.copy(
                        device: device,
                        source: item.path,
                        to: pasteDestination,
                        destinationName: queuedDestinationName,
                        replace: queuedShouldReplace
                    )
                case .cut:
                    do {
                        _ = try await fileRepository.move(
                            device: device,
                            source: item.path,
                            to: pasteDestination,
                            destinationName: queuedDestinationName,
                            replace: queuedShouldReplace
                        )
                    } catch FileOperationError.moveCompletedWithRecoveryCopy(
                        _,
                        let recoveryPath,
                        let reason
                    ) {
                        self?.alert = UserAlert(
                            title: "Move Finished with a Recovery Copy",
                            message: "The replaced item is safe at \(recoveryPath). \(reason)"
                        )
                    }
                }
                try controller.checkCancellation()
                controller.updateProgress(fractionCompleted: 1)
                try? await self?.refreshFilesThrowing()
                return TransferJobResult(message: "Pasted")
            }

            switch clipboard.mode {
            case .copy:
                let redo = FileHistoryOperation.copyItems(
                    deviceSerial: device.serial,
                    items: [item],
                    destination: pasteDestination,
                    destinationNames: [queuedDestinationName],
                    actionName: "Paste"
                )
                historyOperations.append(
                    .queuedTransfer(
                        jobID: jobID,
                        completedUndo: .deletePaths(
                            deviceSerial: device.serial,
                            paths: [destinationPath],
                            redo: redo,
                            actionName: "Paste"
                        ),
                        redo: redo,
                        actionName: "Paste"
                    )
                )
            case .cut:
                let redo = FileHistoryOperation.moveItems(
                    deviceSerial: device.serial,
                    steps: [
                        FileHistoryMoveStep(
                            sourcePath: item.path,
                            destinationDirectory: pasteDestination,
                            destinationName: queuedDestinationName,
                            replace: queuedShouldReplace
                        )
                    ],
                    actionName: "Move"
                )
                let completedUndo = FileHistoryOperation.moveItems(
                    deviceSerial: device.serial,
                    steps: [
                        FileHistoryMoveStep(
                            sourcePath: destinationPath,
                            destinationDirectory: (item.path as NSString).deletingLastPathComponent,
                            destinationName: item.name,
                            replace: false
                        )
                    ],
                    actionName: "Move"
                )
                historyOperations.append(
                    .queuedTransfer(jobID: jobID, completedUndo: completedUndo, redo: redo, actionName: "Move")
                )
            }
            queuedCount += 1
        }

        if historyOperations.count == 1, let operation = historyOperations.first {
            recordFileHistory(operation)
        } else if !historyOperations.isEmpty {
            recordFileHistory(
                .group(
                    operations: historyOperations,
                    actionName: clipboard.mode == .copy ? "Paste" : "Move"
                )
            )
        }
        transferQueue.isPanelExpanded = true
        statusMessage = queuedCount == 0 ? "Paste skipped." : "Queued \(queuedCount) paste operation\(queuedCount == 1 ? "" : "s")."
    }

    private func runCrossDevicePaste(
        clipboard: RemoteClipboard,
        sourceSerial: String,
        targetDevice: AndroidDevice,
        destination pasteDestination: String
    ) async throws {
        guard let sourceDevice = devices.first(where: { $0.serial == sourceSerial }) else {
            alert = UserAlert(
                title: "Source Device Not Connected",
                message: "Reconnect the source Android device before pasting these cut or copied items."
            )
            statusMessage = "Source device not connected."
            return
        }

        let duplicateNames = try await duplicateNames(for: clipboard.items, device: targetDevice, destination: pasteDestination)
        let resolution = duplicateNames.isEmpty
            ? nil
            : promptDuplicateResolution(itemNames: duplicateNames, destination: pasteDestination)
        if !duplicateNames.isEmpty, resolution == nil {
            statusMessage = "Paste canceled."
            return
        }

        let stagingRoot = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "AndroidFileBrowserCrossDevicePaste", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var succeededItems: [RemoteClipboardItem] = []
        var pastedCount = 0
        for item in clipboard.items {
            var remoteName = item.name
            var shouldReplace = false
            if duplicateNames.contains(item.name), let resolution {
                switch resolution {
                case .skip:
                    continue
                case .replace:
                    shouldReplace = true
                case .keep:
                    remoteName = try await fileRepository.availableRemoteName(
                        device: targetDevice,
                        directory: pasteDestination,
                        preferredName: item.name
                    )
                }
            }

            let queuedRemoteName = remoteName
            let queuedShouldReplace = shouldReplace
            let result = try await transferQueue.enqueueAndWait(
                kind: .paste,
                title: item.name,
                subtitle: "Copying between devices",
                source: TransferEndpoint(kind: .adb, deviceID: sourceDevice.serial, path: item.path, displayName: item.path),
                destination: TransferEndpoint(kind: .adb, deviceID: targetDevice.serial, path: ADBClient.joinRemote(pasteDestination, queuedRemoteName), displayName: queuedRemoteName),
                totalBytes: item.size
            ) { [fileRepository] controller in
                try controller.checkCancellation()
                let localURL = try await fileRepository.pull(
                    device: sourceDevice,
                    remotePath: item.path,
                    to: stagingRoot,
                    replace: true
                ) { fraction in
                    Task { @MainActor in
                        controller.updateProgress(fractionCompleted: fraction * 0.5, message: "Copying from source")
                    }
                }
                try controller.checkCancellation()
                _ = try await fileRepository.push(
                    device: targetDevice,
                    localURL: localURL,
                    to: pasteDestination,
                    remoteName: queuedRemoteName,
                    replace: queuedShouldReplace
                ) { fraction in
                    Task { @MainActor in
                        controller.updateProgress(fractionCompleted: 0.5 + fraction * 0.5, message: "Copying to target")
                    }
                }
                try controller.checkCancellation()
                return TransferJobResult(message: "Pasted")
            }

            if result != nil {
                succeededItems.append(item)
                pastedCount += 1
            }
        }

        try? await refreshFilesThrowing()
        if clipboard.mode == .cut, !succeededItems.isEmpty, confirmCrossDeviceCutDelete(count: succeededItems.count) {
            for item in succeededItems {
                let file = AndroidFile(name: item.name, path: item.path, kind: item.kind, size: item.size, modified: nil, permissions: nil)
                _ = try await trashAndRecord(device: sourceDevice, file: file)
            }
            statusMessage = "Pasted \(pastedCount) item\(pastedCount == 1 ? "" : "s") and moved originals to Trash."
        } else {
            statusMessage = pastedCount == 0 ? "Paste skipped." : "Pasted \(pastedCount) item\(pastedCount == 1 ? "" : "s") between devices."
        }
    }

    private func duplicateNames(for items: [RemoteClipboardItem], device: AndroidDevice, destination: String) async throws -> [String] {
        var duplicates: [String] = []
        for item in items where try await fileRepository.fileExists(device: device, path: ADBClient.joinRemote(destination, item.name)) {
            duplicates.append(item.name)
        }
        return duplicates
    }

    public func copyPathToPasteboard(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        statusMessage = "Copied \(path)."
    }

    private static func localFileURLsFromPasteboard() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { object in
            if let url = object as? URL, url.isFileURL {
                return url
            }
            if let nsURL = object as? NSURL {
                let url = nsURL as URL
                return url.isFileURL ? url : nil
            }
            return nil
        }
    }

    public func loadPackages() async {
        let message = packages.isEmpty ? "Loading apps..." : "Refreshing apps..."
        await performCancellableRead(message) { [self] in
            try await loadPackagesThrowing()
            statusMessage = "Loaded \(packages.count) app\(packages.count == 1 ? "" : "s")."
        }
    }

    public func loadSelectedPackageDetails() async {
        guard settings.autoLoadAppDetails else { return }
        guard let package = selectedPackage else { return }
        await loadPackageDetails(package: package)
    }

    public func selectPackage(_ package: AndroidPackage, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        selectedFileIDs.removeAll()
        selectedAppStorageLocation = nil
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        let visibleIDs = filteredPackages.map(\.id)

        if shift,
           let anchor = lastSelectedPackageID,
           let anchorIndex = visibleIDs.firstIndex(of: anchor),
           let selectedIndex = visibleIDs.firstIndex(of: package.id) {
            let range = anchorIndex <= selectedIndex ? anchorIndex...selectedIndex : selectedIndex...anchorIndex
            let rangeIDs = Set(range.map { visibleIDs[$0] })
            if command {
                selectedPackageIDs.formUnion(rangeIDs)
            } else {
                selectedPackageIDs = rangeIDs
            }
        } else if command {
            if selectedPackageIDs.contains(package.id) {
                selectedPackageIDs.remove(package.id)
            } else {
                selectedPackageIDs.insert(package.id)
            }
        } else {
            selectedPackageIDs = [package.id]
        }

        lastSelectedPackageID = package.id
        Task { await loadSelectedPackageDetails() }
    }

    public func loadPackageDetails(package: AndroidPackage) async {
        await performCancellableRead("Loading \(package.packageName)...") { [self] in
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            guard let index = packages.firstIndex(where: { $0.id == package.id }) else { return }
            var updated = try await appManager.details(device: device, package: package)
            updated.isRunning = await isPackageRunning(updated, device: device)
            updated.availableStorageKinds = try await visibleAppStorageKinds(device: device, package: updated)
            packages[index] = updated
            statusMessage = "Loaded details for \(package.packageName)."
        }
    }

    func selectAppStorageLocation(package: AndroidPackage, location: AppStorageLocation) {
        selectedFileIDs.removeAll()
        selectedPackageIDs = [package.id]
        lastSelectedPackageID = package.id

        let isBrowseable = package.hasStorageLocation(location.kind)
        selectedAppStorageLocation = SelectedAppStorageLocation(
            packageName: package.packageName,
            displayName: package.displayName,
            versionName: package.versionName,
            location: location,
            sizeBytes: package.storageSizeBytes(for: location),
            isBrowseable: isBrowseable,
            isProtected: location.kind == .userData && !isBrowseable
        )

        if PreviewWindowPresenter.isSessionVisible, let selectedAppStorageLocation {
            showQuickLookPreview(for: selectedAppStorageLocation)
        }
    }

    func sortStorageAppsByLargest() {
        appSort = .size
        appSortAscending = false
        appSortDescriptors = [AppSortDescriptor(column: .size, ascending: false)]
    }

    public func openApp(package: AndroidPackage) async {
        await perform("Opening \(package.packageName)...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            try await appManager.launch(device: device, packageName: package.packageName)
            setPackageRunning(package.id, running: true)
            statusMessage = "Opened \(package.packageName)."
        }
    }

    public func forceStop(package: AndroidPackage) async {
        guard confirmForceStop(packages: [package]) else { return }
        await perform("Force closing \(package.packageName)...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            try await appManager.forceStop(device: device, packageName: package.packageName)
            setPackageRunning(package.id, running: false)
            statusMessage = "Force closed \(package.packageName)."
        }
    }

    public func forceStopSelectedPackages() async {
        let selected = packages.filter { selectedPackageIDs.contains($0.id) }
        guard !selected.isEmpty, confirmForceStop(packages: selected) else { return }

        await perform("Force closing \(selected.count) app\(selected.count == 1 ? "" : "s")...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            for package in selected {
                try await appManager.forceStop(device: device, packageName: package.packageName)
                setPackageRunning(package.id, running: false)
            }
            statusMessage = "Force closed \(selected.count) app\(selected.count == 1 ? "" : "s")."
        }
    }

    public func toggleStorageAppExpansion(package: AndroidPackage) async {
        if expandedStorageAppPackageIDs.contains(package.id) {
            expandedStorageAppPackageIDs.remove(package.id)
            return
        }

        expandedStorageAppPackageIDs.insert(package.id)
        guard package.availableStorageKinds == nil,
              !loadingStorageAppPackageIDs.contains(package.id) else {
            return
        }

        loadingStorageAppPackageIDs.insert(package.id)
        defer { loadingStorageAppPackageIDs.remove(package.id) }
        await loadPackageDetails(package: package)
    }

    func openAppStorageLocationOrExplain(package: AndroidPackage, location: AppStorageLocation) async {
        if location.kind == .userData, package.hasStorageLocation(location.kind) == false {
            alert = UserAlert(
                title: "User Data Is Protected",
                message: "Android protects \(package.packageName)'s private user data at \(location.path). You can clear it with Clear Storage, but individual files usually cannot be browsed without root or a debuggable app."
            )
            return
        }

        await openAppStorageLocation(package: package, location: location)
    }

    public func clearAppCache(package: AndroidPackage) async {
        await perform("Clearing cache for \(package.packageName)...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            try await appManager.clearCache(device: device, packageName: package.packageName)
            if let index = packages.firstIndex(where: { $0.id == package.id }) {
                packages[index].availableStorageKinds = nil
            }
            statusMessage = "Cleared cache for \(package.packageName)."
        }
    }

    public func clearAppStorage(package: AndroidPackage) async {
        guard confirmClearStorage(package: package) else { return }
        await perform("Clearing storage for \(package.packageName)...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            try await appManager.clearStorage(device: device, packageName: package.packageName)
            if let index = packages.firstIndex(where: { $0.id == package.id }) {
                packages[index].availableStorageKinds = nil
                packages[index].isRunning = false
            }
            statusMessage = "Cleared storage for \(package.packageName)."
        }
    }

    public func pullAPK(package: AndroidPackage) async {
        guard package.apkPath != nil else {
            alert = UserAlert(title: "APK Path Not Available", message: "Android did not report an APK path for \(package.packageName).")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save APK"
        panel.nameFieldStringValue = "\(safePackageFileName(package.packageName)).apk"
        if let apkType = UTType(filenameExtension: "apk") {
            panel.allowedContentTypes = [apkType]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        await perform("Queueing APK backup for \(package.packageName)...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            transferQueue.enqueue(
                kind: .appBackup,
                title: "\(package.displayName).apk",
                subtitle: "Backing up \(package.packageName)",
                source: TransferEndpoint(kind: .adb, deviceID: device.serial, path: package.apkPath ?? "", displayName: package.packageName),
                destination: TransferEndpoint(kind: .mac, path: destination.path, displayName: destination.lastPathComponent),
                totalBytes: package.apkSizeBytes
            ) { [appManager] controller in
                try controller.checkCancellation()
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try controller.checkCancellation()
                try await appManager.pullAPK(device: device, package: package, to: destination) { fraction in
                    Task { @MainActor in
                        controller.updateProgress(fractionCompleted: fraction)
                    }
                }
                try controller.checkCancellation()
                return TransferJobResult(outputURL: destination, message: "Saved")
            }
            transferQueue.isPanelExpanded = true
            statusMessage = "Queued APK backup for \(package.packageName)."
        }
    }

    public func installAPK(url: URL) async {
        await installAppPackages(urls: [url])
    }

    public func installDroppedAppPackages(urls: [URL]) async {
        var seenPaths = Set<String>()
        let uniqueURLs = urls.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
        if uniqueURLs.count > 1,
           uniqueURLs.allSatisfy({ AppPackageFormat.format(for: $0) == .apk }) {
            enqueueDroppedAPKInstalls(uniqueURLs)
        } else {
            await installAppPackages(urls: uniqueURLs)
        }
    }

    private func enqueueDroppedAPKInstalls(_ urls: [URL]) {
        guard !isPreparingForTermination else { return }
        guard let device = selectedDevice, device.state == .device else {
            connectionMode = .adb
            sidebarSelection = nil
            statusMessage = "Developer Options is required to install apps."
            alert = UserAlert(
                title: "Connect with Developer Options",
                message: "Installing app packages requires ADB. Connect with USB debugging or pair over Wireless debugging, then drop the packages again."
            )
            return
        }

        pendingAppInstallRecovery = nil
        let groupID = transferQueue.enqueueGroup(
            kind: .appInstall,
            title: "Install \(urls.count) apps",
            subtitle: "Installing on \(device.title)",
            source: TransferEndpoint(kind: .mac, path: urls.first?.deletingLastPathComponent().path ?? "", displayName: "Finder"),
            destination: TransferEndpoint(kind: .adb, deviceID: device.id, path: "apps", displayName: device.title),
            itemKind: .file
        )
        let exclusiveGroup = "app-install:\(device.id)"

        for url in urls {
            transferQueue.enqueue(
                kind: .appInstall,
                title: url.lastPathComponent,
                subtitle: "Waiting to install on \(device.title)",
                source: TransferEndpoint(kind: .mac, path: url.path, displayName: url.lastPathComponent),
                destination: TransferEndpoint(kind: .adb, deviceID: device.id, path: "apps", displayName: device.title),
                parentID: groupID,
                totalBytes: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
                exclusiveGroup: exclusiveGroup
            ) { [weak self, appManager] controller in
                guard let self else { throw CancellationError() }
                try controller.checkCancellation()
                controller.updateProgress(message: "Installing")
                let result = try await appManager.install(device: device, packageURLs: [url])
                try controller.checkCancellation()
                controller.updateProgress(message: "Refreshing app list")
                await self.refreshPackageListAfterInstall(on: device)
                let expansionDetail = result.copiedExpansionFileCount > 0
                    ? " and \(result.copiedExpansionFileCount) expansion file\(result.copiedExpansionFileCount == 1 ? "" : "s")"
                    : ""
                self.statusMessage = "Installed \(url.lastPathComponent) on \(device.title)\(expansionDetail)."
                return TransferJobResult(message: "Installed")
            }
        }

        transferQueue.isPanelExpanded = true
        statusMessage = "Queued \(urls.count) apps for installation on \(device.title)."
    }

    public func installAppPackages(
        urls: [URL],
        options: AppInstallOptions = AppInstallOptions(),
        replacingPackageName: String? = nil,
        targetDeviceID: AndroidDevice.ID? = nil
    ) async {
        guard !isPreparingForTermination, !isAppPackageInstallInProgress else { return }
        let targetDevice = targetDeviceID.flatMap { id in devices.first { $0.id == id } }
        guard let device = targetDeviceID == nil ? selectedDevice : targetDevice,
              device.state == .device else {
            connectionMode = .adb
            sidebarSelection = nil
            statusMessage = "Developer Options is required to install apps."
            alert = UserAlert(
                title: "Connect with Developer Options",
                message: "Installing app packages requires ADB. Connect with USB debugging or pair over Wireless debugging, then drop the package again."
            )
            return
        }

        let displayName = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) split APKs"
        isInstallingAppPackage = true
        pendingAppInstallRecovery = nil
        beginTrackedOperation(blocksTermination: true)
        statusMessage = replacingPackageName == nil
            ? "Installing \(displayName) on \(device.title)…"
            : "Replacing existing app on \(device.title)…"
        defer {
            isInstallingAppPackage = false
            endTrackedOperation(blocksTermination: true)
        }

        do {
            if let replacingPackageName {
                statusMessage = "Removing the existing copy of \(replacingPackageName)…"
                try await appManager.uninstall(device: device, packageName: replacingPackageName)
            }
            let result = try await appManager.install(
                device: device,
                packageURLs: urls,
                options: options
            )
            await refreshPackageListAfterInstall(on: device)
            let expansionDetail = result.copiedExpansionFileCount > 0
                ? " and copied \(result.copiedExpansionFileCount) expansion file\(result.copiedExpansionFileCount == 1 ? "" : "s")"
                : ""
            statusMessage = "Installed \(displayName) on \(device.title)\(expansionDetail)."
        } catch let conflict as AppInstallConflict {
            if conflict.kind == .newerVersionInstalled, options.allowDowngrade {
                alert = UserAlert(
                    title: "Downgrade Not Allowed",
                    message: "Android still refused this older version. Many release apps and newer Android versions cannot be downgraded without removing the installed copy first. To protect app data, ASOP File Browser did not remove it."
                )
                statusMessage = "Android did not allow the downgrade."
            } else if conflict.kind == .differentSignature, conflict.packageName == nil {
                alert = UserAlert(
                    title: "App Signed Differently",
                    message: "Android won’t replace the installed app because the new package has a different signature. Uninstall the existing app first if you accept losing its app data, then try again."
                )
                statusMessage = "App signature does not match the installed copy."
            } else {
                pendingAppInstallRecovery = AppInstallRecoveryRequest(
                    urls: urls,
                    conflict: conflict,
                    deviceID: device.id,
                    deviceName: device.title
                )
                statusMessage = conflict.kind == .newerVersionInstalled
                    ? "A newer version is already installed."
                    : "App signature does not match the installed copy."
            }
        } catch let installError as AppPackageInstallError {
            alert = UserAlert(title: installError.title, message: installError.localizedDescription)
            statusMessage = installError.title
        } catch {
            handleOperationError(error)
        }
    }

    private func refreshPackageListAfterInstall(on device: AndroidDevice) async {
        guard selectedDevice?.id == device.id, device.state == .device else { return }
        let requestedKind = appKind
        guard let loadedPackages = try? await appManager.packages(device: device, kind: requestedKind),
              selectedDevice?.id == device.id,
              appKind == requestedKind else { return }

        let existingByID = Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) })
        let mergedPackages = loadedPackages.map { package -> AndroidPackage in
            guard let existing = existingByID[package.id] else { return package }
            var merged = package
            merged.isRunning = existing.isRunning
            merged.appLabel = existing.appLabel
            merged.iconPNGData = existing.iconPNGData
            return merged
        }
        applyLoadedPackages(mergedPackages)
    }

    public func retryPendingAppInstallAllowingDowngrade() async {
        guard let request = pendingAppInstallRecovery else { return }
        pendingAppInstallRecovery = nil
        await installAppPackages(
            urls: request.urls,
            options: AppInstallOptions(allowDowngrade: true),
            targetDeviceID: request.deviceID
        )
    }

    public func replacePendingAppInstall() async {
        guard let request = pendingAppInstallRecovery,
              let packageName = request.conflict.packageName else { return }
        pendingAppInstallRecovery = nil
        await installAppPackages(
            urls: request.urls,
            replacingPackageName: packageName,
            targetDeviceID: request.deviceID
        )
    }

    public func uninstall(package: AndroidPackage) async {
        guard confirmUninstall(packages: [package]) else { return }
        await perform("Uninstalling \(package.packageName)...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            try await appManager.uninstall(device: device, packageName: package.packageName)
            try await loadPackagesThrowing()
            statusMessage = "Uninstalled \(package.packageName)."
        }
    }

    public func uninstallSelectedPackages() async {
        let selected = packages.filter { selectedPackageIDs.contains($0.id) }
        guard !selected.isEmpty, confirmUninstall(packages: selected) else { return }

        await perform("Uninstalling \(selected.count) app\(selected.count == 1 ? "" : "s")...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            for package in selected {
                try await appManager.uninstall(device: device, packageName: package.packageName)
            }
            selectedPackageIDs.removeAll()
            try await loadPackagesThrowing()
            statusMessage = "Uninstalled \(selected.count) app\(selected.count == 1 ? "" : "s")."
        }
    }

    public func viewData(package: AndroidPackage) async {
        let targetLocation = package.defaultAppDataLocation
        await openAppStorageLocation(package: package, location: targetLocation)
    }

    func openAppStorageLocation(package: AndroidPackage, location: AppStorageLocation) async {
        await perform("Opening \(location.title) for \(package.packageName)...") {
            guard selectedDevice != nil else { throw FileOperationError.noDevice }
            appFolderContext = AppFolderContext(
                packageName: package.packageName,
                displayName: package.displayName,
                locationTitle: location.title,
                rootPaths: package.appStorageLocations.map(\.path)
            )
            sidebarSelection = .location(QuickLocation(id: location.path, title: package.displayName, path: location.path, symbol: "folder.badge.gearshape"))
            selectedFileIDs.removeAll()
            let task = beginADBFolderNavigation(to: location.path)
            await task?.value
            statusMessage = "Viewing \(location.title) for \(package.packageName)."
        }
    }

    public func setEnabled(_ enabled: Bool, package: AndroidPackage) async {
        await perform("\(enabled ? "Enabling" : "Disabling") \(package.packageName)...") {
            guard let device = selectedDevice else { throw FileOperationError.noDevice }
            if enabled {
                try await appManager.enable(device: device, packageName: package.packageName)
            } else {
                try await appManager.disable(device: device, packageName: package.packageName)
            }
            try await loadPackagesThrowing()
            statusMessage = "\(enabled ? "Enabled" : "Disabled") \(package.packageName)."
        }
    }

    public func requestScreenshot() {
        requestPhoneCapture(.screenshot)
    }

    public func requestScreenRecording() {
        requestPhoneCapture(.recording)
    }

    public func requestPhoneControl() {
        requestPhoneCapture(.phoneControl)
    }

    public func showScreenshotSettings() {
        showPhoneCaptureControls(for: .screenshot)
    }

    public func showRecordingSettings() {
        showPhoneCaptureControls(for: .recording)
    }

    public func showPhoneControlSettings() {
        showPhoneCaptureControls(for: .phoneControl)
    }

    func showPhoneCaptureControls(for mode: PhoneCaptureMode) {
        switch settings.phoneCapturePresentation {
        case .attachedPopover:
            PhoneCaptureWindowPresenter.close()
            activePhoneCapturePopoverMode = mode
        case .separateWindow:
            activePhoneCapturePopoverMode = nil
            PhoneCaptureWindowPresenter.show(model: self, mode: mode)
        }
    }

    func dismissPhoneCapturePopover(_ mode: PhoneCaptureMode) {
        if activePhoneCapturePopoverMode == mode {
            activePhoneCapturePopoverMode = nil
        }
    }

    public func phoneCapturePresentationDidChange() {
        switch settings.phoneCapturePresentation {
        case .attachedPopover:
            PhoneCaptureWindowPresenter.close()
        case .separateWindow:
            activePhoneCapturePopoverMode = nil
        }
    }

    private func requestPhoneCapture(_ mode: PhoneCaptureMode) {
        if shouldShowPhoneCaptureSetup(for: mode) {
            showPhoneCaptureControls(for: mode)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            switch mode {
            case .screenshot:
                await captureScreenshotWithOptions()
            case .recording:
                await startScreenRecording()
            case .phoneControl:
                await launchScrcpy()
            }
        }
    }

    private func shouldShowPhoneCaptureSetup(for mode: PhoneCaptureMode) -> Bool {
        switch mode {
        case .screenshot:
            return true
        case .recording:
            return true
        case .phoneControl:
            return settings.showPhoneControlSetup || isLaunchingScrcpy
        }
    }

    func selectedCaptureDeviceSerials(for mode: PhoneCaptureMode) -> Set<String> {
        let readyDevices = devices.filter { $0.state == .device }
        let readySerials = Set(readyDevices.map(\.serial))
        let storedSerials: Set<String>
        switch mode {
        case .screenshot:
            storedSerials = screenshotCaptureDeviceSerials
        case .recording:
            storedSerials = recordingCaptureDeviceSerials
        case .phoneControl:
            return selectedDevice.map { [$0.serial] } ?? []
        }

        let validSerials = storedSerials.intersection(readySerials)
        if !validSerials.isEmpty { return validSerials }
        if let selectedDevice, selectedDevice.state == .device {
            return [selectedDevice.serial]
        }
        return readyDevices.first.map { [$0.serial] } ?? []
    }

    func setCaptureDevice(_ serial: String, selected: Bool, for mode: PhoneCaptureMode) {
        guard mode != .phoneControl else { return }
        var serials = selectedCaptureDeviceSerials(for: mode)
        if selected {
            serials.insert(serial)
        } else if serials.count > 1 {
            serials.remove(serial)
        }
        switch mode {
        case .screenshot:
            screenshotCaptureDeviceSerials = serials
        case .recording:
            recordingCaptureDeviceSerials = serials
        case .phoneControl:
            break
        }
    }

    private func captureDevices(for mode: PhoneCaptureMode, explicitSerial: String? = nil) -> [AndroidDevice] {
        let serials = explicitSerial.map { Set([$0]) } ?? selectedCaptureDeviceSerials(for: mode)
        return devices.filter { serials.contains($0.serial) && $0.state == .device }
    }

    public func captureScreenshot() async {
        await captureScreenshotWithOptions()
    }

    public func captureScreenshotWithOptions(deviceSerial: String? = nil) async {
        guard !isCapturingScreenshot,
              screenRecordingSession == nil,
              !isStartingScreenRecording,
              !isFinishingScreenRecording else { return }

        isCapturingScreenshot = true
        statusMessage = "Capturing screenshot..."
        defer { isCapturingScreenshot = false }

        do {
            let captureDevices = captureDevices(for: .screenshot, explicitSerial: deviceSerial)
            guard !captureDevices.isEmpty else { throw FileOperationError.noDevice }
            try await adb.validateADB()
            var options = normalizedCaptureOptions(screenshotOptions)
            options.showTouches = false
            screenshotOptions = options
            var preparedDevices: [PreparedCaptureDevice] = []
            for device in captureDevices {
                if let activeRestorePlan = phoneControlRestorePlans[device.serial] {
                    await captureService.applyCapturePresentation(
                        device: device,
                        options: options,
                        restorePlan: activeRestorePlan
                    )
                    await captureService.launchCaptureApp(
                        device: device,
                        packageName: options.normalizedPackageName
                    )
                    preparedDevices.append(PreparedCaptureDevice(
                        device: device,
                        restorePlan: activeRestorePlan,
                        shouldRestoreAfterCapture: false
                    ))
                } else {
                    let restorePlan = await captureService.prepareScreenRecording(device: device, options: options)
                    preparedDevices.append(PreparedCaptureDevice(
                        device: device,
                        restorePlan: restorePlan,
                        shouldRestoreAfterCapture: true
                    ))
                }
            }

            var restoredPresentation = false
            do {
                let captureService = captureService
                var screenshotURLsBySerial: [String: URL] = [:]
                try await withThrowingTaskGroup(of: (String, URL).self) { group in
                    for device in captureDevices {
                        group.addTask {
                            (device.serial, try await captureService.screenshot(device: device))
                        }
                    }
                    for try await (serial, url) in group {
                        screenshotURLsBySerial[serial] = url
                    }
                }
                let orderedURLs = captureDevices.compactMap { screenshotURLsBySerial[$0.serial] }
                let outputURL = try await captureCompositionService.combineScreenshots(orderedURLs)
                if orderedURLs.count > 1 {
                    orderedURLs.forEach { try? FileManager.default.removeItem(at: $0) }
                }
                await restoreAfterScreenshot(preparedDevices)
                restoredPresentation = true
                let previewURL = try await prepareCapturedPreview(outputURL)
                PreviewWindowPresenter.show(url: previewURL) { [weak self] in
                    self?.releaseCachedPreviewURL(previewURL)
                }
                statusMessage = captureDevices.count > 1
                    ? "Side-by-side screenshot captured and opened in a preview window."
                    : "Screenshot captured and opened in a preview window."
            } catch {
                if !restoredPresentation {
                    await restoreAfterScreenshot(preparedDevices)
                }
                throw error
            }
        } catch {
            handleOperationError(error)
        }
    }

    private func restoreAfterScreenshot(_ preparedDevices: [PreparedCaptureDevice]) async {
        for prepared in preparedDevices {
            if prepared.shouldRestoreAfterCapture {
                await captureService.restoreScreenRecordingSettings(
                    serial: prepared.device.serial,
                    restorePlan: prepared.restorePlan
                )
            } else if phoneControlSession(for: prepared.device.serial) != nil {
                await reapplyPhoneControlPresentation(
                    deviceSerial: prepared.device.serial,
                    fallbackRestorePlan: prepared.restorePlan
                )
            }
        }
    }

    public func recordScreen() async {
        requestScreenRecording()
    }

    public func startScreenRecording(deviceSerial: String? = nil) async {
        guard screenRecordingSession == nil,
              !isCapturingScreenshot,
              !isLaunchingScrcpy,
              !isStartingScreenRecording,
              !isFinishingScreenRecording else { return }

        isStartingScreenRecording = true
        screenRecordingRequestDeviceSerial = deviceSerial
        statusMessage = "Preparing screen recording..."
        defer {
            isStartingScreenRecording = false
            screenRecordingRequestDeviceSerial = nil
        }

        do {
            let captureDevices = captureDevices(for: .recording, explicitSerial: deviceSerial)
            guard !captureDevices.isEmpty else { throw FileOperationError.noDevice }
            try await adb.validateADB()
            let options = normalizedCaptureOptions(screenRecordingOptions)
            screenRecordingOptions = options

            var restorePlans: [String: ScreenRecordingRestorePlan] = [:]
            for device in captureDevices {
                if let phoneControlRestorePlan = phoneControlRestorePlans[device.serial] {
                    restorePlans[device.serial] = phoneControlRestorePlan
                    await captureService.applyCapturePresentation(
                        device: device,
                        options: options,
                        restorePlan: phoneControlRestorePlan
                    )
                    await captureService.launchCaptureApp(
                        device: device,
                        packageName: options.normalizedPackageName
                    )
                } else {
                    restorePlans[device.serial] = await captureService.prepareScreenRecording(
                        device: device,
                        options: options
                    )
                }
            }

            let captureService = captureService
            var outcomes: [ScreenRecordingLaunchOutcome] = []
            await withTaskGroup(of: ScreenRecordingLaunchOutcome.self) { group in
                for device in captureDevices {
                    group.addTask {
                        do {
                            let handle = try await captureService.startScreenRecording(
                                device: device,
                                options: options
                            )
                            return ScreenRecordingLaunchOutcome(
                                device: device,
                                handle: handle,
                                errorMessage: nil
                            )
                        } catch {
                            return ScreenRecordingLaunchOutcome(
                                device: device,
                                handle: nil,
                                errorMessage: error.localizedDescription
                            )
                        }
                    }
                }
                for await outcome in group {
                    outcomes.append(outcome)
                }
            }

            let handles = Dictionary(
                uniqueKeysWithValues: outcomes.compactMap { outcome in
                    outcome.handle.map { (outcome.device.serial, $0) }
                }
            )
            if let failure = outcomes.first(where: { $0.errorMessage != nil }) {
                await discardPartiallyStartedRecordings(handles: handles, restorePlans: restorePlans)
                throw FileOperationError.commandFailed(
                    failure.errorMessage ?? "A selected display could not start recording."
                )
            }

            let deviceSessions = captureDevices.compactMap { device -> ScreenRecordingDeviceSession? in
                guard let handle = handles[device.serial] else { return nil }
                return ScreenRecordingDeviceSession(
                    deviceSerial: device.serial,
                    deviceTitle: device.title,
                    startedAt: handle.startedAt
                )
            }
            let session = ScreenRecordingSession(devices: deviceSessions, options: options)
            screenRecordingHandles = handles
            screenRecordingRestorePlans = restorePlans
            screenRecordingSession = session
            statusMessage = captureDevices.count > 1
                ? "Recording \(captureDevices.count) displays."
                : "Recording \(captureDevices[0].title)."
            startScreenRecordingMonitor(sessionID: session.id, handles: handles)
        } catch FileOperationError.commandFailed(let message) where isADBConnectionFailure(message) {
            handleADBConnectionFailure()
        } catch FileOperationError.commandFailed(let message) {
            alert = UserAlert(title: "Recording Couldn't Start", message: message)
            statusMessage = "Screen recording could not start."
        } catch {
            handleOperationError(error)
        }
    }

    private func discardPartiallyStartedRecordings(
        handles: [String: ADBScreenRecordingProcess],
        restorePlans: [String: ScreenRecordingRestorePlan]
    ) async {
        handles.values.forEach { $0.stop() }
        for (serial, restorePlan) in restorePlans {
            if let handle = handles[serial] {
                let discardedURL = try? await captureService.finishScreenRecording(
                    handle: handle,
                    restorePlan: restorePlan
                )
                if let discardedURL {
                    try? FileManager.default.removeItem(at: discardedURL)
                }
            } else if phoneControlSession(for: serial) == nil {
                await captureService.restoreScreenRecordingSettings(
                    serial: serial,
                    restorePlan: restorePlan
                )
            }
            if phoneControlSession(for: serial) != nil {
                await reapplyPhoneControlPresentation(
                    deviceSerial: serial,
                    fallbackRestorePlan: restorePlan
                )
            }
        }
    }

    public func stopScreenRecording() async {
        await finishScreenRecording(interrupt: true)
    }

    public func togglePhoneControlRecording(deviceSerial: String) async {
        guard phoneControlSession(for: deviceSerial) != nil else { return }
        if isScreenRecording(deviceSerial: deviceSerial) {
            await stopScreenRecording()
            return
        }
        if let session = screenRecordingSession {
            alert = UserAlert(
                title: "Recording Already in Progress",
                message: "Stop the recording of \(session.deviceTitle) before starting another one."
            )
            return
        }
        await startScreenRecording(deviceSerial: deviceSerial)
    }

    public func launchScrcpy(deviceSerial: String? = nil) async {
        guard let device = deviceSerial.flatMap({ serial in devices.first { $0.serial == serial } }) ?? selectedDevice else {
            handleADBConnectionFailure()
            return
        }
        if let session = phoneControlSession(for: device.serial) {
            showPhoneControl(deviceSerial: session.deviceSerial)
            statusMessage = "Phone Control is already open for \(session.deviceTitle)."
            return
        }
        guard !isCapturingScreenshot,
              !isLaunchingScrcpy,
              !isStartingScreenRecording,
              !isFinishingScreenRecording else { return }
        isLaunchingScrcpy = true
        let deviceOptions = settings.phoneControlOptions(for: device.serial)
        statusMessage = "Opening Phone Control..."
        defer {
            isLaunchingScrcpy = false
        }

        do {
            try await adb.validatePhoneControlTools()
            let options = normalizedCaptureOptions(phoneControlOptions)
            phoneControlOptions = options
            let restorePlan: ScreenRecordingRestorePlan
            let recordingRestorePlan = screenRecordingSession?.deviceSerials.contains(device.serial) == true
                ? screenRecordingRestorePlans[device.serial]
                : nil
            let sharesRecordingPresentation = recordingRestorePlan != nil
            if let recordingRestorePlan {
                restorePlan = recordingRestorePlan
                await captureService.applyCapturePresentation(
                    device: device,
                    options: options,
                    restorePlan: recordingRestorePlan
                )
                await captureService.launchCaptureApp(device: device, packageName: options.normalizedPackageName)
            } else {
                restorePlan = await captureService.prepareScreenRecording(device: device, options: options)
            }
            let observation: DetachedLaunchObservation
            do {
                let preferredPlacement = PhoneControlCompanionWindowPresenter.preferredScrcpyPlacement(
                    sessionIndex: phoneControlSessions.count
                )
                let placement = preferredPlacement.map {
                    ScrcpyWindowPlacement(
                        x: $0.x,
                        y: $0.y,
                        width: $0.width,
                        height: $0.height,
                        alwaysOnTop: deviceOptions.alwaysOnTop
                    )
                }
                observation = try await adb.launchScrcpy(
                    serial: device.serial,
                    windowTitle: phoneControlWindowTitle(for: device),
                    options: options,
                    deviceOptions: deviceOptions,
                    placement: placement
                )
            } catch {
                if !sharesRecordingPresentation {
                    await captureService.restoreScreenRecordingSettings(serial: device.serial, restorePlan: restorePlan)
                }
                throw error
            }
            registerPhoneControl(observation: observation, device: device, restorePlan: restorePlan)
            suppressedToolSetup.remove(.scrcpy)
            statusMessage = "Phone Control opened for \(device.title)."
        } catch FileOperationError.noDevice {
            handleADBConnectionFailure()
        } catch FileOperationError.commandFailed(let message) where isADBConnectionFailure(message) {
            handleADBConnectionFailure()
        } catch FileOperationError.commandFailed(let message) {
            alert = UserAlert(title: "Phone Control Couldn't Open", message: scrcpyFailureMessage(for: message))
            statusMessage = "Phone Control could not open."
        } catch FileOperationError.missingTool(let tool) {
            presentToolSetup(
                tool: ToolchainTool(rawValue: tool.lowercased()) ?? .scrcpy,
                resumeAction: .phoneControl,
                force: true
            )
        } catch FileOperationError.toolUnavailable(let tool, let reason) {
            if isTransientToolTimeout(tool: tool, reason: reason) {
                presentTransientToolTimeout(reason)
            } else {
                presentToolSetup(tool: tool, issue: reason, resumeAction: .phoneControl, force: true)
            }
        } catch {
            alert = UserAlert(title: "Phone Control Couldn't Open", message: "Phone Control could not start. Try again or repair Phone Tools in Settings → Tools.")
            statusMessage = "Phone Control could not open."
        }
    }

    public func stopPhoneControl(deviceSerial: String? = nil) {
        let targetSerial = deviceSerial ?? phoneControlSession?.deviceSerial
        guard let targetSerial,
              let session = phoneControlSession(for: targetSerial) else { return }
        phoneControlStopRequests.insert(targetSerial)
        statusMessage = "Closing Phone Control for \(session.deviceTitle)..."
        PhoneControlCompanionWindowPresenter.close(deviceSerial: targetSerial)
        let processIdentifier = session.processIdentifier
        Darwin.kill(pid_t(processIdentifier), SIGINT)
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard Self.isProcessAlive(processIdentifier) else { return }
            Darwin.kill(pid_t(processIdentifier), SIGTERM)
            try? await Task.sleep(for: .seconds(1))
            if Self.isProcessAlive(processIdentifier) {
                Darwin.kill(pid_t(processIdentifier), SIGKILL)
            }
        }
    }

    public func stopAllPhoneControls() {
        for session in phoneControlSessions {
            stopPhoneControl(deviceSerial: session.deviceSerial)
        }
    }

    public func showPhoneControl(deviceSerial: String? = nil) {
        let targetSerial = deviceSerial ?? phoneControlSession?.deviceSerial
        guard let targetSerial,
              let session = phoneControlSession(for: targetSerial) else { return }
        startScrcpyForegrounding(processIdentifier: session.processIdentifier)
        PhoneControlCompanionWindowPresenter.show(
            model: self,
            session: session,
            windowTitle: phoneControlWindowTitle(deviceTitle: session.deviceTitle, serial: session.deviceSerial)
        )
    }

    func performPhoneControlShortcut(_ shortcut: PhoneControlShortcut, deviceSerial: String) async {
        guard phoneControlSession(for: deviceSerial) != nil else { return }
        do {
            let result = try await adb.shell(
                serial: deviceSerial,
                shortcut.adbCommand,
                allowFailure: true,
                timeout: 8
            )
            guard result.exitCode == 0 else {
                throw FileOperationError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            statusMessage = shortcut.successMessage
        } catch {
            handleOperationError(error)
        }
    }

    public func capturePresentationOptionDidChange(options: ScreenRecordingOptions) {
        guard screenRecordingSession != nil || phoneControlSession != nil else { return }
        capturePresentationRevision += 1
        let revision = capturePresentationRevision
        capturePresentationUpdateTask?.cancel()
        capturePresentationUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.applyCapturePresentation(revision: revision, options: options)
        }
    }

    public func captureAppSelectionDidChange(options: ScreenRecordingOptions) {
        guard screenRecordingSession != nil || phoneControlSession != nil else { return }
        let targetDevices: [AndroidDevice]
        if let screenRecordingSession {
            let serials = Set(screenRecordingSession.deviceSerials)
            targetDevices = devices.filter { serials.contains($0.serial) }
        } else if let selectedDevice {
            targetDevices = [selectedDevice]
        } else {
            targetDevices = []
        }
        let packageName = options.normalizedPackageName
        Task { [captureService, targetDevices] in
            for device in targetDevices {
                await captureService.launchCaptureApp(device: device, packageName: packageName)
            }
        }
    }

    public func loadCaptureAppChoices(force: Bool = false) async {
        guard let device = selectedDevice, device.state == .device else {
            captureAppChoices = []
            captureAppChoicesDeviceSerial = nil
            return
        }
        guard !isLoadingCaptureApps else { return }
        if !force,
           captureAppChoicesDeviceSerial == device.serial,
           !captureAppChoices.isEmpty {
            return
        }

        isLoadingCaptureApps = true
        defer { isLoadingCaptureApps = false }

        do {
            async let allPackages = appManager.packages(device: device, kind: .all)
            async let launchablePackageNames = appManager.launchablePackageNames(device: device)
            var choices = try await allPackages
            if let launchablePackageNames = await launchablePackageNames {
                choices = choices.filter { launchablePackageNames.contains($0.packageName) }
            }
            guard selectedDevice?.serial == device.serial else { return }
            captureAppChoices = choices.sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .user
                }
                let displayComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if displayComparison != .orderedSame {
                    return displayComparison == .orderedAscending
                }
                return lhs.packageName.localizedStandardCompare(rhs.packageName) == .orderedAscending
            }
            captureAppChoicesDeviceSerial = device.serial
        } catch {
            guard captureAppChoices.isEmpty else { return }
            handleOperationError(error)
        }
    }

    private func startScreenRecordingMonitor(
        sessionID: ScreenRecordingSession.ID,
        handles: [String: ADBScreenRecordingProcess]
    ) {
        screenRecordingMonitorTask?.cancel()
        screenRecordingMonitorTask = Task { @MainActor [weak self] in
            while handles.values.allSatisfy(\.isRunning) {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            await self?.finishScreenRecording(interrupt: true, sessionID: sessionID)
        }
    }

    private func finishScreenRecording(interrupt: Bool, sessionID: ScreenRecordingSession.ID? = nil) async {
        guard !isFinishingScreenRecording,
              let session = screenRecordingSession,
              sessionID == nil || session.id == sessionID,
              !screenRecordingHandles.isEmpty else {
            return
        }

        isFinishingScreenRecording = true
        beginTrackedOperation()
        defer { endTrackedOperation() }
        let handles = screenRecordingHandles
        if interrupt {
            handles.values.forEach { $0.stop() }
            Task.detached(priority: .utility) { [handles] in
                try? await Task.sleep(for: .seconds(2))
                for handle in handles.values where handle.isRunning {
                    handle.terminate()
                }
            }
        }
        statusMessage = "Saving screen recording..."
        let restorePlans = screenRecordingRestorePlans
        let phoneControlSerials = Set(session.deviceSerials.filter { phoneControlSession(for: $0) != nil })

        var sourcesBySerial: [String: CapturedVideoSource] = [:]
        do {
            let captureService = captureService
            try await withThrowingTaskGroup(of: (String, CapturedVideoSource).self) { group in
                for (serial, handle) in handles {
                    let restorePlan = restorePlans[serial]
                    group.addTask {
                        let url = try await captureService.finishScreenRecording(
                            handle: handle,
                            restorePlan: restorePlan
                        )
                        return (serial, CapturedVideoSource(url: url, startedAt: handle.startedAt))
                    }
                }
                for try await (serial, source) in group {
                    sourcesBySerial[serial] = source
                }
            }
            let orderedSources = session.deviceSerials.compactMap { sourcesBySerial[$0] }
            let url = try await captureCompositionService.combineRecordings(orderedSources)
            if orderedSources.count > 1 {
                orderedSources.forEach { try? FileManager.default.removeItem(at: $0.url) }
            }
            clearScreenRecordingState()
            for serial in phoneControlSerials {
                await reapplyPhoneControlPresentation(
                    deviceSerial: serial,
                    fallbackRestorePlan: restorePlans[serial]
                )
            }
            let previewURL = try await prepareCapturedPreview(url)
            PreviewWindowPresenter.show(url: previewURL) { [weak self] in
                self?.releaseCachedPreviewURL(previewURL)
            }
            statusMessage = session.devices.count > 1
                ? "Side-by-side recording saved and opened in a preview window."
                : "Screen recording saved and opened in a preview window."
        } catch {
            sourcesBySerial.values.forEach { try? FileManager.default.removeItem(at: $0.url) }
            clearScreenRecordingState()
            for serial in phoneControlSerials {
                await reapplyPhoneControlPresentation(
                    deviceSerial: serial,
                    fallbackRestorePlan: restorePlans[serial]
                )
            }
            alert = UserAlert(
                title: "Recording Couldn't Finish",
                message: "The selected displays could not be saved together. Make sure each display is connected, awake, and able to record, then try again."
            )
            statusMessage = "Screen recording could not be saved."
        }
    }

    private func clearScreenRecordingState() {
        screenRecordingMonitorTask?.cancel()
        screenRecordingMonitorTask = nil
        screenRecordingHandles = [:]
        screenRecordingRestorePlans = [:]
        screenRecordingSession = nil
        isFinishingScreenRecording = false
        if phoneControlSessions.isEmpty {
            capturePresentationUpdateTask?.cancel()
            isApplyingCapturePresentation = false
        }
    }

    private func normalizedCaptureOptions(_ source: ScreenRecordingOptions) -> ScreenRecordingOptions {
        var options = source
        options.fixedDurationSeconds = options.effectiveFixedDurationSeconds
        options.customWidth = options.effectiveCustomWidth
        options.customHeight = options.effectiveCustomHeight
        options.videoBitRateMbps = options.effectiveVideoBitRateMbps
        options.appPackageName = ""
        return options
    }

    private func registerPhoneControl(
        observation: DetachedLaunchObservation,
        device: AndroidDevice,
        restorePlan: ScreenRecordingRestorePlan
    ) {
        let session = PhoneControlSession(
            deviceSerial: device.serial,
            deviceTitle: device.title,
            processIdentifier: observation.processIdentifier
        )
        phoneControlMonitorTasks[device.serial]?.cancel()
        phoneControlStopRequests.remove(device.serial)
        phoneControlRestorePlans[device.serial] = restorePlan
        phoneControlSessions.removeAll { $0.deviceSerial == device.serial }
        phoneControlSessions.append(session)
        phoneControlCapabilityStates[device.serial] = .checking
        startScrcpyForegrounding(processIdentifier: observation.processIdentifier)
        PhoneControlCompanionWindowPresenter.show(
            model: self,
            session: session,
            windowTitle: phoneControlWindowTitle(for: device)
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            async let battery: Void = self.refreshBatteryStatus(for: device)
            async let capabilities: Void = self.refreshPhoneControlCapabilities(for: device)
            _ = await (battery, capabilities)
        }

        let processHandle = observation.processHandle
        phoneControlMonitorTasks[device.serial] = Task { @MainActor [weak self] in
            let exitCode = await Task.detached(priority: .utility) {
                processHandle.waitUntilExit()
            }.value
            guard !Task.isCancelled else { return }
            await self?.phoneControlDidExit(
                processIdentifier: observation.processIdentifier,
                exitCode: exitCode,
                logURL: observation.logURL
            )
        }
    }

    private func phoneControlDidExit(processIdentifier: Int32, exitCode: Int32, logURL: URL) async {
        guard let session = phoneControlSessions.first(where: { $0.processIdentifier == processIdentifier }) else {
            return
        }

        let stopWasRequested = phoneControlStopRequests.remove(session.deviceSerial) != nil
        let restorePlan = phoneControlRestorePlans.removeValue(forKey: session.deviceSerial)
        phoneControlSessions.removeAll { $0.processIdentifier == processIdentifier }
        phoneControlCapabilityStates[session.deviceSerial] = nil
        phoneControlMonitorTasks[session.deviceSerial] = nil
        PhoneControlCompanionWindowPresenter.close(deviceSerial: session.deviceSerial)

        if screenRecordingSession?.deviceSerials.contains(session.deviceSerial) == true,
           !isFinishingScreenRecording,
           let device = devices.first(where: { $0.serial == session.deviceSerial }) {
            await captureService.applyCapturePresentation(
                device: device,
                options: normalizedCaptureOptions(screenRecordingOptions),
                restorePlan: screenRecordingRestorePlans[session.deviceSerial] ?? restorePlan
            )
        } else if !isFinishingScreenRecording {
            if selectedDevice?.serial == session.deviceSerial {
                capturePresentationUpdateTask?.cancel()
                capturePresentationRevision += 1
                isApplyingCapturePresentation = false
            }
            await captureService.restoreScreenRecordingSettings(
                serial: session.deviceSerial,
                restorePlan: restorePlan
            )
        }
        let output = Self.readToolLog(at: logURL)
        let lowercasedOutput = output.lowercased()
        let disconnected = lowercasedOutput.contains("device disconnected")
            || lowercasedOutput.contains("device not found")
            || lowercasedOutput.contains("device offline")
            || lowercasedOutput.contains("unauthorized")
            || lowercasedOutput.contains("connection closed")
            || lowercasedOutput.contains("broken pipe")
        let installationFailure = lowercasedOutput.contains("library not loaded")
            || lowercasedOutput.contains("dyld")
            || lowercasedOutput.contains("scrcpy-server") && lowercasedOutput.contains("not found")
            || lowercasedOutput.contains("bad cpu type")
            || lowercasedOutput.contains("exec format")
        let stoppedUnexpectedly = !stopWasRequested
            && (exitCode != 0 || disconnected || lowercasedOutput.contains("fatal:"))

        if !stoppedUnexpectedly {
            statusMessage = "Phone Control closed."
        } else if installationFailure {
            presentToolSetup(
                tool: .scrcpy,
                issue: "Phone Control stopped because its support files could not be used.",
                resumeAction: .phoneControl,
                force: true
            )
        } else if disconnected {
            statusMessage = "Phone Control disconnected."
            alert = UserAlert(
                title: "Phone Control Disconnected",
                message: "Reconnect the device, approve debugging if asked, and try again.",
                onDismiss: { [weak self] in
                    self?.closeDisconnectedPhoneControl(
                        deviceSerial: session.deviceSerial,
                        processIdentifier: session.processIdentifier
                    )
                }
            )
        } else {
            statusMessage = "Phone Control closed unexpectedly."
            alert = UserAlert(
                title: "Phone Control Closed",
                message: "Phone Control stopped unexpectedly. Try again or repair Phone Tools in Settings → Tools.\n\nDetails were saved to \(logURL.path)."
            )
        }
    }

    private func closeDisconnectedPhoneControl(deviceSerial: String, processIdentifier: Int32) {
        PhoneControlCompanionWindowPresenter.close(deviceSerial: deviceSerial)
        guard Self.isProcessAlive(processIdentifier) else { return }
        Darwin.kill(pid_t(processIdentifier), SIGTERM)
    }

    private func refreshPhoneControlCapabilities(for device: AndroidDevice) async {
        guard phoneControlSession(for: device.serial) != nil else { return }
        do {
            let capabilities = try await captureService.phoneControlCapabilities(device: device)
            guard phoneControlSession(for: device.serial) != nil else { return }
            phoneControlCapabilityStates[device.serial] = .available(capabilities)
        } catch is CancellationError {
            return
        } catch {
            guard phoneControlSession(for: device.serial) != nil else { return }
            phoneControlCapabilityStates[device.serial] = .unavailable
        }
    }

    private func applyCapturePresentation(revision: Int, options: ScreenRecordingOptions) async {
        guard revision == capturePresentationRevision,
              screenRecordingSession != nil || phoneControlSession != nil else {
            return
        }

        let targetDevices: [AndroidDevice]
        if let screenRecordingSession {
            let serials = Set(screenRecordingSession.deviceSerials)
            targetDevices = devices.filter { serials.contains($0.serial) && $0.state == .device }
        } else if let selectedDevice, selectedDevice.state == .device {
            targetDevices = [selectedDevice]
        } else {
            targetDevices = []
        }
        guard !targetDevices.isEmpty else { return }

        let options = normalizedCaptureOptions(options)
        isApplyingCapturePresentation = true
        for device in targetDevices {
            let restorePlan = screenRecordingRestorePlans[device.serial]
                ?? phoneControlRestorePlans[device.serial]
            await captureService.applyCapturePresentation(
                device: device,
                options: options,
                restorePlan: restorePlan
            )
        }
        guard revision == capturePresentationRevision else { return }
        isApplyingCapturePresentation = false
        statusMessage = "Updated phone capture settings."
    }

    private func reapplyPhoneControlPresentation(
        deviceSerial: String,
        fallbackRestorePlan: ScreenRecordingRestorePlan?
    ) async {
        guard phoneControlSession(for: deviceSerial) != nil,
              let device = devices.first(where: { $0.serial == deviceSerial }) else { return }
        await captureService.applyCapturePresentation(
            device: device,
            options: normalizedCaptureOptions(phoneControlOptions),
            restorePlan: phoneControlRestorePlans[deviceSerial] ?? fallbackRestorePlan
        )
    }

    private func phoneControlWindowTitle(for device: AndroidDevice) -> String {
        phoneControlWindowTitle(deviceTitle: device.title, serial: device.serial)
    }

    private func phoneControlWindowTitle(deviceTitle: String, serial: String) -> String {
        let serialSuffix = serial.count > 8 ? String(serial.suffix(8)) : serial
        return "ASOP File Browser — \(deviceTitle) [\(serialSuffix)]"
    }

    private nonisolated static func isProcessAlive(_ processIdentifier: Int32) -> Bool {
        Darwin.kill(pid_t(processIdentifier), 0) == 0 || errno == EPERM
    }

    private nonisolated static func readToolLog(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    private func startScrcpyForegrounding(processIdentifier: Int32) {
        activateScrcpyApplication(processIdentifier: processIdentifier)
        Task { @MainActor [weak self] in
            for delay in [0.25, 0.75, 1.25] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.activateScrcpyApplication(processIdentifier: processIdentifier)
            }
        }
    }

    @discardableResult
    private func activateScrcpyApplication(processIdentifier: Int32) -> Bool {
        if let application = NSRunningApplication(processIdentifier: pid_t(processIdentifier)) {
            return application.activate(options: [.activateAllWindows])
        }

        guard let application = NSWorkspace.shared.runningApplications.first(where: { application in
            application.localizedName?.localizedCaseInsensitiveContains("scrcpy") == true
        }) else {
            return false
        }
        return application.activate(options: [.activateAllWindows])
    }

    public func connectWiFi(host: String) async {
        await perform("Connecting to \(host)...") {
            try await deviceManager.connect(host: host)
            await refreshDevices()
        }
    }

    public func startADBQRPairing() {
        guard toolchainManager.status(for: .adb).isReady else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await toolchainManager.refresh()
                if toolchainManager.status(for: .adb).isReady {
                    beginADBQRPairing()
                } else {
                    presentToolSetup(tool: .adb, force: true)
                }
            }
            return
        }
        beginADBQRPairing()
    }

    private func beginADBQRPairing() {
        adbQRPairingTask?.cancel()
        adbDiscovery?.stop()
        adbQRPairedHost = nil
        let session = ADBQRPairingSession.make()
        adbQRPairingSession = session
        adbQRPairingStatus = "Open Android Wireless debugging, choose Pair device with QR code, then scan this code."

        let discovery = ADBDiscovery { [weak self] services in
            Task { @MainActor [weak self] in
                await self?.handleADBQRServices(services)
            }
        }
        adbDiscovery = discovery
        discovery.start()
    }

    public func stopADBQRPairing() {
        adbQRPairingTask?.cancel()
        adbQRPairingTask = nil
        adbDiscovery?.stop()
        adbDiscovery = nil
        adbQRPairedHost = nil
        adbQRPairingSession = nil
    }

    public func adbQRPairingSheetDidDismiss() {
        stopADBQRPairing()
        guard let pending = pendingToolSetupAfterQR else { return }
        pendingToolSetupAfterQR = nil
        presentToolSetup(tool: pending.tool, issue: pending.issue, force: true)
    }

    private func handleADBQRServices(_ services: [ADBService]) async {
        guard let session = adbQRPairingSession, adbQRPairingTask == nil else { return }

        if let pairedHost = adbQRPairedHost,
           let connectService = services.first(where: { $0.kind == .connect && $0.host == pairedHost })
                ?? services.first(where: { $0.kind == .connect }) {
            adbQRPairingTask = Task { [weak self] in
                await self?.connectPairedADBService(connectService.endpoint)
            }
            return
        }

        guard let pairingService = services.first(where: { $0.kind == .pairing && $0.name == session.serviceName }) else {
            adbQRPairingStatus = "Waiting for the phone to advertise the QR pairing service..."
            return
        }

        adbQRPairingTask = Task { [weak self] in
            await self?.pairADBQRCode(endpoint: pairingService.endpoint, host: pairingService.host, password: session.password)
        }
    }

    private func pairADBQRCode(endpoint: String, host: String, password: String) async {
        do {
            await MainActor.run {
                self.adbQRPairingStatus = "Pairing with \(endpoint)..."
            }
            try await deviceManager.pair(host: endpoint, code: password)
            await MainActor.run {
                self.adbQRPairedHost = host
                self.adbQRPairingStatus = "Paired. Waiting for Android's wireless ADB connection service..."
                self.adbQRPairingTask = nil
            }
        } catch {
            await MainActor.run {
                if case FileOperationError.missingTool = error {
                    self.adbRuntimeIssue = "Phone tools are not installed."
                    self.pendingToolSetupAfterQR = (.adb, nil)
                    self.stopADBQRPairing()
                } else if case FileOperationError.toolUnavailable(let tool, let reason) = error {
                    if tool == .adb {
                        self.adbRuntimeIssue = reason
                    }
                    self.pendingToolSetupAfterQR = (tool, reason)
                    self.stopADBQRPairing()
                } else {
                    self.adbQRPairingStatus = "Pairing could not finish. Check the code and try again."
                }
                self.adbQRPairingTask = nil
            }
        }
    }

    private func connectPairedADBService(_ endpoint: String) async {
        do {
            await MainActor.run {
                self.adbQRPairingStatus = "Connecting to \(endpoint)..."
            }
            try await deviceManager.connect(host: endpoint)
            await refreshDevices()
            await MainActor.run {
                self.adbQRPairingStatus = "Connected over wireless ADB."
                self.stopADBQRPairing()
            }
        } catch {
            await MainActor.run {
                if case FileOperationError.missingTool = error {
                    self.adbRuntimeIssue = "Phone tools are not installed."
                    self.pendingToolSetupAfterQR = (.adb, nil)
                    self.stopADBQRPairing()
                } else if case FileOperationError.toolUnavailable(let tool, let reason) = error {
                    if tool == .adb {
                        self.adbRuntimeIssue = reason
                    }
                    self.pendingToolSetupAfterQR = (tool, reason)
                    self.stopADBQRPairing()
                } else {
                    self.adbQRPairingStatus = "The Wi-Fi connection could not be completed. Check the phone and try again."
                }
                self.adbQRPairingTask = nil
            }
        }
    }

    public func savePreviewAs() {
        guard let previewURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = previewURL.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: previewURL, to: destination)
            statusMessage = "Saved \(destination.lastPathComponent)."
        } catch {
            alert = UserAlert(error: error)
        }
    }

    public func discardPreview() {
        previewURL = nil
        statusMessage = "Preview discarded."
    }

    public func refreshCacheUsage() async {
        isRefreshingCacheUsage = true
        cacheUsage = await cacheStore.usage()
        isRefreshingCacheUsage = false
    }

    public func performPreviewCacheMaintenance(force: Bool = false) async {
        let now = Date()
        if !force,
           let lastPreviewCacheMaintenanceAt,
           now.timeIntervalSince(lastPreviewCacheMaintenanceAt) < 300 {
            return
        }
        lastPreviewCacheMaintenanceAt = now

        let cutoff = now.addingTimeInterval(-Double(settings.previewCacheRetention.rawValue * 60))
        do {
            _ = try await cacheStore.expirePreviewFiles(olderThan: cutoff)
            cacheUsage = try await cacheStore.reprotectPreviewFiles(encrypt: settings.encryptPreviewCache)
            removeMissingThumbnailReferences()
        } catch {
            cacheUsage = await cacheStore.usage()
        }
    }

    public func updatePreviewCacheProtection() async {
        isRefreshingCacheUsage = true
        do {
            cacheUsage = try await cacheStore.reprotectPreviewFiles(encrypt: settings.encryptPreviewCache)
            statusMessage = settings.encryptPreviewCache
                ? "Preview cache encrypted."
                : "Preview cache encryption turned off."
        } catch {
            alert = UserAlert(title: "Preview Cache Could Not Be Updated", message: error.localizedDescription)
            cacheUsage = await cacheStore.usage()
        }
        isRefreshingCacheUsage = false
    }

    public func preparePreviewCacheForTermination() async {
        PreviewWindowPresenter.closeAll()
        if settings.clearMediaCacheOnQuit {
            await clearAllCaches()
            return
        }
        do {
            try await cacheStore.clearPreviewFiles()
            previewURL = nil
            cacheUsage = await cacheStore.usage()
        } catch {
            // A launch-time sweep will remove any files left after an interrupted quit.
        }
    }

    public func enforceMediaCacheLimit() async {
        isRefreshingCacheUsage = true
        let byteLimit = Int64(settings.mediaCacheLimitMB) * 1024 * 1024
        let protectedURLs = Set([previewURL].compactMap { $0 })
        do {
            cacheUsage = try await cacheStore.trim(toByteLimit: byteLimit, protecting: protectedURLs)
            removeMissingThumbnailReferences()
        } catch {
            alert = UserAlert(title: "Cache Could Not Be Updated", message: error.localizedDescription)
            cacheUsage = await cacheStore.usage()
        }
        isRefreshingCacheUsage = false
    }

    public func clearThumbnailCache() async {
        do {
            requestedThumbnailCacheKeysByFileID.removeAll()
            try await cacheStore.clearThumbnails()
            thumbnailURLs.removeAll()
            thumbnailCacheKeysByFileID.removeAll()
            cacheUsage = await cacheStore.usage()
            statusMessage = "Thumbnail cache cleared."
        } catch {
            alert = UserAlert(title: "Thumbnails Could Not Be Cleared", message: error.localizedDescription)
        }
    }

    public func clearPreviewCache() async {
        do {
            try await cacheStore.clearPreviewFiles()
            previewURL = nil
            cacheUsage = await cacheStore.usage()
            statusMessage = "Preview and file cache cleared."
        } catch {
            alert = UserAlert(title: "Preview Files Could Not Be Cleared", message: error.localizedDescription)
        }
    }

    public func clearAllCaches() async {
        do {
            requestedThumbnailCacheKeysByFileID.removeAll()
            try await cacheStore.clearAll()
            previewURL = nil
            thumbnailURLs.removeAll()
            thumbnailCacheKeysByFileID.removeAll()
            cacheUsage = .zero
            statusMessage = "Cache cleared."
        } catch {
            alert = UserAlert(title: "Cache Could Not Be Cleared", message: error.localizedDescription)
            cacheUsage = await cacheStore.usage()
        }
    }

    private func scheduleCacheMaintenance() {
        cacheMaintenanceTask?.cancel()
        cacheMaintenanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.enforceMediaCacheLimit()
            self.cacheMaintenanceTask = nil
        }
    }

    private func prepareCapturedPreview(_ sourceURL: URL) async throws -> URL {
        try await cacheStore.storePreview(
            from: sourceURL,
            at: sourceURL,
            encrypt: settings.encryptPreviewCache
        )
        guard let readableURL = try await cacheStore.readablePreviewURL(
            for: sourceURL,
            encrypt: settings.encryptPreviewCache
        ) else {
            throw FileOperationError.commandFailed("The captured preview could not be prepared.")
        }
        scheduleCacheMaintenance()
        return readableURL
    }

    private func releaseCachedPreviewURL(_ url: URL) {
        if previewURL == url {
            previewURL = nil
        }
        Task {
            await cacheStore.releaseReadablePreview(url)
            await refreshCacheUsage()
        }
    }

    private func removeMissingThumbnailReferences() {
        let missingIDs = thumbnailURLs.compactMap { id, url in
            FileManager.default.fileExists(atPath: url.path) ? nil : id
        }
        for id in missingIDs {
            thumbnailURLs[id] = nil
            thumbnailCacheKeysByFileID[id] = nil
        }
    }

    private func refreshFilesThrowing() async throws {
        guard let device = selectedDevice, device.state == .device else {
            throw FileOperationError.noDevice
        }
        let path = currentPath
        let mutationRevision = browserMutationRevision(for: path)
        guard !hasActiveBrowserMutation(at: path) else { return }
        invalidateFolderSizes(under: path)
        let loadedFiles = try await fileRepository.listFiles(device: device, path: path)
        try Task.checkCancellation()
        guard currentPath == path,
              selectedDevice?.id == device.id,
              browserMutationRevision(for: path) == mutationRevision,
              !hasActiveBrowserMutation(at: path) else { return }
        applyCurrentFolderFiles(loadedFiles)
        scheduleFolderSizeCalculations(for: loadedFiles)
    }

    private func applyCurrentFolderFiles(_ loadedFiles: [AndroidFile]) {
        let availableIDs = Set(loadedFiles.map(\.id))
        files = loadedFiles
        let normalizedPath = normalizedFolderCachePath(currentPath)
        adbFolderListingsByPath[normalizedPath] = loadedFiles
        treeChildrenByPath[normalizedPath] = loadedFiles
        selectedFileIDs = selectedFileIDs.intersection(availableIDs.union(Set(treeChildrenByPath.values.flatMap { $0.map(\.id) })))
        if let inlineRenameFileID, !availableIDs.contains(inlineRenameFileID) {
            cancelInlineRename()
        }
        scheduleFullDeviceSearchIfNeeded()
    }

    private func loadPackagesThrowing() async throws {
        guard let device = selectedDevice, device.state == .device else {
            throw FileOperationError.noDevice
        }
        packageLoadRevision &+= 1
        let loadRevision = packageLoadRevision
        let requestedKind = appKind
        let basePackages = try await appManager.packages(device: device, kind: appKind)
        try validatePackageLoad(device: device, kind: requestedKind, revision: loadRevision)

        var visiblePackages = requestedKind == .all
            ? basePackages
            : basePackages.filter { $0.kind == requestedKind }
        applyLoadedPackages(visiblePackages)
        statusMessage = "Loaded \(visiblePackages.count) app\(visiblePackages.count == 1 ? "" : "s")."

        let processNames: Set<String>
        do {
            processNames = try await appManager.runningProcessNames(device: device)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            processNames = []
        }
        try validatePackageLoad(device: device, kind: requestedKind, revision: loadRevision)
        visiblePackages = markRunning(visiblePackages, processNames: processNames)
        applyLoadedPackages(visiblePackages)

        do {
            let presentations = try await appManager.presentations(
                device: device,
                packages: visiblePackages
            ) { [weak self] batch in
                guard let self else { throw CancellationError() }
                try await self.applyPackagePresentationBatch(
                    batch,
                    device: device,
                    kind: requestedKind,
                    revision: loadRevision
                )
            }
            try validatePackageLoad(device: device, kind: requestedKind, revision: loadRevision)
            visiblePackages = visiblePackages.map { package in
                guard let presentation = presentations[package.packageName] else { return package }
                var presentedPackage = package
                presentedPackage.appLabel = presentation.label
                presentedPackage.iconPNGData = presentation.iconPNGData
                return presentedPackage
            }
            applyLoadedPackages(visiblePackages)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Package names and deterministic artwork remain available when a
            // device cannot provide richer launcher metadata.
        }

        for package in visiblePackages {
            try validatePackageLoad(device: device, kind: requestedKind, revision: loadRevision)
            let enrichedPackage: AndroidPackage
            do {
                enrichedPackage = try await appManager.details(device: device, package: package)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            try validatePackageLoad(device: device, kind: requestedKind, revision: loadRevision)
            guard let index = packages.firstIndex(where: { $0.id == enrichedPackage.id }) else { continue }
            packages[index] = enrichedPackage
        }
    }

    private func applyPackagePresentationBatch(
        _ presentations: [String: AndroidAppPresentation],
        device: AndroidDevice,
        kind: AppKind,
        revision: Int
    ) throws {
        try validatePackageLoad(device: device, kind: kind, revision: revision)
        packages = packages.map { package in
            guard let presentation = presentations[package.packageName] else { return package }
            var updated = package
            updated.appLabel = presentation.label
            updated.iconPNGData = presentation.iconPNGData
            return updated
        }
    }

    private func validatePackageLoad(
        device: AndroidDevice,
        kind: AppKind,
        revision: Int
    ) throws {
        try Task.checkCancellation()
        guard packageLoadRevision == revision,
              appKind == kind,
              selectedDeviceID == device.id,
              devices.contains(where: { $0.id == device.id && $0.state == .device }) else {
            throw CancellationError()
        }
    }

    private func applyLoadedPackages(_ loadedPackages: [AndroidPackage]) {
        let selectedIDsAtApply = selectedPackageIDs
        let lastSelectedIDAtApply = lastSelectedPackageID
        let availableIDs = Set(loadedPackages.map(\.id))
        packages = loadedPackages
        selectedPackageIDs = selectedIDsAtApply.intersection(availableIDs)
        expandedStorageAppPackageIDs = expandedStorageAppPackageIDs.intersection(availableIDs)
        loadingStorageAppPackageIDs = loadingStorageAppPackageIDs.intersection(availableIDs)
        if let lastSelectedIDAtApply, selectedPackageIDs.contains(lastSelectedIDAtApply) {
            lastSelectedPackageID = lastSelectedIDAtApply
        } else {
            lastSelectedPackageID = selectedPackageIDs.first
        }
    }

    private func scheduleStorageCategoryPrefetch(device: AndroidDevice, summaries: [StorageSummary]) {
        guard device.state == .device, !summaries.isEmpty else {
            cancelStorageCategoryPrefetch()
            return
        }

        let signature = storagePrefetchSignature(device: device, summaries: summaries)
        if storageCategoryPrefetchSignature == signature,
           storageCategoryPrefetchTask != nil {
            return
        }

        cancelStorageCategoryPrefetch(clearSignature: false)
        storageCategoryPrefetchSignature = signature
        storageCategoryPrefetchTask = Task(priority: .utility) { [weak self, device, summaries, signature] in
            await self?.prefetchStorageCategories(device: device, summaries: summaries, signature: signature)
        }
    }

    private func cancelStorageCategoryPrefetch(clearSignature: Bool = true) {
        storageCategoryPrefetchTask?.cancel()
        storageCategoryPrefetchTask = nil
        if clearSignature {
            storageCategoryPrefetchSignature = nil
        }
        prefetchingStorageBreakdownIDs.removeAll()
        prefetchingStorageCategoryIDs.removeAll()
        isPrefetchingStorageCategories = false
    }

    private func storagePrefetchSignature(device: AndroidDevice, summaries: [StorageSummary]) -> String {
        let summarySignature = summaries
            .map { "\($0.id):\($0.path):\($0.usedBytes):\($0.totalBytes)" }
            .joined(separator: "|")
        return "\(device.id)|\(summarySignature)"
    }

    private func prefetchStorageCategories(
        device: AndroidDevice,
        summaries: [StorageSummary],
        signature: String
    ) async {
        isPrefetchingStorageCategories = true
        defer {
            if storageCategoryPrefetchSignature == signature {
                storageCategoryPrefetchTask = nil
                prefetchingStorageBreakdownIDs.removeAll()
                prefetchingStorageCategoryIDs.removeAll()
                isPrefetchingStorageCategories = false
            }
        }

        for summary in summaries {
            guard shouldContinueStoragePrefetch(device: device) else { return }

            let breakdown: StorageBreakdown
            if let cached = storageBreakdowns[summary.id] {
                breakdown = cached
            } else {
                prefetchingStorageBreakdownIDs.insert(summary.id)
                do {
                    breakdown = try await fileRepository.storageBreakdown(device: device, summary: summary)
                    guard shouldContinueStoragePrefetch(device: device) else { return }
                    storageBreakdowns[summary.id] = breakdown
                } catch {
                    prefetchingStorageBreakdownIDs.remove(summary.id)
                    continue
                }
                prefetchingStorageBreakdownIDs.remove(summary.id)
            }

            await prefetchStorageCategoryFileLists(device: device, breakdown: breakdown)
        }
    }

    private func prefetchStorageCategoryFileLists(device: AndroidDevice, breakdown: StorageBreakdown) async {
        for category in breakdown.visibleCategories where category.kind.canBrowseFiles {
            guard shouldContinueStoragePrefetch(device: device) else { return }
            let listID = storageCategoryFileListID(summaryID: breakdown.summary.id, categoryID: category.id)
            guard storageCategoryFileLists[listID] == nil else { continue }

            if category.kind == .apps {
                await prefetchAppsIfNeeded(listID: listID)
                continue
            }

            prefetchingStorageCategoryIDs.insert(listID)
            do {
                let files = try await fileRepository.storageCategoryFiles(
                    device: device,
                    summary: breakdown.summary,
                    category: category
                )
                guard shouldContinueStoragePrefetch(device: device) else { return }
                storageCategoryFileLists[listID] = StorageCategoryFileList(
                    summaryID: breakdown.summary.id,
                    category: category,
                    files: files
                )
            } catch {
                // Background prefetch should not interrupt active browsing. Foreground selection can retry and report details.
            }
            prefetchingStorageCategoryIDs.remove(listID)
            await Task.yield()
        }
    }

    private func prefetchAppsIfNeeded(listID: StorageCategoryFileList.ID) async {
        guard packages.isEmpty else {
            return
        }

        prefetchingStorageCategoryIDs.insert(listID)
        do {
            try await loadPackagesThrowing()
        } catch {
            // Foreground Apps selection will retry and show an error if needed.
        }
        prefetchingStorageCategoryIDs.remove(listID)
    }

    private func shouldContinueStoragePrefetch(device: AndroidDevice) -> Bool {
        !Task.isCancelled && selectedDevice?.id == device.id && selectedDevice?.state == .device
    }

    private func sortedPackagesForDisplay(_ packages: [AndroidPackage]) -> [AndroidPackage] {
        packages.sorted { lhs, rhs in
            for descriptor in activeAppSortDescriptors {
                let result = comparePackages(lhs, rhs, by: descriptor.column)
                if result != .orderedSame {
                    return descriptor.ascending ? result == .orderedAscending : result == .orderedDescending
                }
            }

            return lhs.packageName.localizedStandardCompare(rhs.packageName) == .orderedAscending
        }
    }

    private func comparePackages(_ lhs: AndroidPackage, _ rhs: AndroidPackage, by column: AppColumn) -> ComparisonResult {
        switch column {
        case .package:
            lhs.packageName.localizedStandardCompare(rhs.packageName)
        case .status:
            lhs.isRunning == rhs.isRunning ? .orderedSame : (lhs.isRunning ? .orderedAscending : .orderedDescending)
        case .kind:
            lhs.kind.label.localizedStandardCompare(rhs.kind.label)
        case .enabled:
            compareOptionalInt64(Int64(enabledSortValue(lhs.enabled)), Int64(enabledSortValue(rhs.enabled)), missingValue: 2)
        case .size:
            compareOptionalInt64(lhs.storageStats?.totalBytes ?? lhs.apkSizeBytes, rhs.storageStats?.totalBytes ?? rhs.apkSizeBytes, missingValue: -1)
        case .apk:
            (lhs.apkPath ?? "").localizedStandardCompare(rhs.apkPath ?? "")
        }
    }

    private func enabledSortValue(_ value: Bool?) -> Int {
        switch value {
        case .some(true): 0
        case .some(false): 1
        case .none: 2
        }
    }

    private func markRunning(_ packages: [AndroidPackage], processNames: Set<String>) -> [AndroidPackage] {
        packages.map { package in
            var updated = package
            updated.isRunning = processNames.contains { processName in
                processName == package.packageName || processName.hasPrefix("\(package.packageName):")
            }
            return updated
        }
    }

    private func isPackageRunning(_ package: AndroidPackage, device: AndroidDevice) async -> Bool {
        guard let processNames = try? await appManager.runningProcessNames(device: device) else {
            return package.isRunning
        }
        return processNames.contains { processName in
            processName == package.packageName || processName.hasPrefix("\(package.packageName):")
        }
    }

    private func setPackageRunning(_ packageID: AndroidPackage.ID, running: Bool) {
        guard let index = packages.firstIndex(where: { $0.id == packageID }) else { return }
        packages[index].isRunning = running
    }

    private func visibleAppStorageKinds(device: AndroidDevice, package: AndroidPackage) async throws -> Set<AppStorageLocation.Kind> {
        var kinds = Set<AppStorageLocation.Kind>()
        for location in package.appStorageLocations {
            if package.storageSizeBytes(for: location) ?? 0 > 0 {
                kinds.insert(location.kind)
                continue
            }
            if location.kind == .userData || location.kind == .cache {
                continue
            }
            if try await fileRepository.directoryHasVisibleContent(device: device, path: location.path) {
                kinds.insert(location.kind)
            }
        }
        return kinds
    }

    private func safePackageFileName(_ packageName: String) -> String {
        packageName
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
    }

    private func refreshStorage() async throws {
        guard let device = selectedDevice else { throw FileOperationError.noDevice }
        let loadedSummaries = try await fileRepository.storageSummaries(device: device)
        try Task.checkCancellation()
        guard selectedDevice?.id == device.id else { return }
        storageSummaries = loadedSummaries
        let visibleSummaryIDs = Set(loadedSummaries.map(\.id))
        storageBreakdowns = storageBreakdowns.filter { visibleSummaryIDs.contains($0.key) }
        storageCategoryFileLists = storageCategoryFileLists.filter { visibleSummaryIDs.contains($0.value.summaryID) }
        if case .storage(let summaryID) = sidebarSelection, !visibleSummaryIDs.contains(summaryID) {
            let home = Self.defaultQuickLocations[0]
            currentPath = home.path
            sidebarSelection = .location(home)
        }
        // Storage category scans walk much of the phone and can monopolize the ADB
        // connection. Load them when the user opens Storage instead of delaying normal
        // file browsing in the background.
        cancelStorageCategoryPrefetch()
    }

    private func refreshBatteryStatus() async {
        guard let device = selectedDevice, device.state == .device else { return }
        await refreshBatteryStatus(for: device)
    }

    private func refreshBatteryStatus(for device: AndroidDevice) async {
        guard device.state == .device else { return }
        do {
            if let status = try await deviceManager.batteryStatus(device: device) {
                guard devices.contains(where: { $0.id == device.id && $0.state == .device }) else { return }
                batteryStatuses[device.id] = status
            }
        } catch {
            if devices.contains(where: { $0.id == device.id }) {
                batteryStatuses[device.id] = nil
            }
        }
    }

    private func refreshConnectedADBBatteryStatuses() async {
        for device in devices where device.state == .device {
            await refreshBatteryStatus(for: device)
        }
    }

    @discardableResult
    private func applyADBDeviceSnapshot(_ found: [AndroidDevice]) -> Bool {
        let hadReadyADBDevice = hasReadyADBDevice
        let previousSelectedDeviceID = selectedDeviceID
        devices = found
        let foundDeviceIDs = Set(found.map(\.id))
        batteryStatuses = batteryStatuses.filter { foundDeviceIDs.contains($0.key) }
        wirelessADBSetupStates = wirelessADBSetupStates.filter { deviceID, state in
            if foundDeviceIDs.contains(deviceID) || wirelessADBSetupTasks[deviceID] != nil {
                return true
            }
            if case .ready(let endpoint) = state {
                return foundDeviceIDs.contains(endpoint)
            }
            return false
        }

        let selectedDeviceIsReady = found.first { $0.id == selectedDeviceID }?.state == .device
        if selectedDeviceID == nil
            || !found.contains(where: { $0.id == selectedDeviceID })
            || !selectedDeviceIsReady {
            selectedDeviceID = found.first(where: { $0.state == .device })?.id
        }

        if previousSelectedDeviceID != selectedDeviceID {
            adbBackHistory.removeAll()
            adbForwardHistory.removeAll()
        }

        if selectedDevice?.state != .device {
            clearADBOnlyState()
            if hadReadyADBDevice, connectionMode == .adb {
                shouldShowADBSetupAfterConnectionModeSwitch = true
                sidebarSelection = nil
            }
        }

        return !hadReadyADBDevice && hasReadyADBDevice
    }

    private func prepareADBReadySurfaceForTransition() {
        shouldShowADBSetupAfterConnectionModeSwitch = false
        usbTransferManager.noteADBConnectionBecameReady()
        selectedFileIDs.removeAll()
        selectedPackageIDs.removeAll()

        if isUSBTransferSelected || sidebarSelection == nil {
            let home = Self.defaultQuickLocations[0]
            currentPath = home.path
            sidebarSelection = .location(home)
        }
    }

    private func connectionStatusMessage(adbDevices: [AndroidDevice]) -> String {
        if adbDevices.contains(where: { $0.state == .device }) {
            return "Ready."
        }

        if adbDevices.contains(where: { $0.state == .unauthorized }) {
            return "ADB authorization needed. Open Connection Status for details."
        }

        if adbDevices.contains(where: { $0.state == .offline }) {
            return "ADB device is offline. Open Connection Status for details."
        }

        if !usbTransferManager.devices.isEmpty {
            return "ADB not connected. File Transfer device detected."
        }

        if usbTransferManager.didEnumerateLocalDevices {
            return "No ADB or File Transfer device detected. Open Connection Status."
        }

        return "No ADB device found."
    }

    private func perform(_ message: String, operation: () async throws -> Void) async {
        guard !isPreparingForTermination else {
            statusMessage = "Quit is in progress."
            return
        }
        beginTrackedOperation(blocksTermination: true)
        defer { endTrackedOperation(blocksTermination: true) }
        statusMessage = message
        do {
            try await operation()
        } catch is CancellationError {
            return
        } catch {
            handleOperationError(error)
        }
    }

    func performCancellableRead(
        _ message: String,
        deviceScoped: Bool = true,
        operation: @escaping @MainActor () async throws -> Void
    ) async {
        guard !isPreparingForTermination else { return }

        let operationID = UUID()
        let deviceSessionRevision = adbDeviceSessionRevision
        beginTrackedOperation(blocksTermination: false)
        defer {
            cancellableReadTasks[operationID] = nil
            deviceScopedReadTaskIDs.remove(operationID)
            endTrackedOperation(blocksTermination: false)
        }
        statusMessage = message

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard !deviceScoped || deviceSessionRevision == self.adbDeviceSessionRevision else {
                    throw CancellationError()
                }
                try await operation()
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                guard !deviceScoped || deviceSessionRevision == self.adbDeviceSessionRevision else { return }
                handleOperationError(error)
            }
        }
        cancellableReadTasks[operationID] = task
        if deviceScoped {
            deviceScopedReadTaskIDs.insert(operationID)
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func cancelReadWorkForTermination() {
        cancelADBFolderLoading()
        Task { await thumbnailRequestScheduler.cancelAllWaitingRequests() }
        browserReconciliationTask?.cancel()
        browserReconciliationTask = nil
        for task in delayedTransferPresentationTasks.values {
            task.cancel()
        }
        delayedTransferPresentationTasks.removeAll()
        presentedDelayedTransferJobIDs.removeAll()
        for task in cancellableReadTasks.values {
            task.cancel()
        }
        for task in wirelessADBSetupTasks.values {
            task.cancel()
        }
        wirelessADBSetupTasks.removeAll()
        wirelessADBPreflightTask?.cancel()
        wirelessADBPreflightTask = nil
        searchTask?.cancel()
        searchTask = nil
        cacheMaintenanceTask?.cancel()
        cacheMaintenanceTask = nil
        cancelStorageCategoryPrefetch()
        for job in transferQueue.unfinishedJobs where job.kind == .preview {
            transferQueue.cancel(jobID: job.id)
        }
    }

    private func beginTrackedOperation(blocksTermination: Bool = true) {
        operationActivity.begin(blocksTermination: blocksTermination)
        isBusy = operationActivity.isBusy
    }

    private func cancelDeviceScopedReadWork() {
        for operationID in deviceScopedReadTaskIDs {
            cancellableReadTasks[operationID]?.cancel()
        }
    }

    private func endTrackedOperation(blocksTermination: Bool = true) {
        operationActivity.end(blocksTermination: blocksTermination)
        isBusy = operationActivity.isBusy
    }

    private func handleOperationError(_ error: Error) {
        switch error {
        case FileOperationError.noDevice:
            handleADBConnectionFailure()
        case FileOperationError.commandFailed(let message) where isADBConnectionFailure(message):
            handleADBConnectionFailure()
        case FileOperationError.commandFailed(let message):
            alert = UserAlert(title: commandFailureTitle(for: message), message: commandFailureMessage(for: message))
            statusMessage = commandFailureStatus(for: message)
        case FileOperationError.moveCompletedWithRecoveryCopy(_, let recoveryPath, let reason):
            alert = UserAlert(
                title: "Move Finished with a Recovery Copy",
                message: "The replaced item is safe at \(recoveryPath). \(reason)"
            )
            statusMessage = "Move finished. A replaced item was kept as a recovery copy."
        case FileOperationError.duplicateExists(let path):
            alert = UserAlert(title: "Duplicate Detected", message: "A file already exists at \(path). Rename it, delete it, or repeat the action with replace enabled.")
            statusMessage = "Duplicate detected."
        case FileOperationError.missingTool(let tool):
            if tool.caseInsensitiveCompare(ToolchainTool.adb.rawValue) == .orderedSame {
                adbRuntimeIssue = "Phone tools are not installed."
            }
            presentToolSetup(tool: ToolchainTool(rawValue: tool.lowercased()) ?? .adb, force: true)
        case FileOperationError.toolUnavailable(let tool, let reason):
            if isTransientToolTimeout(tool: tool, reason: reason) {
                presentTransientToolTimeout(reason)
            } else {
                if tool == .adb {
                    adbRuntimeIssue = reason
                }
                presentToolSetup(tool: tool, issue: reason, force: true)
            }
        default:
            alert = UserAlert(error: error)
            statusMessage = error.localizedDescription
        }
    }

    public func installManagedTools() async {
        guard let request = toolSetupRequest else { return }
        let previousADBMode = settings.adbToolMode
        let previousScrcpyMode = settings.scrcpyToolMode
        switch request.tool {
        case .adb:
            settings.adbToolMode = .automatic
        case .scrcpy:
            settings.scrcpyToolMode = .automatic
        }

        let installed = await toolchainManager.installManagedTools()
        guard installed else {
            settings.adbToolMode = previousADBMode
            settings.scrcpyToolMode = previousScrcpyMode
            await toolchainManager.refresh()
            return
        }
        guard toolchainManager.status(for: request.tool).isReady else {
            toolSetupRequest = ToolSetupRequest(
                id: request.id,
                tool: request.tool,
                issue: "The tools were installed, but \(request.tool.title) still could not be opened.",
                resumeAction: request.resumeAction
            )
            return
        }
        _ = await completeToolSetupIfUsable(request)
    }

    public func useExistingTool(_ url: URL, for tool: ToolchainTool) async {
        guard let request = toolSetupRequest else { return }
        toolchainManager.clearInstallError()
        switch tool {
        case .adb:
            settings.adbToolPath = url.path
            settings.adbToolMode = .custom
        case .scrcpy:
            settings.scrcpyToolPath = url.path
            settings.scrcpyToolMode = .custom
        }
        await toolchainManager.refresh()

        if toolchainManager.status(for: tool).isReady {
            _ = await completeToolSetupIfUsable(request)
            return
        }

        let issue: String
        switch toolchainManager.status(for: tool) {
        case .needsRepair(let message):
            issue = message
        case .missing:
            issue = "That file could not be used. Choose the \(tool.executableName) executable itself."
        default:
            issue = "That copy did not pass its version check."
        }
        toolSetupRequest = ToolSetupRequest(
            id: request.id,
            tool: tool,
            issue: issue,
            resumeAction: request.resumeAction
        )
    }

    public func retryToolSetup() async {
        guard let request = toolSetupRequest else { return }
        toolchainManager.clearInstallError()
        await toolchainManager.refresh()
        guard toolchainManager.status(for: request.tool).isReady else {
            let issue: String
            switch toolchainManager.status(for: request.tool) {
            case .missing:
                issue = "\(request.tool.title) still could not be found."
            case .needsRepair(let message):
                issue = message
            default:
                issue = request.issue ?? "The tool is not ready yet."
            }
            toolSetupRequest = ToolSetupRequest(
                id: request.id,
                tool: request.tool,
                issue: issue,
                resumeAction: request.resumeAction
            )
            return
        }
        _ = await completeToolSetupIfUsable(request)
    }

    public func useManagedToolsForCurrentRequest() async {
        guard let request = toolSetupRequest else { return }
        toolchainManager.clearInstallError()
        switch request.tool {
        case .adb:
            settings.adbToolMode = .automatic
        case .scrcpy:
            settings.scrcpyToolMode = .automatic
        }
        await toolchainManager.refresh()
        if toolchainManager.status(for: request.tool).isReady {
            _ = await completeToolSetupIfUsable(request)
        } else {
            toolSetupRequest = ToolSetupRequest(
                id: request.id,
                tool: request.tool,
                issue: "The managed copy needs repair.",
                resumeAction: request.resumeAction
            )
        }
    }

    public func dismissToolSetup() {
        if let tool = toolSetupRequest?.tool {
            suppressedToolSetup.insert(tool)
        }
        toolSetupRequest = nil
    }

    public func toolSetupSheetDidDismiss() {
        guard let dismissed = lastPresentedToolSetup else { return }
        lastPresentedToolSetup = nil

        if programmaticToolSetupDismissalID == dismissed.id {
            programmaticToolSetupDismissalID = nil
            let resume = pendingToolSetupResume?.id == dismissed.id ? pendingToolSetupResume : nil
            pendingToolSetupResume = nil
            if let resume {
                Task { await resumeToolSetupAction(resume.action) }
            }
        } else {
            suppressedToolSetup.insert(dismissed.tool)
        }
    }

    public func requestPhoneToolsSetup(for tool: ToolchainTool = .adb) {
        presentToolSetup(tool: tool, issue: tool == .adb ? adbRuntimeIssue : nil, force: true)
    }

    private func presentToolSetup(
        tool: ToolchainTool,
        issue: String? = nil,
        resumeAction: ToolSetupResumeAction = .none,
        force: Bool = false
    ) {
        statusMessage = tool == .adb
            ? "Phone tools need setup. File Transfer is still available."
            : "Phone Control needs setup."
        if force {
            suppressedToolSetup.remove(tool)
        } else if suppressedToolSetup.contains(tool) {
            return
        }
        guard lastPresentedToolSetup == nil else { return }
        guard toolSetupRequest == nil else { return }
        let request = ToolSetupRequest(tool: tool, issue: issue, resumeAction: resumeAction)
        toolSetupRequest = request
        lastPresentedToolSetup = (request.id, tool)
        Task { await toolchainManager.refresh() }
    }

    private func completeToolSetup(_ request: ToolSetupRequest) {
        suppressedToolSetup.remove(request.tool)
        if request.tool == .adb {
            adbRuntimeIssue = nil
        }
        programmaticToolSetupDismissalID = request.id
        pendingToolSetupResume = (request.id, request.resumeAction)
        toolSetupRequest = nil
        statusMessage = "Phone tools are ready."
    }

    @discardableResult
    private func completeToolSetupIfUsable(_ request: ToolSetupRequest) async -> Bool {
        do {
            switch request.tool {
            case .adb:
                try await adb.validateADB()
            case .scrcpy:
                try await adb.validatePhoneControlTools()
            }
            completeToolSetup(request)
            return true
        } catch FileOperationError.toolUnavailable(let tool, let reason) {
            if tool == .adb {
                adbRuntimeIssue = reason
            }
            lastPresentedToolSetup = (request.id, tool)
            toolSetupRequest = ToolSetupRequest(
                id: request.id,
                tool: tool,
                issue: reason,
                resumeAction: request.resumeAction
            )
        } catch FileOperationError.missingTool(let name) {
            let missingTool = ToolchainTool(rawValue: name.lowercased()) ?? request.tool
            if missingTool == .adb {
                adbRuntimeIssue = "Phone tools are not installed."
            }
            lastPresentedToolSetup = (request.id, missingTool)
            toolSetupRequest = ToolSetupRequest(
                id: request.id,
                tool: missingTool,
                issue: "The selected copy could not be found.",
                resumeAction: request.resumeAction
            )
        } catch {
            toolSetupRequest = ToolSetupRequest(
                id: request.id,
                tool: request.tool,
                issue: "The selected copy could not be opened.",
                resumeAction: request.resumeAction
            )
        }
        return false
    }

    private func resumeToolSetupAction(_ action: ToolSetupResumeAction) async {
        switch action {
        case .none:
            break
        case .refreshDevices:
            await refreshDevices()
        case .phoneControl:
            await launchScrcpy()
        }
    }

    private func canUseADBFileBrowser() -> Bool {
        guard hasReadyADBDevice else {
            connectionMode = .adb
            selectedFileIDs.removeAll()
            sidebarSelection = nil
            statusMessage = "ADB is not connected. Follow the setup steps to connect with USB debugging or QR pairing."
            return false
        }
        return true
    }

    private func canUseADBDestination(named name: String) -> Bool {
        guard hasReadyADBDevice else {
            connectionMode = .adb
            clearADBOnlyState()
            sidebarSelection = nil
            statusMessage = "\(name) requires ADB. Follow the setup steps to connect with USB debugging or QR pairing."
            return false
        }
        return true
    }

    private func handleADBConnectionFailure() {
        clearADBOnlyState(clearDevices: true)
        connectionMode = .adb
        sidebarSelection = nil
        statusMessage = "ADB is not connected."
        alert = UserAlert(
            title: "ADB Not Connected",
            message: "This folder requires ADB. Connect with USB debugging, pair over Wireless debugging with QR code, or switch the connection mode to File Transfer for limited file access."
        )
    }

    private func resetADBSessionStateForDeviceChange() {
        cancelADBFolderLoading()
        browserReconciliationTask?.cancel()
        browserReconciliationTask = nil
        browserReconciliationRequestID = nil
        pendingBrowserReconciliationPaths.removeAll()
        browserMutationRevisionsByPath.removeAll()
        activeBrowserMutationCountsByPath.removeAll()
        adbBackHistory.removeAll()
        adbForwardHistory.removeAll()
        adbFolderListingsByPath.removeAll()
        treeChildrenByPath.removeAll()
        expandedTreePaths.removeAll()
        files.removeAll()
        selectedFileIDs.removeAll()
        lastSelectedFileID = nil
        keyboardSelectionAnchorFileID = nil
        lastSelectionFileOrder.removeAll()
        cancelInlineRename()
        searchTask?.cancel()
        searchTask = nil
        searchResults.removeAll()
        cancelStorageCategoryPrefetch()
        storageSummaries.removeAll()
        storageBreakdowns.removeAll()
        storageCategoryFileLists.removeAll()
        selectedStorageCategoryID = nil
        packages.removeAll()
        selectedPackageIDs.removeAll()
        lastSelectedPackageID = nil
        appFolderContext = nil
        selectedAppStorageLocation = nil
        expandedStorageAppPackageIDs.removeAll()
        loadingStorageAppPackageIDs.removeAll()
        packageLoadRevision &+= 1
        captureAppChoices.removeAll()
        captureAppChoicesDeviceSerial = nil
        thumbnailURLs.removeAll()
        thumbnailCacheKeysByFileID.removeAll()
        requestedThumbnailCacheKeysByFileID.removeAll()
        loadingThumbnailIDs.removeAll()
        mediaMetadataByFileID.removeAll()
        loadingMediaMetadataFileIDs.removeAll()
        failedMediaMetadataFileMessages.removeAll()
        folderSizeBytesByPath.removeAll()
        loadingFolderSizePaths.removeAll()
        failedFolderSizePaths.removeAll()
        fileUndoStack.removeAll()
        fileRedoStack.removeAll()
        fileHistoryRevision &+= 1
    }

    private func invalidateADBDeviceSession() {
        adbDeviceSessionRevision &+= 1
        cancelDeviceScopedReadWork()
        resetADBSessionStateForDeviceChange()
    }

    private func clearADBOnlyState(clearDevices: Bool = false) {
        cancelADBFolderLoading()
        browserReconciliationTask?.cancel()
        browserReconciliationTask = nil
        browserReconciliationRequestID = nil
        pendingBrowserReconciliationPaths.removeAll()
        browserMutationRevisionsByPath.removeAll()
        activeBrowserMutationCountsByPath.removeAll()
        adbBackHistory.removeAll()
        adbForwardHistory.removeAll()
        cancelStorageCategoryPrefetch()
        if clearDevices {
            devices.removeAll()
            selectedDeviceID = nil
        }
        files = []
        adbFolderListingsByPath.removeAll()
        treeChildrenByPath.removeAll()
        expandedTreePaths.removeAll()
        folderSizeBytesByPath = [:]
        loadingFolderSizePaths = []
        failedFolderSizePaths = []
        packages = []
        captureAppChoices = []
        captureAppChoicesDeviceSerial = nil
        storageSummaries = []
        storageBreakdowns = [:]
        storageCategoryFileLists = [:]
        selectedStorageCategoryID = nil
        expandedStorageAppPackageIDs = []
        loadingStorageAppPackageIDs = []
        loadingStorageBreakdownID = nil
        loadingStorageCategoryID = nil
        prefetchingStorageBreakdownIDs = []
        prefetchingStorageCategoryIDs = []
        isPrefetchingStorageCategories = false
        batteryStatuses = [:]
        selectedFileIDs.removeAll()
        selectedPackageIDs.removeAll()
    }

    private func invalidateFolderSizes(under path: String) {
        let normalizedPath = normalizedFolderCachePath(path)
        cancelFolderSizeWorker(clearQueue: true)
        if normalizedPath == "/" {
            folderSizeBytesByPath.removeAll()
            loadingFolderSizePaths.removeAll()
            failedFolderSizePaths.removeAll()
            return
        }

        let prefix = "\(normalizedPath)/"
        folderSizeBytesByPath = folderSizeBytesByPath.filter { key, _ in
            key != normalizedPath && !key.hasPrefix(prefix)
        }
        loadingFolderSizePaths = loadingFolderSizePaths.filter { key in
            key != normalizedPath && !key.hasPrefix(prefix)
        }
        failedFolderSizePaths = failedFolderSizePaths.filter { key in
            key != normalizedPath && !key.hasPrefix(prefix)
        }
    }

    private func normalizedFolderCachePath(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result.isEmpty ? "/" : result
    }

    private func refreshUSBTransferSoon() {
        DispatchQueue.main.async { [usbTransferManager] in
            usbTransferManager.refresh()
        }
    }

    private func requestUSBTransferAccessAfterMissingADBDevice() {
        guard !hasReadyADBDevice else { return }
        statusMessage = "Developer Options unavailable. Checking File Transfer..."
        if usbTransferManager.hasStartedBrowsing {
            usbTransferManager.refresh()
        } else {
            usbTransferManager.startBrowsingIfNeeded()
        }
    }

    private func isADBConnectionFailure(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("no devices/emulators found")
            || lowercased.contains("device not found")
            || lowercased.contains("device offline")
            || lowercased.contains("unauthorized")
            || lowercased.contains("closed")
    }

    private func commandFailureTitle(for message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("took too long") {
            return "Device Didn’t Respond"
        }
        if lowercased.contains("permission denied") {
            return "Folder Unavailable"
        }
        if lowercased.contains("no such file") || lowercased.contains("not found") {
            return "Item Not Found"
        }
        return "Android Command Failed"
    }

    private func commandFailureMessage(for message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("took too long") {
            return "The device did not respond in time. It may still finish the change. Wait a moment, then try again."
        }
        if trimmed.localizedCaseInsensitiveContains("permission denied") {
            return "\(trimmed)\n\nAndroid blocked access to this location. Shared storage folders are usually available; protected app-private folders may require a debuggable app, root, or a different access method."
        }
        return trimmed.isEmpty ? "Android did not return an error message." : trimmed
    }

    private func isTransientToolTimeout(tool: ToolchainTool, reason: String) -> Bool {
        tool == .adb && reason.localizedCaseInsensitiveContains("took too long")
    }

    private func presentTransientToolTimeout(_ reason: String) {
        alert = UserAlert(
            title: commandFailureTitle(for: reason),
            message: commandFailureMessage(for: reason)
        )
        statusMessage = "The device did not respond in time."
    }

    private func scrcpyFailureMessage(for message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Phone Control closed during startup. Check the phone connection and try again."
        }
        let lowercased = trimmed.lowercased()
        if lowercased.contains("unauthorized") {
            return "Unlock the phone and approve USB debugging, then try again."
        }
        if lowercased.contains("offline") || lowercased.contains("device not found") {
            return "The phone disconnected before Phone Control opened. Reconnect it and try again."
        }
        let logPath = trimmed
            .components(separatedBy: "\n")
            .last(where: { $0.hasPrefix("Log: ") })?
            .dropFirst("Log: ".count)
        if let logPath, !logPath.isEmpty {
            return "Phone Control closed during startup. Try again or repair Phone Tools in Settings → Tools.\n\nDetails were saved to \(logPath)."
        }
        return "Phone Control closed during startup. Try again or repair Phone Tools in Settings → Tools."
    }

    private func commandFailureStatus(for message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("permission denied") {
            return "Folder unavailable."
        }
        if lowercased.contains("no such file") || lowercased.contains("not found") {
            return "Item not found."
        }
        return "Android command failed."
    }

    private func confirmUninstall(packages: [AndroidPackage]) -> Bool {
        guard settings.confirmBeforeUninstallingApps else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = packages.count == 1 ? "Uninstall \(packages[0].packageName)?" : "Uninstall \(packages.count) apps?"
        alert.informativeText = "This removes the selected app\(packages.count == 1 ? "" : "s") from the Android device."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func promptDuplicateResolution(itemNames: [String], destination: String) -> TransferConflictResolution? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = itemNames.count == 1 ? "An item named \(itemNames[0]) already exists." : "\(itemNames.count) items already exist."
        let sample = itemNames.prefix(6).joined(separator: ", ")
        let suffix = itemNames.count > 6 ? " and \(itemNames.count - 6) more" : ""
        alert.informativeText = "Choose how to handle duplicates in \(destination).\n\n\(sample)\(suffix)"
        alert.addButton(withTitle: TransferConflictResolution.keep.label)
        alert.addButton(withTitle: TransferConflictResolution.skip.label)
        alert.addButton(withTitle: TransferConflictResolution.replace.label)
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .keep
        case .alertSecondButtonReturn:
            return .skip
        case .alertThirdButtonReturn:
            return .replace
        default:
            return nil
        }
    }

    private func confirmCrossDeviceCutDelete(count: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1 ? "Move the original item to Trash?" : "Move the original \(count) items to Trash?"
        alert.informativeText = "The copy to the other Android device completed. To finish the cut operation, ASOP File Browser can move the source item\(count == 1 ? "" : "s") into its app-managed Trash on the original device."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep Originals")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func localUploadRequest(for url: URL, remoteName: String, replace: Bool) throws -> LocalUploadRequest {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values.isDirectory == true {
            let contents = try localUploadContents(in: url)
            return LocalUploadRequest(
                url: url,
                remoteName: remoteName,
                replace: replace,
                isDirectory: true,
                directories: contents.directories,
                files: contents.files
            )
        }

        return LocalUploadRequest(
            url: url,
            remoteName: remoteName,
            replace: replace,
            isDirectory: false,
            directories: [],
            files: [
                LocalUploadFile(
                    url: url,
                    relativeDirectory: "",
                    remoteName: remoteName,
                    size: values.fileSize.map(Int64.init)
                )
            ]
        )
    }

    private func localUploadContents(in directory: URL) throws -> (directories: [String], files: [LocalUploadFile]) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }

        var directories: [String] = []
        var files: [LocalUploadFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let relativePath = relativePath(for: url, under: directory)
            if values.isDirectory == true {
                if !relativePath.isEmpty {
                    directories.append(relativePath)
                }
                continue
            }

            files.append(
                LocalUploadFile(
                    url: url,
                    relativeDirectory: (relativePath as NSString).deletingLastPathComponent,
                    remoteName: url.lastPathComponent,
                    size: values.fileSize.map(Int64.init)
                )
            )
        }

        let sortedDirectories = directories.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let sortedFiles = files.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        return (sortedDirectories, sortedFiles)
    }

    private func relativePath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func localDirectoryNames(_ directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private func confirmForceStop(packages: [AndroidPackage]) -> Bool {
        let systemPackages = packages.filter { $0.kind == .system }
        guard !systemPackages.isEmpty else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if systemPackages.count == 1 {
            alert.messageText = "Force close system app \(systemPackages[0].packageName)?"
        } else {
            alert.messageText = "Force close \(systemPackages.count) system apps?"
        }
        alert.informativeText = "Force closing system apps can interrupt Android services, notifications, syncing, or device stability. Only continue if you know this app is safe to stop."
        alert.addButton(withTitle: "Force Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmClearStorage(package: AndroidPackage) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Clear storage for \(package.packageName)?"
        alert.informativeText = "This resets the app as if it was freshly installed. It clears user data, sign-ins, settings, databases, downloaded app files, and cache for this Android user. This cannot be undone from this app."
        alert.addButton(withTitle: "Clear Storage")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func trashRecordsURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "AndroidFileBrowser", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "trash-records.json")
    }

    private static func loadTrashRecords(from storage: TrashRecordsStorage) -> [TrashRecord] {
        do {
            let url: URL
            switch storage {
            case .applicationSupport:
                url = try trashRecordsURL()
            case .file(let fileURL):
                url = fileURL
            case .memoryOnly:
                return []
            }
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([TrashRecord].self, from: data)
        } catch {
            return []
        }
    }

    private func saveTrashRecords(_ records: [TrashRecord]) throws {
        let url: URL
        switch trashRecordsStorage {
        case .applicationSupport:
            url = try Self.trashRecordsURL()
        case .file(let fileURL):
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            url = fileURL
        case .memoryOnly:
            return
        }
        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: .atomic)
    }

    private func replaceTrashRecords(_ records: [TrashRecord]) throws {
        do {
            try saveTrashRecords(records)
            trashRecords = records
        } catch {
            throw FileOperationError.commandFailed(
                "Trash information could not be saved on this Mac. \(error.localizedDescription)"
            )
        }
    }

    private func trashAndRecord(device: AndroidDevice, file: AndroidFile) async throws -> TrashRecord {
        let record = try await fileRepository.trash(device: device, file: file)
        var updatedRecords = trashRecords
        updatedRecords.append(record)
        updatedRecords.sort { $0.deletedAt > $1.deletedAt }

        do {
            try replaceTrashRecords(updatedRecords)
            return record
        } catch {
            do {
                try await fileRepository.restore(device: device, record: record, replace: false)
            } catch let restoreError {
                throw FileOperationError.commandFailed(
                    "\(file.name) was moved to \(record.trashPath), but its Trash record could not be saved and the original location could not be restored. Reconnect the phone and move that item back manually. \(restoreError.localizedDescription)"
                )
            }
            throw FileOperationError.commandFailed(
                "Trash information could not be saved, so \(file.name) was returned to its original location. \(error.localizedDescription)"
            )
        }
    }
}

public struct UserAlert: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let onDismiss: (@MainActor () -> Void)?

    public init(
        title: String,
        message: String,
        onDismiss: (@MainActor () -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.onDismiss = onDismiss
    }

    public init(error: Error) {
        self.title = "Something went wrong"
        self.message = error.localizedDescription
        self.onDismiss = nil
    }
}
