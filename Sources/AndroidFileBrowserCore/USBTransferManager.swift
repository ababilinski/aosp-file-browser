import AppKit
import Foundation
import MTPKit
import UniformTypeIdentifiers
@preconcurrency import ImageCaptureCore

private struct USBLocalUploadFile: Sendable {
    let url: URL
    let relativeDirectory: String
    let remoteName: String
    let size: Int64?
}

private struct USBLocalUploadRequest: Sendable {
    let url: URL
    var remoteName: String
    var replace: Bool
    let isDirectory: Bool
    let files: [USBLocalUploadFile]

    var totalBytes: Int64? {
        let knownSizes = files.compactMap(\.size)
        guard knownSizes.count == files.count else { return nil }
        return knownSizes.reduce(0, +)
    }
}

@MainActor
private final class QueuedMTPFolderUploadContext {
    let storageID: String
    var rootNodeID: String?
    private var directoryIDs: [String: String] = [:]

    init(storageID: String) {
        self.storageID = storageID
    }

    func installRootNodeID(_ nodeID: String) {
        rootNodeID = nodeID
        directoryIDs[""] = nodeID
    }

    func parentID(for relativeDirectory: String, transport: MTPTransport) async throws -> String {
        guard let rootNodeID else {
            throw FileOperationError.commandFailed("The folder upload was not prepared.")
        }
        guard !relativeDirectory.isEmpty else { return rootNodeID }

        var parentID = rootNodeID
        var accumulatedComponents: [String] = []
        for component in relativeDirectory.split(separator: "/").map(String.init) {
            accumulatedComponents.append(component)
            let key = accumulatedComponents.joined(separator: "/")
            if let cachedID = directoryIDs[key] {
                parentID = cachedID
                continue
            }

            let node = try await transport.createDirectory(named: component, inParent: parentID, in: storageID)
            directoryIDs[key] = node.id
            parentID = node.id
        }
        return parentID
    }
}

private struct MTPPathState: Sendable, Equatable {
    let storageID: String?
    let parentID: String?
    let path: String
}

private struct MTPFolderListingKey: Hashable, Sendable {
    let storageID: String?
    let parentID: String?
    let path: String
}

enum MTPObservedRefreshScope: Hashable, Sendable {
    case storageList
    case folder(storageID: String, parentID: String?)
    case allVisibleFolders
}

private struct USBFolderNavigationSnapshot: Sendable, Equatable {
    let pathComponents: [USBTransferPathComponent]
    let currentContainerID: USBTransferItem.ID?
    let currentMTPStorageID: String?
    let currentMTPParentID: String?
    let mtpPathStates: [USBTransferPathComponent.ID: MTPPathState]
}

private struct MTPDownloadRequest: Sendable {
    let item: USBTransferItem
    let nodeID: String
}

private final class MTPAggregateDownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var completedBytes: Int64 = 0
    let totalBytes: Int64?

    init(totalBytes: Int64?) {
        self.totalBytes = totalBytes
    }

    func baseCompletedBytes() -> Int64 {
        lock.withLock { completedBytes }
    }

    func commit(bytes: Int64) {
        lock.withLock {
            completedBytes += max(0, bytes)
        }
    }

    func aggregateProgress(fileName: String, fileProgress: TransferProgress, base: Int64) -> TransferProgress {
        TransferProgress(
            fileName: fileName,
            completedBytes: base + fileProgress.completedBytes,
            totalBytes: totalBytes ?? 0
        )
    }
}

private struct MTPDeleteRequest: Sendable {
    let item: USBTransferItem
    let nodeID: String
}

private struct MTPUploadTarget: Sendable {
    let storageID: String
    let parentID: String?
    let displayPath: String
    let refreshesCurrentListing: Bool
}

private struct MTPFolderCreationTarget: Sendable {
    let storageID: String
    let parentID: String?
    let displayPath: String
    let parentItemID: USBTransferItem.ID?
    let listingKey: MTPFolderListingKey
}

private struct SendableCameraFolder: @unchecked Sendable {
    let folder: ICCameraFolder
}

@MainActor
private final class MTPMoveOperationState {
    var jobID: UUID?
    var completedRequestIDs = Set<USBTransferItem.ID>()
}

private struct MTPArchiveNodeRequest: Sendable {
    let item: USBTransferItem
    let node: FileNode
}

private struct MTPQuickAccessDefinition: Sendable {
    let id: String
    let title: String
    let symbol: String
    let candidates: [[String]]
}

