import Foundation
import SwiftUI

public enum DeviceState: String, Codable, Sendable {
    case device
    case unauthorized
    case offline
    case unknown

    var displayName: String {
        switch self {
        case .device: "Ready"
        case .unauthorized: "Authorize on Android"
        case .offline: "Offline"
        case .unknown: "Unknown"
        }
    }
}

public struct AndroidDevice: Identifiable, Hashable, Codable, Sendable {
    public var id: String { serial }
    public let serial: String
    public let state: DeviceState
    public let model: String?
    public let product: String?
    public let transport: String?
    public let usbLocation: String?

    public init(
        serial: String,
        state: DeviceState,
        model: String?,
        product: String?,
        transport: String?,
        usbLocation: String? = nil
    ) {
        self.serial = serial
        self.state = state
        self.model = model
        self.product = product
        self.transport = transport
        self.usbLocation = usbLocation
    }

    public var title: String {
        model?.replacingOccurrences(of: "_", with: " ") ?? serial
    }

    public var subtitle: String {
        [serial, product, transport].compactMap { $0 }.joined(separator: " • ")
    }

    public var connectionKind: ADBConnectionKind {
        if serial.hasPrefix("emulator-") {
            return .virtual
        }
        if serial.contains(":") || serial.contains("._adb-tls-connect._tcp") {
            return .wifi
        }
        return .usb
    }
}

public enum ADBConnectionKind: String, Codable, Sendable {
    case usb
    case wifi
    case virtual

    public var label: String {
        switch self {
        case .usb: "USB"
        case .wifi: "Wi-Fi"
        case .virtual: "Virtual"
        }
    }

    public var symbol: String {
        switch self {
        case .usb: "cable.connector"
        case .wifi: "wifi"
        case .virtual: "desktopcomputer"
        }
    }
}

public enum ADBWirelessSetupState: Equatable, Sendable {
    case preparing
    case ready(endpoint: String)
    case failed(message: String)

    public var detail: String {
        switch self {
        case .preparing:
            "Preparing Wi-Fi…"
        case .ready:
            "Wi-Fi ready · Unplug cable"
        case .failed:
            "Wi-Fi setup failed"
        }
    }
}

public enum ADBWirelessDebuggingStatus: Equatable, Sendable {
    case enabled
    case disabled
    case unavailable
}

public struct ADBWirelessSetupPresentation: Identifiable, Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case checking
        case readyToConnect(verificationUnavailable: Bool)
        case needsWirelessDebugging
        case connecting
        case connected(endpoint: String)
        case failed(message: String)
    }

    public let deviceID: AndroidDevice.ID
    public let deviceName: String
    public var phase: Phase

    public var id: AndroidDevice.ID { deviceID }

    public init(deviceID: AndroidDevice.ID, deviceName: String, phase: Phase) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.phase = phase
    }
}

public enum AndroidFileKind: String, Codable, Sendable {
    case directory
    case file
    case symlink
    case locked
    case unknown

    var symbol: String {
        switch self {
        case .directory: "folder"
        case .file: "doc"
        case .symlink: "arrow.triangle.branch"
        case .locked: "lock"
        case .unknown: "questionmark.square.dashed"
        }
    }

    var displayName: String {
        switch self {
        case .directory: "Folder"
        case .file: "File"
        case .symlink: "Link"
        case .locked: "Locked"
        case .unknown: "Unknown"
        }
    }
}

public struct AndroidFile: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let kind: AndroidFileKind
    public let size: Int64?
    public let modified: Date?
    public let permissions: String?
    public let created: Date?

    public init(
        name: String,
        path: String,
        kind: AndroidFileKind,
        size: Int64?,
        modified: Date?,
        permissions: String?,
        created: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.created = created
    }

    public var isDirectory: Bool { kind == .directory || kind == .locked }

    public var displaySize: String {
        guard kind != .directory, let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var displayModified: String {
        guard let modified else { return "—" }
        return Self.dateFormatter.string(from: modified)
    }

    public var displayCreated: String {
        guard let created else { return "—" }
        return Self.dateFormatter.string(from: created)
    }

    public var fileExtension: String {
        (name as NSString).pathExtension
    }

    public var mediaKind: AndroidMediaKind? {
        AndroidMediaKind(fileExtension: fileExtension)
    }

    public var canCompress: Bool {
        kind == .file || kind == .directory
    }

    public var isExtractableArchive: Bool {
        guard kind == .file else { return false }
        return ArchiveType.isSupportedArchiveName(name)
    }

    public var canQuickLook: Bool {
        kind == .file || isDirectory
    }

    public var archiveExtractionFolderName: String {
        ArchiveType.extractionFolderName(for: name)
    }

    var fallbackSymbol: String {
        switch kind {
        case .file:
            FileIconSymbol.symbol(forExtension: fileExtension)
        case .directory, .symlink, .locked, .unknown:
            kind.symbol
        }
    }

    public var canGenerateThumbnail: Bool {
        guard kind == .file, mediaKind != nil else { return false }
        guard let size else { return true }
        return size <= 75 * 1024 * 1024
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

public enum AndroidMediaKind: String, Codable, Sendable {
    case image
    case video

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif":
            self = .image
        case "mp4", "mov", "m4v", "3gp", "mkv", "webm", "avi":
            self = .video
        default:
            return nil
        }
    }
}

public enum ConnectionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case adb
    case usbTransfer

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .adb: "Developer Options"
        case .usbTransfer: "File Transfer"
        }
    }

    var symbol: String {
        switch self {
        case .adb: "terminal"
        case .usbTransfer: "externaldrive.connected.to.line.below"
        }
    }
}

