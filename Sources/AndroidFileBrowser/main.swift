import AndroidFileBrowserCore
import AppKit
import SwiftUI

@main
struct AndroidFileBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var model: AppModel

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: AppModel(settings: settings))
    }

    var body: some Scene {
        Window("AOSP File Manager", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1120, minHeight: 720)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .onAppear {
                    appDelegate.configure(model: model)
                    applyAppearance(settings.appearanceMode)
                }
                .onValueChange(of: settings.appearanceMode) { _, mode in
                    applyAppearance(mode)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Folder") {
                    model.requestActiveFileModeNewFolder()
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(!model.canCreateFolderInActiveFileMode)

                Button("Folder Up") {
                    model.navigateUp()
                }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(!model.canNavigateActiveFileModeUp)

                Button("Back") {
                    model.navigateBack()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!model.canNavigateBack)

                Button("Forward") {
                    model.navigateForward()
                }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(!model.canNavigateForward)

                Button("Open") {
                    model.openActiveFileSelection()
                }
                .disabled(!model.canOpenActiveFileSelection)

                Button("Upload Files...") {
                    model.beginActiveFileModeUpload()
                }
                .keyboardShortcut("u", modifiers: [.command])
                .disabled(!model.canCreateFolderInActiveFileMode)
            }

            CommandMenu("Device") {
                Button("Connection Status") {
                    model.showConnectionStatus()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Button("Refresh Devices") {
                    Task { await model.refreshDevices() }
                }

                Button("Refresh") {
                    Task { await model.refreshCurrentSurfaceSafely() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!model.canRefreshActiveFileMode)

                Button("Refresh File Transfer") {
                    model.usbTransferManager.refresh()
                }
                .disabled(!model.isUSBTransferSelected)

                Button("Switch Tab") {
                    model.switchActiveFileModeTab()
                }
                .keyboardShortcut("1", modifiers: [.command])

                Divider()

                Button("Screenshot") {
                    model.requestScreenshot()
                }
                .disabled(!model.hasReadyADBDevice || model.sidebarSelection == .usbTransfer)

                Button("Screen Recording") {
                    model.requestScreenRecording()
                }
                .disabled(!model.hasReadyADBDevice || model.sidebarSelection == .usbTransfer)

                Button("Phone Control") {
                    model.requestPhoneControl()
                }
                .disabled(!model.hasReadyADBDevice || model.sidebarSelection == .usbTransfer)
            }

            CommandGroup(after: .sidebar) {
                Toggle("Progress Panel", isOn: Binding(
                    get: { model.transferQueue.isPanelExpanded },
                    set: { model.transferQueue.isPanelExpanded = $0 }
                ))
                .disabled(!model.transferQueue.hasVisibleJobs)
            }

            CommandGroup(after: .undoRedo) {
                Divider()

                Button(model.undoFileCommandTitle) {
                    Task { await model.undoLastFileOperation() }
                }
                .disabled(!model.canUndoFileOperation)

                Button(model.redoFileCommandTitle) {
                    Task { await model.redoLastFileOperation() }
                }
                .disabled(!model.canRedoFileOperation)
            }

            CommandGroup(after: .pasteboard) {
                Button("Copy") {
                    model.copyActiveFileSelection()
                }
                .keyboardShortcut("c", modifiers: [.command])
                .disabled(!model.canCopyActiveFileSelection)

                Button("Copy to Queue") {
                    model.copyActiveFileSelectionToQueue()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.canCopyActiveFileSelectionToQueue)

                Button("Copy Remote Path") {
                    model.copyActiveFilePathsToPasteboard()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!model.canCopyActiveFilePath)

                Button("Cut") {
                    model.cutSelected()
                }
                .keyboardShortcut("x", modifiers: [.command])
                .disabled(!model.hasReadyADBDevice || model.sidebarSelection == .usbTransfer)

                Button("Paste") {
                    Task { await model.pasteFromPasteboardOrClipboard() }
                }
                .keyboardShortcut("v", modifiers: [.command])
                .disabled(!model.canPasteInActiveFileMode)

                Divider()

                Button("Select All") {
                    model.selectAllActiveFileItems()
                }
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(!model.canSelectAllActiveFileItems)

                Button("Rename") {
                    model.requestActiveFileModeRename()
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!model.canRenameActiveFileSelection)

                Button("Delete") {
                    Task { await model.deleteActiveFileSelection() }
                }
                .disabled(!model.canDeleteActiveFileSelection)
            }
        }

        Settings {
            SettingsView(settings: settings, model: model)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
        }
        .windowResizability(.contentSize)
    }

    private func applyAppearance(_ mode: AppAppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum TerminationPhase {
        case idle
        case awaitingReply
        case approved
    }

    private weak var model: AppModel?
    private var terminationPhase: TerminationPhase = .idle

    func configure(model: AppModel) {
        self.model = model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        sender.activate(ignoringOtherApps: true)
        if !flag {
            sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch terminationPhase {
        case .approved:
            return .terminateNow
        case .awaitingReply:
            return .terminateLater
        case .idle:
            break
        }
        guard let model else { return .terminateNow }
        guard model.beginTerminationRequest() else {
            presentOperationInProgressAlert(model: model)
            return .terminateCancel
        }
        guard confirmClosingPhoneControlWindowsIfNeeded(model: model) else {
            model.cancelTerminationRequest()
            return .terminateCancel
        }
        if model.shouldAutomaticallyEmptyTrashAtSessionEnd {
            finishTermination(model: model, sender: sender, emptyTrash: true)
            return .terminateLater
        }

        guard model.shouldConfirmEmptyTrashAtSessionEnd else {
            finishTermination(model: model, sender: sender, emptyTrash: false)
            return .terminateLater
        }

        let totalCount = model.trashRecords.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Trash Contents?"
        alert.informativeText = trashDeletionPromptDetail(totalCount: totalCount)
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Don’t Delete").keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my choice"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            switch response {
            case .alertFirstButtonReturn:
                model.settings.trashQuitBehavior = .emptyAutomatically
            case .alertSecondButtonReturn:
                model.settings.trashQuitBehavior = .keep
            default:
                break
            }
        }

        switch response {
        case .alertFirstButtonReturn:
            finishTermination(model: model, sender: sender, emptyTrash: true)
            return .terminateLater
        case .alertSecondButtonReturn:
            finishTermination(model: model, sender: sender, emptyTrash: false)
            return .terminateLater
        default:
            model.cancelTerminationRequest()
            return .terminateCancel
        }
    }

    private func confirmClosingPhoneControlWindowsIfNeeded(model: AppModel) -> Bool {
        let windowCount = model.phoneControlSessions.count
        guard windowCount > 0 else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = windowCount == 1
            ? "Close Phone Control and quit?"
            : "Close Phone Control windows and quit?"
        alert.informativeText = windowCount == 1
            ? "Closing AOSP File Manager will also close the Phone Control window opened by this app."
            : "Closing AOSP File Manager will also close the \(windowCount) Phone Control windows opened by this app."
        alert.addButton(withTitle: "Close Windows and Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func finishTermination(model: AppModel, sender: NSApplication, emptyTrash: Bool) {
        terminationPhase = .awaitingReply
        model.stopAllPhoneControls()
        Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }

            if !emptyTrash {
                await model.preparePreviewCacheForTermination()
                self.approveTermination(sender)
                return
            }

            let result = await model.emptyTrash()
            if result.isComplete, model.trashRecords.isEmpty {
                await model.preparePreviewCacheForTermination()
                self.approveTermination(sender)
                return
            }

            let failureAlert = NSAlert()
            failureAlert.alertStyle = .critical
            failureAlert.messageText = result.deletedCount == 0
                ? "Trash couldn't be emptied"
                : "Some Trash items couldn't be deleted"
            failureAlert.informativeText = trashFailureDetail(result, model: model)
            failureAlert.addButton(withTitle: "Quit Anyway")
            failureAlert.addButton(withTitle: "Keep App Open")
            let shouldQuit = failureAlert.runModal() == .alertFirstButtonReturn
            if shouldQuit {
                await model.preparePreviewCacheForTermination()
                self.approveTermination(sender)
            } else {
                model.cancelTerminationRequest()
                self.terminationPhase = .idle
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
    }

    private func approveTermination(_ sender: NSApplication) {
        terminationPhase = .approved
        sender.reply(toApplicationShouldTerminate: true)
    }

    private func trashDeletionPromptDetail(totalCount: Int) -> String {
        totalCount == 1
            ? "Trash contains 1 item. Deleting it permanently cannot be undone. Choose Don’t Delete to keep it for next time."
            : "Trash contains \(totalCount) items. Deleting them permanently cannot be undone. Choose Don’t Delete to keep them for next time."
    }

    private func trashFailureDetail(_ result: TrashEmptyResult, model: AppModel) -> String {
        let remainingRecords = model.trashRecords
        let summary = "\(remainingRecords.count) item\(remainingRecords.count == 1 ? " remains" : "s remain") in Trash. Reconnect the device named beside each item and try again."
        let failuresByRecordID = Dictionary(uniqueKeysWithValues: result.failures.map { ($0.record.id, $0.message) })
        let details = remainingRecords.prefix(4).map { record in
            let deviceName = model.selectedDevice?.title ?? "Selected phone"
            let message = failuresByRecordID[record.id] ?? "This item was added while Trash was being emptied."
            return "• \(record.name) — \(deviceName): \(message)"
        }.joined(separator: "\n")
        let moreCount = remainingRecords.count - min(remainingRecords.count, 4)
        let more = moreCount > 0 ? "\n• \(moreCount) more" : ""
        return "\(summary)\n\n\(details)\(more)"
    }

    private func presentOperationInProgressAlert(model: AppModel) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        if model.hasActiveScreenRecordingActivity {
            alert.messageText = "A screen recording is still in progress"
            alert.informativeText = "Stop the recording and wait for it to save, then quit again."
        } else {
            alert.messageText = "A file operation is still in progress"
            alert.informativeText = "Let it finish, then quit again."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
