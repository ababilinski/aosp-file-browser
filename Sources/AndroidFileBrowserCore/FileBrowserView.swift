import SwiftUI

struct FileBrowserView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    let onBlankSpaceDeselection: () -> Void
    @State private var dropTargeted = false

    init(model: AppModel, onBlankSpaceDeselection: @escaping () -> Void) {
        self.model = model
        self.settings = model.settings
        self.onBlankSpaceDeselection = onBlankSpaceDeselection
    }

    var body: some View {
        VStack(spacing: 0) {
            PathBar(model: model, path: model.breadcrumbPath)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            ZStack {
                switch model.browserLayout {
                case .list:
                    FileList(model: model, onBlankSpaceDeselection: onBlankSpaceDeselection)
                case .icons:
                    FileIconGrid(model: model, onBlankSpaceDeselection: onBlankSpaceDeselection)
                }

                if dropTargeted {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [9, 7]))
                        .padding(18)
                        .allowsHitTesting(false)
                }

                if model.isLoadingCurrentFolder, model.files.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading \(loadingFolderTitle)…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                }
            }
            .localFileDropTarget { targeted in
                dropTargeted = targeted
            } onDrop: { urls in
                Task { await model.upload(urls: urls) }
            }

            if settings.showPathBar {
                Divider()
                BrowserPathStatusBar(path: model.pathBarPath, showsFolder: model.pathBarShowsFolder)
            }
        }
    }

    private var loadingFolderTitle: String {
        let title = (model.currentPath as NSString).lastPathComponent
        return title.isEmpty ? "folder" : title
    }
}

private struct PathBar: View {
    @ObservedObject var model: AppModel
    let path: String

    var body: some View {
        LiquidGlassContainer(spacing: 8) {
            VStack(spacing: 8) {
                pathControls

                if model.shouldShowSearchOptions {
                    FinderSearchOptionsBar(
                        snapshot: FinderSearchOptionsSnapshot(model: model),
                        searchScope: $model.searchScope,
                        kindFilter: $model.searchKindFilter,
                        dateFilter: $model.searchDateFilter,
                        clearKindFilter: model.clearSearchKindFilter
                    )
                    .equatable()
                }
            }
        }
    }

    private var pathControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if let appFolderContext = model.appFolderContext {
                        appFolderBreadcrumb(appFolderContext)
                    }

