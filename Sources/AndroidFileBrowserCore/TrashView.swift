import AppKit
import SwiftUI

struct TrashView: View {
    @ObservedObject var model: AppModel
    let onBlankSpaceDeselection: () -> Void
    @State private var selectedRecordIDs = Set<TrashRecord.ID>()
    @State private var pendingRenameRecord: TrashRecord?
    @State private var isConfirmingEmptyTrash = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let issue = model.trashPersistenceIssue {
                Label(issue, systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }

            if !model.hasReadyADBDevice {
                CompatibleContentUnavailableView(
                    "Connect a Phone to View Trash",
                    systemImage: "iphone.slash",
                    description: Text("Trash stays private and appears only while its phone is connected and selected.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.trashRecords.isEmpty {
                CompatibleContentUnavailableView(
                    "Trash Is Empty",
                    systemImage: "trash",
                    description: Text("Deleted items appear here until you restore or permanently delete them.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedRecordIDs.removeAll()
                    onBlankSpaceDeselection()
                }
            } else {
                trashTable
            }
        }
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $isConfirmingEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                emptyTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(emptyTrashConfirmationMessage)
        }
        .sheet(item: $pendingRenameRecord) { record in
            NameEntrySheet(title: "Rename", defaultValue: record.name) { name in
                Task { await model.renameTrash(record: record, to: name) }
            }
        }
        .onValueChange(of: model.trashRecords.map(\.id)) { _, recordIDs in
            selectedRecordIDs.formIntersection(recordIDs)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Trash", systemImage: "trash")
                .font(.title3.weight(.semibold))
            Spacer()
            if model.hasReadyADBDevice {
                Text("\(model.trashRecords.count) item\(model.trashRecords.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Button {
                    isConfirmingEmptyTrash = true
                } label: {
                    Label("Empty Trash", systemImage: "trash.slash")
                }
                .disabled(model.trashRecords.isEmpty || model.isBusy)
                .help("Permanently delete every item in this phone's Trash.")
            }
        }
        .padding(14)
    }

    private var trashTable: some View {
        Table(model.trashRecords, selection: $selectedRecordIDs) {
            TableColumn("Name") { record in
                HStack(spacing: 8) {
                    TrashThumbnailView(model: model, record: record)
                    Text(record.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            TableColumn("Original Path") { record in
                Text(record.originalPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TableColumn("Device") { record in
                Text(deviceName(for: record))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn("Deleted") { record in
                Text(record.deletedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            TableColumn("Size") { record in
                Text(record.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: TrashRecord.ID.self) { selection in
            let records = selectedRecords(in: selection)
            if let record = records.first {
                TrashRecordContextMenu(
                    model: model,
                    record: record,
                    selectionCount: records.count,
                    rename: { pendingRenameRecord = record },
                    emptyTrash: { isConfirmingEmptyTrash = true }
                )
            }
        } primaryAction: { selection in
            let records = selectedRecords(in: selection)
            guard records.count == 1, let record = records.first else { return }
            Task { await model.openTrash(record: record) }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                // Native Table owns its selection and clears it when the user clicks
                // below the rows. Check on the next run loop after that update lands.
                DispatchQueue.main.async {
                    if selectedRecordIDs.isEmpty {
                        onBlankSpaceDeselection()
                    }
                }
            }
        )
    }

    private var emptyTrashConfirmationMessage: String {
        let count = model.trashRecords.count
        let itemText = count == 1 ? "the item" : "all \(count) items"
        return "This permanently deletes \(itemText) from the selected phone. Trash belonging to other phones is not shown or changed. This cannot be undone."
    }

    private func selectedRecords(in selection: Set<TrashRecord.ID>) -> [TrashRecord] {
        model.trashRecords.filter { selection.contains($0.id) }
    }

    private func deviceName(for _: TrashRecord) -> String {
        model.selectedDevice?.title ?? "Selected Phone"
    }

    private func emptyTrash() {
        let selectedDeviceID = model.selectedDeviceID
        Task {
            let result = await model.emptyTrash()
            guard model.selectedDeviceID == selectedDeviceID else { return }
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
}

private struct TrashThumbnailView: View {
    @ObservedObject var model: AppModel
    let record: TrashRecord

    var body: some View {
        Image(systemName: model.trashFile(for: record).fallbackSymbol)
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
    }
}

private struct TrashRecordContextMenu: View {
    @ObservedObject var model: AppModel
    let record: TrashRecord
    let selectionCount: Int
    let rename: () -> Void
    let emptyTrash: () -> Void

    private var hasSingleSelection: Bool { selectionCount == 1 }

    var body: some View {
        Button("Open") {
            Task { await model.openTrash(record: record) }
        }
        .disabled(!hasSingleSelection)

        Menu("Open With") {
            ForEach(openWithApplications) { application in
                Button(application.name) {
                    Task { await model.openTrash(record: record, with: application.url) }
                }
            }
            if openWithApplications.isEmpty {
                Text("No Suggested Applications")
            }
            Divider()
            Button("Other…") {
                model.chooseApplicationAndOpenTrash(record: record)
            }
        }
        .disabled(!hasSingleSelection || model.trashFile(for: record).kind != .file)

        Divider()

        Button("Put Back") {
            Task { await model.restoreTrash(record: record) }
        }
        .disabled(!hasSingleSelection || model.isBusy)
        Button("Delete Permanently", role: .destructive) {
            Task { await model.permanentlyDeleteTrash(record: record) }
        }
        .disabled(!hasSingleSelection || model.isBusy)
        Button("Empty Trash", role: .destructive) {
            emptyTrash()
        }
        .disabled(model.isBusy)

        Divider()

        Button("Get Info") {
            model.showTrashInfo(record: record)
        }
        .disabled(!hasSingleSelection)
        Button("Rename") {
            rename()
        }
        .disabled(!hasSingleSelection || model.isBusy)
        Button("Quick Look “\(record.name)”") {
            model.quickLookTrash(record: record)
        }
        .disabled(!hasSingleSelection)

        Divider()

        Button("Copy") {
            Task { await model.copyTrash(record: record) }
        }
        .disabled(!hasSingleSelection)
    }

    private var openWithApplications: [TrashOpenWithApplication] {
        let lookupURL = URL(fileURLWithPath: "/\(record.name)")
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: lookupURL)
            .compactMap { url -> TrashOpenWithApplication? in
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { return nil }
                let bundle = Bundle(url: url)
                let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                return TrashOpenWithApplication(name: name, url: url)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct TrashOpenWithApplication: Identifiable {
    var id: String { url.standardizedFileURL.path }
    let name: String
    let url: URL
}