enum FileIconSymbol {
    static func symbol(forExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif", "raw", "dng":
            return "photo"
        case "mp4", "mov", "m4v", "3gp", "mkv", "webm", "avi":
            return "film"
        case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "amr":
            return "waveform"
        case "pdf":
            return "doc.richtext"
        case "txt", "md", "rtf", "log":
            return "doc.text"
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz":
            return "doc.zipper"
        case "apk", "apks", "aab":
            return "app"
        case "json", "xml", "html", "htm", "css", "js", "ts", "kt", "java", "swift", "py", "sh", "gradle", "properties":
            return "curlybraces"
        case "csv", "xls", "xlsx", "ods":
            return "tablecells"
        case "ppt", "pptx", "key":
            return "chart.bar.doc.horizontal"
        default:
            return fileExtension.isEmpty ? "doc" : "doc.badge.ellipsis"
        }
    }
}

public enum BrowserLayout: String, CaseIterable, Identifiable, Codable {
    case list
    case icons

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .list: "List"
        case .icons: "Icons"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .icons: "square.grid.2x2"
        }
    }
}

public enum FileSearchScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case currentFolder
    case fullDevice

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .currentFolder: "Current Folder"
        case .fullDevice: "Everywhere"
        }
    }
}

public enum FileSearchKindFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case any
    case applications
    case archives
    case documents
    case executables
    case folders
    case files
    case images
    case videos
    case music
    case pdfs
    case presentations
    case text
    case other

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .any: "Any"
        case .applications: "Applications"
        case .archives: "Archives"
        case .documents: "Documents"
        case .executables: "Executables"
        case .folders: "Folders"
        case .files: "Files"
        case .images: "Images"
        case .videos: "Movies"
        case .music: "Music"
        case .pdfs: "PDFs"
        case .presentations: "Presentations"
        case .text: "Text"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .any: "line.3.horizontal.decrease.circle"
        case .applications: "app"
        case .archives: "doc.zipper"
        case .documents: "doc.text"
        case .executables: "terminal"
        case .folders: "folder"
        case .files: "doc"
        case .images: "photo"
        case .videos: "film"
        case .music: "music.note"
        case .pdfs: "doc.richtext"
        case .presentations: "chart.bar.doc.horizontal"
        case .text: "text.alignleft"
        case .other: "questionmark.square.dashed"
        }
    }

    var searchTokenLabel: String {
        switch self {
        case .any: "Any"
        case .applications: "Application"
        case .archives: "Archive"
        case .documents: "Document"
        case .executables: "Executable"
        case .folders: "Folder"
        case .files: "File"
        case .images: "Image"
        case .videos: "Movie"
        case .music: "Music"
        case .pdfs: "PDF"
        case .presentations: "Presentation"
        case .text: "Text"
        case .other: "Other"
        }
    }

    static func searchSuggestions(for query: String) -> [FileSearchKindFilter] {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return [] }

        return allCases
            .filter { $0 != .any }
            .filter { filter in
                filter.searchSuggestionTerms.contains { term in
                    term == normalized || term.hasPrefix(normalized) || normalized.hasPrefix(term)
                }
            }
            .sorted { lhs, rhs in
                let lhsExact = lhs.searchSuggestionTerms.contains(normalized)
                let rhsExact = rhs.searchSuggestionTerms.contains(normalized)
                if lhsExact != rhsExact { return lhsExact }
                return lhs.searchTokenLabel.localizedStandardCompare(rhs.searchTokenLabel) == .orderedAscending
            }
    }

    public init?(searchAlias: String) {
        let normalized = searchAlias
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        switch normalized {
        case "any", "all":
            self = .any
        case "app", "apps", "application", "applications", "apk", "apks", "aab", "package", "packages":
            self = .applications
        case "archive", "archives", "zip", "rar", "7z", "tar", "gzip", "gz":
            self = .archives
        case "document", "documents", "doc", "docs", "docx", "odt", "pages", "spreadsheet", "spreadsheets":
            self = .documents
        case "executable", "executables", "binary", "binaries", "script", "scripts":
            self = .executables
        case "folder", "folders", "directory", "directories":
            self = .folders
        case "file", "files":
            self = .files
        case "image", "images", "picture", "pictures", "photo", "photos", "jpg", "jpeg", "png", "gif", "heic", "heif", "webp":
            self = .images
        case "video", "videos", "movie", "movies", "film", "films", "mp4", "mov", "m4v", "3gp":
            self = .videos
        case "music", "audio", "song", "songs", "sound", "sounds", "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus":
            self = .music
        case "pdf", "pdfs":
            self = .pdfs
        case "presentation", "presentations", "slide", "slides", "ppt", "pptx", "key", "keynote":
            self = .presentations
        case "text", "texts", "code", "source", "txt", "md", "markdown", "rtf", "log", "json", "xml", "html", "css", "js", "ts", "java", "kt", "kotlin", "swift", "py", "python":
            self = .text
        case "other", "others":
            self = .other
        default:
            return nil
        }
    }

    private var searchSuggestionTerms: [String] {
        switch self {
        case .any:
            return []
        case .applications:
            return ["app", "apps", "application", "applications", "apk", "apks", "aab", "package", "packages"]
        case .archives:
            return ["archive", "archives", "zip", "rar", "7z", "tar", "gzip", "gz"]
        case .documents:
            return ["document", "documents", "doc", "docs", "docx", "odt", "pages", "spreadsheet", "spreadsheets"]
        case .executables:
            return ["executable", "executables", "binary", "binaries", "script", "scripts"]
        case .folders:
            return ["folder", "folders", "directory", "directories"]
        case .files:
            return ["file", "files"]
        case .images:
            return ["image", "images", "picture", "pictures", "photo", "photos", "jpg", "jpeg", "png", "gif", "heic", "heif", "webp"]
        case .videos:
            return ["video", "videos", "movie", "movies", "film", "films", "mp4", "mov", "m4v", "3gp"]
        case .music:
            return ["music", "audio", "song", "songs", "sound", "sounds", "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"]
        case .pdfs:
            return ["pdf", "pdfs"]
        case .presentations:
            return ["presentation", "presentations", "slide", "slides", "ppt", "pptx", "key", "keynote"]
        case .text:
            return ["text", "texts", "code", "source", "txt", "md", "markdown", "rtf", "log", "json", "xml", "html", "css", "js", "ts", "java", "kt", "kotlin", "swift", "py", "python"]
        case .other:
            return ["other", "others"]
        }
    }

    var requiresFilePredicate: Bool {
        switch self {
        case .applications, .archives, .documents, .executables, .files, .images, .videos, .music, .pdfs, .presentations, .text, .other:
            return true
        case .any, .folders:
            return false
        }
    }

    var adbFindExtensionPredicate: String? {
        let extensions: Set<String>?
        switch self {
        case .applications:
            extensions = Self.applicationExtensions
        case .archives:
            extensions = Self.archiveExtensions
        case .documents:
            extensions = Self.documentExtensions
        case .executables:
            extensions = Self.executableExtensions
        case .images:
            extensions = Self.imageExtensions
        case .videos:
            extensions = Self.videoExtensions
        case .music:
            extensions = Self.musicExtensions
        case .pdfs:
            extensions = ["pdf"]
        case .presentations:
            extensions = Self.presentationExtensions
        case .text:
            extensions = Self.textExtensions
        case .any, .folders, .files, .other:
            extensions = nil
        }

        guard let extensions, !extensions.isEmpty else { return nil }
        let clauses = extensions.sorted().map { "-iname \(ADBClient.quoteRemote("*.\($0)"))" }
        return "\\( \(clauses.joined(separator: " -o ")) \\)"
    }

    func matches(file: AndroidFile) -> Bool {
        matches(kind: file.kind.fileSearchKind, fileExtension: file.fileExtension)
    }

    func matches(item: USBTransferItem) -> Bool {
        matches(kind: item.kind.fileSearchKind, fileExtension: item.fileExtension)
    }

    private func matches(kind: FileSearchableKind, fileExtension: String) -> Bool {
        switch self {
        case .any:
            return true
        case .folders:
            return kind == .folder
        case .files:
            return kind == .file
        case .other:
            return kind == .file && Self.specificFilter(forExtension: fileExtension) == nil
        case .applications, .archives, .documents, .executables, .images, .videos, .music, .pdfs, .presentations, .text:
            return kind == .file && Self.specificFilter(forExtension: fileExtension) == self
        }
    }

    private static func specificFilter(forExtension fileExtension: String) -> FileSearchKindFilter? {
        let ext = fileExtension.lowercased()
        guard !ext.isEmpty else { return nil }

        if applicationExtensions.contains(ext) { return .applications }
        if archiveExtensions.contains(ext) { return .archives }
        if imageExtensions.contains(ext) { return .images }
        if videoExtensions.contains(ext) { return .videos }
        if musicExtensions.contains(ext) { return .music }
        if ext == "pdf" { return .pdfs }
        if presentationExtensions.contains(ext) { return .presentations }
        if executableExtensions.contains(ext) { return .executables }
        if textExtensions.contains(ext) { return .text }
        if documentExtensions.contains(ext) { return .documents }
        return nil
    }

    private static let applicationExtensions: Set<String> = ["apk", "apks", "aab"]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]
    private static let documentExtensions: Set<String> = ["doc", "docx", "odt", "pages", "numbers", "csv", "xls", "xlsx", "ods"]
    private static let executableExtensions: Set<String> = ["sh", "bash", "zsh", "bin", "run", "dex", "jar", "so"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif", "raw", "dng"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp", "mkv", "webm", "avi"]
    private static let musicExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "amr"]
    private static let presentationExtensions: Set<String> = ["ppt", "pptx", "key"]
    private static let textExtensions: Set<String> = ["txt", "md", "markdown", "rtf", "log", "json", "xml", "html", "htm", "css", "js", "ts", "kt", "java", "swift", "py", "sh", "gradle", "properties"]
}