                    ForEach(segments) { segment in
                        Button {
                            if !isTerminalSelectedPath(segment.path) {
                                model.navigate(to: segment.path)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(segment.title)
                                    .font(.callout)
                                    .lineLimit(1)
                                if segment.path == path, model.isLoadingCurrentFolder, !model.files.isEmpty {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .accessibilityLabel("Updating \(segment.title)")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(segment.path == path ? .primary : .secondary)
                        .help(segment.path)
                        .contextMenu {
                            Button {
                                model.copyPathToPasteboard(segment.path)
                            } label: {
                                Label("Copy Path", systemImage: "doc.on.clipboard")
                            }
                        }

                        if segment.id != segments.last?.id {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Spacer(minLength: 12)

            InlineSearchField(text: $model.searchText, prompt: "Search", kindFilter: $model.searchKindFilter)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func isTerminalSelectedPath(_ segmentPath: String) -> Bool {
        segmentPath == path
    }

    @ViewBuilder
    private func appFolderBreadcrumb(_ context: AppFolderContext) -> some View {
        Button {
            model.open(destination: .apps)
        } label: {
            Label("Apps", systemImage: "app.dashed")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Back to Apps")

        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)

        Text(context.displayName)
            .font(.callout)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .help(context.packageName)

        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)

        Text(context.locationTitle)
            .font(.callout)
            .lineLimit(1)
            .foregroundStyle(.secondary)

        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private var segments: [PathSegment] {
        let components = path.split(separator: "/").map(String.init)
        var built = ""
        return components.enumerated().map { index, component in
            built += "/\(component)"
            let title = index == 0 ? "/\(component)" : component
            return PathSegment(id: built, title: title, path: built)
        }
    }
}

private struct PathSegment: Identifiable {
    let id: String
    let title: String
    let path: String
}

struct FinderSearchOptionsSnapshot: Equatable {
    let searchScope: FileSearchScope
    let kindFilter: FileSearchKindFilter
    let effectiveKindFilter: FileSearchKindFilter
    let typedKindFilter: FileSearchKindFilter?
    let dateFilter: FileSearchDateFilter
    let isSearchingFullDevice: Bool
    let hasSearchFiltersApplied: Bool

    @MainActor
    init(model: AppModel) {
        searchScope = model.searchScope
        kindFilter = model.searchKindFilter
        effectiveKindFilter = model.effectiveSearchKindFilter
        typedKindFilter = model.parsedSearchQuery.kindFilter
        dateFilter = model.searchDateFilter
        isSearchingFullDevice = model.isSearchingFullDevice
        hasSearchFiltersApplied = model.hasSearchFiltersApplied
    }
}

private struct FinderSearchOptionsBar: View, Equatable {
    nonisolated let snapshot: FinderSearchOptionsSnapshot
    @Binding var searchScope: FileSearchScope
    @Binding var kindFilter: FileSearchKindFilter
    @Binding var dateFilter: FileSearchDateFilter
    let clearKindFilter: () -> Void
    @State private var showsFilterRows = false

    private var shouldShowFilterRows: Bool {
        showsFilterRows || snapshot.hasSearchFiltersApplied
    }

    nonisolated static func == (lhs: FinderSearchOptionsBar, rhs: FinderSearchOptionsBar) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Search:")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)

                Picker(selection: $searchScope) {
                    ForEach(FileSearchScope.allCases) { scope in
                        Text(scope.label)
                            .lineLimit(1)
                            .tag(scope)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                .accessibilityLabel("Search Scope")
                .help("Search Scope: search only the current folder or search shared storage across the phone.")

                Spacer()

                if snapshot.isSearchingFullDevice {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
                    kindFilter: $kindFilter,
                    effectiveKindFilter: snapshot.effectiveKindFilter,
                    typedKindFilter: snapshot.typedKindFilter,
                    dateFilter: $dateFilter,
                    clearKindFilter: clearKindFilter
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct FileList: View {
    @ObservedObject var model: AppModel
    let onBlankSpaceDeselection: () -> Void

    var body: some View {
        FileColumnBrowser(model: model, density: .compact, onBlankSpaceDeselection: onBlankSpaceDeselection)
    }
}

private enum FileRowDensity {
    case compact
    case comfortable

    var rowHeight: CGFloat {
        switch self {
        case .compact: 34
        case .comfortable: 42
        }
    }

    var thumbnailSize: CGFloat {
        switch self {
        case .compact: 22
        case .comfortable: 26
        }
    }
}

private struct FileColumnBrowser: View {
    @ObservedObject var model: AppModel
    let density: FileRowDensity
    let onBlankSpaceDeselection: () -> Void
    @State private var columnWidths: [FileColumn: CGFloat] = [:]
    @State private var resizeStartWidths: [FileColumn: CGFloat]?
    @State private var scrollPositionID: AndroidFile.ID?
    @State private var scrollPositionsByPath: [String: AndroidFile.ID] = [:]

    private var visibleColumns: [FileColumn] {
        let columns = FileColumn.allCases.filter { model.visibleFileColumns.contains($0) }
        return columns.isEmpty ? [.name] : columns
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = FileColumnMetrics.layout(
                for: visibleColumns,
                availableWidth: proxy.size.width,
                preferredWidths: columnWidths
            )

            VStack(spacing: 0) {
                FileColumnHeader(
                    model: model,
                    columns: visibleColumns,
                    layout: layout
                ) { column, translation in
                    resizeColumn(column, translation: translation, layout: layout)
                } onResizeEnded: {
                    resizeStartWidths = nil
                }
                Divider()
                ZStack {
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            FileBrowserBackgroundSurface(model: model, onBlankSpaceDeselection: onBlankSpaceDeselection)
                                .frame(width: layout.totalWidth)
                                .frame(minHeight: max(proxy.size.height - 33, 0))

                            LazyVStack(spacing: 0) {
                                ForEach(model.visibleFiles) { file in
                                    FileColumnRow(
                                        model: model,
                                        file: file,
                                        columns: visibleColumns,
                                        layout: layout,
                                        density: density,
                                        level: 0
                                    )
                                    .compatibleScrollTarget(id: file.id, in: "adb-file-column-scroll")
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
                        coordinateSpace: "adb-file-column-scroll"
                    )
                    .onValueChange(of: model.currentPath) { oldPath, newPath in
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
            .frame(width: proxy.size.width, alignment: .leading)
        }
    }

    private func resizeColumn(_ column: FileColumn, translation: CGFloat, layout: FileColumnLayout) {
        guard let nextColumn = layout.nextColumn(after: column) else { return }
        let start: [FileColumn: CGFloat]
        if let resizeStartWidths {
            start = resizeStartWidths
        } else {
            start = layout.widths
            resizeStartWidths = start
            columnWidths = start
        }

        let currentStart = start[column] ?? layout.width(for: column)
        let nextStart = start[nextColumn] ?? layout.width(for: nextColumn)
        let currentMinimum = FileColumnMetrics.minimumWidth(for: column)
        let nextMinimum = FileColumnMetrics.minimumWidth(for: nextColumn)
        let clampedTranslation = min(max(translation, currentMinimum - currentStart), nextStart - nextMinimum)
        columnWidths[column] = currentStart + clampedTranslation
        columnWidths[nextColumn] = nextStart - clampedTranslation
    }
}

private struct FileColumnHeader: View {
    @ObservedObject var model: AppModel
    let columns: [FileColumn]
    let layout: FileColumnLayout
    let resize: (FileColumn, CGFloat) -> Void
    let onResizeEnded: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                FileColumnHeaderCell(model: model, column: column)
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
        .contextMenu {
            ColumnVisibilityMenu(model: model)
        }
    }
}

private struct FileColumnHeaderCell: View {
    @ObservedObject var model: AppModel
    let column: FileColumn

    var body: some View {
        HStack(spacing: 6) {
            Text(column.label)
                .font(.caption.weight(.semibold))
            if let sortIndicator = model.fileSortIndicator(for: column) {
                Image(systemName: sortIndicator.ascending ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                SortPriorityBadge(priority: sortIndicator.priority)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(model.fileSortIndicator(for: column) == nil ? Color.clear : Color.accentColor.opacity(0.08))
        .contentShape(Rectangle())
        .onTapGesture {
            model.sortBy(column: column)
        }
        .contextMenu {
            ColumnVisibilityMenu(model: model)
        }
        .help("Sort by \(column.label). Command-click to add this column to the current sort. Right-click to show or hide columns.")
    }
}

private struct ColumnVisibilityMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ForEach(FileColumn.allCases) { column in
            Button {
                model.toggleColumn(column)
            } label: {
                if model.visibleFileColumns.contains(column) {
                    Label(column.label, systemImage: "checkmark")
                } else {
                    Text(column.label)
                }
            }
            .disabled(!column.isHideable)
        }
    }
}

private struct FileColumnRow: View {
    @ObservedObject var model: AppModel
    let file: AndroidFile
    let columns: [FileColumn]
    let layout: FileColumnLayout
    let density: FileRowDensity
    let level: Int
    @State private var isDropTargeted = false

    private var isSelected: Bool {
        model.selectedFileIDs.contains(file.id)
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
                .padding(.leading, FileColumnMetrics.dividerInset(forLevel: level))

            if file.isDirectory, isExpanded {
                ForEach(children) { child in
                    FileColumnRow(
                        model: model,
                        file: child,
                        columns: columns,
                        layout: layout,
                        density: density,
                        level: level + 1
                    )
                }
            }
        }
        .id(file.id)
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                FileColumnCell(
                    model: model,
                    file: file,
                    column: column,
                    columnWidth: layout.width(for: column),
                    density: density,
                    level: level,
                    isExpanded: isExpanded,
                    isLoadingChildren: model.loadingTreePaths.contains(file.path)
                ) {
                    withAnimation(.snappy(duration: 0.16)) {
                        model.setTreeExpanded(file, expanded: !isExpanded)
                    }
                }
                    .frame(width: layout.width(for: column), alignment: .leading)
            }
        }
        .frame(height: density.rowHeight)
        .background(backgroundFill)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.open(file: file)
        })
        .onMouseUpSelect {
            model.selectFile(file, from: model.visibleFilesIncludingExpandedChildren)
        }
        .dropDestination(for: URL.self) { urls, _ in
            if file.kind == .directory {
                Task { await model.upload(urls: urls, into: file) }
            } else {
                Task { await model.upload(urls: urls) }
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted && file.kind == .directory
        }
        .contextMenu { FileContextMenu(model: model, file: file) }
        .onDrag {
            model.dragItemProvider(for: file) ?? NSItemProvider(object: file.path as NSString)
        }
        .finderFilePromiseDragSource(
            isEnabled: file.kind == .file || file.kind == .directory,
            passthroughLeadingWidth: file.isDirectory ? FileColumnMetrics.disclosurePassthroughWidth(forLevel: level) : 0,
            selectForMouseDown: { modifiers in
                if !model.selectedFileIDs.contains(file.id)
                    || modifiers.contains(.command)
                    || modifiers.contains(.shift) {
                    model.selectFile(file, from: model.visibleFilesIncludingExpandedChildren, modifiers: modifiers)
                }
            },
            selectForClick: { modifiers in
                model.selectFile(file, from: model.visibleFilesIncludingExpandedChildren, modifiers: modifiers)
            },
            renameClickTrailingX: layout.width(for: .name),
            canStartInlineRenameOnClick: { modifiers in
                !modifiers.contains(.command)
                    && !modifiers.contains(.shift)
                    && model.selectedFileIDs == [file.id]
            },
            renameForClick: {
                model.handleNameClickForInlineRename(file)
            },
            prepareForDrag: { modifiers in
                if !model.selectedFileIDs.contains(file.id) {
                    model.selectFile(file, from: model.visibleFilesIncludingExpandedChildren, modifiers: modifiers)
                }
                return model.filePromiseProvidersForDrag(startingWith: file)
            },
            open: {
                model.open(file: file)
            },
            canAcceptRemoteDrop: { payload in
                model.canAcceptRemoteDrop(payload, into: file)
            },
            setRemoteDropTargeted: { targeted in
                isDropTargeted = targeted && file.kind == .directory
                if targeted, file.kind == .directory, !isExpanded {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(650))
                        guard isDropTargeted else { return }
                        withAnimation(.snappy(duration: 0.16)) {
                            model.setTreeExpanded(file, expanded: true)
                        }
                    }
                }
            },
            performRemoteDrop: { payload in
                model.moveRemoteDrop(payload, into: file)
            }
        )
    }

    private var isExpanded: Bool {
        model.expandedTreePaths.contains(file.path)
    }

    private var children: [AndroidFile] {
        model.filteredTreeChildren(for: file.path)
    }

}

private struct FileColumnCell: View {
    @ObservedObject var model: AppModel
    let file: AndroidFile
    let column: FileColumn
    let columnWidth: CGFloat
    let density: FileRowDensity
    let level: Int
    let isExpanded: Bool
    let isLoadingChildren: Bool
    let toggleExpansion: () -> Void

    var body: some View {
        Group {
            switch column {
            case .name:
                FileNameCell(
                    model: model,
                    file: file,
                    thumbnailSize: density.thumbnailSize,
                    level: level,
                    isExpanded: isExpanded,
                    isLoadingChildren: isLoadingChildren,
                    isRenaming: model.inlineRenameFileID == file.id,
                    toggleExpansion: toggleExpansion,
                    onNameClick: {
                        model.handleNameClickForInlineRename(file)
                    },
                    onRenameCommit: { newName in
                        model.commitInlineRename(file: file, newName: newName)
                    },
                    onRenameCancel: {
                        model.cancelInlineRename()
                    }
                )
            case .kind:
                Text(adaptiveKindString(for: file, width: columnWidth))
                    .foregroundStyle(.secondary)
            case .size:
                Text(model.displaySize(for: file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case .modified:
                Text(adaptiveFileDateString(file.modified, width: columnWidth))
                    .foregroundStyle(.secondary)
            case .created:
                Text(adaptiveFileDateString(file.created, width: columnWidth))
                    .foregroundStyle(.secondary)
            case .permissions:
                Text(file.permissions ?? "—")
                    .foregroundStyle(.secondary)
                    .font(.caption.monospaced())
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 10)
    }
}

private struct FileColumnLayout {
    let columns: [FileColumn]
    let widths: [FileColumn: CGFloat]
    let totalWidth: CGFloat

    func width(for column: FileColumn) -> CGFloat {
        widths[column] ?? FileColumnMetrics.idealWidth(for: column)
    }

    func nextColumn(after column: FileColumn) -> FileColumn? {
        guard let index = columns.firstIndex(of: column),
              index < columns.index(before: columns.endIndex) else {
            return nil
        }
        return columns[columns.index(after: index)]
    }
}

private enum FileColumnMetrics {
    static func layout(
        for columns: [FileColumn],
        availableWidth: CGFloat,
        preferredWidths: [FileColumn: CGFloat]
    ) -> FileColumnLayout {
        let columns = columns.isEmpty ? [.name] : columns
        var widths = Dictionary(uniqueKeysWithValues: columns.map { column in
            (column, preferredWidths[column] ?? idealWidth(for: column))
        })
        let targetWidth = max(1, availableWidth)
        let currentTotal = columns.reduce(CGFloat(0)) { $0 + (widths[$1] ?? idealWidth(for: $1)) }

        if currentTotal < targetWidth {
            let extraWidth = targetWidth - currentTotal
            let totalWeight = columns.reduce(CGFloat(0)) { $0 + expansionWeight(for: $1) }
            for column in columns where totalWeight > 0 {
                widths[column, default: idealWidth(for: column)] += extraWidth * expansionWeight(for: column) / totalWeight
            }
        } else if currentTotal > targetWidth {
            let shrinkAmount = currentTotal - targetWidth
            let shrinkCapacity = columns.reduce(CGFloat(0)) {
                $0 + max(0, (widths[$1] ?? idealWidth(for: $1)) - minimumWidth(for: $1))
            }
            if shrinkCapacity > 0 {
                for column in columns {
                    let width = widths[column] ?? idealWidth(for: column)
                    let capacity = max(0, width - minimumWidth(for: column))
                    widths[column] = max(minimumWidth(for: column), width - shrinkAmount * capacity / shrinkCapacity)
                }
            } else {
                let scale = targetWidth / max(1, currentTotal)
                for column in columns {
                    widths[column, default: idealWidth(for: column)] *= scale
                }
            }
        }

        let totalWidth = columns.reduce(CGFloat(0)) { total, column in
            total + (widths[column] ?? idealWidth(for: column))
        }
        return FileColumnLayout(columns: columns, widths: widths, totalWidth: totalWidth)
    }

    static func idealWidth(for column: FileColumn) -> CGFloat {
        switch column {
        case .name: 460
        case .kind: 108
        case .size: 118
        case .modified: 190
        case .created: 190
        case .permissions: 140
        }
    }

    static func minimumWidth(for column: FileColumn) -> CGFloat {
        switch column {
        case .name: 160
        case .kind: 54
        case .size: 72
        case .modified: 84
        case .created: 84
        case .permissions: 72
        }
    }

    private static func expansionWeight(for column: FileColumn) -> CGFloat {
        switch column {
        case .name: 1
        case .modified, .created: 0.35
        case .kind, .size, .permissions: 0.15
        }
    }

    static let treeIndentation: CGFloat = 22
    // The glyph stays small, but the full 32-point slot is clickable and is also
    // excluded from the Finder drag overlay in FileColumnRow.
    static let disclosureWidth: CGFloat = 32
    private static let disclosurePassthroughSlop: CGFloat = 12

    static func disclosurePassthroughWidth(forLevel level: Int) -> CGFloat {
        10 + CGFloat(level) * treeIndentation + disclosureWidth + disclosurePassthroughSlop
    }

    static func dividerInset(forLevel level: Int) -> CGFloat {
        42 + CGFloat(level) * treeIndentation
    }
}

private func adaptiveFileDateString(_ date: Date?, width: CGFloat) -> String {
    guard let date else { return "—" }
    if width < 100 {
        return fileShortDateFormatter.string(from: date)
    }
    if width < 160 {
        return fileNumericDateTimeFormatter.string(from: date)
    }
    return fileFullDateTimeFormatter.string(from: date)
}

private func adaptiveKindString(for file: AndroidFile, width: CGFloat) -> String {
    if file.isDirectory { return "Folder" }
    if file.kind != .file { return file.kind.displayName }

    let ext = file.fileExtension.uppercased()
    let base = ext.isEmpty ? "File" : ext
    if width < 66 {
        return base
    }

    if let mediaKind = file.mediaKind {
        switch mediaKind {
        case .image:
            return ext.isEmpty ? "Image" : "\(base) image"
        case .video:
            return ext.isEmpty ? "Movie" : "\(base) movie"
        }
    }

    switch file.fileExtension.lowercased() {
    case "pdf":
        return width < 92 ? "PDF" : "PDF document"
    case "zip", "rar", "7z", "tar", "gz", "tgz":
        return width < 100 ? base : "\(base) archive"
    case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "amr":
        return width < 92 ? base : "\(base) audio"
    case "txt", "md", "rtf", "log":
        return width < 92 ? base : "\(base) text"
    case "apk", "apks", "aab":
        return width < 100 ? base : "Android app"
    default:
        return width < 88 ? base : "\(base) file"
    }
}

private let fileFullDateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .short
    return formatter
}()

private let fileNumericDateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
}()

private let fileShortDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter
}()

private struct FileIconGrid: View {
    @ObservedObject var model: AppModel
    let onBlankSpaceDeselection: () -> Void
    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 16)]
    @State private var scrollPositionID: AndroidFile.ID?
    @State private var scrollPositionsByPath: [String: AndroidFile.ID] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                FileIconSortMenu(model: model)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            GeometryReader { proxy in
                ScrollView {
                    ZStack(alignment: .top) {
                        FileBrowserBackgroundSurface(model: model, onBlankSpaceDeselection: onBlankSpaceDeselection)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: proxy.size.height)

                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(model.visibleFiles) { file in
                                FileIconGridItem(model: model, file: file)
                                    .compatibleScrollTarget(id: file.id, in: "adb-file-icon-scroll")
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
                    coordinateSpace: "adb-file-icon-scroll"
                )
                .onValueChange(of: model.currentPath) { oldPath, newPath in
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
    }
}

private struct FileBrowserBackgroundSurface: View {
    @ObservedObject var model: AppModel
    let onBlankSpaceDeselection: () -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                model.clearFileBrowserSelection()
                onBlankSpaceDeselection()
            }
            .contextMenu {
                FileBrowserBackgroundContextMenu(model: model)
            }
            .accessibilityIdentifier("file-browser-background")
    }
}

private struct FileBrowserBackgroundContextMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button {
            model.requestNewFolder()
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }

        Button {
            Task { await model.pasteFromPasteboardOrClipboard() }
        } label: {
            Label("Paste", systemImage: "clipboard")
        }

        Button {
            model.beginUpload()
        } label: {
            Label("Upload Files...", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button {
            Task { await model.refreshCurrentSurfaceSafely() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }
}

private struct FileIconSortMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(FileColumn.allCases) { column in
                Button {
                    model.sortBy(column: column)
                } label: {
                    if let indicator = model.fileSortIndicator(for: column) {
                        Label("\(column.label) \(indicator.ascending ? "Ascending" : "Descending")", systemImage: "checkmark")
                    } else {
                        Text(column.label)
                    }
                }
            }
        } label: {
            Label("Sort: \(model.sort.label)", systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon)
        }
        .help("Sort icon view contents")
    }
}

private struct FileIconGridItem: View {
    @ObservedObject var model: AppModel
    let file: AndroidFile
    @State private var isDropTargeted = false
    @State private var renameText = ""

    private var backgroundFill: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.28)
        }
        return model.selectedFileIDs.contains(file.id) ? Color.accentColor.opacity(0.16) : Color.clear
    }

