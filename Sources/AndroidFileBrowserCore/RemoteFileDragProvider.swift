import AppKit
import Foundation
import UniformTypeIdentifiers

enum RemoteFileDragProvider {
    typealias FileExport = @MainActor @Sendable () async throws -> URL
    typealias PromisedFileExport = @MainActor @Sendable (URL) async throws -> Void

    @MainActor
    static func provider(
        fileName: String,
        typeIdentifier: String?,
        export: @escaping FileExport
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = fileName

        let identifier = typeIdentifier
            ?? UTType(filenameExtension: (fileName as NSString).pathExtension)?.identifier
            ?? UTType.data.identifier
        let session = FileRepresentationExportSession(export: export)

        for registeredIdentifier in Set([identifier, UTType.item.identifier]) {
            provider.registerFileRepresentation(
                forTypeIdentifier: registeredIdentifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                let progress = Progress(totalUnitCount: 100)

                Task { @MainActor in
                    do {
                        let localURL = try await session.exportedURL()
                        progress.completedUnitCount = 100
                        completion(localURL, false, nil)
                    } catch {
                        progress.cancel()
                        completion(nil, false, error)
                    }
                }

                return progress
            }
        }

        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 100)
            Task { @MainActor in
                do {
                    let localURL = try await session.exportedURL()
                    progress.completedUnitCount = 100
                    completion(localURL.absoluteString.data(using: .utf8), nil)
                } catch {
                    progress.cancel()
                    completion(nil, error)
                }
            }
            return progress
        }

        provider.registerObject(fileName as NSString, visibility: .all)
        return provider
    }

    @MainActor
    static func filePromiseProvider(
        fileName: String,
        typeIdentifier: String?,
        exportTo: @escaping PromisedFileExport
    ) -> NSFilePromiseProvider {
        let identifier = typeIdentifier
            ?? UTType(filenameExtension: (fileName as NSString).pathExtension)?.identifier
            ?? UTType.data.identifier
        let delegate = FilePromiseDelegate(fileName: safeFileName(fileName), exportTo: exportTo)
        let provider = NSFilePromiseProvider(fileType: identifier, delegate: delegate)
        FilePromiseDelegateRetainer.retain(delegate, for: provider)
        return provider
    }

    @MainActor
    static func writeFilePromisesToPasteboard(_ providers: [NSFilePromiseProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects(providers)
    }

    @MainActor
    static func writeFileURLsToPasteboard(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    @MainActor
    private final class FileRepresentationExportSession {
        private let export: FileExport
        private var task: Task<URL, Error>?

        init(export: @escaping FileExport) {
            self.export = export
        }

        func exportedURL() async throws -> URL {
            if let task {
                return try await task.value
            }

            let task = Task { @MainActor in
                try await export()
            }
            self.task = task
            return try await task.value
        }
    }

    static func destinationURL(fileName: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "AndroidFileBrowserDragExports", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appending(path: safeFileName(fileName))
    }

    static func destinationDirectory(fileName: String) throws -> URL {
        let destination = try destinationURL(fileName: fileName)
        return destination.deletingLastPathComponent()
    }

    private static func safeFileName(_ fileName: String) -> String {
        let lastPathComponent = (fileName as NSString).lastPathComponent
        return lastPathComponent.isEmpty ? "Untitled" : lastPathComponent
    }
}

private final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let fileName: String
    private let exportTo: RemoteFileDragProvider.PromisedFileExport
    private let operationQueue: OperationQueue

    init(fileName: String, exportTo: @escaping RemoteFileDragProvider.PromisedFileExport) {
        self.fileName = fileName
        self.exportTo = exportTo
        self.operationQueue = OperationQueue()
        self.operationQueue.name = "AOSP File Manager File Promise"
        self.operationQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let exportTo = self.exportTo
        let completion = FilePromiseCompletion(completionHandler)
        let providerID = ObjectIdentifier(filePromiseProvider)
        Task { @MainActor in
            do {
                try await exportTo(url)
                completion(nil)
            } catch {
                completion(error)
            }
            FilePromiseDelegateRetainer.release(providerID)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        operationQueue
    }
}

@MainActor
private enum FilePromiseDelegateRetainer {
    private static var delegatesByProviderID: [ObjectIdentifier: FilePromiseDelegate] = [:]

    static func retain(_ delegate: FilePromiseDelegate, for provider: NSFilePromiseProvider) {
        delegatesByProviderID[ObjectIdentifier(provider)] = delegate
    }

    static func release(_ providerID: ObjectIdentifier) {
        delegatesByProviderID.removeValue(forKey: providerID)
    }
}

private struct FilePromiseCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ error: Error?) {
        handler(error)
    }
}