private enum FileSearchableKind {
    case folder
    case file
    case other
}

private extension AndroidFileKind {
    var fileSearchKind: FileSearchableKind {
        switch self {
        case .directory, .locked:
            return .folder
        case .file:
            return .file
        case .symlink, .unknown:
            return .other
        }
    }
}

private extension USBTransferItemKind {
    var fileSearchKind: FileSearchableKind {
        switch self {
        case .folder:
            return .folder
        case .file:
            return .file
        }
    }
}

public enum FileSearchDateFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case any
    case today
    case last7Days
    case last30Days

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .any: "Any Time"
        case .today: "Today"
        case .last7Days: "Last 7 Days"
        case .last30Days: "Last 30 Days"
        }
    }

    var findPredicate: String? {
        switch self {
        case .any: nil
        case .today: "-mtime -1"
        case .last7Days: "-mtime -7"
        case .last30Days: "-mtime -30"
        }
    }

    func matches(_ modified: Date?) -> Bool {
        guard self != .any else { return true }
        guard let modified else { return false }

        let now = Date()
        switch self {
        case .any:
            return true
        case .today:
            return Calendar.current.isDateInToday(modified)
        case .last7Days:
            return modified >= now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .last30Days:
            return modified >= now.addingTimeInterval(-30 * 24 * 60 * 60)
        }
    }
}

public enum FileSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case kind
    case size
    case modified
    case created
    case permissions

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .kind: "Kind"
        case .size: "Size"
        case .modified: "Modified"
        case .created: "Created"
        case .permissions: "Permissions"
        }
    }
}

public struct FileSortDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: String { sort.rawValue }
    public var sort: FileSort
    public var ascending: Bool
}

public enum FileColumn: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case kind
    case size
    case modified
    case created
    case permissions

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .kind: "Kind"
        case .size: "Size"
        case .modified: "Modified"
        case .created: "Created"
        case .permissions: "Permissions"
        }
    }

    var sort: FileSort {
        switch self {
        case .name: .name
        case .kind: .kind
        case .size: .size
        case .modified: .modified
        case .created: .created
        case .permissions: .permissions
        }
    }

    var isHideable: Bool {
        self != .name
    }
}

public enum SidebarDestination: Hashable, Identifiable, Codable {
    case location(QuickLocation)
    case usbTransferLocation(MTPQuickLocation)
    case storage(String)
    case apps
    case trash
    case usbTransfer

