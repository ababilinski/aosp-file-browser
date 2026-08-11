import AppKit
import QuickLookUI
import SwiftUI

struct DetailInspector: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var usbTransferManager: USBTransferManager

    init(model: AppModel) {
        self.model = model
        self.usbTransferManager = model.usbTransferManager
    }

    var body: some View {
        Group {
            if hasSelection {
                ScrollView {
                    inspectorContent
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                inspectorContent
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var hasSelection: Bool {
        model.isUSBTransferSelected && usbTransferManager.selectedItem != nil
            || model.selectedFile != nil
            || model.selectedAppStorageLocation != nil
            || model.selectedPackage != nil
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if model.isUSBTransferSelected, let item = usbTransferManager.selectedItem {
            USBTransferDetailCard(manager: usbTransferManager, settings: model.settings, item: item)
        } else if let file = model.selectedFile {
            FileDetailCard(model: model, file: file)
        } else if let location = model.selectedAppStorageLocation {
            AppStorageLocationDetailCard(model: model, selection: location)
        } else if let package = model.selectedPackage {
            PackageDetailCard(model: model, package: package)
        } else {
            CompatibleContentUnavailableView("No Selection", systemImage: "sidebar.right", description: Text("Select a file, preview, or app to see details."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private func displayByteCount(_ bytes: Int64?) -> String {
    guard let bytes else { return "—" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private extension View {
    func inspectorGlassCard() -> some View {
        padding(16)
            .liquidGlassPanel(
                in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                fallbackMaterial: .thinMaterial
            )
    }

    func inspectorActionBar() -> some View {
        controlSize(.small)
            .buttonBorderShape(.roundedRectangle)
            .padding(10)
            .liquidGlassPanel(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                fallbackMaterial: .regularMaterial
            )
    }
}

private struct AppStorageLocationDetailCard: View {
    @ObservedObject var model: AppModel
    let selection: SelectedAppStorageLocation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FinderStyleIconView(
                symbol: selection.location.symbol,
                kind: iconKind,
                size: 72,
                usesFinderColors: model.settings.useFinderStyleIconColors
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(selection.location.title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Text(selection.packageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            DetailGrid(rows: [
                ("App", selection.displayName),
                ("Version", selection.versionName ?? "Unknown"),
                ("Kind", selection.isProtected ? "Protected app storage" : "App storage folder"),
                ("Size", selection.displaySize),
                ("Status", selection.isBrowseable ? "Browseable" : "Protected or empty"),
                ("Path", selection.location.path)
            ])

            HStack {
                Button {
                    if let package = model.selectedPackage {
                        Task { await model.openAppStorageLocationOrExplain(package: package, location: selection.location) }
                    }
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .disabled(!selection.isBrowseable)

                if selection.location.kind == .obb {
                    Button {
                        model.beginUpload(to: selection.location.path)
                    } label: {
                        Label("Upload OBB", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    model.copyPathToPasteboard(selection.location.path)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.clipboard")
                }
            }
            .inspectorActionBar()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorGlassCard()
    }

    private var iconKind: FinderStyleIconKind {
        switch selection.location.kind {
        case .data, .files, .cache, .userData:
            .folder
        case .media:
            .image
        case .obb:
            .archive
        }
    }
}

private struct USBTransferDetailCard: View {
    @ObservedObject var manager: USBTransferManager
    @ObservedObject var settings: AppSettings
    let item: USBTransferItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            USBTransferThumbnailView(
                manager: manager,
                settings: settings,
                item: item,
                size: 72,
                purpose: .detail
            )

            Text(item.name)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            DetailGrid(rows: detailRows)

            MediaMetadataDisclosure(
                metadata: manager.mediaMetadataByItemID[item.id],
                isLoading: manager.loadingMediaMetadataItemIDs.contains(item.id),
                errorMessage: manager.failedMediaMetadataItemMessages[item.id]
            )

            HStack {
                Button {
                    manager.preview(item: item)
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .disabled(!item.isDownloadable)
                .help("Preview: download this File Transfer item to a temporary cache and open it in a preview window.")

                Button {
                    manager.download(item: item)
                } label: {
                    Label("Download", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!item.isDownloadable)
                .help("Download: save this File Transfer item to this Mac.")
            }
            .inspectorActionBar()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorGlassCard()
        .task(id: item.id) {
            await manager.prepareFolderSize(for: item)
            await manager.prepareMediaMetadata(for: item)
        }
    }

    private var detailRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Kind", item.kind.displayName),
            ("Size", manager.displaySize(for: item)),
            ("Modified", item.displayModified),
            ("Extension", item.fileExtension.isEmpty ? "—" : item.fileExtension),
            ("UTI", item.uti ?? "—"),
            ("Path", item.path)
        ]
        if let metadata = manager.mediaMetadataByItemID[item.id] {
            rows.insert(contentsOf: metadata.summaryRows.map { ($0.label, $0.value) }, at: min(3, rows.count))
        } else if manager.loadingMediaMetadataItemIDs.contains(item.id) {
            rows.insert(("Media", "Reading metadata..."), at: min(3, rows.count))
        }
        return rows
    }
}

private struct FileDetailCard: View {
    @ObservedObject var model: AppModel
    let file: AndroidFile

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MediaThumbnailView(model: model, file: file, size: 72, purpose: .detail)

            Text(file.name)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            DetailGrid(rows: detailRows)

            MediaMetadataDisclosure(
                metadata: model.mediaMetadataByFileID[file.id],
                isLoading: model.loadingMediaMetadataFileIDs.contains(file.id),
                errorMessage: model.failedMediaMetadataFileMessages[file.id]
            )

            HStack {
                Button {
                    Task { await model.preview(file: file) }
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .disabled(file.kind != .file)
                .help("Preview: pull this Android file to a temporary cache and open it in a preview window.")

                Button {
                    Task { await model.download(file: file) }
                } label: {
                    Label("Download", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(file.kind != .file)
                .help("Download: copy this Android file to this Mac.")

                if !isTrashFile {
                    Button(role: .destructive) {
                        model.selectedFileIDs = [file.id]
                        Task { await model.deleteSelectedToTrash() }
                    } label: {
                        Label("Trash", systemImage: "trash")
                    }
                    .help("Move this file to AOSP File Manager Trash.")
                }
            }
            .inspectorActionBar()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorGlassCard()
        .task(id: file.path) {
            await model.prepareFolderSize(for: file)
            await model.prepareMediaMetadata(for: file)
        }
    }

    private var detailRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Kind", file.kind.displayName),
            ("Size", model.displaySize(for: file)),
            ("Modified", file.displayModified),
            ("Created", file.displayCreated),
            ("Extension", file.fileExtension.isEmpty ? "—" : file.fileExtension),
            ("Permissions", file.permissions ?? "—"),
            ("Path", file.path)
        ]
        if let metadata = model.mediaMetadataByFileID[file.id] {
            rows.insert(contentsOf: metadata.summaryRows.map { ($0.label, $0.value) }, at: min(3, rows.count))
        } else if model.loadingMediaMetadataFileIDs.contains(file.id) {
            rows.insert(("Media", "Reading metadata..."), at: min(3, rows.count))
        }
        return rows
    }

    private var isTrashFile: Bool {
        file.path.contains("/.AndroidFileBrowserTrash/") || file.path.contains("/.Trash/")
    }
}

private struct PackageDetailCard: View {
    @ObservedObject var model: AppModel
    let package: AndroidPackage
    @State private var tab: PackageInspectorTab = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                PackageIconView(
                    package: package,
                    size: 58,
                    usesFinderColors: model.settings.useFinderStyleIconColors
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(package.displayName)
                        .font(.title3.weight(.semibold))
                    Text(package.packageName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Picker("Details", selection: $tab) {
                ForEach(PackageInspectorTab.allCases) { tab in
                    Text(tab.pickerTitle).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch tab {
            case .overview:
                VStack(alignment: .leading, spacing: 14) {
                    DetailGrid(rows: overviewRows)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], alignment: .leading, spacing: 8) {
                        Button {
                            Task { await model.openApp(package: package) }
                        } label: {
                            Label("Open", systemImage: "play.fill")
                        }
                        .help("Open this app on the Android device.")

                        Button {
                            Task { await model.forceStop(package: package) }
                        } label: {
                            Label("Force Close", systemImage: "xmark.octagon")
                        }
                        .disabled(!package.isRunning)
                        .help("Force Close: stop this running app on the Android device.")

                        Button {
                            Task { await model.pullAPK(package: package) }
                        } label: {
                            Label("Pull APK", systemImage: "square.and.arrow.down")
                        }
                        .disabled(package.apkPath == nil)
                        .help("Pull APK: save this app's APK to this Mac.")

                        Button {
                            Task { await model.loadPackageDetails(package: package) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh: fetch permissions, activities, services, receivers, providers, and visible app folders from Android.")
                    }
                    .inspectorActionBar()

                    PackagePermissionsDisclosure(package: package)
                }
            case .folders:
                PackageStorageLocationsView(model: model, package: package)
            case .intents:
                ComponentDisclosure(title: "Activities", endpoints: package.activities)
                ComponentDisclosure(title: "Receivers", endpoints: package.receivers)
                ComponentDisclosure(title: "Services", endpoints: package.services)
                ComponentDisclosure(title: "Providers", endpoints: package.providers)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorGlassCard()
    }

    private var overviewRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Type", package.kind.label),
            ("Status", package.isRunning ? "Running" : "Idle"),
            ("Enabled", package.enabled.map { $0 ? "Yes" : "No" } ?? "Unknown"),
            ("Version", package.versionName ?? "Unknown"),
            ("APK", package.apkPath ?? "Unknown"),
            ("APK Size", package.displayAPKSize),
            ("Total Size", package.displayTotalSize),
            ("Permissions", "\(package.permissions.count)"),
            ("Intent Endpoints", "\(package.activities.count + package.receivers.count + package.services.count + package.providers.count)")
        ]

        if let storageStats = package.storageStats {
            rows.insert(("App Size", displayByteCount(storageStats.appBytes)), at: 6)
            rows.insert(("User Data", displayByteCount(storageStats.userDataBytes)), at: 7)
            rows.insert(("Cache", displayByteCount(storageStats.cacheBytes)), at: 8)
        }
        return rows
    }
}

private enum PackageInspectorTab: String, CaseIterable, Identifiable {
    case overview
    case folders
    case intents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .folders: "Folders"
        case .intents: "Intents"
        }
    }

    var pickerTitle: String {
        switch self {
        case .overview: "Info"
        case .folders: "Folders"
        case .intents: "Intents"
        }
    }
}

private struct PackagePermissionsDisclosure: View {
    let package: AndroidPackage

    var body: some View {
        DisclosureGroup("Permissions (\(package.permissions.count))") {
            VStack(alignment: .leading, spacing: 6) {
                if package.permissions.isEmpty {
                    Text("No permissions reported by Android.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(package.permissions, id: \.self) { permission in
                        Text(permission)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 8)
        }
    }
}

private struct PackageStorageLocationsView: View {
    @ObservedObject var model: AppModel
    let package: AndroidPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if package.availableStorageKinds == nil {
                CompatibleContentUnavailableView(
                    "Storage Details Needed",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Refresh app details to see which app folders exist and contain data.")
                )
                Button {
                    Task { await model.loadPackageDetails(package: package) }
                } label: {
                    Label("Refresh Details", systemImage: "arrow.clockwise")
                }
            } else if package.visibleAppStorageLocations.isEmpty {
                CompatibleContentUnavailableView(
                    "No App Storage Data",
                    systemImage: "folder",
                    description: Text("No app storage folders with visible data were found.")
                )
            } else {
                ForEach(package.visibleAppStorageLocations) { location in
                    PackageStorageLocationRow(model: model, package: package, location: location)
                }
            }
        }
    }
}

private struct PackageStorageLocationRow: View {
    @ObservedObject var model: AppModel
    let package: AndroidPackage
    let location: AppStorageLocation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                FinderStyleIconView(
                    symbol: location.symbol,
                    kind: iconKind,
                    size: 24,
                    usesFinderColors: model.settings.useFinderStyleIconColors
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(location.title)
                        .font(.callout.weight(.semibold))
                    Text(location.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(location.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)
            }

            HStack {
                Button {
                    Task { await model.openAppStorageLocationOrExplain(package: package, location: location) }
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open \(location.title) in the file browser.")

                if location.kind == .obb {
                    Button {
                        model.beginUpload(to: location.path)
                    } label: {
                        Label("Upload OBB", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Upload OBB: copy files from this Mac into this app's OBB folder.")
                }
            }
        }
        .padding(10)
        .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 12, style: .continuous), fallbackMaterial: .regularMaterial)
    }

    private var iconKind: FinderStyleIconKind {
        switch location.kind {
        case .data, .files, .cache, .userData:
            .folder
        case .media:
            .image
        case .obb:
            .archive
        }
    }
}

private struct PackageIconView: View {
    let package: AndroidPackage
    let size: CGFloat
    let usesFinderColors: Bool

    var body: some View {
        PackageArtwork(package: package, size: size, usesFinderColors: usesFinderColors)
    }
}

private struct ComponentDisclosure: View {
    let title: String
    let endpoints: [AndroidIntentEndpoint]

    var body: some View {
        DisclosureGroup("\(title) (\(endpoints.count))") {
            VStack(alignment: .leading, spacing: 12) {
                if endpoints.isEmpty {
                    Text("No \(title.lowercased()) reported by Android.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(endpoints) { endpoint in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(endpoint.component)
                                .font(.caption.weight(.semibold))
                                .textSelection(.enabled)
                            IntentFlow(label: "Actions", values: endpoint.actions)
                            IntentFlow(label: "Categories", values: endpoint.categories)
                            IntentFlow(label: "Data", values: endpoint.data)
                        }
                        .padding(10)
                        .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 12, style: .continuous), fallbackMaterial: .regularMaterial)
                    }
                }
            }
            .padding(.top, 8)
        }
    }
}

private struct IntentFlow: View {
    let label: String
    let values: [String]

    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct DetailGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .textSelection(.enabled)
                        .lineLimit(label == "Path" || label == "APK" ? 4 : 1)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.callout)
    }
}

struct MediaMetadataDisclosure: View {
    let metadata: RemoteFileMetadata?
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading media metadata...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let metadata, !metadata.groups.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(metadata.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            DetailGrid(rows: group.rows.map { ($0.label, $0.value) })
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("More Metadata", systemImage: "info.circle")
                    .font(.callout.weight(.medium))
            }
        } else if let errorMessage {
            Label(errorMessage, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = context.coordinator.item
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        context.coordinator.item.url = url
        nsView.previewItem = context.coordinator.item
        nsView.refreshPreviewItem()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator {
        let item: PreviewItem

        init(url: URL) {
            self.item = PreviewItem(url: url)
        }
    }

    final class PreviewItem: NSObject, QLPreviewItem {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        var previewItemURL: URL? { url }
    }
}
