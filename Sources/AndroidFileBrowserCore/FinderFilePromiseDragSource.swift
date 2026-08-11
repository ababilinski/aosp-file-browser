import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum RemoteBrowserDragBackend: String, Codable, Sendable {
    case adb
    case mtp
}

struct RemoteBrowserDragItem: Codable, Hashable, Sendable {
    let id: String
    let path: String
    let name: String
    let isFolder: Bool
    let size: Int64?
}

struct RemoteBrowserDragPayload: Codable, Sendable {
    static let filePromisePasteboardType = NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")
    static let internalPasteboardType = NSPasteboard.PasteboardType(
        "\(AOSPAppIdentity.bundleIdentifier).remote-browser-drag"
    )

    let backend: RemoteBrowserDragBackend
    let deviceID: String
    let items: [RemoteBrowserDragItem]
}

struct FinderFilePromiseDragItem {
    let pasteboardWriter: any NSPasteboardWriting
    let fileName: String
    let typeIdentifier: String
    let isFolder: Bool
    let remoteDragPayload: RemoteBrowserDragPayload?
    let supportsExternalCopy: Bool

    init(
        provider: NSFilePromiseProvider,
        fileName: String,
        typeIdentifier: String,
        isFolder: Bool,
        remoteDragPayload: RemoteBrowserDragPayload?
    ) {
        self.pasteboardWriter = provider
        self.fileName = fileName
        self.typeIdentifier = typeIdentifier
        self.isFolder = isFolder
        self.remoteDragPayload = remoteDragPayload
        self.supportsExternalCopy = true
    }

    static func internalOnly(
        fileName: String,
        typeIdentifier: String,
        isFolder: Bool,
        remoteDragPayload: RemoteBrowserDragPayload
    ) -> FinderFilePromiseDragItem? {
        guard let writer = RemoteBrowserDragPasteboardWriter(payload: remoteDragPayload) else {
            return nil
        }
        return FinderFilePromiseDragItem(
            pasteboardWriter: writer,
            fileName: fileName,
            typeIdentifier: typeIdentifier,
            isFolder: isFolder,
            remoteDragPayload: remoteDragPayload,
            supportsExternalCopy: false
        )
    }

    private init(
        pasteboardWriter: any NSPasteboardWriting,
        fileName: String,
        typeIdentifier: String,
        isFolder: Bool,
        remoteDragPayload: RemoteBrowserDragPayload?,
        supportsExternalCopy: Bool
    ) {
        self.pasteboardWriter = pasteboardWriter
        self.fileName = fileName
        self.typeIdentifier = typeIdentifier
        self.isFolder = isFolder
        self.remoteDragPayload = remoteDragPayload
        self.supportsExternalCopy = supportsExternalCopy
    }

    var fileExtension: String {
        (fileName as NSString).pathExtension
    }
}

private final class RemoteBrowserDragPasteboardWriter: NSObject, NSPasteboardWriting {
    private let data: Data

    init?(payload: RemoteBrowserDragPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        self.data = data
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [RemoteBrowserDragPayload.internalPasteboardType]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == RemoteBrowserDragPayload.internalPasteboardType ? data : nil
    }
}

struct FinderFilePromiseDragSource: NSViewRepresentable {
    let isEnabled: Bool
    let passthroughLeadingWidth: CGFloat
    let selectForMouseDown: (NSEvent.ModifierFlags) -> Void
    let selectForClick: (NSEvent.ModifierFlags) -> Void
    let renameClickTrailingX: CGFloat?
    let canStartInlineRenameOnClick: (NSEvent.ModifierFlags) -> Bool
    let renameForClick: () -> Void
    let prepareForDrag: (NSEvent.ModifierFlags) -> [FinderFilePromiseDragItem]
    let open: () -> Void
    let canAcceptRemoteDrop: (RemoteBrowserDragPayload) -> Bool
    let setRemoteDropTargeted: (Bool) -> Void
    let performRemoteDrop: (RemoteBrowserDragPayload) -> Void

    func makeNSView(context: Context) -> FilePromiseDragSourceView {
        FilePromiseDragSourceView()
    }

