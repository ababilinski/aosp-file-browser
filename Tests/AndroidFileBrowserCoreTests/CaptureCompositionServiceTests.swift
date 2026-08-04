import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AndroidFileBrowserCore

final class CaptureCompositionServiceTests: XCTestCase {
    func testSideBySideLayoutAspectFitsDifferentDisplayShapesWithBlackSpace() {
        let layout = SideBySideCaptureLayout.make(sourceSizes: [
            CGSize(width: 40, height: 80),
            CGSize(width: 80, height: 40)
        ])

        XCTAssertEqual(layout.renderSize, CGSize(width: 168, height: 80))
        XCTAssertEqual(layout.frames.count, 2)
        XCTAssertEqual(layout.frames[0], CGRect(x: 20, y: 0, width: 40, height: 80))
        XCTAssertEqual(layout.frames[1], CGRect(x: 88, y: 20, width: 80, height: 40))
        XCTAssertLessThan(layout.frames[0].maxX, layout.frames[1].minX)
    }

    func testSideBySideLayoutStaysWithinExportLimitAndUsesEvenPixels() {
        let layout = SideBySideCaptureLayout.make(sourceSizes: [
            CGSize(width: 1_080, height: 2_400),
            CGSize(width: 2_560, height: 1_440),
            CGSize(width: 1_440, height: 2_560)
        ])

        XCTAssertLessThanOrEqual(layout.renderSize.width, 3_840)
        XCTAssertLessThanOrEqual(layout.renderSize.height, 2_160)
        XCTAssertEqual(Int(layout.renderSize.width) % 2, 0)
        XCTAssertEqual(Int(layout.renderSize.height) % 2, 0)
        XCTAssertEqual(layout.frames.count, 3)
    }

    func testCombiningScreenshotsWritesOneImageWithBlackPaddingAndGutter() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptureCompositionServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let portraitURL = directory.appending(path: "portrait.png")
        let landscapeURL = directory.appending(path: "landscape.png")
        try writeSolidImage(size: CGSize(width: 40, height: 80), color: CGColor(red: 1, green: 0, blue: 0, alpha: 1), to: portraitURL)
        try writeSolidImage(size: CGSize(width: 80, height: 40), color: CGColor(red: 0, green: 1, blue: 0, alpha: 1), to: landscapeURL)

        let outputURL = try await CaptureCompositionService().combineScreenshots([portraitURL, landscapeURL])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let providerData = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(providerData) else {
            return XCTFail("Combined screenshot could not be decoded.")
        }
        XCTAssertEqual(image.width, 168)
        XCTAssertEqual(image.height, 80)

