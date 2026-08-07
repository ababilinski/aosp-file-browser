import SwiftUI

struct USBTransferView: View {
    @ObservedObject var manager: USBTransferManager
    @ObservedObject var settings: AppSettings
    @Binding var layout: BrowserLayout
    let isADBConnected: Bool
    let pasteIntoCurrentFolder: () -> Void
    let onBlankSpaceDeselection: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if manager.devices.isEmpty {
                USBTransferEmptyState(manager: manager)
            } else {
                VStack(spacing: 0) {
                    if manager.mtpAccessIssue != nil || manager.backend != .mtp {
                        USBTransferCapabilityBanner(manager: manager, isADBConnected: isADBConnected)
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                    }

                    USBTransferPathBar(manager: manager)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                    if manager.shouldShowSearchOptions {
                        USBTransferSearchOptionsBar(manager: manager)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                    }

                    Divider()

                    ZStack {
                        switch layout {
                        case .list:
                            USBTransferColumnBrowser(
                                manager: manager,
                                settings: settings,
                                pasteIntoCurrentFolder: pasteIntoCurrentFolder,
                                onBlankSpaceDeselection: onBlankSpaceDeselection
                            )
                        case .icons:
                            USBTransferIconGrid(
                                manager: manager,
                                settings: settings,
                                pasteIntoCurrentFolder: pasteIntoCurrentFolder,
                                onBlankSpaceDeselection: onBlankSpaceDeselection
                            )
                        }

                        if manager.isCataloging
                            && manager.items.isEmpty
                            && !manager.isShowingCachedMTPListing {
                            ProgressView("Cataloging device storage...")
                                .padding(18)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }

                    if settings.showPathBar {
                        Divider()
                        BrowserPathStatusBar(path: manager.pathBarPath, showsFolder: manager.pathBarShowsFolder)
                    }
                }
            }
        }
        .task {
            manager.startBrowsingIfNeeded()
        }
        .alert(item: $manager.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"), action: { alert.onDismiss?() })
            )
        }
        .sheet(isPresented: $manager.isCreatingMTPFolder) {
            NameEntrySheet(title: "New Folder", defaultValue: "Untitled Folder") { name in
                manager.createMTPFolder(named: name)
            }
        }
        .sheet(item: $manager.pendingMTPRenameItem) { item in
            NameEntrySheet(title: "Rename", defaultValue: item.name) { name in
                manager.renameMTPItem(item, to: name)
            }
        }
        .sheet(item: $manager.pendingMTPArchiveRequest) { request in
            NameEntrySheet(title: "Compress", defaultValue: request.defaultName) { name in
                manager.compressSelectedMTPItems(as: name)
            }
        }
    }
}

private struct USBTransferSearchOptionsBar: View {
    @ObservedObject var manager: USBTransferManager
    @State private var showsFilterRows = false