    public var id: String {
        switch self {
        case .location(let location): "location:\(location.id)"
        case .usbTransferLocation(let location): "usb-transfer-location:\(location.id)"
        case .storage(let summaryID): "storage:\(summaryID)"
        case .apps: "apps"
        case .trash: "trash"
        case .usbTransfer: "usb-transfer"
        }
    }
}

public enum USBTransferItemKind: String, Codable, Sendable {
    case folder
    case file

    var symbol: String {
        switch self {
        case .folder: "folder"
        case .file: "doc"
        }
    }

    var displayName: String {
        switch self {
        case .folder: "Folder"
        case .file: "File"
        }
    }
}

public enum USBTransferSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case kind
    case size
    case modified

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .kind: "Kind"
        case .size: "Size"
        case .modified: "Modified"
        }
    }
}

public enum USBTransferBackend: String, Codable, Sendable {
    case notChecked
    case checking
    case mtp
    case imageCapture

    var displayName: String {
        switch self {
        case .notChecked: "Ready"
        case .checking: "Looking"
        case .mtp: "File Transfer"
        case .imageCapture: "Photo Access"
        }
    }

    var isWritable: Bool {
        self == .mtp
    }
}

public struct USBTransferSortDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: String { sort.rawValue }
    public var sort: USBTransferSort
    public var ascending: Bool
}

public struct USBTransferDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let transport: String
    public let productKind: String?
    public let isReady: Bool
    public let isLocked: Bool
    public let catalogPercent: Int

    public var subtitle: String {
        [productKind, transport].compactMap { $0 }.joined(separator: " • ")
    }

    public var statusLabel: String {
        if isLocked { return "Locked" }
        if isReady { return "Ready" }
        return catalogPercent > 0 ? "Cataloging \(catalogPercent)%" : "Connecting"
    }
}

public struct USBTransferPathComponent: Identifiable, Hashable, Sendable {
    public let id: String
    public let itemID: USBTransferItem.ID?
    public let title: String
    public let path: String
}

public struct USBTransferItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let kind: USBTransferItemKind
    public let size: Int64?
    public let modified: Date?
    public let uti: String?

    public var isFolder: Bool { kind == .folder }
    public var isDownloadable: Bool { kind == .file }
    public var canQuickLook: Bool { kind == .file || kind == .folder }

    public var displaySize: String {
        guard kind == .file, let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var displayModified: String {
        guard let modified else { return "—" }
        return Self.dateFormatter.string(from: modified)
    }

    public var fileExtension: String {
        (name as NSString).pathExtension
    }

    public var mediaKind: AndroidMediaKind? {
        AndroidMediaKind(fileExtension: fileExtension)
    }

    public var canCompress: Bool {
        kind == .file || kind == .folder
    }

    public var isExtractableArchive: Bool {
        guard kind == .file else { return false }
        return ArchiveType.isSupportedArchiveName(name)
    }

    public var archiveExtractionFolderName: String {
        ArchiveType.extractionFolderName(for: name)
    }

    var fallbackSymbol: String {
        switch kind {
        case .folder:
            kind.symbol
        case .file:
            FileIconSymbol.symbol(forExtension: fileExtension)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

enum ArchiveType {
    static let supportedSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".txz", ".zip", ".tar"]

    static func isSupportedArchiveName(_ name: String) -> Bool {
        let lowercasedName = name.lowercased()
        return supportedSuffixes.contains { lowercasedName.hasSuffix($0) }
    }

    static func extractionFolderName(for name: String) -> String {
        let lowercasedName = name.lowercased()
        for suffix in supportedSuffixes where lowercasedName.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return (name as NSString).deletingPathExtension
    }
}

public struct QuickLocation: Hashable, Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let path: String
    public let symbol: String
    public let subtitle: String?
    public let requiresProbe: Bool

    public init(id: String, title: String, path: String, symbol: String, subtitle: String? = nil, requiresProbe: Bool = false) {
        self.id = id
        self.title = title
        self.path = path
        self.symbol = symbol
        self.subtitle = subtitle
        self.requiresProbe = requiresProbe
    }
}

public struct MTPQuickLocation: Hashable, Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let path: String
    public let symbol: String
    public let subtitle: String?
    public let storageID: String
    public let parentID: String?

    public init(
        id: String,
        title: String,
        path: String,
        symbol: String,
        subtitle: String? = nil,
        storageID: String,
        parentID: String?
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.symbol = symbol
        self.subtitle = subtitle
        self.storageID = storageID
        self.parentID = parentID
    }
}

public struct ADBQRPairingSession: Hashable, Identifiable, Sendable {
    public let serviceName: String
    public let password: String

    public var id: String { serviceName }
    public var payload: String { "WIFI:T:ADB;S:\(serviceName);P:\(password);;" }

    public static func make() -> ADBQRPairingSession {
        let serviceSuffix = String((0..<6).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement()! })
        let password = String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        return ADBQRPairingSession(serviceName: "AFB-\(serviceSuffix)", password: password)
    }
}

enum SidebarShortcutSection {
    case favorites
    case locations
    case apps
}

extension QuickLocation {
    var sidebarSection: SidebarShortcutSection {
        switch id {
        case "home", "sdcard":
            return .locations
        case "android-media", "android-data", "android-obb":
            return .apps
        default:
            return .favorites
        }
    }
}

extension MTPQuickLocation {
    var sidebarSection: SidebarShortcutSection {
        switch baseID {
        case "home", "storage":
            return .locations
        case "android-media", "android-data", "android-obb":
            return .apps
        default:
            return .favorites
        }
    }

    var baseID: String {
        id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
    }
}

public struct StorageSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let path: String
    public let usedBytes: Int64
    public let totalBytes: Int64

    public var fractionUsed: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    public var subtitle: String {
        "\(ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) used"
    }
}

public enum StorageBreakdownCategoryKind: String, CaseIterable, Codable, Sendable {
    case apps
    case videos
    case images
    case audio
    case trash
    case documents
    case other
    case games
    case androidSystem
    case temporarySystemFiles