        let gutterOffset = 40 * image.bytesPerRow + 84 * 4
        XCTAssertEqual(bytes[gutterOffset], 0)
        XCTAssertEqual(bytes[gutterOffset + 1], 0)
        XCTAssertEqual(bytes[gutterOffset + 2], 0)
    }

    func testCombiningRecordingsExportsOneSideBySideVideo() async throws {
        try requireLocalVideoExportSupport()

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptureCompositionVideoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let portraitURL = directory.appending(path: "portrait.mov")
        let landscapeURL = directory.appending(path: "landscape.mov")
        try await writeSolidVideo(
            size: CGSize(width: 40, height: 80),
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            to: portraitURL
        )
        try await writeSolidVideo(
            size: CGSize(width: 80, height: 40),
            color: CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            to: landscapeURL
        )

        let startedAt = Date()
        let outputURL = try await CaptureCompositionService().combineRecordings([
            CapturedVideoSource(url: portraitURL, startedAt: startedAt),
            CapturedVideoSource(url: landscapeURL, startedAt: startedAt.addingTimeInterval(0.1))
        ])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let naturalSize = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(naturalSize, CGSize(width: 168, height: 80))
        XCTAssertGreaterThan(duration.seconds, 0.5)
    }

    func testCombiningRecordingsHoldsSingleFrameSourceForTimeline() async throws {
        try requireLocalVideoExportSupport()

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptureCompositionStaticVideoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let movingURL = directory.appending(path: "moving.mov")
        let singleFrameURL = directory.appending(path: "single-frame.mov")
        try await writeSolidVideo(
            size: CGSize(width: 40, height: 80),
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            to: movingURL
        )
        try await writeSolidVideo(
            size: CGSize(width: 80, height: 80),
            color: CGColor.black,
            frameCount: 1,
            to: singleFrameURL
        )

        let startedAt = Date()
        let outputURL = try await CaptureCompositionService().combineRecordings([
            CapturedVideoSource(url: movingURL, startedAt: startedAt),
            CapturedVideoSource(url: singleFrameURL, startedAt: startedAt)
        ])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.5)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let tenthFrameTime = CMTime(value: 9, timescale: 30)
        let tenthFrame = try await generator.image(at: tenthFrameTime).image
        XCTAssertGreaterThan(tenthFrame.width, 0)
        XCTAssertGreaterThan(tenthFrame.height, 0)
    }

    func testCombiningRecordingsAppliesStartupTrimBeforeTenthFrame() async throws {
        try requireLocalVideoExportSupport()

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptureCompositionWarmupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let warmingURL = directory.appending(path: "warming.mov")
        let staticURL = directory.appending(path: "static.mov")
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        try await writeVideo(
            size: CGSize(width: 40, height: 80),
            colors: Array(repeating: CGColor.black, count: 8) + Array(repeating: red, count: 30),
            to: warmingURL
        )
        try await writeSolidVideo(
            size: CGSize(width: 80, height: 80),
            color: CGColor.black,
            frameCount: 30,
            to: staticURL
        )

        let startedAt = Date()
        let outputURL = try await CaptureCompositionService().combineRecordings([
            CapturedVideoSource(url: warmingURL, startedAt: startedAt, startupTrim: 0.75),
            CapturedVideoSource(url: staticURL, startedAt: startedAt, startupTrim: 0.75)
        ])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let tenthFrame = try await generator.image(at: CMTime(value: 9, timescale: 30)).image
        let pixel = try pixelRGBA(in: tenthFrame, x: 40, y: 40)
        XCTAssertGreaterThan(pixel[0], 180)
        XCTAssertLessThan(pixel[1], 60)
        XCTAssertLessThan(pixel[2], 60)
    }

    func testShortSourceUsesActualZeroTrimForTimelineAndStillHoldsItsFrame() async throws {
        try requireLocalVideoExportSupport()

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptureCompositionShortTrimTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let singleFrameURL = directory.appending(path: "single-frame.mov")
        let timelineURL = directory.appending(path: "timeline.mov")
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        try await writeSolidVideo(
            size: CGSize(width: 80, height: 80),
            color: red,
            frameCount: 1,
            to: singleFrameURL
        )
        try await writeSolidVideo(
            size: CGSize(width: 80, height: 80),
            color: CGColor.black,
            to: timelineURL
        )

        let startedAt = Date()
        let outputURL = try await CaptureCompositionService().combineRecordings([
            CapturedVideoSource(
                url: singleFrameURL,
                startedAt: startedAt,
                startupTrim: 0.75
            ),
            CapturedVideoSource(url: timelineURL, startedAt: startedAt)
        ])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(value: 9, timescale: 30)).image
        let pixel = try pixelRGBA(in: frame, x: 40, y: 40)
        XCTAssertGreaterThan(pixel[0], 180)
        XCTAssertLessThan(pixel[1], 60)
        XCTAssertLessThan(pixel[2], 60)
    }

    func testSingleRecordingUsesExactRequestedOutputSizeAndCentersContent() async throws {
        try requireLocalVideoExportSupport()

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptureCompositionOutputSizeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoURL = directory.appending(path: "portrait.mov")
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        try await writeSolidVideo(
            size: CGSize(width: 40, height: 80),
            color: red,
            to: videoURL
        )

        let outputURL = try await CaptureCompositionService().combineRecordings([
            CapturedVideoSource(
                url: videoURL,
                startedAt: Date(),
                requestedOutputSize: CGSize(width: 160, height: 90)
            )
        ])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        XCTAssertNotEqual(outputURL, videoURL)
        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let naturalSize = try await track.load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: 160, height: 90))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(value: 1, timescale: 10)).image
        let centerPixel = try pixelRGBA(in: frame, x: 80, y: 45)
        let pillarboxPixel = try pixelRGBA(in: frame, x: 10, y: 45)
        XCTAssertGreaterThan(centerPixel[0], 180)
        XCTAssertLessThan(centerPixel[1], 60)
        XCTAssertLessThan(centerPixel[2], 60)
        XCTAssertLessThan(pillarboxPixel[0], 40)
        XCTAssertLessThan(pillarboxPixel[1], 40)
        XCTAssertLessThan(pillarboxPixel[2], 40)
    }

    func testCombiningOneRecordingWithSupplementalAudioExportsAnAudioTrack() async throws {
        try requireLocalVideoExportSupport()

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptureCompositionAudioTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoURL = directory.appending(path: "video.mov")
        let audioURL = directory.appending(path: "mac-microphone.caf")
        try await writeSolidVideo(
            size: CGSize(width: 80, height: 80),
            color: CGColor.black,
            to: videoURL
        )
        try writeTone(to: audioURL)

        let startedAt = Date()
        let outputURL = try await CaptureCompositionService().combineRecordings(
            [CapturedVideoSource(
                url: videoURL,
                startedAt: startedAt,
                requestedOutputSize: CGSize(width: 160, height: 90)
            )],
            supplementalAudio: [CapturedAudioSource(url: audioURL, startedAt: startedAt)]
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let naturalSize = try await videoTrack.load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: 160, height: 90))
    }

    func testEmbeddedAudioOutlastingEncodedVideoKeepsFullRecordingDuration() async throws {
        try requireLocalVideoExportSupport()

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptureCompositionLongAudioTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoURL = directory.appending(path: "short-video.mov")
        let audioURL = directory.appending(path: "long-audio.caf")
        let sourceURL = directory.appending(path: "source.mov")
        try await writeSolidVideo(
            size: CGSize(width: 80, height: 80),
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            to: videoURL
        )
        try writeTone(to: audioURL, durationSeconds: 3)
        try await mux(videoURL: videoURL, audioURL: audioURL, to: sourceURL)

        let outputURL = try await CaptureCompositionService().combineRecordings([
            CapturedVideoSource(
                url: sourceURL,
                startedAt: Date(),
                requestedOutputSize: CGSize(width: 160, height: 90)
            )
        ])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertGreaterThan(duration.seconds, 2.5)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertEqual(videoTracks.count, 1)
    }

    private func writeSolidImage(size: CGSize, color: CGColor, to url: URL) throws {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(color)
        context.fill(CGRect(origin: .zero, size: size))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func writeTone(to url: URL, durationSeconds: Int = 1) throws {
        let frameCount = 48_000 * max(durationSeconds, 1)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let samples = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = 0.2 * sin(2 * .pi * 440 * Float(frame) / 48_000)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func mux(videoURL: URL, audioURL: URL, to outputURL: URL) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()
        guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ),
              let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try videoTrack.insertTimeRange(
            try await sourceVideoTrack.load(.timeRange),
            of: sourceVideoTrack,
            at: .zero
        )
        try audioTrack.insertTimeRange(
            try await sourceAudioTrack.load(.timeRange),
            of: sourceAudioTrack,
            at: .zero
        )
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await exporter.export(to: outputURL, as: .mov)
    }

    private func requireLocalVideoExportSupport() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
            "AVFoundation video export requires a physical Mac graphics stack and crashes on headless GitHub runners."
        )
    }

    private func writeSolidVideo(size: CGSize, color: CGColor, to url: URL) async throws {
        try await writeSolidVideo(size: size, color: color, frameCount: 10, to: url)
    }

    private func writeSolidVideo(
        size: CGSize,
        color: CGColor,
        frameCount: Int,
        to url: URL
    ) async throws {
        try await writeVideo(
            size: size,
            colors: Array(repeating: color, count: frameCount),
            to: url
        )
    }

    private func writeVideo(size: CGSize, colors: [CGColor], to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.jpeg,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        for (frameIndex, color) in colors.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                  let buffer = optionalBuffer else {
                throw CocoaError(.fileWriteUnknown)
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw CocoaError(.fileWriteUnknown)
            }
            context.setFillColor(color)
            context.fill(CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: 10)
            ) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    private func pixelRGBA(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        context.draw(
            image,
            in: CGRect(x: -x, y: -y, width: image.width, height: image.height)
        )
        return pixel
    }
}