    func updateNSView(_ nsView: FilePromiseDragSourceView, context: Context) {
        nsView.configuration = FilePromiseDragSourceConfiguration(
            isEnabled: isEnabled,
            passthroughLeadingWidth: passthroughLeadingWidth,
            selectForMouseDown: selectForMouseDown,
            selectForClick: selectForClick,
            renameClickTrailingX: renameClickTrailingX,
            canStartInlineRenameOnClick: canStartInlineRenameOnClick,
            renameForClick: renameForClick,
            prepareForDrag: prepareForDrag,
            open: open,
            canAcceptRemoteDrop: canAcceptRemoteDrop,
            setRemoteDropTargeted: setRemoteDropTargeted,
            performRemoteDrop: performRemoteDrop
        )
    }
}

extension View {
    func finderFilePromiseDragSource(
        isEnabled: Bool,
        passthroughLeadingWidth: CGFloat = 0,
        selectForMouseDown: @escaping (NSEvent.ModifierFlags) -> Void = { _ in },
        selectForClick: @escaping (NSEvent.ModifierFlags) -> Void,
        renameClickTrailingX: CGFloat? = nil,
        canStartInlineRenameOnClick: @escaping (NSEvent.ModifierFlags) -> Bool = { _ in true },
        renameForClick: @escaping () -> Void = {},
        prepareForDrag: @escaping (NSEvent.ModifierFlags) -> [FinderFilePromiseDragItem],
        open: @escaping () -> Void,
        canAcceptRemoteDrop: @escaping (RemoteBrowserDragPayload) -> Bool = { _ in false },
        setRemoteDropTargeted: @escaping (Bool) -> Void = { _ in },
        performRemoteDrop: @escaping (RemoteBrowserDragPayload) -> Void = { _ in }
    ) -> some View {
        overlay {
            FinderFilePromiseDragSource(
                isEnabled: isEnabled,
                passthroughLeadingWidth: passthroughLeadingWidth,
                selectForMouseDown: selectForMouseDown,
                selectForClick: selectForClick,
                renameClickTrailingX: renameClickTrailingX,
                canStartInlineRenameOnClick: canStartInlineRenameOnClick,
                renameForClick: renameForClick,
                prepareForDrag: prepareForDrag,
                open: open,
                canAcceptRemoteDrop: canAcceptRemoteDrop,
                setRemoteDropTargeted: setRemoteDropTargeted,
                performRemoteDrop: performRemoteDrop
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

fileprivate struct FilePromiseDragSourceConfiguration {
    var isEnabled = false
    var passthroughLeadingWidth: CGFloat = 0
    var selectForMouseDown: (NSEvent.ModifierFlags) -> Void = { _ in }
    var selectForClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var renameClickTrailingX: CGFloat?
    var canStartInlineRenameOnClick: (NSEvent.ModifierFlags) -> Bool = { _ in true }
    var renameForClick: () -> Void = {}
    var prepareForDrag: (NSEvent.ModifierFlags) -> [FinderFilePromiseDragItem] = { _ in [] }
    var open: () -> Void = {}
    var canAcceptRemoteDrop: (RemoteBrowserDragPayload) -> Bool = { _ in false }
    var setRemoteDropTargeted: (Bool) -> Void = { _ in }
    var performRemoteDrop: (RemoteBrowserDragPayload) -> Void = { _ in }
}

final class FilePromiseDragSourceView: NSView, NSDraggingSource {
    fileprivate var configuration = FilePromiseDragSourceConfiguration() {
        didSet {
            registerForDraggedTypes([
                RemoteBrowserDragPayload.internalPasteboardType,
                RemoteBrowserDragPayload.filePromisePasteboardType
            ])
        }
    }

    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false
    private var inlineRenameClickWasArmed = false
    private var activeRemoteDragPayload: RemoteBrowserDragPayload?
    private var activeSupportsExternalCopy = false

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard configuration.isEnabled else { return nil }
        guard point.x >= configuration.passthroughLeadingWidth else { return nil }
        guard let event = window?.currentEvent else { return super.hitTest(point) }

        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return bounds.contains(point) ? self : nil
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard configuration.isEnabled else { return }
        mouseDownEvent = event
        didStartDrag = false
        inlineRenameClickWasArmed = configuration.canStartInlineRenameOnClick(event.modifierFlags)
        configuration.selectForMouseDown(event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        guard configuration.isEnabled, let initialEvent = mouseDownEvent, !didStartDrag else { return }
        guard dragDistance(from: initialEvent, to: event) >= 4 else { return }

        let items = configuration.prepareForDrag(event.modifierFlags)
        guard !items.isEmpty else {
            mouseDownEvent = nil
            inlineRenameClickWasArmed = false
            return
        }

        didStartDrag = true
        activeRemoteDragPayload = items.compactMap(\.remoteDragPayload).first
        activeSupportsExternalCopy = items.contains(where: \.supportsExternalCopy)
        let draggingItems = makeDraggingItems(for: items, event: initialEvent)
        let session = beginDraggingSession(with: draggingItems, event: initialEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownEvent = nil
            didStartDrag = false
            inlineRenameClickWasArmed = false
        }

        guard configuration.isEnabled, !didStartDrag else { return }
        if event.clickCount >= 2 {
            configuration.open()
        } else {
            configuration.selectForClick(event.modifierFlags)
            if inlineRenameClickWasArmed,
               let trailingX = configuration.renameClickTrailingX {
                let point = convert(event.locationInWindow, from: nil)
                if point.x <= trailingX {
                    configuration.renameForClick()
                }
            }
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        if context == .withinApplication {
            return .move
        }
        return activeSupportsExternalCopy ? .copy : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        activeRemoteDragPayload = nil
        activeSupportsExternalCopy = false
        mouseDownEvent = nil
        didStartDrag = false
        inlineRenameClickWasArmed = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = remotePayload(from: sender), configuration.canAcceptRemoteDrop(payload) else {
            return []
        }
        configuration.setRemoteDropTargeted(true)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = remotePayload(from: sender), configuration.canAcceptRemoteDrop(payload) else {
            configuration.setRemoteDropTargeted(false)
            return []
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        configuration.setRemoteDropTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        configuration.setRemoteDropTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = remotePayload(from: sender), configuration.canAcceptRemoteDrop(payload) else {
            configuration.setRemoteDropTargeted(false)
            return false
        }
        configuration.setRemoteDropTargeted(false)
        configuration.performRemoteDrop(payload)
        return true
    }

    private func makeDraggingItems(for items: [FinderFilePromiseDragItem], event: NSEvent) -> [NSDraggingItem] {
        let location = convert(event.locationInWindow, from: nil)
        let visibleCount = min(items.count, 4)

        return items.enumerated().map { index, item in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.pasteboardWriter)
            let offset = CGFloat(min(index, visibleCount - 1)) * 4
            let frame = NSRect(x: location.x - 18 + offset, y: location.y - 18 - offset, width: 36, height: 36)
            draggingItem.setDraggingFrame(frame, contents: dragImage(for: item))
            return draggingItem
        }
    }

    private func remotePayload(from sender: NSDraggingInfo) -> RemoteBrowserDragPayload? {
        for item in sender.draggingPasteboard.pasteboardItems ?? [] {
            if let data = item.data(forType: RemoteBrowserDragPayload.internalPasteboardType),
               let payload = try? JSONDecoder().decode(RemoteBrowserDragPayload.self, from: data) {
                return payload
            }
        }

        guard sender.draggingPasteboard.availableType(from: [RemoteBrowserDragPayload.filePromisePasteboardType]) != nil,
              let source = sender.draggingSource as? FilePromiseDragSourceView else { return nil }
        return source.activeRemoteDragPayload
    }

    private func dragDistance(from initialEvent: NSEvent, to event: NSEvent) -> CGFloat {
        let start = convert(initialEvent.locationInWindow, from: nil)
        let current = convert(event.locationInWindow, from: nil)
        return hypot(current.x - start.x, current.y - start.y)
    }

    private func dragImage(for item: FinderFilePromiseDragItem) -> NSImage {
        let contentType: UTType
        if item.isFolder {
            contentType = .folder
        } else if !item.fileExtension.isEmpty, let type = UTType(filenameExtension: item.fileExtension) {
            contentType = type
        } else {
            contentType = UTType(item.typeIdentifier) ?? .data
        }

        let image = (NSWorkspace.shared.icon(for: contentType).copy() as? NSImage)
            ?? NSWorkspace.shared.icon(for: UTType.data)
        image.size = NSSize(width: 32, height: 32)
        return image
    }
}