    public var title: String {
        switch self {
        case .apps: "Apps"
        case .videos: "Videos"
        case .images: "Images"
        case .audio: "Audio"
        case .trash: "Trash"
        case .documents: "Documents"
        case .other: "Other"
        case .games: "Games"
        case .androidSystem: "Android System"
        case .temporarySystemFiles: "Temporary System Files"
        }
    }

    public var symbol: String {
        switch self {
        case .apps: "app.dashed"
        case .videos: "film"
        case .images: "photo"
        case .audio: "music.note"
        case .trash: "trash"
        case .documents: "doc"
        case .other: "square.stack.3d.up"
        case .games: "gamecontroller"
        case .androidSystem: "gearshape.2"
        case .temporarySystemFiles: "clock.arrow.circlepath"
        }
    }

    public var canBrowseFiles: Bool {
        switch self {
        case .androidSystem, .temporarySystemFiles:
            return false
        case .apps, .videos, .images, .audio, .trash, .documents, .other, .games:
            return true
        }
    }
}

public struct StorageBreakdownCategory: Identifiable, Hashable, Codable, Sendable {
    public var id: String { kind.rawValue }
    public let kind: StorageBreakdownCategoryKind
    public let bytes: Int64
    public var titleOverride: String? = nil

    public var displayTitle: String {
        titleOverride ?? kind.title
    }

    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public func fraction(of totalBytes: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(totalBytes)))
    }
}

public struct StorageBreakdown: Identifiable, Hashable, Sendable {
    public var id: String { summary.id }
    public let summary: StorageSummary
    public let categories: [StorageBreakdownCategory]

    public var measuredBytes: Int64 {
        categories.reduce(0) { $0 + $1.bytes }
    }

    public var visibleCategories: [StorageBreakdownCategory] {
        categories.filter { $0.bytes > 0 }
    }
}

public struct StorageCategoryFileList: Identifiable, Hashable, Sendable {
    public var id: String { "\(summaryID):\(category.id)" }
    public let summaryID: StorageSummary.ID
    public let category: StorageBreakdownCategory
    public let files: [AndroidFile]
}

public enum BatteryChargeState: String, Codable, Sendable {
    case charging
    case discharging
    case notCharging
    case full
    case unknown
}

public enum BatteryChargingSource: String, Codable, Sendable {
    case ac
    case usb
    case wireless
    case dock
    case unknown
}

public struct BatteryStatus: Hashable, Codable, Sendable {
    public let levelPercent: Int
    public let chargeState: BatteryChargeState
    public let chargingSource: BatteryChargingSource?

    public var isCharging: Bool {
        chargeState == .charging || chargeState == .full || chargingSource != nil
    }

    public var statusLabel: String {
        switch chargeState {
        case .full:
            return "Charged"
        case .charging:
            switch chargingSource {
            case .wireless: return "Wireless charging"
            case .usb: return "USB charging"
            case .ac: return "Charging"
            case .dock: return "Dock charging"
            case .unknown: return "Charging"
            case nil: return "Charging"
            }
        case .discharging:
            return "Discharging"
        case .notCharging:
            if chargingSource != nil {
                return levelPercent >= 100 ? "Charged" : "Connected"
            }
            return "Not charging"
        case .unknown:
            return isCharging ? "Charging" : "Battery"
        }
    }

    public var symbolName: String {
        switch levelPercent {
        case 76...100: "battery.100"
        case 51...75: "battery.75"
        case 26...50: "battery.50"
        case 1...25: "battery.25"
        default: "battery.0"
        }
    }
}

public enum AppKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case all
    case user
    case system

    public var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .user: "User"
        case .system: "System"
        }
    }
}

public enum AppColumn: String, CaseIterable, Identifiable, Codable, Sendable {
    case package
    case status
    case kind
    case enabled
    case size
    case apk

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .package: "App"
        case .status: "Status"
        case .kind: "Type"
        case .enabled: "Enabled"
        case .size: "Size"
        case .apk: "APK"
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .package: 430
        case .status: 120
        case .kind: 100
        case .enabled: 110
        case .size: 110
        case .apk: 310
        }
    }

    var isHideable: Bool {
        self != .package
    }
}

public struct AppSortDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: String { column.rawValue }
    public var column: AppColumn
    public var ascending: Bool
}

public struct AndroidPackage: Identifiable, Hashable, Codable, Sendable {
    public var id: String { packageName }
    public let packageName: String
    public let apkPath: String?
    public var kind: AppKind
    public var isRunning: Bool = false
    public var appLabel: String? = nil
    public var iconPNGData: Data? = nil
    public var apkSizeBytes: Int64?
    public var enabled: Bool?
    public var versionName: String?
    public var permissions: [String]
    public var activities: [AndroidIntentEndpoint]
    public var receivers: [AndroidIntentEndpoint]
    public var services: [AndroidIntentEndpoint]
    public var providers: [AndroidIntentEndpoint]
    var availableStorageKinds: Set<AppStorageLocation.Kind>?
    var storageStats: AppStorageStats? = nil
    var appStorageLocationSizes: [AppStorageLocation.Kind: Int64] = [:]