    private var shouldShowFilterRows: Bool {
        showsFilterRows || manager.effectiveSearchKindFilter != .any || manager.searchDateFilter != .any
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Search:")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)

                Text("Current Folder")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help("File Transfer searches the current folder. Search Everywhere needs Developer Options.")

                Spacer()

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        showsFilterRows.toggle()
                    }
                } label: {
                    Image(systemName: shouldShowFilterRows ? "minus" : "plus")
                }
                .liquidGlassButton()
                .help(shouldShowFilterRows ? "Hide search filters" : "Add search filter")
            }

            if shouldShowFilterRows {
                SearchFilterRows(
                    kindFilter: $manager.searchKindFilter,
                    effectiveKindFilter: manager.effectiveSearchKindFilter,
                    typedKindFilter: SearchQueryParser.parse(manager.searchText).kindFilter,
                    dateFilter: $manager.searchDateFilter
                ) {
                    manager.clearSearchKindFilter()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct USBTransferEmptyState: View {
    @ObservedObject var manager: USBTransferManager

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: iconName)
                    .font(.system(size: 44, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(manager.mtpAccessIssue == nil ? Color.accentColor : Color.orange)

                VStack(spacing: 7) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 580)
                }

                if manager.mtpAccessIssue == nil {
                    connectionSteps
                }

                actionButtons
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: 840)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionSteps: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    setupStep(number: 1, title: "Connect and unlock", detail: "Use a USB data cable and keep the phone awake.")
                    setupStep(number: 2, title: "Open the USB notice", detail: "Pull down notifications and tap the USB connection.")
                    setupStep(number: 3, title: "Choose File transfer", detail: "Then come back here and check again.")
                }

                VStack(spacing: 10) {
                    setupStep(number: 1, title: "Connect and unlock", detail: "Use a USB data cable and keep the phone awake.")
                    setupStep(number: 2, title: "Open the USB notice", detail: "Pull down notifications and tap the USB connection.")
                    setupStep(number: 3, title: "Choose File transfer", detail: "Then come back here and check again.")
                }
            }

            Label("No phone app is needed. USB debugging can stay on.", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func setupStep(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var actionButtons: some View {
        if manager.isRecoveringMTPConnection {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reconnecting File Transfer…")
                    .foregroundStyle(.secondary)
            }
        } else if manager.isReleasingADBForMTP {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Pausing Phone Tools…")
                    .foregroundStyle(.secondary)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    checkAgainButton
                    recoveryButton
                }

                VStack(spacing: 10) {
                    checkAgainButton
                    recoveryButton
                }
            }
        }
    }

    @ViewBuilder
    private var recoveryButton: some View {
        if let issue = manager.mtpAccessIssue, issue.canRunRecoveryAction {
            Button(issue.actionTitle ?? "Try Again") {
                manager.recoverMTPAccessIssue()
            }
            .buttonStyle(.borderedProminent)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var checkAgainButton: some View {
        if manager.mtpAccessIssue == nil {
            Button("Check Again") {
                manager.refresh()
            }
            .buttonStyle(.borderedProminent)
            .fixedSize(horizontal: true, vertical: false)
        } else {
            Button("Check Again") {
                manager.refresh()
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var title: String {
        manager.mtpAccessIssue?.title ?? "Turn On File Transfer"
    }

    private var description: String {
        manager.mtpAccessIssue?.message ?? "On your phone, open the USB notification and choose File transfer / Android Auto."
    }

    private var iconName: String {
        manager.mtpAccessIssue == nil ? "cable.connector.slash" : "exclamationmark.triangle"
    }
}

private struct USBTransferHeader: View {
    @ObservedObject var manager: USBTransferManager

    var body: some View {
        HStack(spacing: 10) {
            Label("File Transfer", systemImage: "externaldrive.connected.to.line.below")
                .font(.headline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if manager.selectedDevice != nil {
                Text(activeDeviceStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(manager.selectedDevice?.subtitle ?? manager.statusMessage)
            }

            Spacer()

            InlineSearchField(text: $manager.searchText, prompt: "Search", kindFilter: $manager.searchKindFilter)

            Button {
                manager.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("Refresh: reload the current File Transfer folder.")
            .accessibilityLabel("Refresh File Transfer")
            .accessibilityHint("Reload the files shown through File Transfer.")

            if manager.mtpAccessIssue?.canRunRecoveryAction == true {
                Button {
                    manager.recoverMTPAccessIssue()
                } label: {
                    Label(manager.mtpAccessIssue?.actionTitle ?? "Try Again", systemImage: "bolt.horizontal.circle")
                }
                .labelStyle(.iconOnly)
                .disabled(manager.isReleasingADBForMTP || manager.isRecoveringMTPConnection)
                .help("Try the File Transfer connection again.")
                .accessibilityLabel(manager.mtpAccessIssue?.actionTitle ?? "Try Again")
                .accessibilityHint("Try the File Transfer connection again.")
            }

            if manager.backend == .mtp {
                Button {
                    manager.requestMTPNewFolder()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .labelStyle(.iconOnly)
                .disabled(!manager.canWriteCurrentMTPFolder)
                .help("New Folder: create a folder in the current phone folder.")
                .accessibilityLabel("New Folder")
                .accessibilityHint("Create a folder on the phone.")

                Button {
                    manager.uploadToCurrentMTPFolder()
                } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .disabled(!manager.canWriteCurrentMTPFolder)
                .help("Upload: copy files from this Mac into the current phone folder.")
                .accessibilityLabel("Upload to Phone")
                .accessibilityHint("Upload files to the current phone folder.")

                Button {
                    manager.requestMTPCompressSelected()
                } label: {
                    Label("Compress", systemImage: "doc.zipper")
                }
                .labelStyle(.iconOnly)
                .disabled(!manager.canCompressSelectedMTPItems)
                .help("Compress: create a zip archive from the selected files or folders.")
                .accessibilityLabel("Compress Items")
                .accessibilityHint("Create a zip archive from the selected File Transfer items.")

                Button {
                    if let archive = manager.selectedMTPExtractableArchive {
                        manager.confirmAndExtractMTPArchive(archive)
                    }
                } label: {
                    Label("Uncompress", systemImage: "archivebox")
                }
                .labelStyle(.iconOnly)
                .disabled(manager.selectedMTPExtractableArchive == nil)
                .help("Uncompress: extract the selected archive into a new folder.")
                .accessibilityLabel("Uncompress Archive")
                .accessibilityHint("Extract the selected archive into a folder next to it.")

                Button(role: .destructive) {
                    manager.deleteSelectedMTPItems()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .disabled(!manager.canDeleteSelectedMTPItems)
                .help("Delete: permanently remove the selected items from the phone.")
                .accessibilityLabel("Delete Items")
                .accessibilityHint("Delete selected items from the phone.")
            }

            Button {
                if let item = manager.selectedDownloadableItems.first, manager.selectedDownloadableItems.count == 1 {
                    manager.preview(item: item)
                }
            } label: {
                Label("Preview", systemImage: "eye")
            }
            .labelStyle(.iconOnly)
            .disabled(manager.selectedDownloadableItems.count != 1)
            .help("Preview: download the selected file to a temporary cache and open it in a preview window.")
            .accessibilityLabel("Preview File Transfer Item")
            .accessibilityHint("Download the selected file to a temporary cache and preview it.")

            Button {
                manager.downloadSelected()
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .disabled(manager.selectedDownloadableItems.isEmpty)
            .help("Download: save the selected File Transfer files to this Mac.")
            .accessibilityLabel("Download File Transfer Items")
            .accessibilityHint("Download the selected File Transfer files to this Mac.")
        }
    }

    private var activeDeviceStatus: String {
        guard let device = manager.selectedDevice else {
            return manager.statusMessage
        }
        return "\(device.name) · \(device.statusLabel)"
    }
}

private struct USBTransferCapabilityBanner: View {
    @ObservedObject var manager: USBTransferManager
    let isADBConnected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var message: String {
        if let issue = manager.mtpAccessIssue {
            return issue.statusMessage
        }

        switch manager.backend {
        case .mtp:
            return isADBConnected
                ? "File Transfer is connected. USB debugging can stay on."
                : "File Transfer is connected and ready for files and folders."
        case .imageCapture:
            return isADBConnected
                ? "Photo access is read-only. You can preview and download the photos and videos macOS can see."
                : "Photo access is connected. This view is limited to photos and videos."
        case .checking:
            return "Looking for a File Transfer connection."
        case .notChecked:
            return "Open File Transfer to check the phone connection."
        }
    }

    private var iconName: String {
        if manager.mtpAccessIssue != nil {
            return "exclamationmark.triangle"
        }

        return switch manager.backend {
        case .mtp: "externaldrive.connected.to.line.below"
        case .imageCapture: "camera"
        case .checking: "progress.indicator"
        case .notChecked: "cable.connector"
        }
    }

    private var iconColor: Color {
        if manager.mtpAccessIssue != nil {
            return .orange
        }

        return switch manager.backend {
        case .mtp: .green
        case .imageCapture: isADBConnected ? .secondary : .orange
        case .checking, .notChecked: .secondary
        }
    }
}

private struct USBTransferPathBar: View {
    @ObservedObject var manager: USBTransferManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(manager.pathComponents) { component in
                        Button {
                            if component.id != manager.pathComponents.last?.id {
                                manager.navigate(to: component)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(component.title)
                                    .font(.callout)
                                    .lineLimit(1)
                                if component.id == manager.pathComponents.last?.id,
                                   manager.isCataloging,
                                   !manager.items.isEmpty {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .accessibilityLabel("Updating \(component.title)")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(component.id == manager.pathComponents.last?.id ? .primary : .secondary)
                        .help(component.path)
                        .contextMenu {
                            Button {
                                manager.copyPathToPasteboard(component.path)
                            } label: {
                                Label("Copy Path", systemImage: "doc.on.clipboard")
                            }
                        }

                        if component.id != manager.pathComponents.last?.id {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer(minLength: 12)

            InlineSearchField(text: $manager.searchText, prompt: "Search", kindFilter: $manager.searchKindFilter)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct USBTransferColumnBrowser: View {
    @ObservedObject var manager: USBTransferManager
    @ObservedObject var settings: AppSettings
    let pasteIntoCurrentFolder: () -> Void
    let onBlankSpaceDeselection: () -> Void
    @State private var dropTargeted = false
    @State private var columnWidths: [USBTransferSort: CGFloat] = [:]
    @State private var resizeStartWidths: [USBTransferSort: CGFloat]?
    @State private var scrollPositionID: USBTransferItem.ID?
    @State private var scrollPositionsByPath: [String: USBTransferItem.ID] = [:]
    private let columns: [USBTransferSort] = [.name, .kind, .size, .modified]

    private var currentFolderPath: String {
        manager.pathComponents.last?.path ?? "/"
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = USBTransferColumnMetrics.layout(
                for: columns,
                availableWidth: proxy.size.width,
                preferredWidths: columnWidths
            )

            ZStack {
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        USBTransferColumnHeader(
                            manager: manager,
                            columns: columns,
                            layout: layout
                        ) { column, translation in
                            resizeColumn(column, translation: translation, layout: layout)
                        } onResizeEnded: {
                            resizeStartWidths = nil
                        }
                        Divider()

                        if manager.visibleItems.isEmpty {
                            CompatibleContentUnavailableView(
                                manager.searchText.isEmpty ? "No Items" : "No Results",
                                systemImage: manager.searchText.isEmpty ? "folder" : "magnifyingglass",
                                description: Text(emptyDescription)
                            )
                            .frame(width: layout.totalWidth)
                            .frame(minHeight: 360)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                manager.clearItemSelection()
                                onBlankSpaceDeselection()
                            }
                            .contextMenu {
                                USBTransferBackgroundContextMenu(
                                    manager: manager,
                                    pasteIntoCurrentFolder: pasteIntoCurrentFolder
                                )
                            }
                        } else {
                            ScrollView {
                                ZStack(alignment: .topLeading) {
                                    USBTransferBackgroundSurface(
                                        manager: manager,
                                        pasteIntoCurrentFolder: pasteIntoCurrentFolder,
                                        onBlankSpaceDeselection: onBlankSpaceDeselection
                                    )
                                    .frame(width: layout.totalWidth)
                                    .frame(minHeight: max(proxy.size.height - 33, 0))

                                    LazyVStack(spacing: 0) {
                                        ForEach(manager.visibleItems) { item in
                                            USBTransferColumnRow(
                                                manager: manager,
                                                settings: settings,
                                                item: item,
                                                layout: layout,
                                                level: 0
                                            )
                                            .compatibleScrollTarget(id: item.id, in: "usb-file-column-scroll")
                                        }
                                    }
                                    .compatibleScrollTargetLayout()
                                }
                                .frame(width: layout.totalWidth, alignment: .leading)
                                .frame(minHeight: max(proxy.size.height - 33, 0), alignment: .top)
                            }
                            .compatibleScrollPosition(
                                id: $scrollPositionID,
                                anchor: .top,
                                coordinateSpace: "usb-file-column-scroll"
                            )
                            .onValueChange(of: currentFolderPath) { oldPath, newPath in
                                if let scrollPositionID {
                                    scrollPositionsByPath[oldPath] = scrollPositionID
                                }
                                let restoredPosition = scrollPositionsByPath[newPath]
                                DispatchQueue.main.async {
                                    scrollPositionID = restoredPosition
                                }
                            }
                        }
                    }
                    .frame(width: layout.totalWidth, alignment: .leading)
                }

                if dropTargeted {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [9, 7]))
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                manager.acceptLocalFileDrop(urls)
            } isTargeted: { targeted in
                dropTargeted = targeted && manager.canAcceptLocalFileDrop()
            }
        }
    }

    private func resizeColumn(
        _ column: USBTransferSort,
        translation: CGFloat,
        layout: USBTransferColumnLayout
    ) {
        guard let nextColumn = layout.nextColumn(after: column) else { return }
        let start: [USBTransferSort: CGFloat]
        if let resizeStartWidths {
            start = resizeStartWidths
        } else {
            start = layout.widths
            resizeStartWidths = start
            columnWidths = start
        }

        let currentStart = start[column] ?? layout.width(for: column)
        let nextStart = start[nextColumn] ?? layout.width(for: nextColumn)
        let currentMinimum = USBTransferColumnMetrics.minimumWidth(for: column)
        let nextMinimum = USBTransferColumnMetrics.minimumWidth(for: nextColumn)
        let clampedTranslation = min(
            max(translation, currentMinimum - currentStart),
            nextStart - nextMinimum
        )
        columnWidths[column] = currentStart + clampedTranslation
        columnWidths[nextColumn] = nextStart - clampedTranslation
    }

    private var emptyDescription: String {
        if !manager.searchText.isEmpty {
            return "Try a different search."
        }
        return manager.mtpAccessIssue?.message ?? "This USB transfer folder is empty or not exposed by the phone."
    }
}

private struct USBTransferIconGrid: View {
    @ObservedObject var manager: USBTransferManager
    @ObservedObject var settings: AppSettings
    let pasteIntoCurrentFolder: () -> Void
    let onBlankSpaceDeselection: () -> Void
    @State private var dropTargeted = false
    @State private var scrollPositionID: USBTransferItem.ID?
    @State private var scrollPositionsByPath: [String: USBTransferItem.ID] = [:]
    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 16)]

    private var currentFolderPath: String {
        manager.pathComponents.last?.path ?? "/"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                USBTransferIconSortMenu(manager: manager)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            GeometryReader { proxy in
                ZStack {
                    if manager.visibleItems.isEmpty {
                        CompatibleContentUnavailableView(
                            manager.searchText.isEmpty ? "No Items" : "No Results",
                            systemImage: manager.searchText.isEmpty ? "folder" : "magnifyingglass",
                            description: Text(manager.searchText.isEmpty ? "This folder is empty." : "Try a different search.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            manager.clearItemSelection()
                            onBlankSpaceDeselection()
                        }
                        .contextMenu {
                            USBTransferBackgroundContextMenu(
                                manager: manager,
                                pasteIntoCurrentFolder: pasteIntoCurrentFolder
                            )
                        }
                    } else {
                        ScrollView {
                            ZStack(alignment: .top) {
                                USBTransferBackgroundSurface(
                                    manager: manager,
                                    pasteIntoCurrentFolder: pasteIntoCurrentFolder,
                                    onBlankSpaceDeselection: onBlankSpaceDeselection
                                )
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: proxy.size.height)

                                LazyVGrid(columns: columns, spacing: 18) {
                                    ForEach(manager.visibleItems) { item in
                                        USBTransferIconGridItem(
                                            manager: manager,
                                            settings: settings,
                                            item: item
                                        )
                                        .compatibleScrollTarget(id: item.id, in: "usb-file-icon-scroll")
                                    }
                                }
                                .compatibleScrollTargetLayout()
                                .padding(18)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: proxy.size.height, alignment: .top)
                        }
                        .compatibleScrollPosition(
                            id: $scrollPositionID,
                            anchor: .top,
                            coordinateSpace: "usb-file-icon-scroll"
                        )
                        .onValueChange(of: currentFolderPath) { oldPath, newPath in
                            if let scrollPositionID {
                                scrollPositionsByPath[oldPath] = scrollPositionID
                            }
                            let restoredPosition = scrollPositionsByPath[newPath]
                            DispatchQueue.main.async {
                                scrollPositionID = restoredPosition
                            }
                        }
                    }

                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [9, 7]))
                            .padding(18)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    manager.acceptLocalFileDrop(urls)
                } isTargeted: { targeted in
                    dropTargeted = targeted && manager.canAcceptLocalFileDrop()
                }
            }
        }
    }
}

private struct USBTransferIconSortMenu: View {
    @ObservedObject var manager: USBTransferManager

    var body: some View {
        Menu {
            ForEach(USBTransferSort.allCases) { sort in
                Button {
                    manager.sortBy(sort)
                } label: {
                    if let indicator = manager.sortIndicator(for: sort) {
                        Label("\(sort.label) \(indicator.ascending ? "Ascending" : "Descending")", systemImage: "checkmark")
                    } else {
                        Text(sort.label)
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort icon view contents")
    }
}

private struct USBTransferIconGridItem: View {
    @ObservedObject var manager: USBTransferManager
    @ObservedObject var settings: AppSettings
    let item: USBTransferItem
    @State private var isDropTargeted = false
    @State private var renameText = ""

    private var backgroundFill: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.28)
        }
        return manager.selectedItemIDs.contains(item.id) ? Color.accentColor.opacity(0.16) : Color.clear
    }

    var body: some View {
        VStack(spacing: 10) {
            USBTransferThumbnailView(manager: manager, settings: settings, item: item, size: 54)
            nameContent
                .frame(height: 34, alignment: .top)
        }
        .frame(width: 120, height: 116)
        .padding(8)
        .background(backgroundFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .id(item.id)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            manager.open(item: item)
        })
        .onMouseUpSelect {
            manager.selectItem(item, from: manager.visibleItems)
        }
        .dropDestination(for: URL.self) { urls, _ in
            if manager.canAcceptLocalFileDrop(onto: item) {
                return manager.acceptLocalFileDrop(urls, onto: item)
            }
            return manager.acceptLocalFileDrop(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted && manager.canAcceptLocalFileDrop(onto: item)
        }
        .contextMenu {
            USBTransferItemContextMenu(manager: manager, item: item)
        }
        .onDrag {
            manager.dragItemProvider(for: item) ?? NSItemProvider(object: item.path as NSString)
        }
        .finderFilePromiseDragSource(
            isEnabled: manager.canStartRemoteDrag(with: item),
            selectForMouseDown: { modifiers in
                if !manager.selectedItemIDs.contains(item.id)
                    || modifiers.contains(.command)
                    || modifiers.contains(.shift) {
                    manager.selectItem(item, from: manager.visibleItems, modifiers: modifiers)
                }
            },
            selectForClick: { modifiers in
                manager.selectItem(item, from: manager.visibleItems, modifiers: modifiers)
            },
            renameClickTrailingX: .greatestFiniteMagnitude,
            canStartInlineRenameOnClick: { modifiers in
                !modifiers.contains(.command)
                    && !modifiers.contains(.shift)
                    && manager.selectedItemIDs == [item.id]
            },
            renameForClick: {
                manager.handleNameClickForInlineRename(item)
            },
            prepareForDrag: { modifiers in
                if !manager.selectedItemIDs.contains(item.id) {
                    manager.selectItem(item, from: manager.visibleItems, modifiers: modifiers)
                }
                return manager.filePromiseProvidersForDrag(startingWith: item)
            },
            open: {
                manager.open(item: item)
            },
            canAcceptRemoteDrop: { payload in
                manager.canAcceptRemoteDrop(payload, onto: item)
            },
            setRemoteDropTargeted: { targeted in
                isDropTargeted = targeted && item.isFolder
            },
            performRemoteDrop: { payload in
                manager.moveRemoteDrop(payload, onto: item)
            }
        )
        .onAppear {
            renameText = item.name
        }
        .onValueChange(of: manager.inlineRenameItemID == item.id) { _, isRenaming in
            if isRenaming {
                renameText = item.name
            }
        }
    }

    @ViewBuilder
    private var nameContent: some View {
        if manager.inlineRenameItemID == item.id {
            InlineRenameTextField(
                text: $renameText,
                selectedPrefixLength: InlineRenameSelection.selectedPrefixLength(for: item.name, isFolder: item.isFolder),
                onCommit: {
                    manager.commitInlineRename(item: item, newName: renameText)
                },
                onCancel: {
                    renameText = item.name
                    manager.cancelInlineRename()
                }
            )
            .font(.caption)
        } else {
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .contentShape(Rectangle())
                .onMouseUpSelect {
                    manager.handleNameClickForInlineRename(item)
                }
        }
    }
}

private struct USBTransferBackgroundSurface: View {
    @ObservedObject var manager: USBTransferManager
    let pasteIntoCurrentFolder: () -> Void
    let onBlankSpaceDeselection: () -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                manager.clearItemSelection()
                onBlankSpaceDeselection()
            }
            .contextMenu {
                USBTransferBackgroundContextMenu(
                    manager: manager,
                    pasteIntoCurrentFolder: pasteIntoCurrentFolder
                )
            }
            .accessibilityIdentifier("usb-transfer-background")
    }
}

private struct USBTransferBackgroundContextMenu: View {
    @ObservedObject var manager: USBTransferManager
    let pasteIntoCurrentFolder: () -> Void

    var body: some View {
        Button {
            manager.requestMTPNewFolder()
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        .disabled(!manager.canWriteCurrentMTPFolder)

        Button {
            pasteIntoCurrentFolder()
        } label: {
            Label("Paste", systemImage: "clipboard")
        }
        .disabled(!manager.canWriteCurrentMTPFolder)

        Button {
            manager.uploadToCurrentMTPFolder()
        } label: {
            Label("Upload Files...", systemImage: "square.and.arrow.up")
        }
        .disabled(!manager.canWriteCurrentMTPFolder)

        Divider()

        Button {
            manager.refresh()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }
}

private struct USBTransferColumnHeader: View {
    @ObservedObject var manager: USBTransferManager
    let columns: [USBTransferSort]
    let layout: USBTransferColumnLayout
    let resize: (USBTransferSort, CGFloat) -> Void
    let onResizeEnded: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                USBTransferHeaderCell(manager: manager, sort: column)
                    .frame(width: layout.width(for: column), height: 32)
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
        .frame(width: layout.totalWidth, height: 32, alignment: .leading)
        .background(.regularMaterial)
    }
}

private struct USBTransferHeaderCell: View {
    @ObservedObject var manager: USBTransferManager
    let sort: USBTransferSort

    var body: some View {
        HStack(spacing: 6) {
            Text(sort.label)
                .font(.caption.weight(.semibold))
            if let sortIndicator = manager.sortIndicator(for: sort) {
                Image(systemName: sortIndicator.ascending ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                SortPriorityBadge(priority: sortIndicator.priority)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(manager.sortIndicator(for: sort) == nil ? Color.clear : Color.accentColor.opacity(0.08))
        .contentShape(Rectangle())
        .onTapGesture {
            manager.sortBy(sort)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.16))
                .frame(width: 1)
        }
        .help("Sort by \(sort.label). Command-click to add this column to the current sort.")
    }
}

private struct USBTransferColumnRow: View {
    @ObservedObject var manager: USBTransferManager
    @ObservedObject var settings: AppSettings
    let item: USBTransferItem
    let layout: USBTransferColumnLayout
    let level: Int
    @State private var isDropTargeted = false

    private var isSelected: Bool {
        manager.selectedItemIDs.contains(item.id)
    }

    private var backgroundFill: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.28)
        }
        return isSelected ? Color.accentColor.opacity(0.20) : Color.clear
    }

    var body: some View {
        VStack(spacing: 0) {
            rowContent
            Divider()
                .padding(.leading, USBTransferColumnMetrics.dividerInset(forLevel: level))

            if item.isFolder, isExpanded {
                ForEach(children) { child in
                    USBTransferColumnRow(
                        manager: manager,
                        settings: settings,
                        item: child,
                        layout: layout,
                        level: level + 1
                    )
                }
            }
        }
        .id(item.id)
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            USBTransferNameCell(
                manager: manager,
                settings: settings,
                item: item,
                level: level,
                isExpanded: isExpanded,
                isLoadingChildren: manager.loadingTreeItemIDs.contains(item.id),
                isRenaming: manager.inlineRenameItemID == item.id
            ) {
                withAnimation(.snappy(duration: 0.16)) {
                    manager.setFolderExpanded(item, expanded: !isExpanded)
                }
            } onNameClick: {
                manager.handleNameClickForInlineRename(item)
            } onRenameCommit: { newName in
                manager.commitInlineRename(item: item, newName: newName)
            } onRenameCancel: {
                manager.cancelInlineRename()
            }
                .padding(.horizontal, 10)
                .frame(width: layout.width(for: .name), alignment: .leading)
            Text(item.kind.displayName)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(width: layout.width(for: .kind), alignment: .leading)
            Text(manager.displaySize(for: item))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, 10)
                .frame(width: layout.width(for: .size), alignment: .leading)
                .task(id: "\(item.id)|\(settings.calculateFolderSizes)") {
                    guard settings.calculateFolderSizes else { return }
                    await manager.prepareFolderSize(for: item)
                }
            Text(item.displayModified)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(width: layout.width(for: .modified), alignment: .leading)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(height: 42)
        .background(backgroundFill)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            manager.open(item: item)
        })
        .onMouseUpSelect {
            manager.selectItem(item, from: manager.visibleItemsIncludingExpandedChildren)
        }
        .dropDestination(for: URL.self) { urls, _ in
            if manager.canAcceptLocalFileDrop(onto: item) {
                return manager.acceptLocalFileDrop(urls, onto: item)
            }
            return manager.acceptLocalFileDrop(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted && manager.canAcceptLocalFileDrop(onto: item)
        }
        .contextMenu {
            USBTransferItemContextMenu(manager: manager, item: item)
        }
        .onDrag {
            manager.dragItemProvider(for: item) ?? NSItemProvider(object: item.path as NSString)
        }
        .finderFilePromiseDragSource(
            isEnabled: manager.canStartRemoteDrag(with: item),
            passthroughLeadingWidth: item.isFolder
                ? USBTransferColumnMetrics.disclosurePassthroughWidth(forLevel: level)
                : 0,
            selectForMouseDown: { modifiers in
                if !manager.selectedItemIDs.contains(item.id)
                    || modifiers.contains(.command)
                    || modifiers.contains(.shift) {
                    manager.selectItem(item, from: manager.visibleItemsIncludingExpandedChildren, modifiers: modifiers)
                }
            },
            selectForClick: { modifiers in
                manager.selectItem(item, from: manager.visibleItemsIncludingExpandedChildren, modifiers: modifiers)
            },
            renameClickTrailingX: layout.width(for: .name),
            canStartInlineRenameOnClick: { modifiers in
                !modifiers.contains(.command)
                    && !modifiers.contains(.shift)
                    && manager.selectedItemIDs == [item.id]
            },
            renameForClick: {
                manager.handleNameClickForInlineRename(item)
            },
            prepareForDrag: { modifiers in
                if !manager.selectedItemIDs.contains(item.id) {
                    manager.selectItem(item, from: manager.visibleItemsIncludingExpandedChildren, modifiers: modifiers)
                }
                return manager.filePromiseProvidersForDrag(startingWith: item)
            },
            open: {
                manager.open(item: item)
            },
            canAcceptRemoteDrop: { payload in
                manager.canAcceptRemoteDrop(payload, onto: item)
            },
            setRemoteDropTargeted: { targeted in
                isDropTargeted = targeted && item.isFolder
                if targeted, item.isFolder, !isExpanded {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(650))
                        guard isDropTargeted else { return }
                        withAnimation(.snappy(duration: 0.16)) {
                            manager.setFolderExpanded(item, expanded: true)
                        }
                    }
                }
            },
            performRemoteDrop: { payload in
                manager.moveRemoteDrop(payload, onto: item)
            }
        )
    }

    private var isExpanded: Bool {
        manager.expandedFolderItemIDs.contains(item.id)
    }

    private var children: [USBTransferItem] {
        manager.filteredTreeChildren(for: item.id)
    }

}

