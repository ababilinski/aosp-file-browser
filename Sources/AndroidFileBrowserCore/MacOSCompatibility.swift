import AppKit
import SwiftUI

struct CompatibleContentUnavailableView<
    LabelContent: View,
    DescriptionContent: View,
    ActionsContent: View
>: View {
    private let labelContent: LabelContent
    private let descriptionContent: DescriptionContent
    private let actionsContent: ActionsContent

    init(
        @ViewBuilder label: () -> LabelContent,
        @ViewBuilder description: () -> DescriptionContent,
        @ViewBuilder actions: () -> ActionsContent
    ) {
        self.labelContent = label()
        self.descriptionContent = description()
        self.actionsContent = actions()
    }

    init(
        @ViewBuilder label: () -> LabelContent,
        @ViewBuilder description: () -> DescriptionContent
    ) where ActionsContent == EmptyView {
        self.init(label: label, description: description, actions: { EmptyView() })
    }

    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        description: Text
    ) where
        LabelContent == Label<Text, Image>,
        DescriptionContent == Text,
        ActionsContent == EmptyView
    {
        self.init(
            label: { Label(title, systemImage: systemImage) },
            description: { description },
            actions: { EmptyView() }
        )
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 14, *) {
            ContentUnavailableView {
                labelContent
            } description: {
                descriptionContent
            } actions: {
                actionsContent
            }
        } else {
            VStack(spacing: 14) {
                labelContent
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                descriptionContent
                    .font(.callout)
                    .foregroundStyle(.secondary)
                actionsContent
            }
            .multilineTextAlignment(.center)
            .padding(24)
        }
    }
}

extension View {
    @ViewBuilder
    public func onValueChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (_ oldValue: Value, _ newValue: Value) -> Void
    ) -> some View {
        if #available(macOS 14, *) {
            onChange(of: value, initial: false, action)
        } else {
            modifier(LegacyValueChangeModifier(value: value, action: action))
        }
    }
}

@available(macOS, introduced: 10.15, obsoleted: 14)
private struct LegacyValueChangeModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value, Value) -> Void
    @State private var previousValue: Value

    init(value: Value, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.action = action
        _previousValue = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content.onChange(of: value) { newValue in
            let oldValue = previousValue
            previousValue = newValue
            action(oldValue, newValue)
        }
    }
}

private struct CompatibleScrollTargetOffsetsKey<ID: Hashable>: PreferenceKey {
    static var defaultValue: [ID: CGFloat] { [:] }

    static func reduce(value: inout [ID: CGFloat], nextValue: () -> [ID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

extension View {
    @ViewBuilder
    func compatibleScrollTarget<ID: Hashable>(id: ID, in coordinateSpace: String) -> some View {
        if #available(macOS 14, *) {
            self.id(id)
        } else {
            self.id(id)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CompatibleScrollTargetOffsetsKey<ID>.self,
                            value: [id: proxy.frame(in: .named(coordinateSpace)).minY]
                        )
                    }
                }
        }
    }

    @ViewBuilder
    func compatibleScrollTargetLayout() -> some View {
        if #available(macOS 14, *) {
            scrollTargetLayout()
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleScrollPosition<ID: Hashable>(
        id: Binding<ID?>,
        anchor: UnitPoint,
        coordinateSpace: String
    ) -> some View {
        if #available(macOS 14, *) {
            scrollPosition(id: id, anchor: anchor)
        } else {
            modifier(
                LegacyScrollPositionModifier(
                    position: id,
                    anchor: anchor,
                    coordinateSpace: coordinateSpace
                )
            )
        }
    }

    @ViewBuilder
    func compatibleWindowMaterialBackground() -> some View {
        if #available(macOS 15, *) {
            containerBackground(.regularMaterial, for: .window)
        } else {
            background(.regularMaterial)
        }
    }

    @ViewBuilder
    func compatiblePresentationBackground(_ color: Color) -> some View {
        if #available(macOS 13.3, *) {
            presentationBackground(color)
        } else {
            background(color)
        }
    }

    @ViewBuilder
    func compatibleToolbarRemovingSidebarToggle() -> some View {
        if #available(macOS 14, *) {
            toolbar(removing: .sidebarToggle)
                .background(SidebarToggleRemover())
        } else {
            background(SidebarToggleRemover())
        }
    }
}