    public var displayName: String {
        if let appLabel = appLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !appLabel.isEmpty {
            return appLabel
        }

        let packageComponent = packageName
            .split(separator: ".")
            .last
            .map(String.init)
            ?? packageName
        let words = packageComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return packageName }
        return words.map { word in
            let value = String(word)
            guard value == value.lowercased() else { return value }
            return value.prefix(1).uppercased() + value.dropFirst()
        }
        .joined(separator: " ")
    }

    var displayInitials: String {
        let words = displayName.split { character in
            !character.isLetter && !character.isNumber
        }
        if words.count >= 2 {
            return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        }
        return String((words.first ?? Substring("?"))).prefix(2).uppercased()
    }

    var artworkPaletteIndex: Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in packageName.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % 8)
    }

    var appStorageLocations: [AppStorageLocation] {
        [
            AppStorageLocation(
                kind: .data,
                title: "App Data",
                path: "/storage/emulated/0/Android/data/\(packageName)",
                symbol: "folder.badge.gearshape",
                description: "Shared Android/data folder"
            ),
            AppStorageLocation(
                kind: .userData,
                title: "User Data",
                path: "/data/user/0/\(packageName)",
                symbol: "person.crop.circle.badge.exclamationmark",
                description: "Private app data managed by Android"
            ),
            AppStorageLocation(
                kind: .cache,
                title: "App Cache",
                path: "/storage/emulated/0/Android/data/\(packageName)/cache",
                symbol: "clock.arrow.circlepath",
                description: "Cache files Android exposes for this app"
            ),
            AppStorageLocation(
                kind: .files,
                title: "App Files",
                path: "/storage/emulated/0/Android/data/\(packageName)/files",
                symbol: "folder",
                description: "App files folder when Android exposes it"
            ),
            AppStorageLocation(
                kind: .media,
                title: "App Media",
                path: "/storage/emulated/0/Android/media/\(packageName)",
                symbol: "photo.stack",
                description: "MediaStore-visible app media folder"
            ),
            AppStorageLocation(
                kind: .obb,
                title: "OBB",
                path: "/storage/emulated/0/Android/obb/\(packageName)",
                symbol: "shippingbox",
                description: "Expansion files and OBB assets"
            )
        ]
    }

    var defaultAppDataLocation: AppStorageLocation {
        appStorageLocations[0]
    }

    var obbStorageLocation: AppStorageLocation {
        appStorageLocations.first { $0.kind == .obb } ?? appStorageLocations.last!
    }

    var visibleAppStorageLocations: [AppStorageLocation] {
        guard let availableStorageKinds else { return [] }
        return appStorageLocations.filter { availableStorageKinds.contains($0.kind) }
    }

    func hasStorageLocation(_ kind: AppStorageLocation.Kind) -> Bool {
        availableStorageKinds?.contains(kind) == true
    }

    var displayAPKSize: String {
        guard let apkSizeBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: apkSizeBytes, countStyle: .file)
    }

    var displayTotalSize: String {
        guard let bytes = storageStats?.totalBytes ?? apkSizeBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func storageSizeBytes(for location: AppStorageLocation) -> Int64? {
        switch location.kind {
        case .userData:
            storageStats?.userDataBytes ?? appStorageLocationSizes[location.kind]
        case .cache:
            storageStats?.cacheBytes ?? appStorageLocationSizes[location.kind]
        case .data, .files, .media, .obb:
            appStorageLocationSizes[location.kind]
        }
    }

    func displayStorageSize(for location: AppStorageLocation) -> String {
        guard let bytes = storageSizeBytes(for: location) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct AppStorageLocation: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case data
        case userData
        case cache
        case files
        case media
        case obb
    }

    var id: String { kind.rawValue }
    let kind: Kind
    let title: String
    let path: String
    let symbol: String
    let description: String
}

public struct AppStorageStats: Hashable, Codable, Sendable {
    public let appBytes: Int64?
    public let userDataBytes: Int64?
    public let cacheBytes: Int64?

    public var totalBytes: Int64? {
        let values = [appBytes, userDataBytes, cacheBytes].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }
}

struct SelectedAppStorageLocation: Identifiable, Hashable, Sendable {
    var id: String { "\(packageName):\(location.kind.rawValue)" }
    let packageName: String
    let displayName: String
    let versionName: String?
    let location: AppStorageLocation
    let sizeBytes: Int64?
    let isBrowseable: Bool
    let isProtected: Bool

    var displaySize: String {
        guard let sizeBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct AppFolderContext: Equatable, Sendable {
    let packageName: String
    let displayName: String
    let locationTitle: String
    let rootPaths: [String]

    func contains(path: String) -> Bool {
        rootPaths.contains { path == $0 || path.hasPrefix("\($0)/") }
    }
}

public struct AndroidIntentEndpoint: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let component: String
    public var actions: [String]
    public var categories: [String]
    public var data: [String]

    public init(id: String, component: String, actions: [String] = [], categories: [String] = [], data: [String] = []) {
        self.id = id
        self.component = component
        self.actions = actions
        self.categories = categories
        self.data = data
    }
}

public struct TrashRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let deviceSerial: String
    public let originalPath: String
    public let trashPath: String
    public let name: String
    public let deletedAt: Date
    public let size: Int64?
    public let kind: AndroidFileKind?

    public init(
        id: UUID,
        deviceSerial: String,
        originalPath: String,
        trashPath: String,
        name: String,
        deletedAt: Date,
        size: Int64?,
        kind: AndroidFileKind? = nil
    ) {
        self.id = id
        self.deviceSerial = deviceSerial
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.name = name
        self.deletedAt = deletedAt
        self.size = size
        self.kind = kind
    }
}

struct TrashSessionSnapshot: Sendable {
    private let recordIDsAtStart: Set<TrashRecord.ID>

    init(recordsAtStart: [TrashRecord]) {
        self.recordIDsAtStart = Set(recordsAtStart.map(\.id))
    }

    func addedRecords(in currentRecords: [TrashRecord]) -> [TrashRecord] {
        currentRecords.filter { !recordIDsAtStart.contains($0.id) }
    }
}

struct OperationActivityTracker: Sendable {
    private(set) var activeCount = 0
    private(set) var terminationBlockingCount = 0

    var isBusy: Bool { activeCount > 0 }
    var hasTerminationBlockingActivity: Bool { terminationBlockingCount > 0 }

    mutating func begin(blocksTermination: Bool = true) {
        activeCount += 1
        if blocksTermination {
            terminationBlockingCount += 1
        }
    }

    mutating func end(blocksTermination: Bool = true) {
        precondition(activeCount > 0, "Cannot finish an operation that was not started.")
        if blocksTermination {
            precondition(terminationBlockingCount > 0, "Cannot finish a blocking operation that was not started.")
            terminationBlockingCount -= 1
        }
        activeCount -= 1
    }
}

public struct TrashEmptyFailure: Sendable {
    public let record: TrashRecord
    public let message: String

    init(record: TrashRecord, message: String) {
        self.record = record
        self.message = message
    }
}

