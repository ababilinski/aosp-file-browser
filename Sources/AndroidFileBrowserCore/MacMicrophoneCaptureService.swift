import AVFoundation
import Foundation

public enum MacMicrophoneCaptureError: LocalizedError, Sendable {
    case permissionDenied
    case permissionRestricted
    case inputUnavailable
    case preparationFailed(String)
    case recordingCouldNotStart
    case recordingFileUnavailable

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone access is off. Allow AOSP File Manager to use the microphone in System Settings > Privacy & Security > Microphone, then try again."
        case .permissionRestricted:
            "Microphone access is restricted on this Mac."
        case .inputUnavailable:
            "No microphone is available on this Mac. Connect or enable an audio input, then try again."
        case .preparationFailed(let reason):
            "The Mac microphone could not be prepared. \(reason)"
        case .recordingCouldNotStart:
            "The Mac microphone could not start recording. Make sure another app is not preventing access, then try again."
        case .recordingFileUnavailable:
            "The Mac microphone recording could not be saved."
        }
    }
}

public final class MacMicrophoneCaptureHandle: @unchecked Sendable {
    public let localURL: URL
    public let startedAt: Date

    private enum State {
        case recording
        case stopped
        case cleanedUp
    }

    private let recorder: AVAudioRecorder
    private let lock = NSLock()
    private var state: State = .recording

    fileprivate init(localURL: URL, startedAt: Date, recorder: AVAudioRecorder) {
        self.localURL = localURL
        self.startedAt = startedAt
        self.recorder = recorder
    }

    deinit {
        stop()
    }

    public var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .recording && recorder.isRecording
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    @discardableResult
    public func finalize() throws -> URL {
        lock.lock()
        stopLocked()
        let wasCleanedUp = state == .cleanedUp
        lock.unlock()

        guard !wasCleanedUp,
              FileManager.default.fileExists(atPath: localURL.path),
              ((try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
            throw MacMicrophoneCaptureError.recordingFileUnavailable
        }
        return localURL
    }

    public func cleanup() {
        lock.lock()
        stopLocked()
        guard state != .cleanedUp else {
            lock.unlock()
            return
        }
        state = .cleanedUp
        lock.unlock()

        try? FileManager.default.removeItem(at: localURL)
    }

    private func stopLocked() {
        guard state == .recording else { return }
        recorder.stop()
        state = .stopped
    }
}

public struct MacMicrophoneCaptureService: Sendable {
    public init() {}

    public static var defaultInputName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    public func start() async throws -> MacMicrophoneCaptureHandle {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw MacMicrophoneCaptureError.inputUnavailable
        }
        try await authorizeMicrophoneAccess()

        let outputURL = try makeOutputURL()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw MacMicrophoneCaptureError.preparationFailed(error.localizedDescription)
        }

        guard recorder.prepareToRecord() else {
            try? FileManager.default.removeItem(at: outputURL)
            throw MacMicrophoneCaptureError.preparationFailed("macOS could not prepare the selected audio input.")
        }
        guard recorder.record() else {
            recorder.stop()
            try? FileManager.default.removeItem(at: outputURL)
            throw MacMicrophoneCaptureError.recordingCouldNotStart
        }

        return MacMicrophoneCaptureHandle(
            localURL: outputURL,
            startedAt: Date(),
            recorder: recorder
        )
    }

    private func authorizeMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                throw MacMicrophoneCaptureError.permissionDenied
            }
        case .denied:
            throw MacMicrophoneCaptureError.permissionDenied
        case .restricted:
            throw MacMicrophoneCaptureError.permissionRestricted
        @unknown default:
            throw MacMicrophoneCaptureError.permissionDenied
        }
    }

    private func makeOutputURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "AndroidFileBrowserCaptures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "Mac-Microphone-\(UUID().uuidString).m4a")
    }
}