private struct SidebarToggleRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SidebarToggleRemovalView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let removalView = nsView as? SidebarToggleRemovalView else { return }
        removalView.installRemovalController()
    }
}

private final class SidebarToggleRemovalView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installRemovalController()
    }

    func installRemovalController() {
        guard let toolbar = window?.toolbar else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.installRemovalController()
            }
            return
        }
        SidebarToggleRemovalRegistry.shared.install(on: toolbar)
    }
}

enum SidebarToggleIdentifierPolicy {
    static let swiftUISidebarToggle = NSToolbarItem.Identifier(
        "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
    )

    static func shouldRemove(_ identifier: NSToolbarItem.Identifier) -> Bool {
        identifier == .toggleSidebar || identifier == swiftUISidebarToggle
    }
}

@MainActor
private final class SidebarToggleRemovalRegistry {
    static let shared = SidebarToggleRemovalRegistry()

    private let controllers = NSMapTable<NSToolbar, SidebarToggleRemovalController>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    func install(on toolbar: NSToolbar) {
        if let controller = controllers.object(forKey: toolbar) {
            controller.removeSidebarToggles()
            return
        }

        let controller = SidebarToggleRemovalController(toolbar: toolbar)
        controllers.setObject(controller, forKey: toolbar)
    }
}

@MainActor
private final class SidebarToggleRemovalController: NSObject {
    private weak var toolbar: NSToolbar?
    private var removalScheduled = false

    init(toolbar: NSToolbar) {
        self.toolbar = toolbar
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(toolbarWillAddItem),
            name: NSToolbar.willAddItemNotification,
            object: toolbar
        )
        removeSidebarToggles()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func removeSidebarToggles() {
        guard let toolbar else { return }
        let indexes = toolbar.items.indices.filter { index in
            SidebarToggleIdentifierPolicy.shouldRemove(toolbar.items[index].itemIdentifier)
        }
        for index in indexes.reversed() {
            toolbar.removeItem(at: index)
        }
    }

    @objc private func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem,
              SidebarToggleIdentifierPolicy.shouldRemove(item.itemIdentifier)
        else { return }

        item.isEnabled = false
        if #available(macOS 15, *) {
            item.isHidden = true
        }

        guard !removalScheduled else { return }
        removalScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.removalScheduled = false
            self.removeSidebarToggles()
        }
    }
}

@available(macOS, introduced: 10.15, obsoleted: 14)
private struct LegacyScrollPositionModifier<ID: Hashable>: ViewModifier {
    @Binding var position: ID?
    let anchor: UnitPoint
    let coordinateSpace: String
    @State private var lastObservedPosition: ID?

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .coordinateSpace(name: coordinateSpace)
                .onPreferenceChange(CompatibleScrollTargetOffsetsKey<ID>.self) { offsets in
                    guard let visiblePosition = CompatibleScrollPositionResolver
                        .topVisiblePosition(in: offsets)
                    else { return }
                    lastObservedPosition = visiblePosition
                    if position != visiblePosition {
                        position = visiblePosition
                    }
                }
                .onValueChange(of: position) { _, newPosition in
                    guard let newPosition,
                          newPosition != lastObservedPosition
                    else { return }
                    proxy.scrollTo(newPosition, anchor: anchor)
                }
        }
    }
}

enum CompatibleScrollPositionResolver {
    static func topVisiblePosition<ID: Hashable>(in offsets: [ID: CGFloat]) -> ID? {
        let positionsAtOrAboveTop = offsets.filter { $0.value <= 1 }
        if let nearest = positionsAtOrAboveTop.max(by: { $0.value < $1.value }) {
            return nearest.key
        }
        return offsets.min(by: { $0.value < $1.value })?.key
    }
}

struct LegacyWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragNSView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