public struct TrashEmptyResult: Sendable {
    public let deletedCount: Int
    public let failures: [TrashEmptyFailure]

    init(deletedCount: Int, failures: [TrashEmptyFailure]) {
        self.deletedCount = deletedCount
        self.failures = failures
    }

    public var isComplete: Bool { failures.isEmpty }
}

public enum RemoteClipboardMode: String, Codable, Sendable {
    case copy
    case cut
}

public struct RemoteClipboardItem: Codable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let kind: AndroidFileKind
    public let size: Int64?

    public init(path: String, name: String, kind: AndroidFileKind, size: Int64?) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
    }
}

public struct RemoteClipboard: Codable, Sendable {
    public let mode: RemoteClipboardMode
    public let sourceDeviceSerial: String?
    public let items: [RemoteClipboardItem]

    public var paths: [String] {
        items.map(\.path)
    }
}

public enum ScreenRecordingDurationMode: String, CaseIterable, Identifiable, Sendable {
    case untilStopped
    case fixed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .untilStopped: "Until Stopped"
        case .fixed: "Fixed Time"
        }
    }
}

public enum ScreenRecordingDeviceAppearance: String, CaseIterable, Identifiable, Sendable {
    case unchanged
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unchanged: "Keep Current"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public enum CaptureResolutionPreset: String, CaseIterable, Identifiable, Sendable {
    case native
    case hd720
    case fullHD1080
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .native: "Native"
        case .hd720: "720p"
        case .fullHD1080: "1080p"
        case .custom: "Custom"
        }
    }

    public func screenRecordSize(width: Int, height: Int) -> String? {
        switch self {
        case .native:
            return nil
        case .hd720:
            return "1280x720"
        case .fullHD1080:
            return "1920x1080"
        case .custom:
            let safeWidth = min(max(width, 320), 3840)
            let safeHeight = min(max(height, 240), 2160)
            return "\(safeWidth)x\(safeHeight)"
        }
    }

    public func scrcpyMaxSize(width: Int, height: Int) -> Int? {
        switch self {
        case .native:
            return nil
        case .hd720:
            return 1280
        case .fullHD1080:
            return 1920
        case .custom:
            return min(max(max(width, height), 320), 3840)
        }
    }
}

public struct ScreenRecordingOptions: Equatable, Sendable {
    public var durationMode: ScreenRecordingDurationMode
    public var fixedDurationSeconds: Int
    public var showTouches: Bool
    public var deviceAppearance: ScreenRecordingDeviceAppearance
    public var demoMode: Bool
    public var resolutionPreset: CaptureResolutionPreset
    public var customWidth: Int
    public var customHeight: Int
    public var videoBitRateMbps: Int
    public var appPackageName: String

    public init(
        durationMode: ScreenRecordingDurationMode = .untilStopped,
        fixedDurationSeconds: Int = 30,
        showTouches: Bool = false,
        deviceAppearance: ScreenRecordingDeviceAppearance = .unchanged,
        demoMode: Bool = false,
        resolutionPreset: CaptureResolutionPreset = .native,
        customWidth: Int = 1280,
        customHeight: Int = 720,
        videoBitRateMbps: Int = 12,
        appPackageName: String = ""
    ) {
        self.durationMode = durationMode
        self.fixedDurationSeconds = fixedDurationSeconds
        self.showTouches = showTouches
        self.deviceAppearance = deviceAppearance
        self.demoMode = demoMode
        self.resolutionPreset = resolutionPreset
        self.customWidth = customWidth
        self.customHeight = customHeight
        self.videoBitRateMbps = videoBitRateMbps
        self.appPackageName = appPackageName
    }

    public var normalizedPackageName: String? {
        let trimmed = appPackageName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var effectiveFixedDurationSeconds: Int {
        min(max(fixedDurationSeconds, 5), 180)
    }

    public var effectiveCustomWidth: Int {
        min(max(customWidth, 320), 3840)
    }

    public var effectiveCustomHeight: Int {
        min(max(customHeight, 240), 2160)
    }

    public var effectiveVideoBitRateMbps: Int {
        min(max(videoBitRateMbps, 1), 80)
    }

    public var screenRecordSize: String? {
        resolutionPreset.screenRecordSize(width: effectiveCustomWidth, height: effectiveCustomHeight)
    }

    public var scrcpyMaxSize: Int? {
        resolutionPreset.scrcpyMaxSize(width: effectiveCustomWidth, height: effectiveCustomHeight)
    }

    public var timeLimitSeconds: Int? {
        durationMode == .fixed ? effectiveFixedDurationSeconds : 0
    }
}

public struct ScreenRecordingDeviceSession: Identifiable, Equatable, Sendable {
    public var id: String { deviceSerial }
    public let deviceSerial: String
    public let deviceTitle: String
    public let startedAt: Date

    public init(deviceSerial: String, deviceTitle: String, startedAt: Date) {
        self.deviceSerial = deviceSerial
        self.deviceTitle = deviceTitle
        self.startedAt = startedAt
    }
}

public struct ScreenRecordingSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let devices: [ScreenRecordingDeviceSession]
    public let options: ScreenRecordingOptions

    public var deviceSerial: String { devices.first?.deviceSerial ?? "" }
    public var deviceSerials: [String] { devices.map(\.deviceSerial) }
    public var deviceTitle: String {
        devices.count == 1 ? (devices.first?.deviceTitle ?? "Device") : "\(devices.count) devices"
    }
    public var startedAt: Date { devices.map(\.startedAt).min() ?? Date() }

    public init(
        id: UUID = UUID(),
        deviceSerial: String,
        deviceTitle: String,
        startedAt: Date = Date(),
        options: ScreenRecordingOptions
    ) {
        self.id = id
        self.devices = [ScreenRecordingDeviceSession(
            deviceSerial: deviceSerial,
            deviceTitle: deviceTitle,
            startedAt: startedAt
        )]
        self.options = options
    }

    public init(
        id: UUID = UUID(),
        devices: [ScreenRecordingDeviceSession],
        options: ScreenRecordingOptions
    ) {
        self.id = id
        self.devices = devices
        self.options = options
    }
}