    var body: some View {
        VStack(spacing: 10) {
            MediaThumbnailView(model: model, file: file, size: 54)
            iconNameContent
                .frame(height: 34, alignment: .top)
        }
        .frame(width: 120, height: 116)
        .padding(8)
        .background(backgroundFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.open(file: file)
        })
        .onMouseUpSelect {
            model.selectFile(file)
        }
        .dropDestination(for: URL.self) { urls, _ in
            if file.kind == .directory {
                Task { await model.upload(urls: urls, into: file) }
            } else {
                Task { await model.upload(urls: urls) }
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted && file.kind == .directory
        }
        .contextMenu { FileContextMenu(model: model, file: file) }
        .onDrag {
            model.dragItemProvider(for: file) ?? NSItemProvider(object: file.path as NSString)
        }
        .finderFilePromiseDragSource(
            isEnabled: file.kind == .file || file.kind == .directory,
            selectForMouseDown: { modifiers in
                if !model.selectedFileIDs.contains(file.id)
                    || modifiers.contains(.command)
                    || modifiers.contains(.shift) {
                    model.selectFile(file, modifiers: modifiers)
                }
            },
            selectForClick: { modifiers in
                model.selectFile(file, modifiers: modifiers)
            },
            renameClickTrailingX: .greatestFiniteMagnitude,
            canStartInlineRenameOnClick: { modifiers in
                !modifiers.contains(.command)
                    && !modifiers.contains(.shift)
                    && model.selectedFileIDs == [file.id]
            },
            renameForClick: {
                model.handleNameClickForInlineRename(file)
            },
            prepareForDrag: { modifiers in
                if !model.selectedFileIDs.contains(file.id) {
                    model.selectFile(file, modifiers: modifiers)
                }
                return model.filePromiseProvidersForDrag(startingWith: file)
            },
            open: {
                model.open(file: file)
            },
            canAcceptRemoteDrop: { payload in
                model.canAcceptRemoteDrop(payload, into: file)
            },
            setRemoteDropTargeted: { targeted in
                isDropTargeted = targeted && file.kind == .directory
            },
            performRemoteDrop: { payload in
                model.moveRemoteDrop(payload, into: file)
            }
        )
        .onAppear {
            renameText = file.name
        }
        .onValueChange(of: model.inlineRenameFileID == file.id) { _, isRenaming in
            if isRenaming {
                renameText = file.name
            }
        }
    }

