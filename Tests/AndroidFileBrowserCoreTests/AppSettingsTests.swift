import Foundation
import XCTest
@testable import AndroidFileBrowserCore

@MainActor
final class AppSettingsTests: XCTestCase {
    func testConnectionModeLaunchCheckDefaultsOn() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.checkConnectionModesOnLaunch)
    }

    func testBrowserStatusAndFolderSizeSettingsDefaultOnPersistAndReset() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.showPathBar)
        XCTAssertTrue(settings.calculateFolderSizes)

        settings.showPathBar = false
        settings.calculateFolderSizes = false

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.showPathBar)
        XCTAssertFalse(reloaded.calculateFolderSizes)

        settings.reset()
        XCTAssertTrue(settings.showPathBar)
        XCTAssertTrue(settings.calculateFolderSizes)
        XCTAssertTrue(AppSettings(defaults: defaults).showPathBar)
        XCTAssertTrue(AppSettings(defaults: defaults).calculateFolderSizes)
    }

    func testOptionalToolbarButtonsDefaultOffPersistAndReset() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.showUploadToolbarButton)
        XCTAssertFalse(settings.showDownloadToolbarButton)
        XCTAssertFalse(settings.showBatchRenameToolbarButton)
        XCTAssertFalse(settings.showCompressToolbarButton)
        XCTAssertFalse(settings.showUncompressToolbarButton)
        XCTAssertFalse(settings.showConnectionStatusToolbarButton)

        settings.showUploadToolbarButton = true
        settings.showDownloadToolbarButton = true
        settings.showBatchRenameToolbarButton = true
        settings.showCompressToolbarButton = true
        settings.showUncompressToolbarButton = true
        settings.showConnectionStatusToolbarButton = true

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.showUploadToolbarButton)
        XCTAssertTrue(reloaded.showDownloadToolbarButton)
        XCTAssertTrue(reloaded.showBatchRenameToolbarButton)
        XCTAssertTrue(reloaded.showCompressToolbarButton)
        XCTAssertTrue(reloaded.showUncompressToolbarButton)
        XCTAssertTrue(reloaded.showConnectionStatusToolbarButton)

        settings.reset()

        XCTAssertFalse(settings.showUploadToolbarButton)
        XCTAssertFalse(settings.showDownloadToolbarButton)
        XCTAssertFalse(settings.showBatchRenameToolbarButton)
        XCTAssertFalse(settings.showCompressToolbarButton)
        XCTAssertFalse(settings.showUncompressToolbarButton)
        XCTAssertFalse(settings.showConnectionStatusToolbarButton)
    }

    func testResetRestoresConnectionModeLaunchCheck() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.checkConnectionModesOnLaunch = false
        XCTAssertFalse(AppSettings(defaults: defaults).checkConnectionModesOnLaunch)

        settings.reset()

        XCTAssertTrue(settings.checkConnectionModesOnLaunch)
        XCTAssertTrue(AppSettings(defaults: defaults).checkConnectionModesOnLaunch)
    }

    func testPhoneCapturePresentationDefaultsAttachedAndPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.phoneCapturePresentation, .attachedPopover)

        settings.phoneCapturePresentation = .separateWindow
        XCTAssertEqual(AppSettings(defaults: defaults).phoneCapturePresentation, .separateWindow)

        settings.reset()
        XCTAssertEqual(settings.phoneCapturePresentation, .attachedPopover)
        XCTAssertEqual(AppSettings(defaults: defaults).phoneCapturePresentation, .attachedPopover)
    }

    func testPhoneControlDeviceOptionsDefaultSafePersistAndReset() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let serial = "device-serial"

        XCTAssertFalse(settings.phoneControlOptions(for: serial).wakesDeviceOnOpen)
        XCTAssertTrue(settings.phoneControlOptions(for: serial).capturesAudio)

        settings.setPhoneControlOption(true, for: serial, keyPath: \.wakesDeviceOnOpen)
        settings.setPhoneControlOption(false, for: serial, keyPath: \.capturesAudio)
        settings.setPhoneControlOption(.fps30, for: serial, keyPath: \.frameRateLimit)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.phoneControlOptions(for: serial).wakesDeviceOnOpen)
        XCTAssertFalse(reloaded.phoneControlOptions(for: serial).capturesAudio)
        XCTAssertEqual(reloaded.phoneControlOptions(for: serial).frameRateLimit, .fps30)

        settings.reset()
        XCTAssertFalse(settings.phoneControlOptions(for: serial).wakesDeviceOnOpen)
        XCTAssertTrue(settings.phoneControlOptions(for: serial).capturesAudio)
        XCTAssertEqual(settings.phoneControlOptions(for: serial).frameRateLimit, .automatic)
    }

    func testContentBackgroundDefaultsToGlassPersistsAndResets() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.contentBackgroundStyle, .glass)

        settings.contentBackgroundStyle = .solid
        XCTAssertEqual(AppSettings(defaults: defaults).contentBackgroundStyle, .solid)

        settings.reset()
        XCTAssertEqual(settings.contentBackgroundStyle, .glass)
        XCTAssertEqual(AppSettings(defaults: defaults).contentBackgroundStyle, .glass)
    }

    func testEdgeToEdgeSidebarDefaultsOnPersistsAndResets() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.edgeToEdgeSidebar)
        XCTAssertFalse(defaults.bool(forKey: "NSSplitViewItemSidebarDefaultsToFloatingAppearance"))

        settings.edgeToEdgeSidebar = false
        XCTAssertFalse(AppSettings(defaults: defaults).edgeToEdgeSidebar)
        XCTAssertTrue(defaults.bool(forKey: "NSSplitViewItemSidebarDefaultsToFloatingAppearance"))

        settings.reset()
        XCTAssertTrue(settings.edgeToEdgeSidebar)
        XCTAssertTrue(AppSettings(defaults: defaults).edgeToEdgeSidebar)
        XCTAssertFalse(defaults.bool(forKey: "NSSplitViewItemSidebarDefaultsToFloatingAppearance"))
    }

    func testCaptureSetupPromptsDefaultOnPersistAndReset() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.showScreenshotSetup)
        XCTAssertTrue(settings.showRecordingSetup)
        XCTAssertTrue(settings.showPhoneControlSetup)

        settings.showScreenshotSetup = false
        settings.showRecordingSetup = false
        settings.showPhoneControlSetup = false

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.showScreenshotSetup)
        XCTAssertFalse(reloaded.showRecordingSetup)
        XCTAssertFalse(reloaded.showPhoneControlSetup)

        settings.reset()

        XCTAssertTrue(settings.showScreenshotSetup)
        XCTAssertTrue(settings.showRecordingSetup)
        XCTAssertTrue(settings.showPhoneControlSetup)
    }

    func testTrashPreferencesDefaultOnPersistAndReset() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.confirmEmptyTrashAtSessionEnd)
        XCTAssertTrue(settings.showTrashItemCount)

        settings.confirmEmptyTrashAtSessionEnd = false
        settings.showTrashItemCount = false

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.confirmEmptyTrashAtSessionEnd)
        XCTAssertFalse(reloaded.showTrashItemCount)

        settings.reset()

        XCTAssertTrue(settings.confirmEmptyTrashAtSessionEnd)
        XCTAssertTrue(settings.showTrashItemCount)
        XCTAssertTrue(AppSettings(defaults: defaults).confirmEmptyTrashAtSessionEnd)
        XCTAssertTrue(AppSettings(defaults: defaults).showTrashItemCount)
    }

    func testMediaCacheAndTrashQuitBehaviorPersistAndReset() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.mediaCacheLimitMB, 4096)
        XCTAssertFalse(settings.clearMediaCacheOnQuit)
        XCTAssertFalse(settings.encryptPreviewCache)
        XCTAssertEqual(settings.previewCacheRetention, .thirtyMinutes)
        XCTAssertEqual(settings.trashQuitBehavior, .ask)

        settings.mediaCacheLimitMB = 1024
        settings.clearMediaCacheOnQuit = true
        settings.encryptPreviewCache = true
        settings.previewCacheRetention = .fourHours
        settings.trashQuitBehavior = .emptyAutomatically

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.mediaCacheLimitMB, 1024)
        XCTAssertTrue(reloaded.clearMediaCacheOnQuit)
        XCTAssertTrue(reloaded.encryptPreviewCache)
        XCTAssertEqual(reloaded.previewCacheRetention, .fourHours)
        XCTAssertEqual(reloaded.trashQuitBehavior, .emptyAutomatically)
        XCTAssertFalse(reloaded.confirmEmptyTrashAtSessionEnd)

        settings.reset()
        XCTAssertEqual(settings.mediaCacheLimitMB, 4096)
        XCTAssertFalse(settings.clearMediaCacheOnQuit)
        XCTAssertFalse(settings.encryptPreviewCache)
        XCTAssertEqual(settings.previewCacheRetention, .thirtyMinutes)
        XCTAssertEqual(settings.trashQuitBehavior, .ask)
    }

    func testPreviewEncryptionMovesExistingInstallToOptInDefaultOnce() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "settings.encryptPreviewCache")

        let migrated = AppSettings(defaults: defaults)
        XCTAssertFalse(migrated.encryptPreviewCache)

        migrated.encryptPreviewCache = true
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.encryptPreviewCache)
    }

    func testToolSelectionSettingsPersistAndReset() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.adbToolMode = .custom
        settings.adbToolPath = "/Applications/Unity/adb"
        settings.scrcpyToolMode = .managed
        settings.scrcpyToolPath = "/opt/homebrew/bin/scrcpy"

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.adbToolMode, .custom)
        XCTAssertEqual(reloaded.adbToolPath, "/Applications/Unity/adb")
        XCTAssertEqual(reloaded.scrcpyToolMode, .managed)
        XCTAssertEqual(reloaded.scrcpyToolPath, "/opt/homebrew/bin/scrcpy")

        settings.reset()

        XCTAssertEqual(settings.adbToolMode, .automatic)
        XCTAssertEqual(settings.adbToolPath, "")
        XCTAssertEqual(settings.scrcpyToolMode, .automatic)
        XCTAssertEqual(settings.scrcpyToolPath, "")
    }

    func testToolchainLocatorUsesSelectedADBPath() throws {
        let adbURL = try makeExecutable(name: "adb")
        let preferences = ToolchainPreferences(adbMode: .custom, adbPath: adbURL.path)
        let locator = ToolchainLocator(preferencesProvider: { preferences })

        XCTAssertEqual(try locator.adbURL().path, adbURL.standardizedFileURL.path)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AndroidFileBrowserCoreTests.AppSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeExecutable(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AndroidFileBrowserCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