public struct ScrcpyWindowPlacement: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let alwaysOnTop: Bool

    public init(x: Int, y: Int, width: Int, height: Int, alwaysOnTop: Bool = true) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.alwaysOnTop = alwaysOnTop
    }
}

public enum PhoneControlFrameRateLimit: Int, CaseIterable, Identifiable, Codable, Sendable {
    case automatic = 0
    case fps30 = 30
    case fps60 = 60

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .fps30: "30 fps"
        case .fps60: "60 fps"
        }
    }
}

public enum PhoneControlVideoCodec: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case h264
    case h265
    case av1

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .h264: "H.264"
        case .h265: "H.265"
        case .av1: "AV1"
        }
    }
}

public struct PhoneControlDeviceOptions: Equatable, Codable, Sendable {
    public var wakesDeviceOnOpen: Bool
    public var capturesAudio: Bool
    public var acceptsInput: Bool
    public var synchronizesClipboard: Bool
    public var staysAwake: Bool
    public var turnsDeviceScreenOff: Bool
    public var alwaysOnTop: Bool
    public var frameRateLimit: PhoneControlFrameRateLimit
    public var videoCodec: PhoneControlVideoCodec

    public init(
        wakesDeviceOnOpen: Bool = false,
        capturesAudio: Bool = true,
        acceptsInput: Bool = true,
        synchronizesClipboard: Bool = true,
        staysAwake: Bool = false,
        turnsDeviceScreenOff: Bool = false,
        alwaysOnTop: Bool = true,
        frameRateLimit: PhoneControlFrameRateLimit = .automatic,
        videoCodec: PhoneControlVideoCodec = .automatic
    ) {
        self.wakesDeviceOnOpen = wakesDeviceOnOpen
        self.capturesAudio = capturesAudio
        self.acceptsInput = acceptsInput
        self.synchronizesClipboard = synchronizesClipboard
        self.staysAwake = staysAwake
        self.turnsDeviceScreenOff = turnsDeviceScreenOff
        self.alwaysOnTop = alwaysOnTop
        self.frameRateLimit = frameRateLimit
        self.videoCodec = videoCodec
    }
}

public struct PhoneControlSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let deviceSerial: String
    public let deviceTitle: String
    public let processIdentifier: Int32
    public let startedAt: Date

    public init(
        id: UUID = UUID(),
        deviceSerial: String,
        deviceTitle: String,
        processIdentifier: Int32,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.deviceSerial = deviceSerial
        self.deviceTitle = deviceTitle
        self.processIdentifier = processIdentifier
        self.startedAt = startedAt
    }
}

public struct PhoneControlCapabilities: Equatable, Sendable {
    public let supportsKeyEvents: Bool
    public let supportsRotation: Bool
    public let supportsScreenshots: Bool
    public let supportsScreenRecording: Bool
    public let supportsBatteryStatus: Bool

    public init(
        supportsKeyEvents: Bool,
        supportsRotation: Bool,
        supportsScreenshots: Bool,
        supportsScreenRecording: Bool,
        supportsBatteryStatus: Bool
    ) {
        self.supportsKeyEvents = supportsKeyEvents
        self.supportsRotation = supportsRotation
        self.supportsScreenshots = supportsScreenshots
        self.supportsScreenRecording = supportsScreenRecording
        self.supportsBatteryStatus = supportsBatteryStatus
    }

    static func detected(fromProbeOutput output: String) -> PhoneControlCapabilities {
        let commands = Set(
            output
                .split(whereSeparator: \Character.isWhitespace)
                .map { $0.lowercased() }
        )
        return PhoneControlCapabilities(
            supportsKeyEvents: commands.contains("input"),
            supportsRotation: commands.contains("settings"),
            supportsScreenshots: commands.contains("screencap"),
            supportsScreenRecording: commands.contains("screenrecord"),
            supportsBatteryStatus: commands.contains("dumpsys")
        )
    }
}

public enum PhoneControlCapabilityState: Equatable, Sendable {
    case checking
    case available(PhoneControlCapabilities)
    case unavailable
}

struct ArchiveCreationRequest: Identifiable, Hashable, Sendable {
    let id = UUID()
    let defaultName: String
}

public enum ToolSetupResumeAction: Sendable {
    case none
    case refreshDevices
    case phoneControl
}

public struct ToolSetupRequest: Identifiable, Sendable {
    public let id: UUID
    public let tool: ToolchainTool
    public let issue: String?
    public let resumeAction: ToolSetupResumeAction

    public init(
        id: UUID = UUID(),
        tool: ToolchainTool,
        issue: String? = nil,
        resumeAction: ToolSetupResumeAction = .none
    ) {
        self.id = id
        self.tool = tool
        self.issue = issue
        self.resumeAction = resumeAction
    }
}

public enum FileOperationError: LocalizedError {
    case noDevice
    case duplicateExists(String)
    case commandFailed(String)
    case moveCompletedWithRecoveryCopy(destination: String, recoveryPath: String, reason: String)
    case missingTool(String)
    case toolUnavailable(ToolchainTool, String)

    public var errorDescription: String? {
        switch self {
        case .noDevice: "No Android device is selected."
        case .duplicateExists(let path): "A file already exists at \(path)."
        case .commandFailed(let message): message
        case .moveCompletedWithRecoveryCopy(let destination, let recoveryPath, let reason):
            "The move to \(destination) completed, but the replaced item could not be removed. It is safe at \(recoveryPath). \(reason)"
        case .missingTool(let tool): "\(tool) is not installed or could not be found."
        case .toolUnavailable(let tool, let reason): "\(tool.title) could not be used. \(reason)"
        }
    }
}

enum RemoteFileNameValidator {
    static func validationMessage(for name: String) -> String? {
        if name.isEmpty {
            return "Enter a name."
        }
        if name == "." || name == ".." {
            return "Choose a different name."
        }
        if name.contains("/") {
            return "Names can't contain a slash."
        }
        if name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return "Names can't contain line breaks or control characters."
        }
        return nil
    }
}