private actor MTPQuickLocationResolver {
    private let transport: MTPTransport
    private let storage: StorageInfo
    private var childrenByParentKey: [String: [FileNode]] = [:]

    init(transport: MTPTransport, storage: StorageInfo) {
        self.transport = transport
        self.storage = storage
    }

    func resolve(_ components: [String]) async -> (node: FileNode, relativePath: String)? {
        guard !components.isEmpty else { return nil }
        var parentID: String?
        var matched: FileNode?
        var matchedComponents: [String] = []

        for component in components {
            do {
                let children = try await children(of: parentID)
                guard let node = children.first(where: {
                    $0.isDirectory
                        && $0.name.compare(component, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }) else {
                    return nil
                }
                matched = node
                matchedComponents.append(node.name)
                parentID = node.id
            } catch {
                return nil
            }
        }

        guard let matched else { return nil }
        return (matched, matchedComponents.joined(separator: "/"))
    }

    private func children(of parentID: String?) async throws -> [FileNode] {
        let key = parentID ?? "__root__"
        if let cached = childrenByParentKey[key] {
            return cached
        }
        let children = try await transport.listChildren(of: parentID, in: storage.id)
        childrenByParentKey[key] = children
        return children
    }
}

public enum USBTransferRecoveryAction: Equatable, Sendable {
    case releaseADB
    case releaseMacOSCameraService
    case resetMTPConnection
}

public struct USBTransferAccessIssue: Equatable, Sendable {
    public var title: String
    public var message: String
    public var statusMessage: String
    public var actionTitle: String?
    public var recoveryAction: USBTransferRecoveryAction?

    public var canRunRecoveryAction: Bool {
        recoveryAction != nil
    }

    static func adbExclusiveOwner(device: USBDeviceAccessSnapshot) -> USBTransferAccessIssue {
        return USBTransferAccessIssue(
            title: "File Transfer Couldn't Start",
            message: "Another connection is using \(device.displayName). Pause Phone Tools, then try File Transfer again.",
            statusMessage: "Pause Phone Tools, then try File Transfer again.",
            actionTitle: "Pause and Retry",
            recoveryAction: .releaseADB
        )
    }

    static func macOSCameraOwner(interface: USBInterfaceAccessSnapshot) -> USBTransferAccessIssue {
        return USBTransferAccessIssue(
            title: "File Transfer Is Busy",
            message: "macOS is checking \(interface.displayName) for photos. AOSP File Manager can try the connection again.",
            statusMessage: "File Transfer is busy. Try the connection again.",
            actionTitle: "Try Again",
            recoveryAction: .releaseMacOSCameraService
        )
    }

    static func mtpOpenFailed(interface: USBInterfaceAccessSnapshot) -> USBTransferAccessIssue {
        USBTransferAccessIssue(
            title: "File Transfer Couldn't Start",
            message: "Unplug and reconnect \(interface.displayName), keep File transfer / Android Auto selected, then try again.",
            statusMessage: "File Transfer is visible but couldn't be opened.",
            actionTitle: "Try Again",
            recoveryAction: .releaseMacOSCameraService
        )
    }

    static func mtpStorageLoadFailed(interface: USBInterfaceAccessSnapshot, error: Error) -> USBTransferAccessIssue {
        USBTransferAccessIssue(
            title: "Phone Storage Couldn't Load",
            message: "\(interface.displayName) is in File Transfer mode, but its storage couldn't be opened. \(error.localizedDescription)",
            statusMessage: "File Transfer is connected, but phone storage couldn't be loaded.",
            actionTitle: "Try Again",
            recoveryAction: .releaseMacOSCameraService
        )
    }

    static func mtpConnectionLost(error: Error) -> USBTransferAccessIssue {
        USBTransferAccessIssue(
            title: "File Transfer Disconnected",
            message: "The phone stopped responding during File Transfer. AOSP File Manager can reset the USB connection and reconnect without switching to read-only photo access. \(error.friendlyMessage)",
            statusMessage: "File Transfer disconnected. Reconnecting…",
            actionTitle: "Reconnect",
            recoveryAction: .resetMTPConnection
        )
    }
}

public final class USBTransferManager: NSObject, ObservableObject, @unchecked Sendable, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    @Published public var devices: [USBTransferDevice] = []
    @Published public var selectedDeviceID: USBTransferDevice.ID?
    @Published public var pathComponents: [USBTransferPathComponent] = []
    @Published public var items: [USBTransferItem] = []
    @Published public var selectedItemIDs = Set<USBTransferItem.ID>()
    @Published public private(set) var quickLocations: [MTPQuickLocation] = []
    @Published public private(set) var isResolvingQuickLocations = false
    @Published public var searchText = ""
    @Published public var searchKindFilter: FileSearchKindFilter = .any
    @Published public var searchDateFilter: FileSearchDateFilter = .any
    @Published public var sort: USBTransferSort = .name
    @Published public var sortAscending = true
    @Published public var sortDescriptors: [USBTransferSortDescriptor] = [
        USBTransferSortDescriptor(sort: .name, ascending: true)
    ]
    @Published public var expandedFolderItemIDs = Set<USBTransferItem.ID>()
    @Published public private(set) var treeChildrenByItemID: [USBTransferItem.ID: [USBTransferItem]] = [:]
    @Published public private(set) var loadingTreeItemIDs = Set<USBTransferItem.ID>()
    private var treeLoadRequestIDs: [USBTransferItem.ID: UUID] = [:]
    @Published public private(set) var mediaMetadataByItemID: [USBTransferItem.ID: RemoteFileMetadata] = [:]
    @Published public private(set) var loadingMediaMetadataItemIDs = Set<USBTransferItem.ID>()
    @Published public private(set) var failedMediaMetadataItemMessages: [USBTransferItem.ID: String] = [:]
    private var thumbnailURLs: [USBTransferItem.ID: URL] = [:]
    private var loadingThumbnailItemIDs = Set<USBTransferItem.ID>()
    @Published public private(set) var folderSizeBytesByItemID: [USBTransferItem.ID: Int64] = [:]
    @Published public private(set) var loadingFolderSizeItemIDs = Set<USBTransferItem.ID>()
    @Published public private(set) var failedFolderSizeItemIDs = Set<USBTransferItem.ID>()
    @Published public var isBrowsing = false
    @Published public var isCataloging = false
    @Published public private(set) var isShowingCachedMTPListing = false
    @Published public var isDownloading = false
    @Published public var didEnumerateLocalDevices = false
    @Published public private(set) var hasStartedBrowsing = false
    @Published public private(set) var backend: USBTransferBackend = .notChecked
    @Published public var statusMessage = "Looking for USB transfer devices."
    @Published public var alert: UserAlert?
    @Published public var isCreatingMTPFolder = false
    private var pendingMTPFolderCreationTarget: MTPFolderCreationTarget?
    @Published public var pendingMTPRenameItem: USBTransferItem?
    @Published public var inlineRenameItemID: USBTransferItem.ID?
    @Published var pendingMTPArchiveRequest: ArchiveCreationRequest?
    @Published public private(set) var mtpAccessIssue: USBTransferAccessIssue?
    @Published public private(set) var isReleasingADBForMTP = false
    @Published public private(set) var isRecoveringMTPConnection = false
    @Published public private(set) var isADBReleasedForMTPSession = false

    private let browser = ICDeviceBrowser()
    private var cameras: [USBTransferDevice.ID: ICCameraDevice] = [:]
    private var itemObjects: [USBTransferItem.ID: ICCameraItem] = [:]
    private var startedBrowsing = false
    private var imageCaptureStarted = false
    private var currentContainerID: USBTransferItem.ID?
    private var mtpTransport: MTPTransport?
    private var mtpStorages: [StorageInfo] = []
    private var mtpStorageItems: [USBTransferItem.ID: StorageInfo] = [:]
    private var mtpNodes: [USBTransferItem.ID: FileNode] = [:]
    private var mtpPathStates: [USBTransferPathComponent.ID: MTPPathState] = [:]
    private var backHistory: [USBFolderNavigationSnapshot] = []
    private var forwardHistory: [USBFolderNavigationSnapshot] = []
    private var currentMTPStorageID: String?
    private var currentMTPParentID: String?
    private var mtpFolderListingsByKey: [MTPFolderListingKey: [USBTransferItem]] = [:]
    private var visibleMTPListingKey: MTPFolderListingKey?
    private var mtpListingRequestID: UUID?
    private var mtpBrowserMutationDepth = 0
    private var pendingMTPObservedRefreshScopes = Set<MTPObservedRefreshScope>()
    private var mtpObservedRefreshTask: Task<Void, Never>?
    private var mtpChangeTask: Task<Void, Never>?
    private var lastSelectedItemID: USBTransferItem.ID?
    private var keyboardSelectionAnchorItemID: USBTransferItem.ID?
    private var lastSelectionItemOrder: [USBTransferItem] = []
    private var inlineRenameBlockedBySelectionItemID: USBTransferItem.ID?
    private var pendingDownloads = 0
    private var completedDownloads = 0
    private var failedDownloads = 0
    @MainActor private var terminationBlockingActivityCount = 0
    private var adbReleaseHandler: (@Sendable () async -> Bool)?
    private weak var transferQueue: TransferQueue?
    private var delayedMovePresentationTasks: [UUID: Task<Void, Never>] = [:]
    private var presentedDelayedMoveJobIDs = Set<UUID>()
    private var pendingInlineRenameWorkItem: DispatchWorkItem?
    private let thumbnailService = ThumbnailService()
    private var previewCacheStore = AppCacheStore()
    private var previewEncryptionEnabled: @MainActor () -> Bool = { false }
    private var thumbnailCacheKeysByItemID: [USBTransferItem.ID: String] = [:]
    private var previewPreparationTasks: [String: Task<Void, Error>] = [:]
    private var calculatesFolderSizes = true
    private var folderSizeQueue: [USBTransferItem] = []
    private var queuedFolderSizeItemIDs = Set<USBTransferItem.ID>()
    private var folderSizeWorkerTask: Task<Void, Never>?
    private var folderSizeWorkerGeneration = 0

    private static let mtpQuickAccessDefinitions: [MTPQuickAccessDefinition] = [
        MTPQuickAccessDefinition(id: "downloads", title: "Downloads", symbol: "arrow.down.circle", candidates: [["Download"], ["Downloads"]]),
        MTPQuickAccessDefinition(id: "music", title: "Music", symbol: "music.note", candidates: [["Music"], ["Audio"]]),
        MTPQuickAccessDefinition(id: "pictures", title: "Pictures", symbol: "photo", candidates: [["Pictures"], ["DCIM"], ["DCIM", "Camera"]]),
        MTPQuickAccessDefinition(id: "dcim", title: "Camera", symbol: "camera", candidates: [["DCIM", "Camera"], ["DCIM"], ["Pictures", "Camera"]]),
        MTPQuickAccessDefinition(id: "movies", title: "Movies", symbol: "film", candidates: [["Movies"], ["DCIM", "Camera"]]),
        MTPQuickAccessDefinition(id: "android-media", title: "App Media", symbol: "square.stack.3d.up", candidates: [["Android", "media"]]),
        MTPQuickAccessDefinition(id: "android-data", title: "App Data", symbol: "app.badge", candidates: [["Android", "data"]]),
        MTPQuickAccessDefinition(id: "android-obb", title: "App OBB", symbol: "shippingbox", candidates: [["Android", "obb"]])
    ]

    deinit {
        mtpChangeTask?.cancel()
        mtpObservedRefreshTask?.cancel()
        folderSizeWorkerTask?.cancel()
        for task in delayedMovePresentationTasks.values {
            task.cancel()
        }
        browser.stop()
    }

    public var selectedDevice: USBTransferDevice? {
        devices.first { $0.id == selectedDeviceID } ?? devices.first
    }

    @MainActor public var hasTerminationBlockingActivity: Bool {
        terminationBlockingActivityCount > 0
    }

    @MainActor func beginTerminationBlockingActivity() {
        terminationBlockingActivityCount += 1
    }

    @MainActor func endTerminationBlockingActivity() {
        precondition(terminationBlockingActivityCount > 0, "Cannot finish a USB operation that was not started.")
        terminationBlockingActivityCount -= 1
    }

    public var selectedItem: USBTransferItem? {
        guard let id = selectedItemIDs.first else { return nil }
        return knownItems.first { $0.id == id }
    }

    public var selectedItems: [USBTransferItem] {
        knownItems.filter { selectedItemIDs.contains($0.id) }
    }

    private var knownItems: [USBTransferItem] {
        // The current MTP folder can also be present in its parent's tree cache.
        // Keep command targets unique so one selected row never becomes two
        // downloads, renames, or delete requests after navigating into it.
        Self.deduplicatedItems(items + treeChildrenByItemID.values.flatMap { $0 })
    }

    static func deduplicatedItems(_ source: [USBTransferItem]) -> [USBTransferItem] {
        var seen = Set<USBTransferItem.ID>()
        return source.filter { seen.insert($0.id).inserted }
    }

    public var selectedDownloadableItems: [USBTransferItem] {
        selectedItems.filter(canDownload)
    }

    public func canDownload(_ item: USBTransferItem) -> Bool {
        item.isDownloadable || (backend == .mtp && item.isFolder && mtpNodes[item.id] != nil)
    }

    public var canNavigateUp: Bool {
        pathComponents.count > 1
    }

    public var canNavigateBack: Bool { !backHistory.isEmpty }

    public var canNavigateForward: Bool { !forwardHistory.isEmpty }

    public var pathBarPath: String {
        guard selectedItemIDs.count == 1 else { return currentPath }
        return selectedItem?.path ?? currentPath
    }

    public var pathBarShowsFolder: Bool {
        guard selectedItemIDs.count == 1 else { return true }
        return selectedItem?.isFolder ?? true
    }

    @MainActor public func folderSizeCalculationSettingDidChange(isEnabled: Bool) {
        calculatesFolderSizes = isEnabled
        guard !isEnabled else {
            scheduleFolderSizeCalculations(for: visibleItemsIncludingExpandedChildren)
            return
        }
        cancelFolderSizeWorker(clearQueue: true)
        folderSizeBytesByItemID.removeAll()
        loadingFolderSizeItemIDs.removeAll()
        failedFolderSizeItemIDs.removeAll()
    }

    public var canWriteCurrentMTPFolder: Bool {
        backend.isWritable && mtpTransport != nil && currentMTPStorageID != nil
    }

    public var canDeleteSelectedMTPItems: Bool {
        backend.isWritable && !selectedItems.compactMap { mtpNodes[$0.id] }.isEmpty
    }

    public var canRenameSelectedMTPItem: Bool {
        guard selectedItems.count == 1,
              let item = selectedItems.first else {
            return false
        }
        return canModifyMTPItem(item)
    }

    public var selectedMTPCompressibleItems: [USBTransferItem] {
        selectedItems.filter { canCompressMTPItem($0) }
    }

    public var canCompressSelectedMTPItems: Bool {
        !selectedItems.isEmpty && selectedMTPCompressibleItems.count == selectedItems.count
    }

    public var selectedMTPExtractableArchive: USBTransferItem? {
        guard selectedItems.count == 1,
              let item = selectedItems.first,
              canExtractMTPArchive(item) else {
            return nil
        }
        return item
    }

    public func displaySize(for item: USBTransferItem) -> String {
        guard item.isFolder else { return item.displaySize }
        if let bytes = folderSizeBytesByItemID[item.id] {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        if loadingFolderSizeItemIDs.contains(item.id) {
            return "Calculating..."
        }
        if failedFolderSizeItemIDs.contains(item.id) {
            return "Unavailable"
        }
        return "—"
    }

    public var visibleItems: [USBTransferItem] {
        filteredAndSortedItems(from: items)
    }

    public var visibleItemsIncludingExpandedChildren: [USBTransferItem] {
        flattenedVisibleItems(from: visibleItems)
    }

    public func filteredTreeChildren(for itemID: USBTransferItem.ID) -> [USBTransferItem] {
        filteredAndSortedItems(from: treeChildrenByItemID[itemID] ?? [])
    }

    private func flattenedVisibleItems(from source: [USBTransferItem]) -> [USBTransferItem] {
        source.flatMap { item -> [USBTransferItem] in
            guard item.isFolder, expandedFolderItemIDs.contains(item.id) else {
                return [item]
            }
            return [item] + flattenedVisibleItems(from: filteredTreeChildren(for: item.id))
        }
    }

    private func filteredAndSortedItems(from source: [USBTransferItem]) -> [USBTransferItem] {
        let parsedSearch = SearchQueryParser.parse(searchText)
        let trimmedSearch = parsedSearch.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kindFilter = parsedSearch.kindFilter ?? searchKindFilter

        let filtered = source.filter { item in
            let matchesText = trimmedSearch.isEmpty
                || item.name.localizedCaseInsensitiveContains(trimmedSearch)
                || item.path.localizedCaseInsensitiveContains(trimmedSearch)
            return matchesText
                && kindFilter.matches(item: item)
                && searchDateFilter.matches(item.modified)
        }

        return filtered.sorted { lhs, rhs in
            if lhs.kind == .folder, rhs.kind != .folder { return true }
            if lhs.kind != .folder, rhs.kind == .folder { return false }

            for descriptor in activeSortDescriptors {
                let result = compareItems(lhs, rhs, by: descriptor.sort)
                if result != .orderedSame {
                    return descriptor.ascending ? result == .orderedAscending : result == .orderedDescending
                }
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var activeSortDescriptors: [USBTransferSortDescriptor] {
        sortDescriptors.isEmpty
            ? [USBTransferSortDescriptor(sort: sort, ascending: sortAscending)]
            : sortDescriptors
    }

    private func compareItems(_ lhs: USBTransferItem, _ rhs: USBTransferItem, by requestedSort: USBTransferSort) -> ComparisonResult {
        switch requestedSort {
        case .name:
            lhs.name.localizedStandardCompare(rhs.name)
        case .kind:
            lhs.kind.displayName.localizedStandardCompare(rhs.kind.displayName)
        case .size:
            compareOptionalInt64(sortSize(for: lhs), sortSize(for: rhs), missingValue: -1)
        case .modified:
            compareOptionalDates(lhs.modified, rhs.modified)
        }
    }

    private func sortSize(for item: USBTransferItem) -> Int64? {
        item.isFolder ? folderSizeBytesByItemID[item.id] : item.size
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

    public var shouldShowSearchOptions: Bool {
        !searchText.isEmpty || searchKindFilter != .any || searchDateFilter != .any
    }

    public var effectiveSearchKindFilter: FileSearchKindFilter {
        SearchQueryParser.parse(searchText).kindFilter ?? searchKindFilter
    }

    public func resetSearchFilters() {
        searchKindFilter = .any
        searchDateFilter = .any
    }

    public func clearSearchKindFilter() {
        if SearchQueryParser.parse(searchText).kindFilter != nil {
            searchText = SearchQueryParser.removingKindFilters(from: searchText)
        }
        searchKindFilter = .any
    }

    public func startBrowsingIfNeeded() {
        guard !startedBrowsing else { return }

        startedBrowsing = true
        hasStartedBrowsing = true
        isBrowsing = true
        backend = .checking
        didEnumerateLocalDevices = false
        statusMessage = "Looking for phones with File Transfer turned on."
        Task { await discoverMTPOrFallbackToImageCapture() }
    }

    public func startBrowsingForFileTransfer() {
        guard startedBrowsing else {
            startBrowsingIfNeeded()
            return
        }
        refresh()
    }

    public func refresh() {
        startBrowsingIfNeeded()
        if mtpTransport != nil {
            refreshMTPCurrentItems()
            return
        }

        if backend == .checking, isBrowsing {
            return
        }

        if backend == .checking {
            resetForMTPRetry()
            Task { await discoverMTPOrFallbackToImageCapture() }
            return
        }

        if startedBrowsing, cameras.isEmpty {
            Task { await discoverMTPOrFallbackToImageCapture() }
            return
        }

        guard let camera = selectedCamera else {
            statusMessage = devices.isEmpty ? "No phone found in File Transfer mode." : "Choose a phone."
            return
        }

        updateSnapshot(for: camera)
        if camera.hasOpenSession {
            refreshCurrentItems()
        } else {
            statusMessage = "Opening \(camera.name ?? "device")..."
            camera.requestOpenSession()
        }
    }

    public func noteADBConnectionBecameReady() {
        isADBReleasedForMTPSession = false
        selectedItemIDs.removeAll()
        lastSelectedItemID = nil
        statusMessage = devices.isEmpty
            ? "ADB connected."
            : "ADB connected. File Transfer remains available."
    }

    public func configureADBReleaseHandler(_ handler: @escaping @Sendable () async -> Bool) {
        adbReleaseHandler = handler
    }

    public func configureTransferQueue(_ queue: TransferQueue) {
        transferQueue = queue
    }

    public func configurePreviewCache(
        cacheStore: AppCacheStore,
        encryptionEnabled: @escaping @MainActor () -> Bool
    ) {
        previewCacheStore = cacheStore
        previewEncryptionEnabled = encryptionEnabled
    }

    public func releaseADBAndRetryMTP() {
        guard !isReleasingADBForMTP else { return }
        guard mtpAccessIssue?.recoveryAction == .releaseADB else { return }

        let handler = adbReleaseHandler
        isReleasingADBForMTP = true
        statusMessage = "Pausing Phone Tools..."

        Task { @MainActor [weak self, handler] in
            let didRelease = await handler?() ?? false
            try? await Task.sleep(for: .milliseconds(900))
            guard let self else { return }
            self.isReleasingADBForMTP = false

            guard didRelease else {
                self.statusMessage = "Phone Tools couldn't be paused. Turn off USB debugging on the phone, then try again."
                return
            }

            self.isADBReleasedForMTPSession = true
            self.resetForMTPRetry()
            self.statusMessage = "Phone Tools paused. Trying File Transfer again..."
            Task { await self.discoverMTPOrFallbackToImageCapture() }
        }
    }

    public func recoverMTPAccessIssue() {
        guard !isReleasingADBForMTP, !isRecoveringMTPConnection else { return }
        switch mtpAccessIssue?.recoveryAction {
        case .releaseADB:
            releaseADBAndRetryMTP()
        case .releaseMacOSCameraService:
            releaseMacOSCameraServiceAndRetryMTP()
        case .resetMTPConnection:
            recoverMTPConnectionByReset()
        case nil:
            refresh()
        }
    }

    private func recoverMTPConnectionByReset() {
        guard !isRecoveringMTPConnection else { return }
        isRecoveringMTPConnection = true
        backend = .checking
        isBrowsing = true
        isCataloging = true
        quickLocations = []
        isResolvingQuickLocations = false
        statusMessage = "Resetting the File Transfer connection…"

        Task { [weak self] in
            await Task.detached(priority: .userInitiated) {
                MTPTransport.recoverByReset()
            }.value
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            await self.discoverMTPOrFallbackToImageCapture(allowImageCaptureFallback: false)
            await MainActor.run {
                self.isRecoveringMTPConnection = false
            }
        }
    }

    private func releaseMacOSCameraServiceAndRetryMTP() {
        isReleasingADBForMTP = true
            statusMessage = "Trying File Transfer again..."

        Task { @MainActor [weak self] in
            await Task.detached(priority: .userInitiated) {
                USBDeviceAccessProbe.releaseMacOSCameraClients()
            }.value
            guard let self else { return }
            self.isReleasingADBForMTP = false
            self.resetForMTPRetry()
            self.statusMessage = "Trying File Transfer again..."
            Task { await self.discoverMTPOrFallbackToImageCapture() }
        }
    }

    public func selectDevice(id: USBTransferDevice.ID?) {
        selectedDeviceID = id
        selectedItemIDs.removeAll()
        clearExpandedFolderState()
        clearMTPFolderListingCache()
        currentContainerID = nil
        currentMTPStorageID = nil
        currentMTPParentID = nil
        lastSelectedItemID = nil
        backHistory.removeAll()
        forwardHistory.removeAll()
        if mtpTransport != nil, id == mtpTransport?.id || id == nil {
            resetMTPPath()
            refreshMTPCurrentItems()
        } else {
            resetPath()
            refresh()
        }
    }

    public func navigateUp() {
        guard canNavigateUp else { return }
        recordCurrentNavigation()
        if mtpTransport != nil {
            cacheVisibleMTPListing()
        }
        pathComponents.removeLast()
        selectedItemIDs.removeAll()
        if mtpTransport != nil {
            applyMTPPathState(for: pathComponents.last)
            refreshMTPCurrentItems()
        } else {
            clearExpandedFolderState()
            currentContainerID = pathComponents.last?.itemID
            refreshCurrentItems()
        }
    }

    public func navigate(to component: USBTransferPathComponent) {
        guard let index = pathComponents.firstIndex(of: component) else { return }
        guard index < pathComponents.count - 1 else { return }
        recordCurrentNavigation()
        if mtpTransport != nil {
            cacheVisibleMTPListing()
        }
        pathComponents = Array(pathComponents.prefix(through: index))
        selectedItemIDs.removeAll()
        if mtpTransport != nil {
            applyMTPPathState(for: component)
            refreshMTPCurrentItems()
        } else {
            clearExpandedFolderState()
            currentContainerID = component.itemID
            refreshCurrentItems()
        }
    }

    public func navigateBack() {
        guard let destination = backHistory.popLast() else { return }
        forwardHistory.append(currentNavigationSnapshot())
        applyNavigationSnapshot(destination)
    }

    public func navigateForward() {
        guard let destination = forwardHistory.popLast() else { return }
        backHistory.append(currentNavigationSnapshot())
        applyNavigationSnapshot(destination)
    }

    @MainActor public func open(item: USBTransferItem) {
        cancelInlineRename()
        if item.isFolder {
            openFolder(item)
        } else if canExtractMTPArchive(item) {
            confirmAndExtractMTPArchive(item)
        } else {
            preview(item: item)
        }
    }

    @MainActor public func confirmAndExtractMTPArchive(_ item: USBTransferItem) {
        guard canExtractMTPArchive(item),
              ArchiveExtractionConfirmation.confirm(fileName: item.name) else {
            return
        }
        extractMTPArchive(item)
    }

    @MainActor public func showQuickLookPreviewForSelection() {
        cancelInlineRename()
        guard let selected = selectedItem else {
            statusMessage = "Select an item to preview."
            return
        }

        let items = quickLookItemOrder(for: selected)
        guard !items.isEmpty else {
            statusMessage = "Select an item to preview."
            return
        }

        let entries = items.map(quickLookEntry)

        PreviewWindowPresenter.showSession(
            title: "Preview",
            entries: entries,
            selectedID: selected.id,
            loadURL: { [weak self, items] entry in
                guard let self,
                      let item = items.first(where: { $0.id == entry.id }) else {
                    throw FileOperationError.commandFailed("\(entry.title) is no longer available.")
                }
                return try await self.cachedPreviewURL(for: item)
            },
            releaseURL: { [weak self] url in
                self?.releaseCachedPreviewURL(url)
            },
            onSelect: { [weak self, items] entry in
                guard let self,
                      let item = items.first(where: { $0.id == entry.id }) else { return }
                self.selectItem(item, from: items, modifiers: [])
            }
        )
    }

    private func quickLookItemOrder(for selected: USBTransferItem) -> [USBTransferItem] {
        let storedOrder = lastSelectionItemOrder.filter(\.canQuickLook)
        if storedOrder.contains(where: { $0.id == selected.id }) {
            return storedOrder
        }

        let visibleOrder = visibleItemsIncludingExpandedChildren.filter(\.canQuickLook)
        if visibleOrder.contains(where: { $0.id == selected.id }) {
            return visibleOrder
        }

        return [selected]
    }

    private func quickLookEntry(for item: USBTransferItem) -> PreviewWindowPresenter.SessionEntry {
        PreviewWindowPresenter.SessionEntry(
            id: item.id,
            title: item.name,
            kind: item.isFolder ? .folder : .file,
            symbol: item.fallbackSymbol,
            details: [
                ("Kind", item.kind.displayName),
                ("Size", displaySize(for: item)),
                ("Modified", item.displayModified),
                ("Path", item.path)
            ]
        )
    }

    @MainActor public func handleNameClickForInlineRename(_ item: USBTransferItem) {
        guard inlineRenameItemID != item.id,
              canModifyMTPItem(item) else {
            return
        }
        let modifiers = NSEvent.modifierFlags
        guard !modifiers.contains(.command),
              !modifiers.contains(.shift),
              selectedItemIDs == [item.id],
              inlineRenameBlockedBySelectionItemID != item.id else {
            return
        }
        scheduleInlineRename(for: item)
    }

    @MainActor public func beginInlineRename(item: USBTransferItem) {
        guard canModifyMTPItem(item) else { return }
        prepareSelectionForContextMenu(item)
        pendingInlineRenameWorkItem?.cancel()
        pendingInlineRenameWorkItem = nil
        inlineRenameItemID = item.id
    }

    @MainActor public func prepareSelectionForContextMenu(_ item: USBTransferItem) {
        guard !selectedItemIDs.contains(item.id) else { return }
        selectItem(item, from: visibleItemsIncludingExpandedChildren, modifiers: [])
    }

    @MainActor public func cancelInlineRename() {
        pendingInlineRenameWorkItem?.cancel()
        pendingInlineRenameWorkItem = nil
        inlineRenameItemID = nil
    }

    @MainActor public func commitInlineRename(item: USBTransferItem, newName: String) {
        cancelInlineRename()
        renameMTPItem(item, to: newName)
    }

    @MainActor private func scheduleInlineRename(for item: USBTransferItem) {
        pendingInlineRenameWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.selectedItemIDs == [item.id],
                      self.knownItems.contains(where: { $0.id == item.id }),
                      self.canModifyMTPItem(item) else {
                    return
                }
                self.inlineRenameItemID = item.id
                self.pendingInlineRenameWorkItem = nil
            }
        }
        pendingInlineRenameWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    public func openQuickLocation(_ location: MTPQuickLocation) {
        guard backend == .mtp else {
            refresh()
            return
        }

        recordCurrentNavigation()
        cacheVisibleMTPListing()
        selectedItemIDs.removeAll()
        lastSelectedItemID = nil
        currentMTPStorageID = location.storageID
        currentMTPParentID = location.parentID

        let rootTitle = mtpTransport?.displayName ?? "File Transfer"
        let rootID = "mtp-root-\(mtpTransport?.id ?? "device")"
        let root = USBTransferPathComponent(id: rootID, itemID: nil, title: rootTitle, path: "/")
        let shortcut = USBTransferPathComponent(
            id: "mtp-quick-\(location.id)",
            itemID: nil,
            title: location.title,
            path: location.path
        )
        pathComponents = [root, shortcut]
        mtpPathStates = [
            root.id: MTPPathState(storageID: nil, parentID: nil, path: "/"),
            shortcut.id: MTPPathState(storageID: location.storageID, parentID: location.parentID, path: location.path)
        ]
        refreshMTPCurrentItems()
    }

    @MainActor public func showQuickLocationInEnclosingFolder(_ location: MTPQuickLocation) {
        guard backend == .mtp, let transport = mtpTransport else { return }

        guard let nodeID = location.parentID else {
            recordCurrentNavigation()
            cacheVisibleMTPListing()
            let root = makeMTPRootPathComponent(for: transport)
            pathComponents = [root]
            mtpPathStates = [root.id: MTPPathState(storageID: nil, parentID: nil, path: "/")]
            currentMTPStorageID = nil
            currentMTPParentID = nil
            selectedItemIDs = [mtpStorageItemID(location.storageID)]
            refreshMTPCurrentItems()
            return
        }

        statusMessage = "Finding \(location.title)..."
        Task { [weak self, transport] in
            do {
                let node = try await transport.metadata(for: nodeID)
                await MainActor.run {
                    guard let self, self.mtpTransport === transport else { return }
                    self.revealMTPQuickLocation(location, node: node, transport: transport)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.mtpTransport === transport else { return }
                    self.alert = UserAlert(error: error)
                    self.statusMessage = "Could not show \(location.title) in its enclosing folder."
                }
            }
        }
    }

    @MainActor public func showQuickLocationInfo(_ location: MTPQuickLocation) {
        let itemID = location.parentID.map { "mtp:\(location.storageID):\($0)" }
            ?? mtpStorageItemID(location.storageID)
        let storage = mtpStorages.first { $0.id == location.storageID }
        if location.parentID == nil, let storage {
            mtpStorageItems[itemID] = storage
            folderSizeBytesByItemID[itemID] = storage.usedBytes
        }
        let item = USBTransferItem(
            id: itemID,
            name: location.title,
            path: location.path,
            kind: .folder,
            size: location.parentID == nil ? storage?.capacityBytes : nil,
            modified: nil,
            uti: UTType.folder.identifier
        )
        FileInfoWindowPresenter.show(manager: self, item: item)

        guard let nodeID = location.parentID, let transport = mtpTransport else { return }
        Task { [weak self, transport] in
            guard let node = try? await transport.metadata(for: nodeID) else { return }
            await MainActor.run {
                guard let self, self.mtpTransport === transport else { return }
                let parentPath = (location.path as NSString).deletingLastPathComponent
                let refreshedItem = self.makeMTPItem(from: node, parentPath: parentPath.isEmpty ? "/" : parentPath)
                FileInfoWindowPresenter.show(manager: self, item: refreshedItem)
            }
        }
    }

    @MainActor private func revealMTPQuickLocation(
        _ location: MTPQuickLocation,
        node: FileNode,
        transport: MTPTransport
    ) {
        recordCurrentNavigation()
        cacheVisibleMTPListing()

        let root = makeMTPRootPathComponent(for: transport)
        let parentPath = (location.path as NSString).deletingLastPathComponent
        let normalizedParentPath = parentPath.isEmpty ? "/" : parentPath
        let enclosingFolder = USBTransferPathComponent(
            id: "mtp-enclosing-\(location.storageID)-\(node.parentID ?? "root")",
            itemID: node.parentID.map { "mtp:\(location.storageID):\($0)" },
            title: (normalizedParentPath as NSString).lastPathComponent,
            path: normalizedParentPath
        )

        pathComponents = [root, enclosingFolder]
        mtpPathStates = [
            root.id: MTPPathState(storageID: nil, parentID: nil, path: "/"),
            enclosingFolder.id: MTPPathState(
                storageID: location.storageID,
                parentID: node.parentID,
                path: normalizedParentPath
            )
        ]
        currentMTPStorageID = location.storageID
        currentMTPParentID = node.parentID
        selectedItemIDs = [mtpItemID(for: node)]
        refreshMTPCurrentItems()
    }

    private func makeMTPRootPathComponent(for transport: MTPTransport) -> USBTransferPathComponent {
        USBTransferPathComponent(
            id: "mtp-root-\(transport.id)",
            itemID: nil,
            title: transport.displayName,
            path: "/"
        )
    }

    @MainActor public func setFolderExpanded(_ item: USBTransferItem, expanded: Bool) {
        guard item.isFolder else { return }
        if expanded {
            expandedFolderItemIDs.insert(item.id)
            // Keep cached children visible and reconcile them in the background.
            Task { await loadFolderChildren(for: item) }
        } else {
            expandedFolderItemIDs.remove(item.id)
        }
    }

    @MainActor public func loadFolderChildren(for item: USBTransferItem) async {
        guard item.isFolder, !loadingTreeItemIDs.contains(item.id) else { return }

        let hadCachedChildren = treeChildrenByItemID[item.id] != nil
        let requestID = UUID()
        loadingTreeItemIDs.insert(item.id)
        treeLoadRequestIDs[item.id] = requestID
        defer {
            if treeLoadRequestIDs[item.id] == requestID {
                loadingTreeItemIDs.remove(item.id)
                treeLoadRequestIDs[item.id] = nil
            }
        }

        do {
            if let transport = mtpTransport {
                let nodes: [FileNode]
                let storageID: String
                let parentID: String?
                let parentPath = item.path
                if let storage = mtpStorageItems[item.id] {
                    storageID = storage.id
                    parentID = nil
                    nodes = try await transport.listChildren(of: nil, in: storage.id)
                } else if let node = mtpNodes[item.id], node.isDirectory {
                    storageID = node.storageID
                    parentID = node.id
                    nodes = try await transport.listChildren(of: node.id, in: node.storageID)
                } else {
                    guard treeLoadRequestIDs[item.id] == requestID else { return }
                    treeChildrenByItemID[item.id] = []
                    return
                }
                guard treeLoadRequestIDs[item.id] == requestID,
                      mtpTransport === transport else {
                    return
                }
                let children = nodes.map { makeMTPItem(from: $0, parentPath: parentPath) }
                treeChildrenByItemID[item.id] = children
                mtpFolderListingsByKey[
                    MTPFolderListingKey(storageID: storageID, parentID: parentID, path: parentPath)
                ] = children
                return
            }

            guard let folder = itemObjects[item.id] as? ICCameraFolder else {
                guard treeLoadRequestIDs[item.id] == requestID else { return }
                treeChildrenByItemID[item.id] = []
                return
            }
            let deviceID = selectedCamera.map(id(for:)) ?? selectedDeviceID ?? "usb-transfer"
            guard treeLoadRequestIDs[item.id] == requestID else { return }
            treeChildrenByItemID[item.id] = (folder.contents ?? []).compactMap {
                makeItem(from: $0, deviceID: deviceID, parentPath: item.path)
            }
        } catch {
            guard treeLoadRequestIDs[item.id] == requestID else { return }
            if !hadCachedChildren {
                treeChildrenByItemID[item.id] = []
                statusMessage = "Could not load \(item.name): \(error.localizedDescription)"
            } else {
                statusMessage = "Could not update \(item.name). Showing the last folder contents."
            }
        }
    }

    @MainActor private func invalidateFolderChildrenLoad(for itemID: USBTransferItem.ID) {
        treeLoadRequestIDs[itemID] = nil
        loadingTreeItemIDs.remove(itemID)
    }

    public func selectItem(_ item: USBTransferItem, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        selectItem(item, from: visibleItems, modifiers: modifiers)
    }

    public func selectItem(
        _ item: USBTransferItem,
        from visibleSource: [USBTransferItem],
        modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {
        lastSelectionItemOrder = visibleSource
        let wasSingleSelectedItem = selectedItemIDs == [item.id]
        if !wasSingleSelectedItem {
            Task { @MainActor in
                cancelInlineRename()
            }
        }

        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        let visibleIDs = visibleSource.map(\.id)

        if shift,
           let anchor = lastSelectedItemID,
           let anchorIndex = visibleIDs.firstIndex(of: anchor),
           let selectedIndex = visibleIDs.firstIndex(of: item.id) {
            let range = anchorIndex <= selectedIndex ? anchorIndex...selectedIndex : selectedIndex...anchorIndex
            let rangeIDs = Set(range.map { visibleIDs[$0] })
            if command {
                selectedItemIDs.formUnion(rangeIDs)
            } else {
                selectedItemIDs = rangeIDs
            }
        } else if command {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
        } else {
            selectedItemIDs = [item.id]
        }

        lastSelectedItemID = item.id
        if !shift {
            keyboardSelectionAnchorItemID = item.id
        }
        if !wasSingleSelectedItem, selectedItemIDs == [item.id] {
            blockInlineRenameForCurrentSelectionEvent(itemID: item.id)
        }
        if let inlineRenameItemID, !selectedItemIDs.contains(inlineRenameItemID) {
            Task { @MainActor in
                cancelInlineRename()
            }
        }
        if selectedItemIDs == [item.id], item.canQuickLook {
            Task { @MainActor in
                guard PreviewWindowPresenter.isSessionVisible,
                      self.selectedItemIDs == [item.id] else {
                    return
                }
                let didUpdateSession = PreviewWindowPresenter.updateSessionSelection(selectedID: item.id)
                if !didUpdateSession {
                    showQuickLookPreviewForSelection()
                }
            }
        }
    }

    @MainActor public func clearItemSelection() {
        cancelInlineRename()
        selectedItemIDs.removeAll()
        lastSelectedItemID = nil
        keyboardSelectionAnchorItemID = nil
        lastSelectionItemOrder.removeAll()
    }

    public func selectAllVisibleItems() {
        let visible = visibleItemsIncludingExpandedChildren
        guard !visible.isEmpty else { return }
        Task { @MainActor in
            cancelInlineRename()
        }
        selectedItemIDs = Set(visible.map(\.id))
        lastSelectionItemOrder = visible
        keyboardSelectionAnchorItemID = visible.first?.id
        lastSelectedItemID = visible.last?.id
    }

    public func moveSelection(by delta: Int, extending: Bool) {
        let visible = visibleItemsIncludingExpandedChildren
        guard !visible.isEmpty else { return }

        let currentID = lastSelectedItemID.flatMap { id in
            selectedItemIDs.contains(id) ? id : nil
        } ?? visible.first(where: { selectedItemIDs.contains($0.id) })?.id

        let targetIndex: Int
        if let currentID,
           let currentIndex = visible.firstIndex(where: { $0.id == currentID }) {
            targetIndex = min(max(currentIndex + delta, 0), visible.count - 1)
        } else {
            targetIndex = delta < 0 ? visible.count - 1 : 0
        }

        let target = visible[targetIndex]
        if !extending || selectedItemIDs.isEmpty {
            selectItem(target, from: visible, modifiers: [])
            keyboardSelectionAnchorItemID = target.id
            return
        }

        Task { @MainActor in
            cancelInlineRename()
        }
        let anchorID = keyboardSelectionAnchorItemID
            ?? lastSelectedItemID
            ?? selectedItemIDs.first
            ?? target.id
        guard let anchorIndex = visible.firstIndex(where: { $0.id == anchorID }) else {
            selectItem(target, from: visible, modifiers: [])
            keyboardSelectionAnchorItemID = target.id
            return
        }

        let lowerBound = min(anchorIndex, targetIndex)
        let upperBound = max(anchorIndex, targetIndex)
        selectedItemIDs = Set(visible[lowerBound...upperBound].map(\.id))
        lastSelectionItemOrder = visible
        lastSelectedItemID = target.id
        keyboardSelectionAnchorItemID = anchorID
    }

    private func blockInlineRenameForCurrentSelectionEvent(itemID: USBTransferItem.ID) {
        inlineRenameBlockedBySelectionItemID = itemID
        DispatchQueue.main.async { [weak self] in
            guard self?.inlineRenameBlockedBySelectionItemID == itemID else { return }
            self?.inlineRenameBlockedBySelectionItemID = nil
        }
    }

    public func sortBy(_ requestedSort: USBTransferSort) {
        sortBy(requestedSort, modifiers: NSEvent.modifierFlags)
    }

    public func sortBy(_ requestedSort: USBTransferSort, modifiers: NSEvent.ModifierFlags) {
        let command = modifiers.contains(.command)
        let defaultAscending = requestedSort == .modified ? false : true

        if command {
            updateSortDescriptors(sort: requestedSort, defaultAscending: defaultAscending)
        } else if sort == requestedSort {
            sortAscending.toggle()
            sortDescriptors = [USBTransferSortDescriptor(sort: requestedSort, ascending: sortAscending)]
        } else {
            sort = requestedSort
            sortAscending = defaultAscending
            sortDescriptors = [USBTransferSortDescriptor(sort: requestedSort, ascending: defaultAscending)]
        }
        syncPrimarySortFromDescriptors()
    }

    public func sortIndicator(for requestedSort: USBTransferSort) -> (priority: Int, ascending: Bool)? {
        guard let index = activeSortDescriptors.firstIndex(where: { $0.sort == requestedSort }) else { return nil }
        return (index + 1, activeSortDescriptors[index].ascending)
    }

    private func updateSortDescriptors(sort requestedSort: USBTransferSort, defaultAscending: Bool) {
        var descriptors = activeSortDescriptors
        if let index = descriptors.firstIndex(where: { $0.sort == requestedSort }) {
            descriptors[index].ascending.toggle()
        } else {
            descriptors.append(USBTransferSortDescriptor(sort: requestedSort, ascending: defaultAscending))
        }
        sortDescriptors = descriptors
    }

    private func syncPrimarySortFromDescriptors() {
        guard let primary = activeSortDescriptors.first else { return }
        sort = primary.sort
        sortAscending = primary.ascending
    }

    @MainActor public func downloadSelected() {
        download(items: selectedDownloadableItems)
    }

    @MainActor public func download(item: USBTransferItem) {
        selectedItemIDs = [item.id]
        download(items: [item])
    }

    @MainActor public func prepareFolderSize(for item: USBTransferItem) async {
        guard item.isFolder,
              calculatesFolderSizes,
              folderSizeBytesByItemID[item.id] == nil,
              !loadingFolderSizeItemIDs.contains(item.id),
              !failedFolderSizeItemIDs.contains(item.id) else {
            return
        }

        if let storage = mtpStorageItems[item.id] {
            folderSizeBytesByItemID[item.id] = storage.usedBytes
            return
        }

        scheduleFolderSizeCalculations(for: [item])
    }

    @MainActor private func scheduleFolderSizeCalculations(for candidates: [USBTransferItem]) {
        guard calculatesFolderSizes else { return }
        for item in candidates where item.isFolder {
            guard mtpStorageItems[item.id] == nil,
                  folderSizeBytesByItemID[item.id] == nil,
                  !loadingFolderSizeItemIDs.contains(item.id),
                  !failedFolderSizeItemIDs.contains(item.id),
                  queuedFolderSizeItemIDs.insert(item.id).inserted,
                  mtpNodes[item.id] != nil || itemObjects[item.id] is ICCameraFolder else {
                continue
            }
            folderSizeQueue.append(item)
        }
        startFolderSizeWorkerIfNeeded()
    }

    @MainActor private func startFolderSizeWorkerIfNeeded() {
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
                  self.calculatesFolderSizes,
                  !self.folderSizeQueue.isEmpty {
                let item = self.folderSizeQueue.removeFirst()
                self.queuedFolderSizeItemIDs.remove(item.id)
                self.loadingFolderSizeItemIDs.insert(item.id)

                do {
                    let bytes: Int64
                    if let node = self.mtpNodes[item.id], let transport = self.mtpTransport {
                        bytes = try await Self.mtpFolderSizeBytes(node, transport: transport)
                    } else if let folder = self.itemObjects[item.id] as? ICCameraFolder {
                        let sendableFolder = SendableCameraFolder(folder: folder)
                        bytes = await Task.detached(priority: .utility) {
                            Self.imageCaptureFolderSizeBytes(sendableFolder.folder)
                        }.value
                    } else {
                        self.loadingFolderSizeItemIDs.remove(item.id)
                        continue
                    }

                    try Task.checkCancellation()
                    self.folderSizeBytesByItemID[item.id] = bytes
                    self.failedFolderSizeItemIDs.remove(item.id)
                } catch is CancellationError {
                    self.loadingFolderSizeItemIDs.remove(item.id)
                    return
                } catch {
                    self.failedFolderSizeItemIDs.insert(item.id)
                }
                self.loadingFolderSizeItemIDs.remove(item.id)

                do {
                    try await Task.sleep(for: .milliseconds(100))
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
        loadingFolderSizeItemIDs.removeAll()
        if clearQueue {
            folderSizeQueue.removeAll()
            queuedFolderSizeItemIDs.removeAll()
        }
    }

    @MainActor public func dragItemProvider(for item: USBTransferItem) -> NSItemProvider? {
        guard canDownload(item) else { return nil }
        let typeIdentifier = item.isFolder
            ? UTType.folder.identifier
            : (item.uti
                ?? UTType(filenameExtension: item.fileExtension)?.identifier
                ?? UTType.data.identifier)

        return RemoteFileDragProvider.provider(fileName: item.name, typeIdentifier: typeIdentifier) { [weak self] in
            guard let self else { throw FileOperationError.noDevice }
            return try await self.exportItemForDrag(item)
        }
    }

    @MainActor func canStartRemoteDrag(with item: USBTransferItem) -> Bool {
        item.isDownloadable || (item.isFolder && canModifyMTPItem(item))
    }

    @MainActor func canAcceptRemoteDrop(_ payload: RemoteBrowserDragPayload, onto folder: USBTransferItem) -> Bool {
        guard backend == .mtp,
              folder.isFolder,
              payload.backend == .mtp,
              payload.deviceID == selectedDeviceID,
              !payload.items.isEmpty,
              let targetNode = mtpNodes[folder.id],
              targetNode.isDirectory else {
            return false
        }

        return payload.items.allSatisfy { item in
            guard let sourceNode = mtpNodes[item.id],
                  sourceNode.storageID == targetNode.storageID,
                  (item.path as NSString).deletingLastPathComponent != folder.path,
                  item.path != folder.path else {
                return false
            }
            return !item.isFolder || !folder.path.hasPrefix("\(item.path)/")
        }
    }

    @MainActor func moveRemoteDrop(_ payload: RemoteBrowserDragPayload, onto folder: USBTransferItem) {
        guard canAcceptRemoteDrop(payload, onto: folder),
              let transport = mtpTransport,
              let targetNode = mtpNodes[folder.id] else {
            statusMessage = "That item can't be moved there."
            return
        }

        let normalizedItems = payload.items.filter { candidate in
            !payload.items.contains { possibleAncestor in
                possibleAncestor.id != candidate.id
                    && possibleAncestor.isFolder
                    && candidate.path.hasPrefix("\(possibleAncestor.path)/")
            }
        }
        let requests = normalizedItems.compactMap { item -> (RemoteBrowserDragItem, FileNode)? in
            mtpNodes[item.id].map { (item, $0) }
        }
        guard requests.count == normalizedItems.count, !requests.isEmpty else { return }
        var requestedNames = Set<String>()
        if let duplicate = requests.first(where: {
            !requestedNames.insert($0.0.name.lowercased()).inserted
        }) {
            alert = UserAlert(
                title: "Duplicate Detected",
                message: "More than one selected item is named \(duplicate.0.name)."
            )
            statusMessage = "Move canceled."
            return
        }

        let destinationHadCachedChildren = treeChildrenByItemID[folder.id] != nil
        if let cachedChildren = treeChildrenByItemID[folder.id],
           let duplicate = requests.first(where: { request in
               cachedChildren.contains {
                   $0.id != request.0.id && $0.name.localizedCaseInsensitiveCompare(request.0.name) == .orderedSame
               }
           }) {
            alert = UserAlert(
                title: "Duplicate Detected",
                message: "\(duplicate.0.name) already exists in \(folder.name)."
            )
            statusMessage = "Move canceled."
            return
        }

        let itemsBeforeMove = items
        let treeChildrenBeforeMove = treeChildrenByItemID
        let expandedFoldersBeforeMove = expandedFolderItemIDs
        let selectionBeforeMove = selectedItemIDs
        let nodesBeforeMove = mtpNodes
        let folderListingsBeforeMove = mtpFolderListingsByKey
        let visibleListingBeforeMove = visibleMTPListingKey
        let navigationBeforeMove = currentNavigationSnapshot()
        let backHistoryBeforeMove = backHistory
        let forwardHistoryBeforeMove = forwardHistory
        let lastSelectedBeforeMove = lastSelectedItemID
        let keyboardAnchorBeforeMove = keyboardSelectionAnchorItemID
        let knownItemsBeforeMove = knownItems
        let movedSourcePaths = Set(requests.map { $0.0.path })
        let sourceParentPaths = Set(requests.map {
            let parent = ($0.0.path as NSString).deletingLastPathComponent
            return parent.isEmpty ? "/" : parent
        })
        var affectedTreeItemIDs: Set<USBTransferItem.ID> = [folder.id]

        invalidateFolderChildrenLoad(for: folder.id)
        for (_, sourceNode) in requests {
            guard let parentNodeID = sourceNode.parentID,
                  let parentItemID = mtpNodes.first(where: { $0.value.id == parentNodeID })?.key else {
                continue
            }
            affectedTreeItemIDs.insert(parentItemID)
            invalidateFolderChildrenLoad(for: parentItemID)
        }
        for candidate in knownItemsBeforeMove where requests.contains(where: {
            candidate.path == $0.0.path || candidate.path.hasPrefix("\($0.0.path)/")
        }) {
            affectedTreeItemIDs.insert(candidate.id)
            invalidateFolderChildrenLoad(for: candidate.id)
        }
        for candidate in knownItemsBeforeMove where sourceParentPaths.contains(candidate.path) {
            affectedTreeItemIDs.insert(candidate.id)
            invalidateFolderChildrenLoad(for: candidate.id)
        }
        // Ignore any listing response that started before the optimistic move.
        mtpListingRequestID = UUID()
        mtpBrowserMutationDepth += 1

        // MTP moves are normally metadata-only. Reflect them immediately and let
        // the transport finish out of band so the browser keeps Finder-like pace.
        for (item, _) in requests {
            optimisticallyMoveMTPItem(item, into: folder)
        }
        selectedItemIDs = Set(requests.map { $0.0.id })
        lastSelectedItemID = requests.last?.0.id
        keyboardSelectionAnchorItemID = requests.last?.0.id
        let navigationAfterOptimisticMove = currentNavigationSnapshot()
        let backHistoryAfterOptimisticMove = backHistory
        let forwardHistoryAfterOptimisticMove = forwardHistory
        let selectionAfterOptimisticMove = selectedItemIDs
        let lastSelectedAfterOptimisticMove = lastSelectedItemID
        let keyboardAnchorAfterOptimisticMove = keyboardSelectionAnchorItemID
        let expandedFoldersAfterOptimisticMove = expandedFolderItemIDs

        beginTerminationBlockingActivity()
        statusMessage = "Moving to \(folder.name)..."
        Task { @MainActor [weak self, transport, targetNode, folder, requests, destinationHadCachedChildren] in
            guard let self else { return }
            defer {
                self.endTerminationBlockingActivity()
                self.mtpBrowserMutationDepth = max(0, self.mtpBrowserMutationDepth - 1)
                self.schedulePendingMTPObservedRefresh()
            }

            let moveState = MTPMoveOperationState()
            let performMoves: @MainActor (TransferJobController?) async throws -> Void = { controller in
                if !destinationHadCachedChildren {
                    let existingNames = Set(
                        try await transport.listChildren(of: targetNode.id, in: targetNode.storageID)
                            .map { $0.name.lowercased() }
                    )
                    if let duplicate = requests.first(where: { existingNames.contains($0.0.name.lowercased()) }) {
                        throw FileOperationError.duplicateExists("\(folder.path)/\(duplicate.0.name)")
                    }
                }

                for (index, request) in requests.enumerated() {
                    let (item, node) = request
                    try await transport.move(node.id, toParent: targetNode.id, in: targetNode.storageID)
                    moveState.completedRequestIDs.insert(item.id)
                    self.mtpNodes[item.id] = FileNode(
                        id: node.id,
                        storageID: node.storageID,
                        parentID: targetNode.id,
                        name: node.name,
                        isDirectory: node.isDirectory,
                        size: node.size,
                        modifiedDate: node.modifiedDate,
                        fileExtension: node.fileExtension
                    )
                    controller?.updateProgress(
                        fractionCompleted: Double(index + 1) / Double(requests.count),
                        message: requests.count == 1
                            ? "Moving \(item.name)"
                            : "Moving \(index + 1) of \(requests.count)"
                    )
                }
            }

            do {
                if let queue = self.transferQueue {
                    let knownSizes = requests.compactMap { request in
                        request.0.size ?? self.folderSizeBytesByItemID[request.0.id]
                    }
                    let totalBytes = knownSizes.count == requests.count
                        ? knownSizes.reduce(Int64(0), +)
                        : nil
                    _ = try await queue.enqueueAndWait(
                        kind: .move,
                        title: requests.count == 1 ? requests[0].0.name : "\(requests.count) items",
                        subtitle: "Moving to \(folder.name)",
                        source: TransferEndpoint(
                            kind: .usbTransfer,
                            deviceID: self.selectedDeviceID,
                            path: requests[0].0.path,
                            displayName: requests.count == 1 ? requests[0].0.name : "\(requests.count) items"
                        ),
                        destination: TransferEndpoint(
                            kind: .usbTransfer,
                            deviceID: self.selectedDeviceID,
                            path: folder.path,
                            displayName: folder.name
                        ),
                        itemKind: requests.count == 1 && !requests[0].0.isFolder ? .file : .folder,
                        totalBytes: totalBytes,
                        exclusiveGroup: "mtp:\(transport.id)",
                        defersPresentation: true,
                        onEnqueued: { queuedID in
                            moveState.jobID = queuedID
                            self.scheduleDelayedMovePresentation(for: queuedID)
                        }
                    ) { controller in
                        try await performMoves(controller)
                        return TransferJobResult(message: "Moved")
                    }
                } else {
                    try await performMoves(nil)
                }

                if let jobID = moveState.jobID {
                    self.finishDelayedMovePresentation(for: jobID)
                }
                self.statusMessage = "Moved \(requests.count) item\(requests.count == 1 ? "" : "s") to \(folder.name)."
                self.refreshMTPCurrentItems()
                Task { await self.loadFolderChildren(for: folder) }
            } catch {
                let navigationAtFailure = self.currentNavigationSnapshot()
                let backHistoryAtFailure = self.backHistory
                let forwardHistoryAtFailure = self.forwardHistory
                let selectionAtFailure = self.selectedItemIDs
                let lastSelectedAtFailure = self.lastSelectedItemID
                let keyboardAnchorAtFailure = self.keyboardSelectionAnchorItemID
                let expandedFoldersAtFailure = self.expandedFolderItemIDs
                let treeChildrenAtFailure = self.treeChildrenByItemID
                let folderListingsAtFailure = self.mtpFolderListingsByKey
                let navigationChangedByUser =
                    navigationAtFailure != navigationAfterOptimisticMove
                    || backHistoryAtFailure != backHistoryAfterOptimisticMove
                    || forwardHistoryAtFailure != forwardHistoryAfterOptimisticMove
                let selectionChangedByUser =
                    selectionAtFailure != selectionAfterOptimisticMove
                    || lastSelectedAtFailure != lastSelectedAfterOptimisticMove
                    || keyboardAnchorAtFailure != keyboardAnchorAfterOptimisticMove
                let expansionChangedByUser =
                    expandedFoldersAtFailure != expandedFoldersAfterOptimisticMove

                // Restore the old visual state, then replay only moves that the
                // phone already completed before the error.
                self.items = itemsBeforeMove
                self.treeChildrenByItemID = treeChildrenBeforeMove
                self.expandedFolderItemIDs = expandedFoldersBeforeMove
                self.selectedItemIDs = selectionBeforeMove
                self.mtpNodes = nodesBeforeMove
                self.mtpFolderListingsByKey = folderListingsBeforeMove
                self.visibleMTPListingKey = visibleListingBeforeMove
                self.pathComponents = navigationBeforeMove.pathComponents
                self.currentContainerID = navigationBeforeMove.currentContainerID
                self.currentMTPStorageID = navigationBeforeMove.currentMTPStorageID
                self.currentMTPParentID = navigationBeforeMove.currentMTPParentID
                self.mtpPathStates = navigationBeforeMove.mtpPathStates
                self.backHistory = backHistoryBeforeMove
                self.forwardHistory = forwardHistoryBeforeMove
                self.lastSelectedItemID = lastSelectedBeforeMove
                self.keyboardSelectionAnchorItemID = keyboardAnchorBeforeMove

                let completedRequests = requests.filter { moveState.completedRequestIDs.contains($0.0.id) }
                for (item, node) in completedRequests {
                    self.optimisticallyMoveMTPItem(item, into: folder)
                    self.mtpNodes[item.id] = FileNode(
                        id: node.id,
                        storageID: node.storageID,
                        parentID: targetNode.id,
                        name: node.name,
                        isDirectory: node.isDirectory,
                        size: node.size,
                        modifiedDate: node.modifiedDate,
                        fileExtension: node.fileExtension
                    )
                }

                // Keep folder data loaded during the move unless it belongs to a
                // source or destination that needs reconciliation.
                for (itemID, children) in treeChildrenAtFailure
                    where !affectedTreeItemIDs.contains(itemID) {
                    self.treeChildrenByItemID[itemID] = children
                }
                for (key, cachedItems) in folderListingsAtFailure
                    where !self.mtpListingKey(
                        key,
                        isAffectedBySourcePaths: movedSourcePaths,
                        sourceParentPaths: sourceParentPaths,
                        destinationPath: folder.path
                    ) {
                    self.mtpFolderListingsByKey[key] = cachedItems
                }

                if navigationChangedByUser {
                    self.pathComponents = navigationAtFailure.pathComponents
                    self.currentContainerID = navigationAtFailure.currentContainerID
                    self.currentMTPStorageID = navigationAtFailure.currentMTPStorageID
                    self.currentMTPParentID = navigationAtFailure.currentMTPParentID
                    self.mtpPathStates = navigationAtFailure.mtpPathStates
                    self.backHistory = backHistoryAtFailure
                    self.forwardHistory = forwardHistoryAtFailure
                }
                if selectionChangedByUser {
                    self.selectedItemIDs = selectionAtFailure
                    self.lastSelectedItemID = lastSelectedAtFailure
                    self.keyboardSelectionAnchorItemID = keyboardAnchorAtFailure
                }
                if expansionChangedByUser {
                    self.expandedFolderItemIDs = expandedFoldersAtFailure
                }

                if let jobID = moveState.jobID {
                    self.finishDelayedMovePresentation(for: jobID)
                }
                self.alert = UserAlert(title: "Move Failed", message: error.localizedDescription)
                self.statusMessage = completedRequests.isEmpty
                    ? "Move failed."
                    : "Moved \(completedRequests.count) item\(completedRequests.count == 1 ? "" : "s"); the rest could not be moved."
                self.refreshMTPCurrentItems()
                Task { await self.loadFolderChildren(for: folder) }
            }
        }
    }

    @MainActor private func optimisticallyMoveMTPItem(_ item: RemoteBrowserDragItem, into folder: USBTransferItem) {
        let source = knownItems.first { $0.id == item.id }
        let oldPath = item.path
        let newPath = folder.path == "/" ? "/\(item.name)" : "\(folder.path)/\(item.name)"
        items.removeAll { $0.id == item.id }
        for parentID in Array(treeChildrenByItemID.keys) {
            treeChildrenByItemID[parentID]?.removeAll { $0.id == item.id }
            treeChildrenByItemID[parentID] = treeChildrenByItemID[parentID]?.map {
                remappingMTPItem($0, from: oldPath, to: newPath)
            }
        }

        var remappedListings: [MTPFolderListingKey: [USBTransferItem]] = [:]
        for (key, cachedItems) in mtpFolderListingsByKey {
            let remappedKey = MTPFolderListingKey(
                storageID: key.storageID,
                parentID: key.parentID,
                path: remappingMTPPath(key.path, from: oldPath, to: newPath)
            )
            let remappedItems = cachedItems
                .filter { $0.id != item.id }
                .map { remappingMTPItem($0, from: oldPath, to: newPath) }
            remappedListings[remappedKey, default: []].append(contentsOf: remappedItems)
        }
        mtpFolderListingsByKey = remappedListings
        if let visibleMTPListingKey {
            self.visibleMTPListingKey = MTPFolderListingKey(
                storageID: visibleMTPListingKey.storageID,
                parentID: visibleMTPListingKey.parentID,
                path: remappingMTPPath(visibleMTPListingKey.path, from: oldPath, to: newPath)
            )
        }

        items = items.map { remappingMTPItem($0, from: oldPath, to: newPath) }
        pathComponents = pathComponents.map { component in
            USBTransferPathComponent(
                id: component.id,
                itemID: component.itemID,
                title: component.title,
                path: remappingMTPPath(component.path, from: oldPath, to: newPath)
            )
        }
        mtpPathStates = mtpPathStates.mapValues { state in
            MTPPathState(
                storageID: state.storageID,
                parentID: state.parentID,
                path: remappingMTPPath(state.path, from: oldPath, to: newPath)
            )
        }
        backHistory = backHistory.map {
            remappingNavigationSnapshot($0, from: oldPath, to: newPath)
        }
        forwardHistory = forwardHistory.map {
            remappingNavigationSnapshot($0, from: oldPath, to: newPath)
        }

        let moved = USBTransferItem(
            id: item.id,
            name: item.name,
            path: newPath,
            kind: item.isFolder ? .folder : .file,
            size: item.size,
            modified: source?.modified,
            uti: source?.uti
        )
        expandedFolderItemIDs.insert(folder.id)
        treeChildrenByItemID[folder.id, default: []].append(moved)
        if let targetNode = mtpNodes[folder.id] {
            let destinationKey = MTPFolderListingKey(
                storageID: targetNode.storageID,
                parentID: targetNode.id,
                path: folder.path
            )
            if mtpFolderListingsByKey[destinationKey] != nil {
                mtpFolderListingsByKey[destinationKey, default: []].append(moved)
            }
        }
    }

    private func remappingMTPItem(
        _ item: USBTransferItem,
        from oldPath: String,
        to newPath: String
    ) -> USBTransferItem {
        let remappedPath = remappingMTPPath(item.path, from: oldPath, to: newPath)
        guard remappedPath != item.path else { return item }
        return USBTransferItem(
            id: item.id,
            name: (remappedPath as NSString).lastPathComponent,
            path: remappedPath,
            kind: item.kind,
            size: item.size,
            modified: item.modified,
            uti: item.uti
        )
    }

    private func remappingMTPPath(_ path: String, from oldPath: String, to newPath: String) -> String {
        if path == oldPath {
            return newPath
        }
        guard path.hasPrefix("\(oldPath)/") else { return path }
        return newPath + path.dropFirst(oldPath.count)
    }

    @MainActor private func remapMTPBrowserPath(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        items = items.map { remappingMTPItem($0, from: oldPath, to: newPath) }
        for parentID in Array(treeChildrenByItemID.keys) {
            treeChildrenByItemID[parentID] = treeChildrenByItemID[parentID]?.map {
                remappingMTPItem($0, from: oldPath, to: newPath)
            }
        }

        var remappedListings: [MTPFolderListingKey: [USBTransferItem]] = [:]
        for (key, cachedItems) in mtpFolderListingsByKey {
            let remappedKey = MTPFolderListingKey(
                storageID: key.storageID,
                parentID: key.parentID,
                path: remappingMTPPath(key.path, from: oldPath, to: newPath)
            )
            remappedListings[remappedKey, default: []].append(contentsOf: cachedItems.map {
                remappingMTPItem($0, from: oldPath, to: newPath)
            })
        }
        mtpFolderListingsByKey = remappedListings
        if let visibleMTPListingKey {
            self.visibleMTPListingKey = MTPFolderListingKey(
                storageID: visibleMTPListingKey.storageID,
                parentID: visibleMTPListingKey.parentID,
                path: remappingMTPPath(visibleMTPListingKey.path, from: oldPath, to: newPath)
            )
        }

        pathComponents = pathComponents.map { component in
            USBTransferPathComponent(
                id: component.id,
                itemID: component.itemID,
                title: component.path == oldPath
                    ? (newPath as NSString).lastPathComponent
                    : component.title,
                path: remappingMTPPath(component.path, from: oldPath, to: newPath)
            )
        }
        mtpPathStates = mtpPathStates.mapValues { state in
            MTPPathState(
                storageID: state.storageID,
                parentID: state.parentID,
                path: remappingMTPPath(state.path, from: oldPath, to: newPath)
            )
        }
        backHistory = backHistory.map { remappingNavigationSnapshot($0, from: oldPath, to: newPath) }
        forwardHistory = forwardHistory.map { remappingNavigationSnapshot($0, from: oldPath, to: newPath) }
    }

    private func remappingNavigationSnapshot(
        _ snapshot: USBFolderNavigationSnapshot,
        from oldPath: String,
        to newPath: String
    ) -> USBFolderNavigationSnapshot {
        USBFolderNavigationSnapshot(
            pathComponents: snapshot.pathComponents.map { component in
                let remappedPath = remappingMTPPath(component.path, from: oldPath, to: newPath)
                return USBTransferPathComponent(
                    id: component.id,
                    itemID: component.itemID,
                    title: component.path == oldPath
                        ? (newPath as NSString).lastPathComponent
                        : component.title,
                    path: remappedPath
                )
            },
            currentContainerID: snapshot.currentContainerID,
            currentMTPStorageID: snapshot.currentMTPStorageID,
            currentMTPParentID: snapshot.currentMTPParentID,
            mtpPathStates: snapshot.mtpPathStates.mapValues { state in
                MTPPathState(
                    storageID: state.storageID,
                    parentID: state.parentID,
                    path: remappingMTPPath(state.path, from: oldPath, to: newPath)
                )
            }
        )
    }

    private func mtpListingKey(
        _ key: MTPFolderListingKey,
        isAffectedBySourcePaths sourcePaths: Set<String>,
        sourceParentPaths: Set<String>,
        destinationPath: String
    ) -> Bool {
        if key.path == destinationPath || sourceParentPaths.contains(key.path) {
            return true
        }
        return sourcePaths.contains { sourcePath in
            key.path == sourcePath || key.path.hasPrefix("\(sourcePath)/")
        }
    }

    @MainActor private func scheduleDelayedMovePresentation(for jobID: UUID) {
        delayedMovePresentationTasks[jobID]?.cancel()
        delayedMovePresentationTasks[jobID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self,
                  let queue = self.transferQueue,
                  let job = queue.job(id: jobID),
                  !job.state.isFinished else {
                return
            }
            self.presentedDelayedMoveJobIDs.insert(jobID)
            _ = queue.revealDeferredJob(id: jobID)
            self.delayedMovePresentationTasks[jobID] = nil
        }
    }

    @MainActor private func finishDelayedMovePresentation(for jobID: UUID) {
        delayedMovePresentationTasks.removeValue(forKey: jobID)?.cancel()
        let wasPresented = presentedDelayedMoveJobIDs.remove(jobID) != nil
        guard let queue = transferQueue, let job = queue.job(id: jobID) else { return }
        if job.state == .failed {
            _ = queue.revealDeferredJob(id: jobID)
        } else if !wasPresented {
            _ = queue.discardFinishedJob(id: jobID)
        }
    }

    @MainActor public func copySelectedForPasteboard() {
        let items = selectedDownloadableItems
        guard !items.isEmpty else {
            statusMessage = "Select a File Transfer file to copy."
            return
        }
        statusMessage = "Preparing \(items.count) File Transfer file\(items.count == 1 ? "" : "s") for Finder paste..."
        Task { @MainActor [weak self, items] in
            await self?.copyItemsForFinderPaste(items)
        }
    }

    @MainActor public func copyFilePathsToPasteboard(startingWith item: USBTransferItem) {
        let paths: [String]
        if selectedItemIDs.contains(item.id) {
            paths = selectedItems.map(\.path)
        } else {
            selectedItemIDs = [item.id]
            paths = [item.path]
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        statusMessage = "Copied file path\(paths.count == 1 ? "" : "s")."
    }

    @MainActor public func copySelectedFilePathsToPasteboard() {
        let paths = selectedItems.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        statusMessage = "Copied file path\(paths.count == 1 ? "" : "s")."
    }

    @MainActor public func copyPathToPasteboard(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        statusMessage = "Copied file path."
    }

    @MainActor private func copyItemsForFinderPaste(_ items: [USBTransferItem]) async {
        do {
            var localURLs: [URL] = []
            for item in items {
                let destination = try RemoteFileDragProvider.destinationURL(fileName: item.name)
                let localURL = try await exportItem(item, to: destination, subtitle: "Copying for Finder paste")
                localURLs.append(localURL)
            }

            guard RemoteFileDragProvider.writeFileURLsToPasteboard(localURLs) else {
                throw FileOperationError.commandFailed("Could not place copied files on the pasteboard.")
            }
            statusMessage = "Copied \(localURLs.count) File Transfer file\(localURLs.count == 1 ? "" : "s") for Finder paste."
        } catch {
            alert = UserAlert(title: "Copy Failed", message: error.localizedDescription)
            statusMessage = "Copy for Finder paste failed."
        }
    }

    @MainActor private func filePromiseProvider(
        for item: USBTransferItem,
        remoteDragPayload: RemoteBrowserDragPayload
    ) -> FinderFilePromiseDragItem? {
        guard canDownload(item) else { return nil }
        let typeIdentifier = item.isFolder
            ? UTType.folder.identifier
            : (item.uti
                ?? UTType(filenameExtension: item.fileExtension)?.identifier
                ?? UTType.data.identifier)

        let provider = RemoteFileDragProvider.filePromiseProvider(fileName: item.name, typeIdentifier: typeIdentifier) { [weak self] destinationURL in
            guard let self else { throw FileOperationError.noDevice }
            _ = try await self.exportItem(item, to: destinationURL, subtitle: "Copying to Finder")
        }
        return FinderFilePromiseDragItem(
            provider: provider,
            fileName: item.name,
            typeIdentifier: typeIdentifier,
            isFolder: item.kind == .folder,
            remoteDragPayload: remoteDragPayload
        )
    }

    @MainActor func filePromiseProvidersForDrag(startingWith item: USBTransferItem) -> [FinderFilePromiseDragItem] {
        guard canStartRemoteDrag(with: item) else { return [] }
        let draggedItems = selectedItemIDs.contains(item.id)
            ? selectedItems.filter { canStartRemoteDrag(with: $0) }
            : [item]
        guard let deviceID = selectedDeviceID else { return [] }
        let payload = RemoteBrowserDragPayload(
            backend: .mtp,
            deviceID: deviceID,
            items: draggedItems.map {
                RemoteBrowserDragItem(
                    id: $0.id,
                    path: $0.path,
                    name: $0.name,
                    isFolder: $0.isFolder,
                    size: $0.size
                )
            }
        )
        return draggedItems.compactMap {
            filePromiseProvider(for: $0, remoteDragPayload: payload)
        }
    }

    @MainActor private func exportItemForDrag(_ item: USBTransferItem) async throws -> URL {
        let destination = try RemoteFileDragProvider.destinationURL(fileName: item.name)
        return try await exportItem(item, to: destination, subtitle: "Copying for drag export")
    }

    @MainActor @discardableResult private func exportItem(_ item: USBTransferItem, to destination: URL, subtitle: String) async throws -> URL {
        statusMessage = "Copying \(item.name) to this Mac..."

        if let transport = mtpTransport, let node = mtpNodes[item.id] {
            let totalBytes = node.isDirectory ? folderSizeBytesByItemID[item.id] : item.size
            if let transferQueue {
                let result = try await transferQueue.enqueueAndWait(
                    kind: .export,
                    title: item.name,
                    subtitle: subtitle,
                    source: TransferEndpoint(kind: .usbTransfer, deviceID: selectedDeviceID, path: item.path, displayName: item.path),
                    destination: TransferEndpoint(kind: .mac, path: destination.path, displayName: destination.lastPathComponent),
                    itemKind: item.isFolder ? .folder : .file,
                    totalBytes: totalBytes,
                    exclusiveGroup: "mtp:\(transport.id)"
                ) { controller in
                    try controller.checkCancellation()
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try controller.checkCancellation()
                    try await Self.downloadMTPNode(
                        node,
                        to: destination,
                        transport: transport,
                        totalBytes: totalBytes
                    ) { progress in
                        Task { @MainActor in
                            let hasKnownTotal = progress.totalBytes > 0
                            controller.updateProgress(
                                completedBytes: progress.completedBytes,
                                totalBytes: hasKnownTotal ? progress.totalBytes : nil,
                                fractionCompleted: hasKnownTotal ? progress.fractionCompleted : nil,
                                message: Self.progressMessage(prefix: "Copying", progress: progress)
                            )
                        }
                    }
                    try controller.checkCancellation()
                    return TransferJobResult(outputURL: destination, message: "Copied")
                }
                guard let outputURL = result?.outputURL else {
                    throw FileOperationError.commandFailed("The copy finished without a local file.")
                }
                statusMessage = "Copied \(item.name) to this Mac."
                return outputURL
            }

            beginTerminationBlockingActivity()
            defer { endTerminationBlockingActivity() }
            try await Self.downloadMTPNode(
                node,
                to: destination,
                transport: transport,
                totalBytes: totalBytes
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.statusMessage = Self.progressMessage(prefix: "Copying", progress: progress)
                }
            }
            statusMessage = "Copied \(item.name) to this Mac."
            return destination
        }

        guard let file = itemObjects[item.id] as? ICCameraFile else {
            throw FileOperationError.commandFailed("The file is no longer available.")
        }

        if let transferQueue {
            let result = try await transferQueue.enqueueAndWait(
                kind: .export,
                title: item.name,
                subtitle: subtitle,
                source: TransferEndpoint(kind: .usbTransfer, deviceID: selectedDeviceID, path: item.path, displayName: item.path),
                destination: TransferEndpoint(kind: .mac, path: destination.path, displayName: destination.lastPathComponent),
                totalBytes: item.size
            ) { controller in
                controller.updateProgress(fractionCompleted: 0)
                try controller.checkCancellation()
                let outputURL = try await self.exportImageCaptureFile(file, item: item, to: destination)
                try controller.checkCancellation()
                controller.updateProgress(fractionCompleted: 1)
                return TransferJobResult(outputURL: outputURL, message: "Copied")
            }
            guard let outputURL = result?.outputURL else {
                throw FileOperationError.commandFailed("The copy finished without a local file.")
            }
            statusMessage = "Copied \(item.name) to this Mac."
            return outputURL
        }

        beginTerminationBlockingActivity()
        defer { endTerminationBlockingActivity() }
        let localURL = try await exportImageCaptureFile(file, item: item, to: destination)
        statusMessage = "Copied \(item.name) to this Mac."
        return localURL
    }

    private static func downloadMTPNode(
        _ node: FileNode,
        to destination: URL,
        transport: MTPTransport,
        totalBytes: Int64?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let aggregate = MTPAggregateDownloadProgress(totalBytes: totalBytes)
        try await downloadMTPNodeRecursively(
            node,
            to: destination,
            transport: transport,
            aggregate: aggregate,
            progress: progress
        )
    }

    private static func downloadMTPNodeRecursively(
        _ node: FileNode,
        to destination: URL,
        transport: MTPTransport,
        aggregate: MTPAggregateDownloadProgress,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        if node.isDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try await transport.listChildren(of: node.id, in: node.storageID)
            for child in children {
                try await downloadMTPNodeRecursively(
                    child,
                    to: destination.appending(path: child.name, directoryHint: child.isDirectory ? .isDirectory : .notDirectory),
                    transport: transport,
                    aggregate: aggregate,
                    progress: progress
                )
            }
            return
        }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let base = aggregate.baseCompletedBytes()
        try await transport.download(node.id, to: destination) { fileProgress in
            progress(aggregate.aggregateProgress(fileName: node.name, fileProgress: fileProgress, base: base))
        }
        aggregate.commit(bytes: node.size)
    }

    private func exportImageCaptureFile(_ file: ICCameraFile, item: USBTransferItem, to destination: URL) async throws -> URL {
        let directory = destination.deletingLastPathComponent()
        let fileName = destination.lastPathComponent
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: directory,
            .saveAsFilename: fileName,
            .overwrite: true,
            .sidecarFiles: true,
            .truncateAfterSuccessfulDownload: true
        ]

        return try await withCheckedThrowingContinuation { continuation in
            _ = file.requestDownload(options: options) { savedFilename, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: directory.appending(path: savedFilename ?? fileName))
            }
        }
    }

    public func canModifyMTPItem(_ item: USBTransferItem) -> Bool {
        backend.isWritable && mtpNodes[item.id] != nil
    }

    public func canCompressMTPItem(_ item: USBTransferItem) -> Bool {
        backend == .mtp && canWriteCurrentMTPFolder && item.canCompress && mtpNodes[item.id] != nil
    }

    public func canExtractMTPArchive(_ item: USBTransferItem) -> Bool {
        backend == .mtp && canWriteCurrentMTPFolder && item.isExtractableArchive && mtpNodes[item.id] != nil
    }

    public func canAcceptLocalFileDrop(onto item: USBTransferItem? = nil) -> Bool {
        backend == .mtp && mtpUploadTarget(for: item) != nil
    }

    @MainActor public func acceptLocalFileDrop(_ urls: [URL], onto item: USBTransferItem? = nil) -> Bool {
        guard backend == .mtp else {
            if let issue = mtpAccessIssue {
                alert = UserAlert(title: issue.title, message: issue.message)
                statusMessage = issue.statusMessage
            } else {
                alert = UserAlert(
                    title: "File Transfer Is Read-Only",
                    message: "Photo access can browse and download photos, but it cannot copy files onto the phone. Choose File transfer / Android Auto for uploads."
                )
                statusMessage = "Photo access is read-only."
            }
            return false
        }

        guard let target = mtpUploadTarget(for: item) else {
            statusMessage = "Open a writable phone folder before dropping files."
            return false
        }

        uploadMTPURLs(urls, target: target)
        return true
    }

    @MainActor public func canPasteLocalFilesFromPasteboard(into item: USBTransferItem? = nil) -> Bool {
        canAcceptLocalFileDrop(onto: item) && !Self.localFileURLsFromPasteboard().isEmpty
    }

    @MainActor public func pasteLocalFilesFromPasteboard(into item: USBTransferItem? = nil) {
        let urls = Self.localFileURLsFromPasteboard()
        guard !urls.isEmpty else {
            statusMessage = "Nothing to paste."
            return
        }
        _ = acceptLocalFileDrop(urls, onto: item)
    }

    private static func localFileURLsFromPasteboard() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        return (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    @MainActor public func uploadToCurrentMTPFolder() {
        guard let target = mtpUploadTarget(for: nil) else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Files or Folders to Upload"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        uploadMTPURLs(panel.urls, target: target)
    }

    @MainActor private func uploadMTPURLs(_ urls: [URL], target: MTPUploadTarget) {
        guard let transport = mtpTransport else { return }
        let uploadRequests: [USBLocalUploadRequest]
        do {
            uploadRequests = try urls.map {
                try localUploadRequest(for: $0, remoteName: $0.lastPathComponent, replace: false)
            }
        } catch {
            alert = UserAlert(title: "Upload Failed", message: error.localizedDescription)
            statusMessage = "Upload failed."
            return
        }

        guard !uploadRequests.isEmpty else {
            statusMessage = "Open a writable phone folder before dropping files."
            return
        }

        if let transferQueue {
            beginTerminationBlockingActivity()
            Task { @MainActor [weak self, transport, target, uploadRequests, transferQueue] in
                guard let self else { return }
                defer { self.endTerminationBlockingActivity() }
                await self.enqueueQueuedMTPUploads(uploadRequests, target: target, transport: transport, queue: transferQueue)
            }
            return
        }

        let uploadURLs = uploadRequests.filter { !$0.isDirectory }.map(\.url)
        guard !uploadURLs.isEmpty else {
            statusMessage = "Folder uploads require the transfer queue."
            return
        }

        isDownloading = true
        beginTerminationBlockingActivity()
        statusMessage = "Uploading \(uploadURLs.count) item\(uploadURLs.count == 1 ? "" : "s") to \(target.displayPath)..."
        Task { [weak self, transport, target, uploadURLs] in
            var completed = 0
            var failures: [String] = []
            var effectiveUploadURLs = uploadURLs

            do {
                let existingNames: Set<String>
                if target.refreshesCurrentListing {
                    existingNames = await MainActor.run {
                        Set(self?.items.map { $0.name.lowercased() } ?? [])
                    }
                } else {
                    let children = try await transport.listChildren(of: target.parentID, in: target.storageID)
                    existingNames = Set(children.map { $0.name.lowercased() })
                }

                let duplicates = uploadURLs.filter { existingNames.contains($0.lastPathComponent.lowercased()) }
                effectiveUploadURLs = uploadURLs.filter { url in
                    !duplicates.contains(where: { $0 == url })
                }

                if !duplicates.isEmpty {
                    await MainActor.run {
                        let names = duplicates.prefix(5).map(\.lastPathComponent).joined(separator: ", ")
                        let suffix = duplicates.count > 5 ? " and \(duplicates.count - 5) more" : ""
                        self?.alert = UserAlert(
                            title: "Duplicate Detected",
                            message: "These files already exist in \(target.displayPath) and were not overwritten: \(names)\(suffix)."
                        )
                    }
                }
            } catch {
                failures.append("Could not inspect \(target.displayPath): \(error.localizedDescription)")
                effectiveUploadURLs = []
            }

            for url in effectiveUploadURLs {
                let name = url.lastPathComponent
                do {
                    _ = try await transport.upload(localURL: url, as: name, toParent: target.parentID, in: target.storageID) { [weak self] progress in
                        Task { @MainActor in
                            self?.statusMessage = Self.progressMessage(prefix: "Uploading", progress: progress)
                        }
                    }
                    completed += 1
                } catch {
                    failures.append("\(name): \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                guard let self else { return }
                self.isDownloading = false
                self.endTerminationBlockingActivity()
                if let firstFailure = failures.first {
                    self.alert = UserAlert(
                        title: "Upload Failed",
                        message: failures.count == 1 ? firstFailure : "\(firstFailure)\n\n\(failures.count - 1) more failed."
                    )
                }
                if completed == 0, failures.isEmpty {
                    self.statusMessage = "Upload skipped to avoid overwriting existing files."
                } else {
                    self.statusMessage = failures.isEmpty
                        ? "Uploaded \(completed) item\(completed == 1 ? "" : "s") to \(target.displayPath)."
                        : "Uploaded \(completed) item\(completed == 1 ? "" : "s"); \(failures.count) failed."
                }
                if target.refreshesCurrentListing {
                    self.refreshMTPCurrentItems()
                }
            }
        }
    }

    @MainActor private func enqueueQueuedMTPUploads(_ uploadRequests: [USBLocalUploadRequest], target: MTPUploadTarget, transport: MTPTransport, queue: TransferQueue) async {
        do {
            let existingNames: Set<String>
            if target.refreshesCurrentListing {
                existingNames = Set(items.map { $0.name.lowercased() })
            } else {
                let children = try await transport.listChildren(of: target.parentID, in: target.storageID)
                existingNames = Set(children.map { $0.name.lowercased() })
            }

            let duplicates = uploadRequests.filter { existingNames.contains($0.remoteName.lowercased()) }
            let resolution = duplicates.isEmpty
                ? nil
                : promptDuplicateResolution(itemNames: duplicates.map(\.remoteName), destination: target.displayPath)
            if !duplicates.isEmpty, resolution == nil {
                statusMessage = "Upload canceled."
                return
            }

            var queuedCount = 0
            var claimedNames = existingNames
            for request in uploadRequests {
                var resolvedRequest = request
                if duplicates.contains(where: { $0.url == request.url }), let resolution {
                    switch resolution {
                    case .skip:
                        continue
                    case .replace:
                        alert = UserAlert(
                            title: "This File Couldn't Be Replaced",
                            message: "This phone does not support safe replacement through File Transfer. \(request.remoteName) was skipped."
                        )
                        continue
                    case .keep:
                        resolvedRequest.remoteName = TransferConflictResolver.enumeratedName(for: request.remoteName, existingNames: claimedNames)
                    }
                }
                claimedNames.insert(resolvedRequest.remoteName.lowercased())

                if resolvedRequest.isDirectory {
                    enqueueMTPFolderUpload(resolvedRequest, target: target, transport: transport, queue: queue)
                } else if let file = resolvedRequest.files.first {
                    enqueueMTPFileUpload(
                        file,
                        title: resolvedRequest.url.lastPathComponent,
                        remoteName: resolvedRequest.remoteName,
                        parentID: target.parentID,
                        displayPath: target.displayPath,
                        storageID: target.storageID,
                        transport: transport,
                        queue: queue,
                        groupID: nil,
                        exclusiveGroup: "mtp:\(transport.id)"
                    )
                }
                queuedCount += 1
            }

            queue.isPanelExpanded = true
            statusMessage = queuedCount == 0 ? "Upload skipped." : "Queued \(queuedCount) upload\(queuedCount == 1 ? "" : "s")."
        } catch {
            alert = UserAlert(title: "Upload Failed", message: error.localizedDescription)
            statusMessage = "Upload failed."
        }
    }

    @MainActor private func enqueueMTPFolderUpload(_ request: USBLocalUploadRequest, target: MTPUploadTarget, transport: MTPTransport, queue: TransferQueue) {
        let remotePath = "\(target.displayPath)/\(request.remoteName)"
        let groupID = queue.enqueueGroup(
            kind: .upload,
            title: request.url.lastPathComponent,
            subtitle: "Uploading folder to \(target.displayPath)",
            source: TransferEndpoint(kind: .mac, path: request.url.path, displayName: request.url.lastPathComponent),
            destination: TransferEndpoint(kind: .usbTransfer, deviceID: selectedDeviceID, path: remotePath, displayName: request.remoteName),
            totalBytes: request.totalBytes
        )
        let exclusiveGroup = "mtp-folder-upload:\(groupID.uuidString)"
        let context = QueuedMTPFolderUploadContext(storageID: target.storageID)

        queue.enqueue(
            kind: .upload,
            title: request.remoteName,
            subtitle: "Creating folder in \(target.displayPath)",
            source: TransferEndpoint(kind: .mac, path: request.url.path, displayName: request.url.lastPathComponent),
            destination: TransferEndpoint(kind: .usbTransfer, deviceID: selectedDeviceID, path: remotePath, displayName: request.remoteName),
            itemKind: .folder,
            parentID: groupID,
            totalBytes: 0,
            exclusiveGroup: exclusiveGroup
        ) { controller in
            controller.updateProgress(fractionCompleted: 0)
            try controller.checkCancellation()
            let node = try await transport.createDirectory(named: request.remoteName, inParent: target.parentID, in: target.storageID)
            try controller.checkCancellation()
            context.installRootNodeID(node.id)
            controller.updateProgress(fractionCompleted: 1)
            return TransferJobResult(message: "Created")
        }

        for file in request.files {
            enqueueMTPFileUpload(
                file,
                title: file.remoteName,
                remoteName: file.remoteName,
                parentID: nil,
                displayPath: file.relativeDirectory.isEmpty ? remotePath : "\(remotePath)/\(file.relativeDirectory)",
                storageID: target.storageID,
                transport: transport,
                queue: queue,
                groupID: groupID,
                exclusiveGroup: exclusiveGroup,
                folderContext: context
            )
        }
    }

    @MainActor private func enqueueMTPFileUpload(
        _ file: USBLocalUploadFile,
        title: String,
        remoteName: String,
        parentID: String?,
        displayPath: String,
        storageID: String,
        transport: MTPTransport,
        queue: TransferQueue,
        groupID: UUID?,
        exclusiveGroup: String,
        folderContext: QueuedMTPFolderUploadContext? = nil
    ) {
        queue.enqueue(
            kind: .upload,
            title: title,
            subtitle: "Uploading to \(displayPath)",
            source: TransferEndpoint(kind: .mac, path: file.url.path, displayName: title),
            destination: TransferEndpoint(kind: .usbTransfer, deviceID: selectedDeviceID, path: "\(displayPath)/\(remoteName)", displayName: remoteName),
            itemKind: .file,
            parentID: groupID,
            totalBytes: file.size,
            exclusiveGroup: exclusiveGroup
        ) { controller in
            try controller.checkCancellation()
            let resolvedParentID: String?
            if let folderContext {
                resolvedParentID = try await folderContext.parentID(for: file.relativeDirectory, transport: transport)
            } else {
                resolvedParentID = parentID
            }

            try controller.checkCancellation()
            _ = try await transport.upload(localURL: file.url, as: remoteName, toParent: resolvedParentID, in: storageID) { progress in
                Task { @MainActor in
                    controller.updateProgress(
                        completedBytes: progress.completedBytes,
                        totalBytes: progress.totalBytes,
                        fractionCompleted: progress.fractionCompleted,
                        message: Self.progressMessage(prefix: "Uploading", progress: progress)
                    )
                }
            }
            try controller.checkCancellation()
            return TransferJobResult(message: "Uploaded")
        }
    }

    @MainActor public func requestMTPCompressSelected() {
        guard canCompressSelectedMTPItems else { return }
        pendingMTPArchiveRequest = ArchiveCreationRequest(defaultName: defaultMTPArchiveName())
    }

    @MainActor public func requestMTPCompress(item: USBTransferItem) {
        guard canCompressMTPItem(item) else { return }
        selectedItemIDs = [item.id]
        pendingMTPArchiveRequest = ArchiveCreationRequest(defaultName: defaultMTPArchiveName(for: [item]))
    }

    @MainActor public func compressSelectedMTPItems(as rawName: String) {
        guard let transport = mtpTransport,
              let storageID = currentMTPStorageID,
              canCompressSelectedMTPItems else {
            return
        }

        let archiveName = Self.normalizedArchiveName(rawName)
        let parentID = currentMTPParentID
        let targetPath = currentPath
        let requests = selectedMTPCompressibleItems.compactMap { item -> MTPArchiveNodeRequest? in
            guard let node = mtpNodes[item.id] else { return nil }
            return MTPArchiveNodeRequest(item: item, node: node)
        }
        guard !requests.isEmpty else { return }

        pendingMTPArchiveRequest = nil
        isDownloading = true
        beginTerminationBlockingActivity()
        statusMessage = "Compressing \(requests.count) item\(requests.count == 1 ? "" : "s")..."

        Task { [weak self, transport, storageID, parentID, targetPath, requests, archiveName] in
            guard let manager = self else { return }
            do {
                let existingNames = try await transport.listChildren(of: parentID, in: storageID).map { $0.name.lowercased() }
                guard !existingNames.contains(archiveName.lowercased()) else {
                    throw FileOperationError.duplicateExists("\(targetPath)/\(archiveName)")
                }

                let workDirectory = try Self.archiveWorkDirectory(prefix: "MTP-Compress")
                defer { try? FileManager.default.removeItem(at: workDirectory) }
                let payloadDirectory = workDirectory.appending(path: "Payload", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)

                var relativePaths: [String] = []
                let updateStatus: @Sendable (String) -> Void = { message in
                    Task { @MainActor in manager.statusMessage = message }
                }

                for request in requests {
                    let relativePath = Self.safeArchiveComponent(request.item.name)
                    let destination = payloadDirectory.appending(path: relativePath)
                    try await Self.downloadMTPNode(
                        request.node,
                        to: destination,
                        transport: transport,
                        status: updateStatus
                    )
                    relativePaths.append(relativePath)
                }

                let localArchiveURL = workDirectory.appending(path: archiveName)
                try await Self.runLocalArchiveTool(
                    executable: "/usr/bin/zip",
                    arguments: ["-qry", localArchiveURL.path, "--"] + relativePaths,
                    currentDirectory: payloadDirectory
                )

                _ = try await transport.upload(localURL: localArchiveURL, as: archiveName, toParent: parentID, in: storageID) { progress in
                    updateStatus(Self.progressMessage(prefix: "Uploading", progress: progress))
                }

                await MainActor.run {
                    manager.isDownloading = false
                    manager.endTerminationBlockingActivity()
                    manager.statusMessage = "Created \(archiveName) in \(targetPath)."
                    manager.refreshMTPCurrentItems()
                }
            } catch {
                await MainActor.run {
                    manager.isDownloading = false
                    manager.endTerminationBlockingActivity()
                    manager.alert = UserAlert(title: "Compress Failed", message: error.localizedDescription)
                    manager.statusMessage = "Compress failed."
                }
            }
        }
    }

    @MainActor public func extractMTPArchive(_ item: USBTransferItem) {
        guard let transport = mtpTransport,
              let storageID = currentMTPStorageID,
              let archiveNode = mtpNodes[item.id],
              canExtractMTPArchive(item) else {
            return
        }

        selectedItemIDs = [item.id]
        let parentID = currentMTPParentID
        let targetPath = currentPath
        let destinationName = Self.safeArchiveComponent(item.archiveExtractionFolderName.isEmpty ? "Extracted Archive" : item.archiveExtractionFolderName)

        isDownloading = true
        beginTerminationBlockingActivity()
        statusMessage = "Uncompressing \(item.name)..."

        Task { [weak self, transport, storageID, parentID, targetPath, item, archiveNode, destinationName] in
            guard let manager = self else { return }
            do {
                let existingNames = try await transport.listChildren(of: parentID, in: storageID).map { $0.name.lowercased() }
                guard !existingNames.contains(destinationName.lowercased()) else {
                    throw FileOperationError.duplicateExists("\(targetPath)/\(destinationName)")
                }

                let workDirectory = try Self.archiveWorkDirectory(prefix: "MTP-Extract")
                defer { try? FileManager.default.removeItem(at: workDirectory) }
                let localArchiveURL = workDirectory.appending(path: item.name)
                let extractDirectory = workDirectory.appending(path: destinationName, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)

                let updateStatus: @Sendable (String) -> Void = { message in
                    Task { @MainActor in manager.statusMessage = message }
                }

                try await transport.download(archiveNode.id, to: localArchiveURL) { progress in
                    updateStatus(Self.progressMessage(prefix: "Downloading", progress: progress))
                }
                try await Self.extractLocalArchive(localArchiveURL, to: extractDirectory)

                let rootNode = try await transport.createDirectory(named: destinationName, inParent: parentID, in: storageID)
                try await Self.uploadDirectoryContents(
                    of: extractDirectory,
                    toParent: rootNode.id,
                    in: storageID,
                    transport: transport,
                    status: updateStatus
                )

                await MainActor.run {
                    manager.isDownloading = false
                    manager.endTerminationBlockingActivity()
                    manager.statusMessage = "Uncompressed \(item.name) to \(targetPath)/\(destinationName)."
                    manager.refreshMTPCurrentItems()
                }
            } catch {
                await MainActor.run {
                    manager.isDownloading = false
                    manager.endTerminationBlockingActivity()
                    manager.alert = UserAlert(title: "Uncompress Failed", message: error.localizedDescription)
                    manager.statusMessage = "Uncompress failed."
                }
            }
        }
    }

    public func requestMTPNewFolder(in item: USBTransferItem? = nil) {
        guard let uploadTarget = mtpUploadTarget(for: item) else { return }
        pendingMTPFolderCreationTarget = MTPFolderCreationTarget(
            storageID: uploadTarget.storageID,
            parentID: uploadTarget.parentID,
            displayPath: uploadTarget.displayPath,
            parentItemID: item?.id,
            listingKey: MTPFolderListingKey(
                storageID: uploadTarget.storageID,
                parentID: uploadTarget.parentID,
                path: uploadTarget.displayPath
            )
        )
        if let item {
            expandedFolderItemIDs.insert(item.id)
            if treeChildrenByItemID[item.id] == nil {
                Task { await loadFolderChildren(for: item) }
            }
        }
        isCreatingMTPFolder = true
    }

    @MainActor public func createMTPFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validationMessage = RemoteFileNameValidator.validationMessage(for: trimmed) {
            alert = UserAlert(title: "That Name Can't Be Used", message: validationMessage)
            return
        }
        guard let transport = mtpTransport,
              let target = pendingMTPFolderCreationTarget else { return }
        pendingMTPFolderCreationTarget = nil

        let siblings = mtpFolderListingsByKey[target.listingKey]
            ?? target.parentItemID.flatMap { treeChildrenByItemID[$0] }
            ?? (currentMTPFolderListingKey == target.listingKey ? items : [])
        if siblings.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            alert = UserAlert(title: "Duplicate Detected", message: "\(trimmed) already exists in this folder.")
            return
        }

        isDownloading = true
        beginTerminationBlockingActivity()
        statusMessage = "Creating \(trimmed)..."
        let provisional = USBTransferItem(
            id: "mtp-pending:\(UUID().uuidString)",
            name: trimmed,
            path: target.displayPath == "/" ? "/\(trimmed)" : "\(target.displayPath)/\(trimmed)",
            kind: .folder,
            size: nil,
            modified: Date(),
            uti: UTType.folder.identifier
        )
        if let parentItemID = target.parentItemID {
            invalidateFolderChildrenLoad(for: parentItemID)
        }
        insertCreatedMTPFolder(provisional, target: target)

        Task { [weak self, transport, target, trimmed, provisional] in
            do {
                let node = try await transport.createDirectory(
                    named: trimmed,
                    inParent: target.parentID,
                    in: target.storageID
                )
                await MainActor.run {
                    guard let self else { return }
                    let created = self.makeMTPItem(from: node, parentPath: target.displayPath)
                    let operationOwnedSelection = self.selectedItemIDs == [provisional.id]
                    self.removeCreatedMTPFolder(provisional, target: target)
                    self.insertCreatedMTPFolder(
                        created,
                        target: target,
                        selectsCreatedItem: operationOwnedSelection && self.isMTPFolderCreationTargetVisible(target)
                    )
                    self.isDownloading = false
                    self.endTerminationBlockingActivity()
                    self.statusMessage = "Created \(trimmed)."
                }
            } catch {
                await MainActor.run {
                    if let self {
                        self.removeCreatedMTPFolder(provisional, target: target)
                    }
                    self?.isDownloading = false
                    self?.endTerminationBlockingActivity()
                    self?.alert = UserAlert(title: "Create Folder Failed", message: error.localizedDescription)
                    self?.statusMessage = "Create folder failed."
                }
            }
        }
    }

    private func insertCreatedMTPFolder(
        _ item: USBTransferItem,
        target: MTPFolderCreationTarget,
        selectsCreatedItem: Bool = true
    ) {
        var listing = mtpFolderListingsByKey[target.listingKey] ?? []
        listing.removeAll { $0.id == item.id || $0.path == item.path }
        listing.append(item)
        mtpFolderListingsByKey[target.listingKey] = listing

        if let parentItemID = target.parentItemID {
            var children = treeChildrenByItemID[parentItemID] ?? []
            children.removeAll { $0.id == item.id || $0.path == item.path }
            children.append(item)
            treeChildrenByItemID[parentItemID] = children
            expandedFolderItemIDs.insert(parentItemID)
        }
        if currentMTPFolderListingKey == target.listingKey {
            items.removeAll { $0.id == item.id || $0.path == item.path }
            items.append(item)
        }
        if selectsCreatedItem {
            selectedItemIDs = [item.id]
            lastSelectedItemID = item.id
            keyboardSelectionAnchorItemID = item.id
        }
    }

    private func removeCreatedMTPFolder(_ item: USBTransferItem, target: MTPFolderCreationTarget) {
        mtpFolderListingsByKey[target.listingKey]?.removeAll { $0.id == item.id }
        if let parentItemID = target.parentItemID {
            treeChildrenByItemID[parentItemID]?.removeAll { $0.id == item.id }
        }
        if currentMTPFolderListingKey == target.listingKey {
            items.removeAll { $0.id == item.id }
        }
        selectedItemIDs.remove(item.id)
        if lastSelectedItemID == item.id { lastSelectedItemID = nil }
        if keyboardSelectionAnchorItemID == item.id { keyboardSelectionAnchorItemID = nil }
    }

    private func isMTPFolderCreationTargetVisible(_ target: MTPFolderCreationTarget) -> Bool {
        if currentMTPFolderListingKey == target.listingKey {
            return true
        }
        guard let parentItemID = target.parentItemID else { return false }
        return expandedFolderItemIDs.contains(parentItemID)
            && visibleItemsIncludingExpandedChildren.contains { $0.id == parentItemID }
    }

    public func requestMTPRename(item: USBTransferItem) {
        guard canModifyMTPItem(item) else { return }
        pendingMTPRenameItem = item
    }

    public func requestRenameSelectedMTPItem() {
        guard selectedItems.count == 1,
              let item = selectedItems.first else {
            return
        }
        requestMTPRename(item: item)
    }

    @MainActor public func renameMTPItem(_ item: USBTransferItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validationMessage = RemoteFileNameValidator.validationMessage(for: trimmed) {
            alert = UserAlert(title: "That Name Can't Be Used", message: validationMessage)
            return
        }
        guard trimmed != item.name,
              let transport = mtpTransport,
              let node = mtpNodes[item.id] else { return }

        let parentPath = (item.path as NSString).deletingLastPathComponent
        let siblings = knownItems.filter {
            ($0.path as NSString).deletingLastPathComponent == parentPath
        }
        if siblings.contains(where: {
            $0.id != item.id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            alert = UserAlert(title: "Duplicate Detected", message: "\(trimmed) already exists in this folder.")
            return
        }

        let newPath = parentPath == "/" ? "/\(trimmed)" : "\(parentPath)/\(trimmed)"
        let itemsBeforeRename = items
        let treeChildrenBeforeRename = treeChildrenByItemID
        let listingsBeforeRename = mtpFolderListingsByKey
        let visibleListingBeforeRename = visibleMTPListingKey
        let navigationBeforeRename = currentNavigationSnapshot()
        let backHistoryBeforeRename = backHistory
        let forwardHistoryBeforeRename = forwardHistory
        let parentItem = node.parentID.flatMap { parentNodeID in
            knownItems.first { mtpNodes[$0.id]?.id == parentNodeID }
        }

        mtpListingRequestID = UUID()
        mtpBrowserMutationDepth += 1
        remapMTPBrowserPath(from: item.path, to: newPath)
        let navigationAfterOptimisticRename = currentNavigationSnapshot()
        let backHistoryAfterOptimisticRename = backHistory
        let forwardHistoryAfterOptimisticRename = forwardHistory

        isDownloading = true
        beginTerminationBlockingActivity()
        statusMessage = "Renaming \(item.name)..."
        Task { [weak self, transport, node, item, trimmed, newPath, parentItem] in
            do {
                let renamedNode = try await transport.rename(node.id, to: trimmed)
                await MainActor.run {
                    guard let self else { return }
                    self.mtpNodes[item.id] = renamedNode
                    self.isDownloading = false
                    self.endTerminationBlockingActivity()
                    self.mtpBrowserMutationDepth = max(0, self.mtpBrowserMutationDepth - 1)
                    self.schedulePendingMTPObservedRefresh()
                    self.statusMessage = "Renamed \(item.name) to \(trimmed)."
                    self.refreshMTPCurrentItems()
                    if let parentItem {
                        self.invalidateFolderChildrenLoad(for: parentItem.id)
                        Task { await self.loadFolderChildren(for: parentItem) }
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    let navigationAtFailure = self.currentNavigationSnapshot()
                    let backHistoryAtFailure = self.backHistory
                    let forwardHistoryAtFailure = self.forwardHistory
                    let itemsAtFailure = self.items
                    let visibleListingAtFailure = self.visibleMTPListingKey
                    let navigationChangedByUser =
                        navigationAtFailure != navigationAfterOptimisticRename
                        || backHistoryAtFailure != backHistoryAfterOptimisticRename
                        || forwardHistoryAtFailure != forwardHistoryAfterOptimisticRename

                    self.items = itemsBeforeRename
                    self.treeChildrenByItemID = treeChildrenBeforeRename
                    self.mtpFolderListingsByKey = listingsBeforeRename
                    self.visibleMTPListingKey = visibleListingBeforeRename
                    self.pathComponents = navigationBeforeRename.pathComponents
                    self.currentContainerID = navigationBeforeRename.currentContainerID
                    self.currentMTPStorageID = navigationBeforeRename.currentMTPStorageID
                    self.currentMTPParentID = navigationBeforeRename.currentMTPParentID
                    self.mtpPathStates = navigationBeforeRename.mtpPathStates
                    self.backHistory = backHistoryBeforeRename
                    self.forwardHistory = forwardHistoryBeforeRename

                    if navigationChangedByUser {
                        self.pathComponents = navigationAtFailure.pathComponents
                        self.currentContainerID = navigationAtFailure.currentContainerID
                        self.currentMTPStorageID = navigationAtFailure.currentMTPStorageID
                        self.currentMTPParentID = navigationAtFailure.currentMTPParentID
                        self.mtpPathStates = navigationAtFailure.mtpPathStates
                        self.backHistory = backHistoryAtFailure
                        self.forwardHistory = forwardHistoryAtFailure
                        self.items = itemsAtFailure.map {
                            self.remappingMTPItem($0, from: newPath, to: item.path)
                        }
                        self.visibleMTPListingKey = visibleListingAtFailure.map {
                            MTPFolderListingKey(
                                storageID: $0.storageID,
                                parentID: $0.parentID,
                                path: self.remappingMTPPath($0.path, from: newPath, to: item.path)
                            )
                        }
                    }

                    self.isDownloading = false
                    self.endTerminationBlockingActivity()
                    self.mtpBrowserMutationDepth = max(0, self.mtpBrowserMutationDepth - 1)
                    self.schedulePendingMTPObservedRefresh()
                    self.alert = UserAlert(title: "Rename Failed", message: error.localizedDescription)
                    self.statusMessage = "Rename failed."
                }
            }
        }
    }

    @MainActor public func deleteSelectedMTPItems() {
        let requests = selectedItems.compactMap { item -> MTPDeleteRequest? in
            guard let node = mtpNodes[item.id] else { return nil }
            return MTPDeleteRequest(item: item, nodeID: node.id)
        }
        guard let transport = mtpTransport, !requests.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = requests.count == 1 ? "Delete \(requests[0].item.name)?" : "Delete \(requests.count) items?"
        alert.informativeText = "File Transfer deletes these items directly from the phone. They cannot be restored from the app Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let itemsBeforeDelete = items
        let treeChildrenBeforeDelete = treeChildrenByItemID
        let listingsBeforeDelete = mtpFolderListingsByKey
        let expandedBeforeDelete = expandedFolderItemIDs
        let selectionBeforeDelete = selectedItemIDs
        let lastSelectedBeforeDelete = lastSelectedItemID
        let keyboardAnchorBeforeDelete = keyboardSelectionAnchorItemID
        let requestedIDs = Set(requests.map(\.item.id))
        let currentPathBeforeDelete = currentPath

        // Invalidate a listing that started before the mutation, then remove the
        // rows immediately. The transport work continues after Finder-like UI
        // feedback, and only failed items are put back.
        mtpListingRequestID = UUID()
        mtpBrowserMutationDepth += 1
        let optimisticallyRemovedIDs = removeMTPItemsFromBrowser(requests.map(\.item))
        let expectedSelectionAfterDelete = selectionBeforeDelete.subtracting(requestedIDs)
        let expectedExpansionAfterDelete = expandedFolderItemIDs

        isDownloading = true
        beginTerminationBlockingActivity()
        statusMessage = "Deleting \(requests.count) item\(requests.count == 1 ? "" : "s")..."
        Task { [weak self, transport, requests] in
            var completedIDs = Set<USBTransferItem.ID>()
            var failures: [(USBTransferItem.ID, String)] = []
            for request in requests {
                do {
                    try await transport.delete(request.nodeID)
                    completedIDs.insert(request.item.id)
                    await MainActor.run {
                        self?.statusMessage = "Deleted \(completedIDs.count) of \(requests.count) item\(requests.count == 1 ? "" : "s")..."
                    }
                } catch {
                    failures.append((request.item.id, "\(request.item.name): \(error.localizedDescription)"))
                }
            }

            await MainActor.run {
                guard let self else { return }
                defer {
                    self.mtpBrowserMutationDepth = max(0, self.mtpBrowserMutationDepth - 1)
                    self.schedulePendingMTPObservedRefresh()
                }
                self.isDownloading = false
                self.endTerminationBlockingActivity()

                if !failures.isEmpty {
                    let currentPathAtCompletion = self.currentPath
                    let itemsAtCompletion = self.items
                    let selectionAtCompletion = self.selectedItemIDs
                    let expansionAtCompletion = self.expandedFolderItemIDs
                    let selectionChangedByUser = selectionAtCompletion != expectedSelectionAfterDelete
                    let expansionChangedByUser = expansionAtCompletion != expectedExpansionAfterDelete

                    // Restore the pre-delete cache, then remove only the objects
                    // the phone actually deleted. This keeps failed rows usable.
                    self.items = itemsBeforeDelete
                    self.treeChildrenByItemID = treeChildrenBeforeDelete
                    self.mtpFolderListingsByKey = listingsBeforeDelete
                    self.expandedFolderItemIDs = expandedBeforeDelete
                    self.selectedItemIDs = selectionBeforeDelete
                    self.lastSelectedItemID = lastSelectedBeforeDelete
                    self.keyboardSelectionAnchorItemID = keyboardAnchorBeforeDelete
                    let completedItems = requests
                        .filter { completedIDs.contains($0.item.id) }
                        .map(\.item)
                    _ = self.removeMTPItemsFromBrowser(completedItems)

                    if currentPathAtCompletion != currentPathBeforeDelete {
                        self.items = itemsAtCompletion
                    }

                    if selectionChangedByUser {
                        self.selectedItemIDs = selectionAtCompletion.subtracting(completedIDs)
                    }
                    if expansionChangedByUser {
                        self.expandedFolderItemIDs = expansionAtCompletion.subtracting(optimisticallyRemovedIDs)
                    }
                }

                for id in completedIDs {
                    self.mtpNodes.removeValue(forKey: id)
                }
                self.pruneMTPNavigationForDeletedPaths(
                    requests.filter { completedIDs.contains($0.item.id) }.map(\.item.path)
                )
                if let firstFailure = failures.first?.1 {
                    self.alert = UserAlert(
                        title: "Delete Failed",
                        message: failures.count == 1 ? firstFailure : "\(firstFailure)\n\n\(failures.count - 1) more failed."
                    )
                }
                let completed = completedIDs.count
                self.statusMessage = failures.isEmpty
                    ? "Deleted \(completed) item\(completed == 1 ? "" : "s")."
                    : "Deleted \(completed) item\(completed == 1 ? "" : "s"); \(failures.count) failed."
                self.refreshMTPCurrentItems()
            }
        }
    }

    @MainActor @discardableResult
    private func removeMTPItemsFromBrowser(_ removedItems: [USBTransferItem]) -> Set<USBTransferItem.ID> {
        let removedPaths = removedItems.map(\.path)
        guard !removedPaths.isEmpty else { return [] }
        let removedIDs = Set(knownItems.filter {
            Self.path($0.path, isEqualToOrDescendantOfAny: removedPaths)
        }.map(\.id)).union(removedItems.map(\.id))

        items.removeAll {
            removedIDs.contains($0.id)
                || Self.path($0.path, isEqualToOrDescendantOfAny: removedPaths)
        }
        for parentID in Array(treeChildrenByItemID.keys) {
            if removedIDs.contains(parentID) {
                treeChildrenByItemID.removeValue(forKey: parentID)
            } else {
                treeChildrenByItemID[parentID]?.removeAll {
                    removedIDs.contains($0.id)
                        || Self.path($0.path, isEqualToOrDescendantOfAny: removedPaths)
                }
            }
        }
        mtpFolderListingsByKey = mtpFolderListingsByKey.reduce(into: [:]) { result, entry in
            let (key, cachedItems) = entry
            guard !Self.path(key.path, isEqualToOrDescendantOfAny: removedPaths) else { return }
            result[key] = cachedItems.filter {
                !removedIDs.contains($0.id)
                    && !Self.path($0.path, isEqualToOrDescendantOfAny: removedPaths)
            }
        }
        expandedFolderItemIDs.subtract(removedIDs)
        selectedItemIDs.subtract(removedIDs)
        folderSizeBytesByItemID = folderSizeBytesByItemID.filter { !removedIDs.contains($0.key) }
        loadingFolderSizeItemIDs.subtract(removedIDs)
        failedFolderSizeItemIDs.subtract(removedIDs)
        if let lastSelectedItemID, removedIDs.contains(lastSelectedItemID) {
            self.lastSelectedItemID = nil
        }
        if let keyboardSelectionAnchorItemID, removedIDs.contains(keyboardSelectionAnchorItemID) {
            self.keyboardSelectionAnchorItemID = nil
        }
        return removedIDs
    }

    static func path(_ path: String, isEqualToOrDescendantOfAny ancestors: [String]) -> Bool {
        ancestors.contains { ancestor in
            path == ancestor || path.hasPrefix("\(ancestor)/")
        }
    }

    @MainActor private func pruneMTPNavigationForDeletedPaths(_ deletedPaths: [String]) {
        guard !deletedPaths.isEmpty else { return }
        mtpPathStates = mtpPathStates.filter {
            !Self.path($0.value.path, isEqualToOrDescendantOfAny: deletedPaths)
        }
        backHistory.removeAll { snapshot in
            guard let path = snapshot.pathComponents.last?.path else { return false }
            return Self.path(path, isEqualToOrDescendantOfAny: deletedPaths)
        }
        forwardHistory.removeAll { snapshot in
            guard let path = snapshot.pathComponents.last?.path else { return false }
            return Self.path(path, isEqualToOrDescendantOfAny: deletedPaths)
        }
    }

    public func preview(item: USBTransferItem) {
        Task { @MainActor in
            do {
                let url = try await cachedPreviewURL(for: item)
                PreviewWindowPresenter.show(url: url) { [weak self] in
                    self?.releaseCachedPreviewURL(url)
                }
            } catch {
                alert = UserAlert(title: "Preview Failed", message: error.localizedDescription)
                statusMessage = "Preview failed."
            }
        }
    }

    @MainActor private func releaseCachedPreviewURL(_ url: URL) {
        Task {
            await previewCacheStore.releaseReadablePreview(url)
        }
    }

    @MainActor public func prepareMediaMetadata(for item: USBTransferItem) async {
        guard item.isDownloadable,
              item.mediaKind != nil,
              mediaMetadataByItemID[item.id] == nil,
              !loadingMediaMetadataItemIDs.contains(item.id) else {
            return
        }

        loadingMediaMetadataItemIDs.insert(item.id)
        failedMediaMetadataItemMessages[item.id] = nil
        defer { loadingMediaMetadataItemIDs.remove(item.id) }

        do {
            let localURL = try await cachedPreviewURL(for: item, reportsActivity: false)
            let metadata = await MediaMetadataService.readMetadata(for: localURL, originalName: item.name)
            await previewCacheStore.releaseReadablePreview(localURL)
            if let metadata {
                mediaMetadataByItemID[item.id] = metadata
            } else {
                failedMediaMetadataItemMessages[item.id] = "No readable media metadata was found."
            }
        } catch {
            failedMediaMetadataItemMessages[item.id] = error.localizedDescription
        }
    }

    @MainActor public func prepareThumbnail(
        for item: USBTransferItem,
        maxFileSizeMB: Int,
        allowsFullFileFallback: Bool
    ) async -> URL? {
        let maxBytes = Int64(maxFileSizeMB) * 1024 * 1024
        guard item.isDownloadable,
              item.mediaKind != nil,
              (item.size ?? 0) <= maxBytes else {
            return nil
        }

        let cacheKey = thumbnailCacheKey(for: item)
        if thumbnailCacheKeysByItemID[item.id] == cacheKey,
           let thumbnailURL = thumbnailURLs[item.id],
           FileManager.default.fileExists(atPath: thumbnailURL.path) {
            return thumbnailURL
        }
        if thumbnailCacheKeysByItemID[item.id] != cacheKey {
            thumbnailURLs[item.id] = nil
            thumbnailCacheKeysByItemID[item.id] = nil
        }
        if let cachedURL = await thumbnailService.cachedThumbnailURL(cacheKey: cacheKey) {
            thumbnailURLs[item.id] = cachedURL
            thumbnailCacheKeysByItemID[item.id] = cacheKey
            return cachedURL
        }
        guard !loadingThumbnailItemIDs.contains(item.id), !Task.isCancelled else { return nil }

        loadingThumbnailItemIDs.insert(item.id)
        defer { loadingThumbnailItemIDs.remove(item.id) }

        do {
            if let transport = mtpTransport, let node = mtpNodes[item.id] {
                do {
                    try Task.checkCancellation()
                    let data = try await transport.thumbnail(for: node.id)
                    try Task.checkCancellation()
                    guard !data.isEmpty else { return nil }
                    let thumbnailURL = try await thumbnailService.storeThumbnailImageData(data, cacheKey: cacheKey)
                    try Task.checkCancellation()
                    thumbnailURLs[item.id] = thumbnailURL
                    thumbnailCacheKeysByItemID[item.id] = cacheKey
                    return thumbnailURL
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        return nil
                    }
                    if Self.requiresMTPConnectionReset(after: error) {
                        handleMTPError(error, from: transport)
                        return nil
                    }
                    guard allowsFullFileFallback else { return nil }
                }
            }

            try Task.checkCancellation()
            let localURL = try await cachedPreviewURL(for: item, reportsActivity: false)
            let thumbnailURL: URL
            do {
                try Task.checkCancellation()
                thumbnailURL = try await thumbnailService.generateThumbnail(localURL: localURL, cacheKey: cacheKey)
                await previewCacheStore.releaseReadablePreview(localURL)
            } catch {
                await previewCacheStore.releaseReadablePreview(localURL)
                throw error
            }
            try Task.checkCancellation()
            thumbnailURLs[item.id] = thumbnailURL
            thumbnailCacheKeysByItemID[item.id] = cacheKey
            return thumbnailURL
        } catch {
            // Thumbnails are opportunistic and should never interrupt browsing.
            return nil
        }
    }

    static func requiresMTPConnectionReset(after error: Error) -> Bool {
        if let mtpError = error as? MTPError {
            switch mtpError {
            case .noDevice, .interfaceNotFound, .usb, .deviceStalled:
                return true
            case .truncated, .unexpectedContainerType, .operationFailed, .stringTooLong, .protocolError:
                break
            }
        }
        if let transportError = error as? TransportError,
           case .notConnected = transportError {
            return true
        }
        let message = error.localizedDescription
        return message.localizedCaseInsensitiveContains("Unable to send IO")
            || message.localizedCaseInsensitiveContains("device stopped responding")
    }

    @MainActor public func showFileInfo(item: USBTransferItem) {
        FileInfoWindowPresenter.show(manager: self, item: item)
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        performOnMain { manager in
            manager.handleDeviceAdded(camera, moreComing: moreComing)
        }
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        performOnMain { manager in
            manager.handleDeviceRemoved(device)
        }
    }

    public func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        performOnMain { manager in
            manager.didEnumerateLocalDevices = true
            if manager.devices.isEmpty {
                manager.statusMessage = manager.mtpAccessIssue?.statusMessage ?? "No phone found in File Transfer mode."
            }
        }
    }

    public func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        guard let camera = device as? ICCameraDevice else { return }
        let errorMessage = error?.localizedDescription
        performOnMain { manager in
            guard manager.isKnownCamera(camera) else { return }
            manager.handleSessionOpened(camera, errorMessage: errorMessage)
        }
    }

    public func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        guard let camera = device as? ICCameraDevice else { return }
        performOnMain { manager in
            guard manager.isKnownCamera(camera) else { return }
            manager.updateSnapshot(for: camera)
        }
    }

    public func didRemove(_ device: ICDevice) {
        performOnMain { manager in
            manager.handleDeviceRemoved(device)
        }
    }

    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        performOnMain { manager in
            guard manager.isKnownCamera(camera) else { return }
            manager.updateSnapshot(for: camera)
            manager.refreshCurrentItems()
        }
    }

    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        performOnMain { manager in
            guard manager.isKnownCamera(camera) else { return }
            manager.updateSnapshot(for: camera)
            manager.refreshCurrentItems()
        }
    }

    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {
    }

    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {
    }

    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        performOnMain { manager in
            guard manager.isKnownCamera(camera) else { return }
            manager.updateSnapshot(for: camera)
            manager.refreshCurrentItems()
        }
    }

    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        performOnMain { manager in
            guard manager.isKnownCamera(camera) else { return }
            manager.updateSnapshot(for: camera)
        }
    }

    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
    }

    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        performOnMain { manager in
            guard manager.isKnownCamera(device) else { return }
            manager.updateSnapshot(for: device)
            manager.refreshCurrentItems()
        }
    }

    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice else { return }
        performOnMain { manager in
            guard manager.isKnownCamera(camera) else { return }
            manager.updateSnapshot(for: camera)
            manager.refreshCurrentItems()
        }
    }

    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice else { return }
        performOnMain { manager in
            guard manager.isKnownCamera(camera) else { return }
            manager.updateSnapshot(for: camera)
        }
    }

    private func discoverMTPOrFallbackToImageCapture(allowImageCaptureFallback: Bool = true) async {
        let adbOwner = USBDeviceAccessProbe.firstADBExclusiveAndroidDevice()
        let mtpInterface = USBDeviceAccessProbe.firstAndroidMTPInterface()
        await MainActor.run {
            self.backend = .checking
            self.isBrowsing = true
            self.mtpAccessIssue = nil
            self.statusMessage = "Looking for a phone with File Transfer turned on..."
        }

        if mtpInterface?.isOwnedByMacOSCameraService == true {
            await MainActor.run {
                self.stopImageCaptureBrowsing()
                self.statusMessage = "Preparing File Transfer..."
            }
        }

        var discovery = if mtpInterface != nil {
            await USBDeviceAccessProbe.withMacOSCameraClientsReleased {
                await self.discoverMTPAndStorages()
            }
        } else {
            await discoverMTPAndStorages()
        }

        if discovery == nil, !allowImageCaptureFallback {
            for _ in 0..<3 where discovery == nil {
                try? await Task.sleep(for: .seconds(1))
                discovery = await discoverMTPAndStorages()
            }
        }

        if let discovery {
            switch discovery {
            case .success(let (transport, storages)):
                await MainActor.run {
                    self.mtpAccessIssue = nil
                    self.installMTPTransport(transport, storages: storages)
                }
            case .failure(let error):
                let visibleMTPInterface = USBDeviceAccessProbe.firstAndroidMTPInterface() ?? mtpInterface
                await MainActor.run {
                    self.stopImageCaptureBrowsing()
                    let issue = visibleMTPInterface.map {
                        USBTransferAccessIssue.mtpStorageLoadFailed(interface: $0, error: error)
                    } ?? USBTransferAccessIssue(
                        title: "Phone Storage Couldn't Load",
                        message: "The phone is in File Transfer mode, but its storage couldn't be opened. \(error.localizedDescription)",
                        statusMessage: "File Transfer is connected, but phone storage couldn't be loaded.",
                        actionTitle: "Try Again",
                        recoveryAction: .releaseMacOSCameraService
                    )
                    self.mtpAccessIssue = issue
                    self.backend = .checking
                    self.isBrowsing = false
                    self.isCataloging = false
                    self.didEnumerateLocalDevices = true
                    self.devices = []
                    self.selectedDeviceID = nil
                    self.items = []
                    self.statusMessage = issue.statusMessage
                }
            }
        } else {
            let visibleMTPInterface = USBDeviceAccessProbe.firstAndroidMTPInterface() ?? mtpInterface
            if let visibleMTPInterface {
                    let issue: USBTransferAccessIssue
                    if visibleMTPInterface.isOwnedByMacOSCameraService {
                        issue = USBTransferAccessIssue.macOSCameraOwner(interface: visibleMTPInterface)
                    } else if let adbOwner {
                        // Debugging and File Transfer normally use separate USB interfaces.
                        // Only offer to pause Phone Tools after opening the visible File
                        // Transfer interface has actually failed and macOS reports whole-device
                        // ownership.
                        issue = USBTransferAccessIssue.adbExclusiveOwner(device: adbOwner)
                    } else {
                        issue = USBTransferAccessIssue.mtpOpenFailed(interface: visibleMTPInterface)
                    }
                await MainActor.run {
                    self.stopImageCaptureBrowsing()
                    self.mtpAccessIssue = issue
                    self.backend = .checking
                    self.isBrowsing = false
                    self.isCataloging = false
                    self.didEnumerateLocalDevices = true
                    self.devices = []
                    self.selectedDeviceID = nil
                    self.items = []
                    self.statusMessage = issue.statusMessage
                }
                return
            }

            await MainActor.run {
                if allowImageCaptureFallback {
                    self.mtpAccessIssue = nil
                    self.startImageCaptureBrowsingIfNeeded()
                } else {
                    let issue = USBTransferAccessIssue(
                        title: "File Transfer Couldn't Reconnect",
                        message: "Keep the phone unlocked with File transfer / Android Auto selected, then reconnect. AOSP File Manager will keep this as a File Transfer connection instead of switching to read-only photo access.",
                        statusMessage: "File Transfer couldn't reconnect. Keep the phone unlocked and try again.",
                        actionTitle: "Reconnect",
                        recoveryAction: .resetMTPConnection
                    )
                    self.mtpAccessIssue = issue
                    self.backend = .checking
                    self.isBrowsing = false
                    self.isCataloging = false
                    self.didEnumerateLocalDevices = true
                    self.devices = []
                    self.selectedDeviceID = nil
                    self.items = []
                    self.quickLocations = []
                    self.statusMessage = issue.statusMessage
                }
            }
        }
    }

    private func stopImageCaptureBrowsing() {
        browser.stop()
        imageCaptureStarted = false
        cameras.values.forEach { $0.delegate = nil }
        cameras.removeAll()
        itemObjects.removeAll()
    }

    private func discoverMTPAndStorages() async -> Result<(MTPTransport, [StorageInfo]), Error>? {
        guard let transport = await MTPTransport.discover() else { return nil }
        do {
            let storages = try await transport.storages()
            return .success((transport, storages))
        } catch {
            await transport.close()
            return .failure(error)
        }
    }

    private func startImageCaptureBrowsingIfNeeded() {
        backend = .imageCapture
        quickLocations = []
        isResolvingQuickLocations = false
        guard !imageCaptureStarted else {
            statusMessage = cameras.isEmpty
                ? mtpAccessIssue?.statusMessage ?? "Looking for phones with File Transfer turned on."
                : "Refreshing photo access."
            return
        }

        imageCaptureStarted = true
        didEnumerateLocalDevices = false
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        statusMessage = mtpAccessIssue?.statusMessage ?? "Looking for phones with File Transfer turned on."
    }

    private func resetForMTPRetry() {
        mtpChangeTask?.cancel()
        mtpChangeTask = nil
        mtpTransport = nil
        mtpStorages = []
        mtpStorageItems.removeAll()
        mtpNodes.removeAll()
        mtpPathStates.removeAll()
        quickLocations = []
        isResolvingQuickLocations = false
        currentMTPStorageID = nil
        currentMTPParentID = nil
        currentContainerID = nil
        folderSizeBytesByItemID = [:]
        loadingFolderSizeItemIDs = []
        failedFolderSizeItemIDs = []
        clearExpandedFolderState()
        clearMTPFolderListingCache()
        selectedItemIDs.removeAll()
        lastSelectedItemID = nil
        devices = []
        selectedDeviceID = nil
        items = []
        itemObjects.removeAll()
        cameras.values.forEach { $0.delegate = nil }
        cameras.removeAll()
        browser.stop()
        imageCaptureStarted = false
        backend = .checking
        isBrowsing = true
        isCataloging = false
        didEnumerateLocalDevices = false
        resetPath()
    }

    private func installMTPTransport(_ transport: MTPTransport, storages: [StorageInfo]) {
        mtpChangeTask?.cancel()
        mtpTransport = transport
        mtpStorages = storages
        backend = .mtp
        isBrowsing = false
        isCataloging = false
        didEnumerateLocalDevices = true
        currentContainerID = nil
        selectedItemIDs.removeAll()
        clearExpandedFolderState()
        clearMTPFolderListingCache()
        lastSelectedItemID = nil

        browser.stop()
        imageCaptureStarted = false
        cameras.values.forEach { $0.delegate = nil }
        cameras.removeAll()
        itemObjects.removeAll()

        let snapshot = USBTransferDevice(
            id: transport.id,
            name: transport.displayName,
            transport: "USB File Transfer",
            productKind: "File Transfer / Android Auto",
            isReady: true,
            isLocked: false,
            catalogPercent: 100
        )
        devices = [snapshot]
        selectedDeviceID = snapshot.id
        resetMTPPath()
        applyMTPStorages(storages)
        refreshMTPQuickLocations(from: transport, storages: storages)
        observeMTPChanges(from: transport)
    }

    private func observeMTPChanges(from transport: MTPTransport) {
        mtpChangeTask = Task { @MainActor [weak self, transport] in
            for await change in transport.changes {
                guard !Task.isCancelled else { return }
                guard self?.mtpTransport?.id == transport.id else { return }
                self?.refreshMTPAfterObservedChange(change)
            }
        }
    }

    static func mtpObservedRefreshScopes(
        for change: DeviceChange,
        knownNodes: [FileNode]
    ) -> Set<MTPObservedRefreshScope> {
        func folderScope(for node: FileNode) -> MTPObservedRefreshScope {
            .folder(storageID: node.storageID, parentID: node.parentID)
        }

        switch change {
        case .storagesChanged:
            return [.storageList, .allVisibleFolders]
        case .reloadNeeded(let parentID, let storageID):
            return [.folder(storageID: storageID, parentID: parentID)]
        case .removed(let id):
            guard let previous = knownNodes.first(where: { $0.id == id }) else {
                return [.allVisibleFolders]
            }
            return [folderScope(for: previous)]
        case .added(let node), .changed(let node):
            var scopes: Set<MTPObservedRefreshScope> = [folderScope(for: node)]
            if let previous = knownNodes.first(where: { $0.id == node.id }) {
                scopes.insert(folderScope(for: previous))
            }
            return scopes
        }
    }

    @MainActor private func refreshMTPAfterObservedChange(_ change: DeviceChange) {
        let scopes = Self.mtpObservedRefreshScopes(for: change, knownNodes: Array(mtpNodes.values))
        if case .added(let node) = change {
            mtpNodes[mtpItemID(for: node)] = node
        } else if case .changed(let node) = change {
            mtpNodes[mtpItemID(for: node)] = node
        }
        pendingMTPObservedRefreshScopes.formUnion(scopes)
        schedulePendingMTPObservedRefresh()
    }

    @MainActor private func schedulePendingMTPObservedRefresh() {
        guard mtpBrowserMutationDepth == 0,
              !pendingMTPObservedRefreshScopes.isEmpty,
              mtpObservedRefreshTask == nil else {
            return
        }

        // One phone operation can produce both an optimistic change and an MTP
        // interrupt event. Coalesce that small burst into one reconciliation pass.
        mtpObservedRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.mtpObservedRefreshTask = nil
            self.flushPendingMTPObservedRefreshes()
        }
    }

    @MainActor private func flushPendingMTPObservedRefreshes() {
        guard mtpBrowserMutationDepth == 0 else { return }
        let scopes = pendingMTPObservedRefreshScopes
        pendingMTPObservedRefreshScopes.removeAll()
        guard !scopes.isEmpty else { return }

        let refreshesAllVisibleFolders = scopes.contains(.allVisibleFolders)
        let refreshesStorageList = scopes.contains(.storageList)
        let targetedFolders = scopes.compactMap { scope -> (storageID: String, parentID: String?)? in
            guard case .folder(let storageID, let parentID) = scope else { return nil }
            return (storageID, parentID)
        }
        let currentFolderIsTargeted = targetedFolders.contains {
            currentMTPStorageID == $0.storageID && currentMTPParentID == $0.parentID
        }

        if refreshesAllVisibleFolders || currentFolderIsTargeted || (refreshesStorageList && currentMTPStorageID == nil) {
            refreshMTPCurrentItems()
        }
        if refreshesStorageList, currentMTPStorageID != nil {
            refreshMTPStorageListInBackground()
        }

        let refreshableItems = Self.deduplicatedItems(
            items
                + treeChildrenByItemID.values.flatMap { $0 }
                + mtpFolderListingsByKey.values.flatMap { $0 }
        )
        let foldersToRefresh = refreshableItems.filter { item in
            guard item.isFolder, expandedFolderItemIDs.contains(item.id) else { return false }
            if refreshesAllVisibleFolders { return true }
            if let storage = mtpStorageItems[item.id] {
                return targetedFolders.contains { $0.storageID == storage.id && $0.parentID == nil }
            }
            guard let node = mtpNodes[item.id] else { return false }
            return targetedFolders.contains { $0.storageID == node.storageID && $0.parentID == node.id }
        }

        for folder in foldersToRefresh {
            // Supersede a stale in-flight enumeration rather than dropping the
            // device event. The old response is ignored by its request token.
            invalidateFolderChildrenLoad(for: folder.id)
            Task { await loadFolderChildren(for: folder) }
        }
    }

    @MainActor private func refreshMTPStorageListInBackground() {
        guard let transport = mtpTransport else { return }
        Task { [weak self, transport] in
            do {
                let storages = try await transport.storages()
                await MainActor.run {
                    guard let self, self.mtpTransport === transport, self.currentMTPStorageID != nil else { return }
                    self.mtpStorages = storages
                    self.mtpStorageItems.removeAll()
                    let storageItems = storages.map(self.makeMTPStorageItem)
                    let rootKey = MTPFolderListingKey(storageID: nil, parentID: nil, path: "/")
                    self.mtpFolderListingsByKey[rootKey] = storageItems
                    for storage in storages {
                        self.folderSizeBytesByItemID[self.mtpStorageItemID(storage.id)] = storage.usedBytes
                    }
                    self.refreshMTPQuickLocations(from: transport, storages: storages)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.mtpTransport === transport else { return }
                    if Self.requiresMTPConnectionReset(after: error) {
                        self.handleMTPError(error, from: transport)
                    }
                    // A transient metadata refresh must not replace good cached rows.
                }
            }
        }
    }

    private func refreshMTPCurrentItems() {
        guard let transport = mtpTransport else {
            items = []
            visibleMTPListingKey = nil
            mtpListingRequestID = nil
            isShowingCachedMTPListing = false
            isCataloging = false
            return
        }

        let storageID = currentMTPStorageID
        let parentID = currentMTPParentID
        let parentPath = currentPath
        let listingKey = MTPFolderListingKey(storageID: storageID, parentID: parentID, path: parentPath)
        let requestID = UUID()
        mtpListingRequestID = requestID
        if let cachedItems = mtpFolderListingsByKey[listingKey] {
            items = cachedItems
            visibleMTPListingKey = listingKey
            isShowingCachedMTPListing = true
            statusMessage = storageID == nil
                ? "Updating phone storage..."
                : "Updating \(parentPath)..."
        } else {
            // Never leave the previous folder's rows beneath a new breadcrumb.
            items = []
            visibleMTPListingKey = listingKey
            isShowingCachedMTPListing = false
            statusMessage = storageID == nil
                ? "Loading phone storage..."
                : "Loading \(parentPath)..."
        }
        isCataloging = true

        Task { @MainActor [weak self, transport, storageID, parentID, parentPath, listingKey, requestID] in
            do {
                if let storageID {
                    let nodes = try await transport.listChildren(of: parentID, in: storageID)
                    self?.applyMTPNodes(
                        nodes,
                        storageID: storageID,
                        parentID: parentID,
                        parentPath: parentPath,
                        listingKey: listingKey,
                        requestID: requestID
                    )
                } else {
                    let storages = try await transport.storages()
                    self?.applyMTPStorages(storages, listingKey: listingKey, requestID: requestID)
                }
            } catch {
                guard let self,
                      self.mtpTransport === transport,
                      self.mtpListingRequestID == requestID,
                      self.currentMTPFolderListingKey == listingKey else {
                    return
                }
                if Self.requiresMTPConnectionReset(after: error) {
                    self.handleMTPError(error, from: transport)
                } else {
                    self.handleMTPListingError(error, listingKey: listingKey)
                }
            }
        }
    }

    @MainActor private func handleMTPListingError(_ error: Error, listingKey: MTPFolderListingKey) {
        mtpListingRequestID = nil
        isCataloging = false
        let hasCachedListing = mtpFolderListingsByKey[listingKey] != nil
        if let cachedItems = mtpFolderListingsByKey[listingKey] {
            items = cachedItems
            visibleMTPListingKey = listingKey
            isShowingCachedMTPListing = true
        }
        statusMessage = hasCachedListing
            ? "Showing saved contents. Refresh to try again."
            : "This folder couldn't be loaded. Refresh to try again."
        if !hasCachedListing {
            alert = UserAlert(title: "Couldn't Open Folder", message: error.localizedDescription)
        }
    }

    private func applyMTPStorages(
        _ storages: [StorageInfo],
        listingKey: MTPFolderListingKey? = nil,
        requestID: UUID? = nil
    ) {
        guard currentMTPStorageID == nil else { return }
        if let requestID {
            guard mtpListingRequestID == requestID,
                  let listingKey,
                  currentMTPFolderListingKey == listingKey else {
                return
            }
        }
        mtpStorages = storages
        mtpStorageItems.removeAll()
        items = storages.map(makeMTPStorageItem)
        let key = listingKey ?? currentMTPFolderListingKey
        mtpFolderListingsByKey[key] = items
        visibleMTPListingKey = key
        pruneFolderSizeCache(keeping: Set(items.map(\.id)))
        for storage in storages {
            folderSizeBytesByItemID[mtpStorageItemID(storage.id)] = storage.usedBytes
        }
        selectedItemIDs = selectedItemIDs.intersection(Set(items.map(\.id)))
        isShowingCachedMTPListing = false
        isCataloging = false
        statusMessage = storages.isEmpty
            ? "No phone storage is available through File Transfer."
            : "\(storages.count) storage volume\(storages.count == 1 ? "" : "s") available."
    }

    private func refreshMTPQuickLocations(from transport: MTPTransport, storages: [StorageInfo]) {
        quickLocations = storages.enumerated().map { index, storage in
            MTPQuickLocation(
                id: index == 0 ? "home" : "storage:\(storage.id)",
                title: index == 0 ? "Internal Storage" : storage.name,
                path: "/\(storage.name)",
                symbol: index == 0 ? "internaldrive" : "sdcard",
                subtitle: index == 0 ? storage.name : "External volume",
                storageID: storage.id,
                parentID: nil
            )
        }
        isResolvingQuickLocations = true

        Task { @MainActor [weak self, transport, storages] in
            let resolved = await Self.resolveMTPQuickLocations(transport: transport, storages: storages)
            guard self?.mtpTransport === transport else { return }
            self?.quickLocations = resolved
            self?.isResolvingQuickLocations = false
        }
    }

    private static func resolveMTPQuickLocations(transport: MTPTransport, storages: [StorageInfo]) async -> [MTPQuickLocation] {
        var locations: [MTPQuickLocation] = []
        var seenTargets = Set<String>()

        for (storageIndex, storage) in storages.enumerated() {
            let resolver = MTPQuickLocationResolver(transport: transport, storage: storage)
            let storageLocation = MTPQuickLocation(
                id: storageIndex == 0 ? "home" : "storage:\(storage.id)",
                title: storageIndex == 0 ? "Internal Storage" : storage.name,
                path: "/\(storage.name)",
                symbol: storageIndex == 0 ? "internaldrive" : "sdcard",
                subtitle: storageIndex == 0 ? storage.name : "External volume",
                storageID: storage.id,
                parentID: nil
            )
            locations.append(storageLocation)
            seenTargets.insert("\(storage.id):root")

            for definition in mtpQuickAccessDefinitions {
                guard let match = await resolveFirstExistingMTPPath(
                    definition.candidates,
                    resolver: resolver
                ) else {
                    continue
                }

                let key = "\(storage.id):\(match.node.id)"
                guard seenTargets.insert(key).inserted else { continue }

                let suffix = storages.count > 1 ? ":\(storage.id)" : ""
                let subtitle = storages.count > 1 ? "\(storage.name) - \(match.relativePath)" : match.relativePath
                locations.append(MTPQuickLocation(
                    id: "\(definition.id)\(suffix)",
                    title: definition.title,
                    path: "/\(storage.name)/\(match.relativePath)",
                    symbol: definition.symbol,
                    subtitle: subtitle,
                    storageID: storage.id,
                    parentID: match.node.id
                ))
            }
        }

        return locations
    }

    private static func resolveFirstExistingMTPPath(
        _ candidates: [[String]],
        resolver: MTPQuickLocationResolver
    ) async -> (node: FileNode, relativePath: String)? {
        for candidate in candidates {
            if let match = await resolver.resolve(candidate) {
                return match
            }
        }
        return nil
    }

    private func applyMTPNodes(
        _ nodes: [FileNode],
        storageID: String,
        parentID: String?,
        parentPath: String,
        listingKey: MTPFolderListingKey,
        requestID: UUID
    ) {
        guard currentMTPStorageID == storageID,
              currentMTPParentID == parentID,
              currentMTPFolderListingKey == listingKey,
              mtpListingRequestID == requestID else {
            return
        }
        items = nodes.map { makeMTPItem(from: $0, parentPath: parentPath) }
        mtpFolderListingsByKey[listingKey] = items
        visibleMTPListingKey = listingKey
        if let containerItemID = pathComponents.last?.itemID {
            treeChildrenByItemID[containerItemID] = items
        }
        let knownIDs = Set(items.map(\.id)).union(treeChildrenByItemID.values.flatMap { $0.map(\.id) })
        pruneFolderSizeCache(keeping: knownIDs)
        selectedItemIDs = selectedItemIDs.intersection(knownIDs)
        isShowingCachedMTPListing = false
        isCataloging = false
        statusMessage = "\(items.count) item\(items.count == 1 ? "" : "s") available."
    }

    private func openMTPFolder(_ item: USBTransferItem) {
        if let storage = mtpStorageItems[item.id] {
            cacheVisibleMTPListing()
            currentMTPStorageID = storage.id
            currentMTPParentID = nil
            selectedItemIDs.removeAll()
            let component = USBTransferPathComponent(id: item.id, itemID: item.id, title: item.name, path: item.path)
            mtpPathStates[component.id] = MTPPathState(storageID: storage.id, parentID: nil, path: item.path)
            pathComponents.append(component)
            refreshMTPCurrentItems()
            return
        }

        guard let node = mtpNodes[item.id], node.isDirectory else { return }
        cacheVisibleMTPListing()
        currentMTPStorageID = node.storageID
        currentMTPParentID = node.id
        selectedItemIDs.removeAll()
        let component = USBTransferPathComponent(id: item.id, itemID: item.id, title: item.name, path: item.path)
        mtpPathStates[component.id] = MTPPathState(storageID: node.storageID, parentID: node.id, path: item.path)
        pathComponents.append(component)
        refreshMTPCurrentItems()
    }

    private func applyMTPPathState(for component: USBTransferPathComponent?) {
        guard let component, let state = mtpPathStates[component.id] else {
            currentMTPStorageID = nil
            currentMTPParentID = nil
            return
        }
        currentMTPStorageID = state.storageID
        currentMTPParentID = state.parentID
    }

    private func clearExpandedFolderState() {
        pendingInlineRenameWorkItem?.cancel()
        pendingInlineRenameWorkItem = nil
        inlineRenameItemID = nil
        expandedFolderItemIDs.removeAll()
        treeChildrenByItemID.removeAll()
        loadingTreeItemIDs.removeAll()
        treeLoadRequestIDs.removeAll()
        cancelFolderSizeWorker(clearQueue: true)
    }

    private func mtpUploadTarget(for item: USBTransferItem?) -> MTPUploadTarget? {
        if let item {
            if let storage = mtpStorageItems[item.id] {
                return MTPUploadTarget(
                    storageID: storage.id,
                    parentID: nil,
                    displayPath: item.path,
                    refreshesCurrentListing: currentMTPStorageID == storage.id && currentMTPParentID == nil
                )
            }

            guard let node = mtpNodes[item.id], node.isDirectory else { return nil }
            return MTPUploadTarget(
                storageID: node.storageID,
                parentID: node.id,
                displayPath: item.path,
                refreshesCurrentListing: currentMTPStorageID == node.storageID && currentMTPParentID == node.id
            )
        }

        guard let storageID = currentMTPStorageID else { return nil }
        return MTPUploadTarget(
            storageID: storageID,
            parentID: currentMTPParentID,
            displayPath: currentPath,
            refreshesCurrentListing: true
        )
    }

    @MainActor private func cachedPreviewURL(for item: USBTransferItem, reportsActivity: Bool = true) async throws -> URL {
        guard item.isDownloadable else {
            throw FileOperationError.commandFailed("\(item.name) cannot be previewed.")
        }

        let directory = try previewCacheDirectory()
        let cacheKey = thumbnailCacheKey(for: item)
        let cacheName = await thumbnailService.sourceCacheFileName(cacheKey: cacheKey, originalName: item.name)
        let destination = directory.appending(path: cacheName)
        let shouldEncrypt = previewEncryptionEnabled()
        if let cachedURL = try await previewCacheStore.readablePreviewURL(
            for: destination,
            encrypt: shouldEncrypt
        ) {
            return cachedURL
        }

        if reportsActivity {
            isDownloading = true
            statusMessage = "Preparing preview for \(item.name)..."
        }
        defer {
            if reportsActivity {
                isDownloading = false
            }
        }

        if let existingTask = previewPreparationTasks[cacheKey] {
            try await existingTask.value
            if reportsActivity {
                statusMessage = "Previewing \(item.name)."
            }
            guard let url = try await previewCacheStore.readablePreviewURL(
                for: destination,
                encrypt: shouldEncrypt
            ) else {
                throw FileOperationError.commandFailed("The preview cache could not be prepared.")
            }
            return url
        }

        let stagingDirectory = try await previewCacheStore.makePreviewStagingDirectory()
        let stagingDestination = stagingDirectory.appending(path: cacheName)
        let task = Task { @MainActor [weak self] () throws -> Void in
            guard let self else {
                throw FileOperationError.commandFailed("The file is no longer available.")
            }
            let downloadedURL = try await self.downloadPreviewFile(
                for: item,
                to: stagingDestination,
                cacheName: cacheName,
                reportsActivity: reportsActivity
            )
            try await self.previewCacheStore.storePreview(
                from: downloadedURL,
                at: destination,
                encrypt: shouldEncrypt
            )
        }
        previewPreparationTasks[cacheKey] = task
        defer { previewPreparationTasks[cacheKey] = nil }

        try await task.value
        if reportsActivity {
            statusMessage = "Previewing \(item.name)."
        }
        guard let url = try await previewCacheStore.readablePreviewURL(
            for: destination,
            encrypt: shouldEncrypt
        ) else {
            throw FileOperationError.commandFailed("The preview cache could not be prepared.")
        }
        return url
    }

    @MainActor private func downloadPreviewFile(
        for item: USBTransferItem,
        to destination: URL,
        cacheName: String,
        reportsActivity: Bool
    ) async throws -> URL {
        if let transport = mtpTransport, let node = mtpNodes[item.id] {
            try await transport.download(node.id, to: destination) { [weak self] progress in
                guard reportsActivity else { return }
                Task { @MainActor in
                    self?.statusMessage = Self.progressMessage(prefix: "Previewing", progress: progress)
                }
            }
            return destination
        }

        guard let file = itemObjects[item.id] as? ICCameraFile else {
            throw FileOperationError.commandFailed("The file is no longer available.")
        }

        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: destination.deletingLastPathComponent(),
            .saveAsFilename: cacheName,
            .overwrite: true,
            .sidecarFiles: true,
            .truncateAfterSuccessfulDownload: true
        ]

        let url: URL = try await withCheckedThrowingContinuation { continuation in
            _ = file.requestDownload(options: options) { filename, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: destination.deletingLastPathComponent().appending(path: filename ?? cacheName))
            }
        }
        return url
    }

    private func thumbnailCacheKey(for item: USBTransferItem) -> String {
        let deviceID = selectedDeviceID ?? "usb-transfer"
        let size = item.size.map(String.init) ?? "unknown-size"
        let modified = item.modified
            .map { String(Int64($0.timeIntervalSince1970 * 1_000)) }
            ?? "unknown-date"
        return "usb-transfer|\(deviceID)|\(item.path)|\(size)|\(modified)"
    }

    private func downloadMTPItems(_ requests: [MTPDownloadRequest], to destination: URL, transport: MTPTransport) async {
        for request in requests {
            let output = destination.appending(path: request.item.name)
            do {
                guard let node = mtpNodes[request.item.id] else {
                    throw FileOperationError.commandFailed("The selected phone item is no longer available.")
                }
                let totalBytes = node.isDirectory ? folderSizeBytesByItemID[request.item.id] : request.item.size
                try await Self.downloadMTPNode(
                    node,
                    to: output,
                    transport: transport,
                    totalBytes: totalBytes
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.statusMessage = Self.progressMessage(prefix: "Downloading", progress: progress)
                    }
                }
                await MainActor.run {
                    self.finishDownload(itemName: request.item.name, savedFilename: request.item.name, errorMessage: nil)
                }
            } catch {
                await MainActor.run {
                    self.finishDownload(itemName: request.item.name, savedFilename: nil, errorMessage: error.localizedDescription)
                }
            }
        }
    }

    private func handleMTPError(_ error: Error, from failedTransport: MTPTransport) {
        guard mtpTransport === failedTransport else { return }
        let previousTransport = failedTransport
        mtpChangeTask?.cancel()
        mtpChangeTask = nil
        mtpTransport = nil
        mtpStorages.removeAll()
        mtpStorageItems.removeAll()
        mtpNodes.removeAll()
        mtpPathStates.removeAll()
        clearExpandedFolderState()
        clearMTPFolderListingCache()
        currentMTPStorageID = nil
        currentMTPParentID = nil
        quickLocations = []
        isResolvingQuickLocations = false
        selectedItemIDs.removeAll()
        items = []
        devices = []
        selectedDeviceID = nil
        isCataloging = true
        isBrowsing = true
        backend = .checking
        let issue = USBTransferAccessIssue.mtpConnectionLost(error: error)
        mtpAccessIssue = issue
        statusMessage = issue.statusMessage
        Task { @MainActor [weak self, previousTransport] in
            await previousTransport.close()
            self?.recoverMTPConnectionByReset()
        }
    }

    private func handleDeviceAdded(_ camera: ICCameraDevice, moreComing: Bool) {
        let id = id(for: camera)
        if let previousCamera = cameras[id], previousCamera !== camera {
            previousCamera.delegate = nil
        }
        cameras[id] = camera
        camera.delegate = self
        updateSnapshot(for: camera)

        if selectedDeviceID == nil {
            selectDevice(id: id)
        } else if !camera.hasOpenSession {
            camera.requestOpenSession()
        }

        statusMessage = moreComing ? "Finding USB transfer devices..." : "USB transfer device found."
    }

    private func handleDeviceRemoved(_ device: ICDevice) {
        let id = id(for: device)
        let removedCamera = cameras.removeValue(forKey: id)
        let hadDevice = removedCamera != nil || devices.contains { $0.id == id }
        guard hadDevice else { return }
        removedCamera?.delegate = nil
        (device as? ICCameraDevice)?.delegate = nil
        devices.removeAll { $0.id == id }
        if selectedDeviceID == id {
            selectedDeviceID = devices.first?.id
            selectedItemIDs.removeAll()
            items = []
            currentContainerID = nil
            resetPath()
            refresh()
        }
        statusMessage = devices.isEmpty ? "No phone found in File Transfer mode." : "File Transfer connection ended."
    }

    private func isKnownCamera(_ camera: ICCameraDevice) -> Bool {
        cameras[id(for: camera)] === camera
    }

    private func handleSessionOpened(_ camera: ICCameraDevice, errorMessage: String?) {
        if let errorMessage {
            alert = UserAlert(title: "File Transfer Session Failed", message: errorMessage)
            statusMessage = errorMessage
            updateSnapshot(for: camera)
            return
        }

        updateSnapshot(for: camera)
        resetPath()
        refreshCurrentItems()
    }

    private func performOnMain(_ action: @escaping @Sendable (USBTransferManager) -> Void) {
        if Thread.isMainThread {
            action(self)
        } else {
            RunLoop.main.perform { [weak self] in
                guard let self else { return }
                action(self)
            }
        }
    }

    private var selectedCamera: ICCameraDevice? {
        if let selectedDeviceID, let camera = cameras[selectedDeviceID] {
            return camera
        }
        return cameras.values.first
    }

    private var currentPath: String {
        pathComponents.last?.path ?? "/"
    }

    private var currentMTPFolderListingKey: MTPFolderListingKey {
        MTPFolderListingKey(
            storageID: currentMTPStorageID,
            parentID: currentMTPParentID,
            path: currentPath
        )
    }

    private func cacheVisibleMTPListing() {
        let key = currentMTPFolderListingKey
        guard visibleMTPListingKey == key else { return }
        mtpFolderListingsByKey[key] = items
    }

    private func clearMTPFolderListingCache() {
        mtpListingRequestID = nil
        visibleMTPListingKey = nil
        mtpFolderListingsByKey.removeAll()
        isShowingCachedMTPListing = false
        mtpBrowserMutationDepth = 0
        pendingMTPObservedRefreshScopes.removeAll()
        mtpObservedRefreshTask?.cancel()
        mtpObservedRefreshTask = nil
    }

    private func openFolder(_ item: USBTransferItem) {
        recordCurrentNavigation()
        if mtpTransport != nil {
            openMTPFolder(item)
            return
        }

        guard itemObjects[item.id] is ICCameraFolder else { return }
        currentContainerID = item.id
        selectedItemIDs.removeAll()
        clearExpandedFolderState()
        pathComponents.append(USBTransferPathComponent(id: item.id, itemID: item.id, title: item.name, path: item.path))
        refreshCurrentItems()
    }

    private func currentNavigationSnapshot() -> USBFolderNavigationSnapshot {
        USBFolderNavigationSnapshot(
            pathComponents: pathComponents,
            currentContainerID: currentContainerID,
            currentMTPStorageID: currentMTPStorageID,
            currentMTPParentID: currentMTPParentID,
            mtpPathStates: mtpPathStates
        )
    }

    private func recordCurrentNavigation() {
        let snapshot = currentNavigationSnapshot()
        guard let currentPath = snapshot.pathComponents.last?.path else { return }
        if backHistory.last?.pathComponents.last?.path != currentPath {
            backHistory.append(snapshot)
            if backHistory.count > 100 {
                backHistory.removeFirst(backHistory.count - 100)
            }
        }
        forwardHistory.removeAll()
    }

    private func applyNavigationSnapshot(_ snapshot: USBFolderNavigationSnapshot) {
        if mtpTransport != nil {
            cacheVisibleMTPListing()
        }
        pathComponents = snapshot.pathComponents
        currentContainerID = snapshot.currentContainerID
        currentMTPStorageID = snapshot.currentMTPStorageID
        currentMTPParentID = snapshot.currentMTPParentID
        mtpPathStates = snapshot.mtpPathStates
        selectedItemIDs.removeAll()
        if mtpTransport != nil {
            refreshMTPCurrentItems()
        } else {
            clearExpandedFolderState()
            refreshCurrentItems()
        }
    }

    private func refreshCurrentItems() {
        if mtpTransport != nil {
            refreshMTPCurrentItems()
            return
        }

        guard let camera = selectedCamera else {
            items = []
            isCataloging = false
            return
        }

        if pathComponents.isEmpty {
            resetPath()
        }

        let container = currentContainerID.flatMap { itemObjects[$0] as? ICCameraFolder }
            ?? folder(at: currentPath, in: camera)
        let sourceItems = container?.contents ?? camera.contents ?? []
        let parentPath = container == nil ? "/" : currentPath
        let deviceID = id(for: camera)

        itemObjects = currentContainerID.flatMap { id in
            container.map { [id: $0 as ICCameraItem] }
        } ?? [:]

        clearExpandedFolderState()
        items = sourceItems.compactMap { makeItem(from: $0, deviceID: deviceID, parentPath: parentPath) }
        pruneFolderSizeCache(keeping: Set(items.map(\.id)))
        selectedItemIDs = selectedItemIDs.intersection(Set(items.map(\.id)))
        isCataloging = camera.contentCatalogPercentCompleted < 100
        statusMessage = items.isEmpty && isCataloging
            ? "Cataloging \(camera.name ?? "device")..."
            : "\(items.count) item\(items.count == 1 ? "" : "s") visible over File Transfer."
    }

    @MainActor private func download(items requestedItems: [USBTransferItem]) {
        guard !requestedItems.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        if let transferQueue {
            enqueueQueuedDownloads(requestedItems, to: destination, queue: transferQueue)
            return
        }

        let duplicates = requestedItems.filter { item in
            FileManager.default.fileExists(atPath: destination.appending(path: item.name).path)
        }
        let downloadableItems = requestedItems.filter { item in
            !duplicates.contains(where: { $0.id == item.id })
        }

        if !duplicates.isEmpty {
            let names = duplicates.prefix(5).map(\.name).joined(separator: ", ")
            let suffix = duplicates.count > 5 ? " and \(duplicates.count - 5) more" : ""
            alert = UserAlert(
                title: "Duplicate Detected",
                message: "These files already exist in the selected folder and were not overwritten: \(names)\(suffix)."
            )
        }

        guard !downloadableItems.isEmpty else {
            statusMessage = "Download skipped to avoid overwriting existing files."
            return
        }

        pendingDownloads = downloadableItems.count
        completedDownloads = 0
        failedDownloads = 0
        isDownloading = true
        beginTerminationBlockingActivity()
        statusMessage = "Downloading \(downloadableItems.count) item\(downloadableItems.count == 1 ? "" : "s")..."

        if let transport = mtpTransport {
            let requests = downloadableItems.compactMap { item -> MTPDownloadRequest? in
                guard let node = mtpNodes[item.id] else { return nil }
                return MTPDownloadRequest(item: item, nodeID: node.id)
            }

            guard !requests.isEmpty else {
                isDownloading = false
                endTerminationBlockingActivity()
                statusMessage = "The selected phone file is no longer available."
                return
            }

            pendingDownloads = requests.count
            Task { [weak self, transport, destination, requests] in
                await self?.downloadMTPItems(requests, to: destination, transport: transport)
            }
            return
        }

        for item in downloadableItems {
            guard let file = itemObjects[item.id] as? ICCameraFile else {
                finishDownload(itemName: item.name, savedFilename: nil, errorMessage: "The file is no longer available.")
                continue
            }

            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: destination,
                .overwrite: false,
                .sidecarFiles: true,
                .truncateAfterSuccessfulDownload: true
            ]

            _ = file.requestDownload(options: options) { [weak self] filename, error in
                let errorMessage = error?.localizedDescription
                Task { @MainActor in
                    self?.finishDownload(itemName: item.name, savedFilename: filename, errorMessage: errorMessage)
                }
            }
        }
    }

    @MainActor private func enqueueQueuedDownloads(_ requestedItems: [USBTransferItem], to destination: URL, queue: TransferQueue) {
        let duplicates = requestedItems.filter { item in
            FileManager.default.fileExists(atPath: destination.appending(path: item.name).path)
        }
        let resolution = duplicates.isEmpty
            ? nil
            : promptDuplicateResolution(itemNames: duplicates.map(\.name), destination: destination.path)
        if !duplicates.isEmpty, resolution == nil {
            statusMessage = "Download canceled."
            return
        }

        let existingNames = localDirectoryNames(destination)
        var queuedCount = 0

        if let transport = mtpTransport {
            for item in requestedItems {
                guard let node = mtpNodes[item.id] else { continue }
                var localName = item.name
                var shouldReplace = false
                if duplicates.contains(where: { $0.id == item.id }), let resolution {
                    switch resolution {
                    case .skip:
                        continue
                    case .replace:
                        shouldReplace = true
                    case .keep:
                        localName = TransferConflictResolver.enumeratedName(for: item.name, existingNames: existingNames)
                    }
                }
                let queuedLocalName = localName
                let queuedShouldReplace = shouldReplace
                let output = destination.appending(path: queuedLocalName)
                let totalBytes = node.isDirectory ? folderSizeBytesByItemID[item.id] : item.size
                queue.enqueue(
                    kind: .download,
                    title: item.name,
                    subtitle: "Downloading from File Transfer",
                    source: TransferEndpoint(kind: .usbTransfer, deviceID: selectedDeviceID, path: item.path, displayName: item.path),
                    destination: TransferEndpoint(kind: .mac, path: output.path, displayName: queuedLocalName),
                    itemKind: item.isFolder ? .folder : .file,
                    totalBytes: totalBytes,
                    exclusiveGroup: "mtp:\(transport.id)"
                ) { controller in
                    try controller.checkCancellation()
                    if queuedShouldReplace, FileManager.default.fileExists(atPath: output.path) {
                        try FileManager.default.removeItem(at: output)
                    }
                    try controller.checkCancellation()
                    try await Self.downloadMTPNode(
                        node,
                        to: output,
                        transport: transport,
                        totalBytes: totalBytes
                    ) { progress in
                        Task { @MainActor in
                            let hasKnownTotal = progress.totalBytes > 0
                            controller.updateProgress(
                                completedBytes: progress.completedBytes,
                                totalBytes: hasKnownTotal ? progress.totalBytes : nil,
                                fractionCompleted: hasKnownTotal ? progress.fractionCompleted : nil,
                                message: Self.progressMessage(prefix: "Downloading", progress: progress)
                            )
                        }
                    }
                    try controller.checkCancellation()
                    return TransferJobResult(outputURL: output, message: "Downloaded")
                }
                queuedCount += 1
            }
        } else {
            for item in requestedItems {
                guard let file = itemObjects[item.id] as? ICCameraFile else { continue }
                var localName = item.name
                var shouldReplace = false
                if duplicates.contains(where: { $0.id == item.id }), let resolution {
                    switch resolution {
                    case .skip:
                        continue
                    case .replace:
                        shouldReplace = true
                    case .keep:
                        localName = TransferConflictResolver.enumeratedName(for: item.name, existingNames: existingNames)
                    }
                }

                let queuedLocalName = localName
                let queuedShouldReplace = shouldReplace
                let output = destination.appending(path: queuedLocalName)
                queue.enqueue(
                    kind: .download,
                    title: item.name,
                    subtitle: "Downloading from File Transfer",
                    source: TransferEndpoint(kind: .usbTransfer, deviceID: selectedDeviceID, path: item.path, displayName: item.path),
                    destination: TransferEndpoint(kind: .mac, path: output.path, displayName: queuedLocalName),
                    totalBytes: item.size
                ) { controller in
                    try controller.checkCancellation()
                    if queuedShouldReplace, FileManager.default.fileExists(atPath: output.path) {
                        try FileManager.default.removeItem(at: output)
                    }
                    try controller.checkCancellation()
                    let options: [ICDownloadOption: Any] = [
                        .downloadsDirectoryURL: destination,
                        .saveAsFilename: queuedLocalName,
                        .overwrite: queuedShouldReplace,
                        .sidecarFiles: true,
                        .truncateAfterSuccessfulDownload: true
                    ]
                    let result: TransferJobResult = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TransferJobResult, Error>) in
                        _ = file.requestDownload(options: options) { filename, error in
                            if let error {
                                continuation.resume(throwing: error)
                                return
                            }
                            continuation.resume(returning: TransferJobResult(outputURL: destination.appending(path: filename ?? queuedLocalName), message: "Downloaded"))
                        }
                    }
                    try controller.checkCancellation()
                    return result
                }
                queuedCount += 1
            }
        }

        queue.isPanelExpanded = true
        statusMessage = queuedCount == 0 ? "Download skipped." : "Queued \(queuedCount) File Transfer download\(queuedCount == 1 ? "" : "s")."
    }

    @MainActor private func finishDownload(itemName: String, savedFilename: String?, errorMessage: String?) {
        if let errorMessage {
            failedDownloads += 1
            alert = UserAlert(title: "Download Failed", message: "\(itemName): \(errorMessage)")
        } else {
            completedDownloads += 1
        }

        let finished = completedDownloads + failedDownloads
        if finished >= pendingDownloads {
            isDownloading = false
            endTerminationBlockingActivity()
            statusMessage = failedDownloads == 0
                ? "Downloaded \(completedDownloads) item\(completedDownloads == 1 ? "" : "s")."
                : "Downloaded \(completedDownloads) item\(completedDownloads == 1 ? "" : "s"); \(failedDownloads) failed."
        } else {
            statusMessage = "Downloaded \(finished) of \(pendingDownloads) item\(pendingDownloads == 1 ? "" : "s")..."
        }
    }

    private func updateSnapshot(for camera: ICCameraDevice) {
        let snapshot = USBTransferDevice(
            id: id(for: camera),
            name: camera.name ?? camera.productKind ?? "File Transfer Device",
            transport: Self.displayTransport(camera.transportType),
            productKind: camera.productKind,
            isReady: camera.hasOpenSession && !camera.isLocked,
            isLocked: camera.isLocked,
            catalogPercent: min(100, Int(camera.contentCatalogPercentCompleted))
        )

        if let index = devices.firstIndex(where: { $0.id == snapshot.id }) {
            devices[index] = snapshot
        } else {
            devices.append(snapshot)
            devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func makeItem(from object: ICCameraItem, deviceID: String, parentPath: String) -> USBTransferItem {
        let name = object.name ?? (object as? ICCameraFile)?.originalFilename ?? "Untitled"
        let path = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        let id = itemID(deviceID: deviceID, path: path, object: object)
        itemObjects[id] = object

        let file = object as? ICCameraFile
        return USBTransferItem(
            id: id,
            name: name,
            path: path,
            kind: object is ICCameraFolder ? .folder : .file,
            size: file.map { Int64($0.fileSize) },
            modified: (file?.fileModificationDate ?? object.modificationDate ?? object.creationDate) as Date?,
            uti: object.uti
        )
    }

    private func makeMTPStorageItem(from storage: StorageInfo) -> USBTransferItem {
        let id = mtpStorageItemID(storage.id)
        let path = "/\(storage.name)"
        mtpStorageItems[id] = storage
        return USBTransferItem(
            id: id,
            name: storage.name,
            path: path,
            kind: .folder,
            size: storage.capacityBytes > 0 ? storage.capacityBytes : nil,
            modified: nil,
            uti: UTType.folder.identifier
        )
    }

    private func makeMTPItem(from node: FileNode, parentPath: String) -> USBTransferItem {
        let id = mtpItemID(for: node)
        let path = parentPath == "/" ? "/\(node.name)" : "\(parentPath)/\(node.name)"
        mtpNodes[id] = node
        return USBTransferItem(
            id: id,
            name: node.name,
            path: path,
            kind: node.isDirectory ? .folder : .file,
            size: node.isDirectory ? nil : node.size,
            modified: node.modifiedDate,
            uti: node.isDirectory ? UTType.folder.identifier : node.fileExtension.flatMap { UTType(filenameExtension: $0)?.identifier }
        )
    }

    private func folder(at path: String, in camera: ICCameraDevice) -> ICCameraFolder? {
        guard path != "/" else { return nil }
        var currentItems = camera.contents ?? []
        var currentFolder: ICCameraFolder?

        for component in path.split(separator: "/").map(String.init) {
            guard let match = currentItems.first(where: { ($0.name ?? "") == component }) as? ICCameraFolder else {
                return nil
            }
            currentFolder = match
            currentItems = match.contents ?? []
        }

        return currentFolder
    }

    private func resetPath() {
        guard mtpTransport == nil else {
            resetMTPPath()
            return
        }

        backHistory.removeAll()
        forwardHistory.removeAll()

        guard let camera = selectedCamera else {
            pathComponents = [USBTransferPathComponent(id: "usb-root", itemID: nil, title: "File Transfer", path: "/")]
            return
        }

        pathComponents = [
            USBTransferPathComponent(
                id: "usb-root-\(id(for: camera))",
                itemID: nil,
                title: camera.name ?? "File Transfer",
                path: "/"
            )
        ]
    }

    private func resetMTPPath() {
        backHistory.removeAll()
        forwardHistory.removeAll()
        let title = mtpTransport?.displayName ?? "File Transfer"
        let rootID = "mtp-root-\(mtpTransport?.id ?? "device")"
        let root = USBTransferPathComponent(id: rootID, itemID: nil, title: title, path: "/")
        pathComponents = [root]
        mtpPathStates = [root.id: MTPPathState(storageID: nil, parentID: nil, path: "/")]
        currentMTPStorageID = nil
        currentMTPParentID = nil
    }

    private func id(for device: ICDevice) -> String {
        if let uuid = device.uuidString, !uuid.isEmpty {
            return uuid
        }

        let vendor = String(format: "%04x", device.usbVendorID)
        let product = String(format: "%04x", device.usbProductID)
        return "\(device.usbLocationID)-\(vendor)-\(product)-\(device.name ?? "device")"
    }

    private func itemID(deviceID: String, path: String, object: ICCameraItem) -> String {
        let handle = object.ptpObjectHandle
        return "\(deviceID):\(handle):\(path)"
    }

    private func mtpStorageItemID(_ storageID: String) -> String {
        "mtp-storage:\(storageID)"
    }

    private func mtpItemID(for node: FileNode) -> String {
        "mtp:\(node.storageID):\(node.id)"
    }

    private func pruneFolderSizeCache(keeping visibleIDs: Set<USBTransferItem.ID>) {
        folderSizeBytesByItemID = folderSizeBytesByItemID.filter { visibleIDs.contains($0.key) }
        loadingFolderSizeItemIDs = loadingFolderSizeItemIDs.intersection(visibleIDs)
        failedFolderSizeItemIDs = failedFolderSizeItemIDs.intersection(visibleIDs)
    }

    private static func imageCaptureFolderSizeBytes(_ folder: ICCameraFolder) -> Int64 {
        (folder.contents ?? []).reduce(Int64(0)) { total, item in
            if let file = item as? ICCameraFile {
                return total + Int64(file.fileSize)
            }
            if let childFolder = item as? ICCameraFolder {
                return total + imageCaptureFolderSizeBytes(childFolder)
            }
            return total
        }
    }

    private static func mtpFolderSizeBytes(_ folder: FileNode, transport: MTPTransport) async throws -> Int64 {
        try Task.checkCancellation()
        let children = try await transport.listChildren(of: folder.id, in: folder.storageID)
        var total: Int64 = 0
        for child in children {
            try Task.checkCancellation()
            if child.isDirectory {
                total += try await mtpFolderSizeBytes(child, transport: transport)
            } else {
                total += max(0, child.size)
            }
        }
        return total
    }

    private func previewCacheDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "AndroidFileBrowserUSBTransferPreviews", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func defaultMTPArchiveName(for items: [USBTransferItem]? = nil) -> String {
        let source = items ?? selectedItems
        if source.count == 1, let name = source.first?.name {
            let baseName = (name as NSString).deletingPathExtension
            return baseName.isEmpty ? "Archive.zip" : "\(baseName).zip"
        }
        return "Archive.zip"
    }

    private static func archiveWorkDirectory(prefix: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "AndroidFileBrowserUSBTransferArchives", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func normalizedArchiveName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = safeArchiveComponent(trimmed.isEmpty ? "Archive.zip" : trimmed)
        return safeName.lowercased().hasSuffix(".zip") ? safeName : "\(safeName).zip"
    }

    private static func safeArchiveComponent(_ rawName: String) -> String {
        let safeName = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
        return safeName.isEmpty ? "Untitled" : safeName
    }

    private static func downloadMTPNode(
        _ node: FileNode,
        to destination: URL,
        transport: MTPTransport,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        if node.isDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try await transport.listChildren(of: node.id, in: node.storageID)
            for child in children {
                try await downloadMTPNode(
                    child,
                    to: destination.appending(path: safeArchiveComponent(child.name)),
                    transport: transport,
                    status: status
                )
            }
            return
        }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await transport.download(node.id, to: destination) { progress in
            status(progressMessage(prefix: "Preparing", progress: progress))
        }
    }

    private static func uploadDirectoryContents(
        of directory: URL,
        toParent parentID: String,
        in storageID: String,
        transport: MTPTransport,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            let name = safeArchiveComponent(url.lastPathComponent)
            if values.isDirectory == true {
                let node = try await transport.createDirectory(named: name, inParent: parentID, in: storageID)
                try await uploadDirectoryContents(
                    of: url,
                    toParent: node.id,
                    in: storageID,
                    transport: transport,
                    status: status
                )
            } else {
                _ = try await transport.upload(localURL: url, as: name, toParent: parentID, in: storageID) { progress in
                    status(progressMessage(prefix: "Uploading", progress: progress))
                }
            }
        }
    }

    private static func extractLocalArchive(_ archiveURL: URL, to destination: URL) async throws {
        let lowercasedName = archiveURL.lastPathComponent.lowercased()
        if lowercasedName.hasSuffix(".zip") {
            try await runLocalArchiveTool(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", archiveURL.path, destination.path],
                currentDirectory: nil
            )
            return
        }

        let flags: String
        if lowercasedName.hasSuffix(".tar.gz") || lowercasedName.hasSuffix(".tgz") {
            flags = "-xzf"
        } else if lowercasedName.hasSuffix(".tar.bz2") || lowercasedName.hasSuffix(".tbz2") {
            flags = "-xjf"
        } else if lowercasedName.hasSuffix(".tar.xz") || lowercasedName.hasSuffix(".txz") {
            flags = "-xJf"
        } else if lowercasedName.hasSuffix(".tar") {
            flags = "-xf"
        } else {
            throw FileOperationError.commandFailed("\(archiveURL.lastPathComponent) is not a supported archive.")
        }

        try await runLocalArchiveTool(
            executable: "/usr/bin/tar",
            arguments: [flags, archiveURL.path, "-C", destination.path],
            currentDirectory: nil
        )
    }

    private static func runLocalArchiveTool(
        executable: String,
        arguments: [String],
        currentDirectory: URL?
    ) async throws {
        let result = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return ADBCommandResult(
                stdoutData: stdoutData,
                stderrData: stderrData,
                exitCode: process.terminationStatus
            )
        }.value

        guard result.exitCode == 0 else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw FileOperationError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func displayTransport(_ rawTransport: String?) -> String {
        switch rawTransport {
        case ICDeviceTransport.transportTypeUSB.rawValue:
            return "USB"
        case ICDeviceTransport.transportTypeMassStorage.rawValue:
            return "Mass Storage"
        case ICDeviceTransport.transportTypeTCPIP.rawValue:
            return "Network"
        case let raw?:
            return raw.replacingOccurrences(of: "ICTransportType", with: "")
        case nil:
            return "USB"
        }
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.reduce(into: "") { $0.append($1) }
    }

    private static func progressMessage(prefix: String, progress: TransferProgress) -> String {
        guard progress.totalBytes > 0 else {
            return "\(prefix) \(progress.fileName)..."
        }
        let percent = Int((progress.fractionCompleted * 100).rounded())
        return "\(prefix) \(progress.fileName) \(percent)%..."
    }

    @MainActor private func promptDuplicateResolution(itemNames: [String], destination: String) -> TransferConflictResolution? {
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

    private func localDirectoryNames(_ directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private func localUploadRequest(for url: URL, remoteName: String, replace: Bool) throws -> USBLocalUploadRequest {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values.isDirectory == true {
            return USBLocalUploadRequest(
                url: url,
                remoteName: remoteName,
                replace: replace,
                isDirectory: true,
                files: try localUploadFiles(in: url)
            )
        }

        return USBLocalUploadRequest(
            url: url,
            remoteName: remoteName,
            replace: replace,
            isDirectory: false,
            files: [
                USBLocalUploadFile(
                    url: url,
                    relativeDirectory: "",
                    remoteName: remoteName,
                    size: values.fileSize.map(Int64.init)
                )
            ]
        )
    }

    private func localUploadFiles(in directory: URL) throws -> [USBLocalUploadFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [USBLocalUploadFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard values.isDirectory != true else { continue }

            let relativePath = relativePath(for: url, under: directory)
            files.append(
                USBLocalUploadFile(
                    url: url,
                    relativeDirectory: (relativePath as NSString).deletingLastPathComponent,
                    remoteName: url.lastPathComponent,
                    size: values.fileSize.map(Int64.init)
                )
            )
        }

        return files.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    private func relativePath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

}