private struct USBTransferItemContextMenu: View {
    @ObservedObject var manager: USBTransferManager
    let item: USBTransferItem

    var body: some View {
        Button {
            manager.open(item: item)
        } label: {
            Label("Open", systemImage: item.isFolder ? "folder" : "arrow.up.right.square")
        }

        Button {
            manager.showFileInfo(item: item)
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }

        Button {
            manager.prepareSelectionForContextMenu(item)
            manager.showQuickLookPreviewForSelection()
        } label: {
            Label("Quick Look “\(item.name)”", systemImage: "eye")
        }
        .disabled(!item.canQuickLook)

        if manager.backend == .mtp, manager.canModifyMTPItem(item) {
            Divider()

            Button {
                manager.beginInlineRename(item: item)
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            if item.isFolder {
                Button {
                    manager.requestMTPNewFolder(in: item)
                } label: {
                    Label("New Folder in “\(item.name)”", systemImage: "folder.badge.plus")
                }
            }

            Button {
                manager.prepareSelectionForContextMenu(item)
                manager.copySelectedForPasteboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(!manager.canDownload(item))

            if item.isFolder {
                Button {
                    manager.pasteLocalFilesFromPasteboard(into: item)
                } label: {
                    Label("Paste Here", systemImage: "clipboard")
                }
                .disabled(!manager.canPasteLocalFilesFromPasteboard(into: item))
            }

            Divider()

            Button {
                manager.requestMTPCompress(item: item)
            } label: {
                Label("Compress...", systemImage: "doc.zipper")
            }
            .disabled(!manager.canCompressMTPItem(item))

            Button {
                manager.confirmAndExtractMTPArchive(item)
            } label: {
                Label("Uncompress", systemImage: "archivebox")
            }
            .disabled(!manager.canExtractMTPArchive(item))

            Divider()

            Button {
                manager.prepareSelectionForContextMenu(item)
                manager.downloadSelected()
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .disabled(!manager.canDownload(item))

            Button(role: .destructive) {
                manager.prepareSelectionForContextMenu(item)
                manager.deleteSelectedMTPItems()
            } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        } else if manager.canDownload(item) {
            Divider()
            Button {
                manager.prepareSelectionForContextMenu(item)
                manager.copySelectedForPasteboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                manager.prepareSelectionForContextMenu(item)
                manager.downloadSelected()
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
        }

        Divider()
        Button {
            manager.copyFilePathsToPasteboard(startingWith: item)
        } label: {
            Label("Copy File Path", systemImage: "doc.on.clipboard")
        }
    }
}

private struct USBTransferNameCell: View {
    @ObservedObject var manager: USBTransferManager
    @ObservedObject var settings: AppSettings
    let item: USBTransferItem
    let level: Int
    let isExpanded: Bool
    let isLoadingChildren: Bool
    let isRenaming: Bool
    let toggleExpansion: () -> Void
    let onNameClick: () -> Void
    let onRenameCommit: (String) -> Void
    let onRenameCancel: () -> Void
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: CGFloat(level) * USBTransferColumnMetrics.treeIndentation)
            disclosureControl
            USBTransferThumbnailView(manager: manager, settings: settings, item: item, size: 24)
            nameContent
                .layoutPriority(1)
            if isLoadingChildren {
                ProgressView()
                    .controlSize(.mini)
                    .help("Updating \(item.name)")
                    .accessibilityLabel("Updating \(item.name)")
            }
        }
        .onAppear {
            renameText = item.name
        }
        .onValueChange(of: isRenaming) { _, isRenaming in
            if isRenaming {
                renameText = item.name
            }
        }
    }

    @ViewBuilder
    private var nameContent: some View {
        if isRenaming {
            InlineRenameTextField(
                text: $renameText,
                selectedPrefixLength: InlineRenameSelection.selectedPrefixLength(for: item.name, isFolder: item.isFolder),
                onCommit: {
                    onRenameCommit(renameText)
                },
                onCancel: {
                    renameText = item.name
                    onRenameCancel()
                }
            )
            .id(item.id)
            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 24, alignment: .leading)
        } else {
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
                .onMouseUpSelect {
                    onNameClick()
                }
        }
    }