    @ViewBuilder
    private var iconNameContent: some View {
        if model.inlineRenameFileID == file.id {
            InlineRenameTextField(
                text: $renameText,
                selectedPrefixLength: InlineRenameSelection.selectedPrefixLength(for: file.name, isFolder: file.isDirectory),
                onCommit: {
                    model.commitInlineRename(file: file, newName: renameText)
                },
                onCancel: {
                    renameText = file.name
                    model.cancelInlineRename()
                }
            )
            .id(file.id)
            .font(.caption)
        } else {
            Text(file.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .contentShape(Rectangle())
                .onMouseUpSelect {
                    model.handleNameClickForInlineRename(file)
                }
        }
    }
}

struct FileNameCell: View {
    @ObservedObject var model: AppModel
    let file: AndroidFile
    var thumbnailSize: CGFloat = 24
    var level: Int = 0
    var isExpanded = false
    var isLoadingChildren = false
    var isRenaming = false
    var toggleExpansion: (() -> Void)?
    var onNameClick: (() -> Void)?
    var onRenameCommit: ((String) -> Void)?
    var onRenameCancel: (() -> Void)?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: CGFloat(level) * FileColumnMetrics.treeIndentation)
            disclosureControl
            MediaThumbnailView(model: model, file: file, size: thumbnailSize)
            nameContent
                .layoutPriority(1)
            if isLoadingChildren {
                ProgressView()
                    .controlSize(.mini)
                    .help("Updating \(file.name)")
                    .accessibilityLabel("Updating \(file.name)")
            }
        }
        .onAppear {
            renameText = file.name
        }
        .onValueChange(of: isRenaming) { _, isRenaming in
            if isRenaming {
                renameText = file.name
            }
        }
    }

    @ViewBuilder
    private var nameContent: some View {
        if isRenaming {
            InlineRenameTextField(
                text: $renameText,
                selectedPrefixLength: InlineRenameSelection.selectedPrefixLength(for: file.name, isFolder: file.isDirectory),
                onCommit: {
                    onRenameCommit?(renameText)
                },
                onCancel: {
                    renameText = file.name
                    onRenameCancel?()
                }
            )
            .id(file.id)
            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 24, alignment: .leading)
        } else {
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
                .onMouseUpSelect {
                    onNameClick?()
                }
        }
    }

    @ViewBuilder
    private var disclosureControl: some View {
        if file.isDirectory {
            Button {
                toggleExpansion?()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                .frame(width: FileColumnMetrics.disclosureWidth, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse \(file.name)" : "Expand \(file.name)")
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(file.name)")
            .accessibilityValue(isLoadingChildren ? "Loading" : (isExpanded ? "Expanded" : "Collapsed"))
        } else {
            Color.clear
                .frame(width: FileColumnMetrics.disclosureWidth, height: 32)
        }
    }
}

private struct FileContextMenu: View {
    @ObservedObject var model: AppModel
    let file: AndroidFile

    var body: some View {
        Button {
            model.open(file: file)
        } label: {
            Label("Open", systemImage: file.isDirectory ? "folder" : "arrow.up.right.square")
        }
        Button {
            model.showFileInfo(file: file)
        } label: {
            Label("Get Info", systemImage: "info.circle")
        }
        Button {
            Task { await model.preview(file: file) }
        } label: {
            Label("Quick Look “\(file.name)”", systemImage: "eye")
        }
        .disabled(file.kind != .file)
        Divider()
        Button {
            model.pendingRename = file
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            model.requestBatchRenameSelected()
        } label: {
            Label("Batch Rename", systemImage: "textformat")
        }
        .disabled(model.selectedFiles.count < 2)
        if file.kind == .directory {
            Button {
                model.requestNewFolder(in: file)
            } label: {
                Label("New Folder in “\(file.name)”", systemImage: "folder.badge.plus")
            }
        }
        Button {
            model.prepareFileSelectionForContextMenu(file)
            model.copySelected()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Button {
            model.prepareFileSelectionForContextMenu(file)
            model.cutSelected()
        } label: {
            Label("Cut", systemImage: "scissors")
        }
        if file.isDirectory {
            Button {
                Task { await model.pasteFromPasteboardOrClipboard(into: file) }
            } label: {
                Label("Paste Here", systemImage: "clipboard")
            }
        }
        Divider()
        Button {
            model.requestCompress(file: file)
        } label: {
            Label("Compress...", systemImage: "doc.zipper")
        }
        .disabled(!file.canCompress)
        Button {
            model.confirmAndExtractArchive(file)
        } label: {
            Label("Uncompress", systemImage: "archivebox")
        }
        .disabled(!file.isExtractableArchive)
        Divider()
        Button {
            model.prepareFileSelectionForContextMenu(file)
            Task { await model.downloadSelected() }
        } label: {
            Label("Download", systemImage: "square.and.arrow.down")
        }
        Button(role: .destructive) {
            model.prepareFileSelectionForContextMenu(file)
            Task { await model.deleteSelectedToTrash() }
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
        Divider()
        Button {
            model.prepareFileSelectionForContextMenu(file)
            model.copySelectedRemotePathsToPasteboard()
        } label: {
            Label("Copy File Path", systemImage: "doc.on.clipboard")
        }
    }
}
