import AppKit
import XCTest
@testable import AndroidFileBrowserCore

final class MacOSCompatibilityTests: XCTestCase {
    func testSidebarTogglePolicyRemovesSystemAndSwiftUIIdentifiers() {
        XCTAssertTrue(
            SidebarToggleIdentifierPolicy.shouldRemove(.toggleSidebar)
        )
        XCTAssertTrue(
            SidebarToggleIdentifierPolicy.shouldRemove(
                NSToolbarItem.Identifier(
                    "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
                )
            )
        )
    }

    func testSidebarTogglePolicyKeepsApplicationToolbarItems() {
        XCTAssertFalse(
            SidebarToggleIdentifierPolicy.shouldRemove(
                NSToolbarItem.Identifier("toolbar-inspector")
            )
        )
    }

    func testScrollResolverChoosesItemNearestTopFromAbove() {
        let result = CompatibleScrollPositionResolver.topVisiblePosition(
            in: ["previous": -48, "visible": -4, "next": 32]
        )

        XCTAssertEqual(result, "visible")
    }

    func testScrollResolverUsesFirstItemBelowTopWhenNoneAreAbove() {
        let result = CompatibleScrollPositionResolver.topVisiblePosition(
            in: ["later": 92, "first": 12, "middle": 48]
        )

        XCTAssertEqual(result, "first")
    }

    func testScrollResolverReturnsNilWithoutVisibleItems() {
        let result: String? = CompatibleScrollPositionResolver.topVisiblePosition(in: [:])

        XCTAssertNil(result)
    }
}