    @ViewBuilder
    private var disclosureControl: some View {
        if item.isFolder {
            Button {
                toggleExpansion()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: USBTransferColumnMetrics.disclosureWidth, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse \(item.name)" : "Expand \(item.name)")
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(item.name)")
            .accessibilityValue(isLoadingChildren ? "Loading" : (isExpanded ? "Expanded" : "Collapsed"))
        } else {
            Color.clear
                .frame(width: USBTransferColumnMetrics.disclosureWidth, height: 32)
        }
    }
}

private struct USBTransferColumnLayout {
    let columns: [USBTransferSort]
    let widths: [USBTransferSort: CGFloat]
    let totalWidth: CGFloat

    func width(for column: USBTransferSort) -> CGFloat {
        widths[column] ?? USBTransferColumnMetrics.idealWidth(for: column)
    }

    func nextColumn(after column: USBTransferSort) -> USBTransferSort? {
        guard let index = columns.firstIndex(of: column), index + 1 < columns.count else { return nil }
        return columns[index + 1]
    }
}

private enum USBTransferColumnMetrics {
    static func layout(
        for columns: [USBTransferSort],
        availableWidth: CGFloat,
        preferredWidths: [USBTransferSort: CGFloat] = [:]
    ) -> USBTransferColumnLayout {
        let idealWidths = Dictionary(uniqueKeysWithValues: columns.map { ($0, idealWidth(for: $0)) })
        let minimumWidths = Dictionary(uniqueKeysWithValues: columns.map { ($0, minimumWidth(for: $0)) })
        var widths = idealWidths
        for column in columns {
            if let preferred = preferredWidths[column] {
                widths[column] = max(minimumWidth(for: column), preferred)
            }
        }
        let idealTotal = columns.reduce(CGFloat(0)) { $0 + (widths[$1] ?? idealWidth(for: $1)) }
        let minimumTotal = columns.reduce(CGFloat(0)) { $0 + minimumWidth(for: $1) }
        let targetWidth = max(availableWidth, minimumTotal)

        if targetWidth >= idealTotal {
            let extraWidth = targetWidth - idealTotal
            let totalWeight = columns.reduce(CGFloat(0)) { $0 + expansionWeight(for: $1) }
            if totalWeight > 0 {
                for column in columns {
                    widths[column, default: idealWidth(for: column)] += extraWidth * expansionWeight(for: column) / totalWeight
                }
            }
        } else {
            let shrinkAmount = idealTotal - targetWidth
            let shrinkCapacity = columns.reduce(CGFloat(0)) {
                $0 + max(0, idealWidth(for: $1) - minimumWidth(for: $1))
            }
            if shrinkCapacity > 0 {
                for column in columns {
                    let ideal = widths[column] ?? idealWidth(for: column)
                    let minimum = minimumWidths[column] ?? ideal
                    let capacity = max(0, ideal - minimum)
                    widths[column] = max(minimum, ideal - shrinkAmount * capacity / shrinkCapacity)
                }
            }
        }

        let totalWidth = columns.reduce(CGFloat(0)) { total, column in
            total + (widths[column] ?? idealWidth(for: column))
        }
        return USBTransferColumnLayout(columns: columns, widths: widths, totalWidth: totalWidth)
    }

    static func idealWidth(for column: USBTransferSort) -> CGFloat {
        switch column {
        case .name: 460
        case .kind: 118
        case .size: 128
        case .modified: 210
        }
    }

    static func minimumWidth(for column: USBTransferSort) -> CGFloat {
        switch column {
        case .name: 260
        case .kind: 96
        case .size: 106
        case .modified: 160
        }
    }

    private static func expansionWeight(for column: USBTransferSort) -> CGFloat {
        switch column {
        case .name: 1
        case .modified: 0.35
        case .kind, .size: 0.15
        }
    }

    static let treeIndentation: CGFloat = 22
    static let disclosureWidth: CGFloat = 32
    private static let disclosurePassthroughSlop: CGFloat = 10

    static func disclosurePassthroughWidth(forLevel level: Int) -> CGFloat {
        10 + CGFloat(level) * treeIndentation + disclosureWidth + disclosurePassthroughSlop
    }

    static func dividerInset(forLevel level: Int) -> CGFloat {
        42 + CGFloat(level) * treeIndentation
    }
}
