import AppKit
import XCTest
@testable import AndroidFileBrowserCore

final class AppPresentationTests: XCTestCase {
    func testPackageUsesReadableNameAndStableInitialsBeforeMetadataLoads() {
        let package = makePackage(name: "com.example.camera_analyzer")

        XCTAssertEqual(package.displayName, "Camera Analyzer")
        XCTAssertEqual(package.displayInitials, "CA")
        XCTAssertTrue(0..<8 ~= package.artworkPaletteIndex)
    }

    func testDeviceLabelOverridesPackageNameFallback() {
        var package = makePackage(name: "com.google.android.apps.bard")
        package.appLabel = "Gemini"

        XCTAssertEqual(package.displayName, "Gemini")
        XCTAssertEqual(package.displayInitials, "GE")
    }

    func testMetadataBridgeParsesLabelAndImage() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let imageData = try XCTUnwrap(image.tiffRepresentation)
        let output = "com.example.camera\tCamera\t\(imageData.base64EncodedString())\n"

        let presentation = try XCTUnwrap(AppMetadataBridgeParser.parse(output)["com.example.camera"])

        XCTAssertEqual(presentation.label, "Camera")
        XCTAssertEqual(presentation.iconPNGData, imageData)
    }

    func testNarrowAppListPreservesMinimumColumnWidths() {
        let columns = AppColumn.allCases.filter { $0 != .apk }
        let layout = AppColumnMetrics.layout(
            for: columns,
            availableWidth: 320,
            preferredWidths: [:]
        )

        XCTAssertEqual(layout.width(for: .package), AppColumnMetrics.minimumWidth(for: .package))
        XCTAssertGreaterThan(layout.totalWidth, 320)
    }

    func testInspectorAutoHideAccountsForVisibleAppColumns() {
        let packageOnlyWidth = InspectorLayoutPolicy.minimumMainContentWidth(
            for: .apps,
            browserLayout: .list,
            visibleFileColumns: [],
            visibleAppColumns: [.package]
        )
        let allColumnsWidth = InspectorLayoutPolicy.minimumMainContentWidth(
            for: .apps,
            browserLayout: .list,
            visibleFileColumns: [],
            visibleAppColumns: Set(AppColumn.allCases)
        )

        XCTAssertFalse(InspectorLayoutPolicy.shouldAutoHideInspector(
            availableWidth: 950,
            minimumMainContentWidth: packageOnlyWidth
        ))
        XCTAssertTrue(InspectorLayoutPolicy.shouldAutoHideInspector(
            availableWidth: 950,
            minimumMainContentWidth: allColumnsWidth
        ))
        XCTAssertFalse(InspectorLayoutPolicy.shouldAutoHideInspector(
            availableWidth: 1_200,
            minimumMainContentWidth: allColumnsWidth
        ))
    }

    func testStoragePrefetchActivityRequiresEveryForegroundLaneToBeIdle() {
        var activity = StoragePrefetchActivity(
            hasReadyDevice: true,
            usesADBConnection: true,
            hasForegroundOperation: false,
            hasActiveTransfer: false,
            hasActiveUSBOperation: false,
            hasActiveSearch: false,
            hasActiveNavigation: false,
            hasActiveFolderAnalysis: false,
            hasActiveCapture: false,
            isPollingConnections: false,
            isPreparingForTermination: false
        )

        XCTAssertTrue(activity.isIdle)
        activity.hasActiveTransfer = true
        XCTAssertFalse(activity.isIdle)
        activity.hasActiveTransfer = false
        activity.hasActiveSearch = true
        XCTAssertFalse(activity.isIdle)
        activity.hasActiveSearch = false
        activity.hasActiveCapture = true
        XCTAssertFalse(activity.isIdle)
        activity.hasActiveCapture = false
        activity.hasReadyDevice = false
        XCTAssertFalse(activity.isIdle)
    }

    @MainActor
    func testSearchOptionsSnapshotIgnoresUnrelatedModelPublications() {
        let model = makeModel()
        let initial = FinderSearchOptionsSnapshot(model: model)

        model.statusMessage = "Battery status refreshed."
        XCTAssertEqual(FinderSearchOptionsSnapshot(model: model), initial)

        model.searchKindFilter = .images
        XCTAssertNotEqual(FinderSearchOptionsSnapshot(model: model), initial)
    }

    @MainActor
    func testBlankSpaceSelectionActionsClearInspectorSources() {
        let model = makeModel()
        let package = makePackage(name: "com.example.selected")

        model.selectedFileIDs = ["/storage/emulated/0/selected.txt"]
        model.selectedPackageIDs = [package.id]
        model.clearFileBrowserSelection()
        XCTAssertTrue(model.selectedFileIDs.isEmpty)
        XCTAssertTrue(model.selectedPackageIDs.isEmpty)

        model.selectedFileIDs = ["/storage/emulated/0/other.txt"]
        model.selectedPackageIDs = [package.id]
        model.clearAppSelection()
        XCTAssertTrue(model.selectedFileIDs.isEmpty)
        XCTAssertTrue(model.selectedPackageIDs.isEmpty)

        model.selectedFileIDs = ["/storage/emulated/0/video.mp4"]
        model.selectedPackageIDs = [package.id]
        model.selectedStorageCategoryID = StorageBreakdownCategoryKind.videos.rawValue
        model.clearStorageSelection()
        XCTAssertTrue(model.selectedFileIDs.isEmpty)
        XCTAssertTrue(model.selectedPackageIDs.isEmpty)
        XCTAssertNil(model.selectedStorageCategoryID)
    }

    private func makePackage(name: String) -> AndroidPackage {
        AndroidPackage(
            packageName: name,
            apkPath: "/data/app/base.apk",
            kind: .user,
            enabled: true,
            versionName: "1.0",
            permissions: [],
            activities: [],
            receivers: [],
            services: [],
            providers: []
        )
    }

    @MainActor
    private func makeModel() -> AppModel {
        let suiteName = "AndroidFileBrowserCoreTests.AppPresentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            settings: AppSettings(defaults: defaults),
            initialTrashRecords: []
        )
    }
}
