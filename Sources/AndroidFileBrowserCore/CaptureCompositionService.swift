import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SideBySideCaptureLayout: Equatable, Sendable {
    let renderSize: CGSize
    let frames: [CGRect]

    static func make(
        sourceSizes: [CGSize],
        maximumRenderSize: CGSize = CGSize(width: 3_840, height: 2_160),
        gutter: CGFloat = 8
    ) -> SideBySideCaptureLayout {
        let sizes = sourceSizes.map {
            CGSize(width: max(abs($0.width), 1), height: max(abs($0.height), 1))
        }
        guard !sizes.isEmpty else {
            return SideBySideCaptureLayout(renderSize: .zero, frames: [])
        }

        let cellWidth = sizes.map(\.width).max() ?? 1
        let cellHeight = sizes.map(\.height).max() ?? 1
        let baseWidth = cellWidth * CGFloat(sizes.count) + gutter * CGFloat(max(sizes.count - 1, 0))
        let scale = min(
            1,
            maximumRenderSize.width / baseWidth,
            maximumRenderSize.height / cellHeight
        )
        let renderWidth = evenPixel(baseWidth * scale)
        let renderHeight = evenPixel(cellHeight * scale)
        let scaledGutter = gutter * scale
        let scaledCellWidth = (renderWidth - scaledGutter * CGFloat(max(sizes.count - 1, 0)))
            / CGFloat(sizes.count)

        let frames = sizes.enumerated().map { index, size in
            let fitScale = min(scaledCellWidth / size.width, renderHeight / size.height)
            let fittedSize = CGSize(width: size.width * fitScale, height: size.height * fitScale)
            let cellOriginX = CGFloat(index) * (scaledCellWidth + scaledGutter)
            return CGRect(
                x: cellOriginX + (scaledCellWidth - fittedSize.width) / 2,
                y: (renderHeight - fittedSize.height) / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )
        }

        return SideBySideCaptureLayout(
            renderSize: CGSize(width: renderWidth, height: renderHeight),
            frames: frames
        )
    }

    private static func evenPixel(_ value: CGFloat) -> CGFloat {
        max(2, floor(value / 2) * 2)
    }
}

public struct CapturedVideoSource: Sendable {
    public let url: URL
    public let startedAt: Date
    public let startupTrim: TimeInterval
    public let requestedOutputSize: CGSize?

    public init(
        url: URL,
        startedAt: Date,
        startupTrim: TimeInterval = 0,
        requestedOutputSize: CGSize? = nil
    ) {
        self.url = url
        self.startedAt = startedAt
        self.startupTrim = max(0, startupTrim)
        self.requestedOutputSize = requestedOutputSize
    }
}

public struct CapturedAudioSource: Sendable {
    public let url: URL
    public let startedAt: Date

    public init(url: URL, startedAt: Date) {
        self.url = url
        self.startedAt = startedAt
    }
}

public actor CaptureCompositionService {
    public init() {}

    public func combineScreenshots(_ urls: [URL]) throws -> URL {
        guard urls.count > 1 else {
            guard let url = urls.first else { throw FileOperationError.commandFailed("No screenshots were captured.") }
            return url
        }

        let images = try urls.map { url -> CGImage in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw FileOperationError.commandFailed("A captured screenshot could not be opened.")
            }
            return image
        }
        let layout = SideBySideCaptureLayout.make(
            sourceSizes: images.map { CGSize(width: $0.width, height: $0.height) }
        )
        let width = Int(layout.renderSize.width)
        let height = Int(layout.renderSize.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FileOperationError.commandFailed("The side-by-side screenshot could not be created.")
        }

        context.setFillColor(CGColor.black)
        context.fill(CGRect(origin: .zero, size: layout.renderSize))
        context.interpolationQuality = .high
        for (image, frame) in zip(images, layout.frames) {
            context.draw(image, in: frame)
        }

        guard let outputImage = context.makeImage() else {
            throw FileOperationError.commandFailed("The side-by-side screenshot could not be finished.")
        }
        let outputURL = try captureOutputURL(prefix: "Screenshot-Side-by-Side", pathExtension: "png")
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw FileOperationError.commandFailed("The side-by-side screenshot could not be saved.")
        }
        CGImageDestinationAddImage(destination, outputImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FileOperationError.commandFailed("The side-by-side screenshot could not be saved.")
        }
        return outputURL
    }

    public func combineRecordings(
        _ sources: [CapturedVideoSource],
        supplementalAudio: [CapturedAudioSource] = []
    ) async throws -> URL {
        guard !sources.isEmpty else {
            throw FileOperationError.commandFailed("No recordings were captured.")
        }
        if sources.count == 1,
           supplementalAudio.isEmpty,
           sources[0].startupTrim == 0,
           sources[0].requestedOutputSize == nil {
            return sources[0].url
        }

        let assets = sources.map { AVURLAsset(url: $0.url) }
        let frameDuration = CMTime(value: 1, timescale: 30)
        let minimumTrimmedSourceDuration = CMTime(seconds: 2, preferredTimescale: 600)
        var videoTracks: [AVAssetTrack] = []
        var sourceRanges: [CMTimeRange] = []
        var sourceMediaDurations: [CMTime] = []
        var appliedTrimDurations: [CMTime] = []
        var orientedSizes: [CGSize] = []

        for (index, asset) in assets.enumerated() {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw FileOperationError.commandFailed("A captured recording did not contain video.")
            }
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            let rawRange = try await track.load(.timeRange)
            let assetDuration = try await asset.load(.duration)
            let requestedTrim = CMTime(
                seconds: sources[index].startupTrim,
                preferredTimescale: 600
            )
            let canTrim = CMTimeCompare(requestedTrim, .zero) > 0
                && CMTimeCompare(rawRange.duration, minimumTrimmedSourceDuration) > 0
                && CMTimeCompare(rawRange.duration, requestedTrim) > 0
            let trimDuration = canTrim ? requestedTrim : .zero

            videoTracks.append(track)
            appliedTrimDurations.append(trimDuration)
            sourceRanges.append(CMTimeRange(
                start: CMTimeAdd(rawRange.start, trimDuration),
                duration: CMTimeSubtract(rawRange.duration, trimDuration)
            ))
            let includedMediaDuration = CMTimeSubtract(
                CMTimeMaximum(assetDuration, CMTimeRangeGetEnd(rawRange)),
                CMTimeAdd(rawRange.start, trimDuration)
            )
            sourceMediaDurations.append(
                CMTimeMaximum(
                    CMTimeSubtract(rawRange.duration, trimDuration),
                    includedMediaDuration
                )
            )
            orientedSizes.append(CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height)))
        }

        let effectiveStartDates = sources.indices.map { index in
            sources[index].startedAt.addingTimeInterval(
                CMTimeGetSeconds(appliedTrimDurations[index])
            )
        }
        let timelineOrigin = effectiveStartDates.min() ?? Date()
        let startOffsets = effectiveStartDates.map {
            CMTime(
                seconds: max(0, $0.timeIntervalSince(timelineOrigin)),
                preferredTimescale: 600
            )
        }
        let timelineDuration = sourceRanges.indices.reduce(CMTime(seconds: 1, preferredTimescale: 600)) {
            partialResult, index in
            let duration = sourceMediaDurations[index]
            guard CMTimeCompare(duration, frameDuration) > 0 else { return partialResult }
            return CMTimeMaximum(partialResult, CMTimeAdd(startOffsets[index], duration))
        }

        let layoutSizes = sources.indices.map { index in
            sources[index].requestedOutputSize ?? orientedSizes[index]
        }
        let layout = SideBySideCaptureLayout.make(sourceSizes: layoutSizes)
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = layout.renderSize
        videoComposition.frameDuration = frameDuration
        var layerInstructions: [AVVideoCompositionLayerInstruction] = []
        var endTime = CMTime.zero

        for index in sources.indices {
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw FileOperationError.commandFailed("A video track could not be created.")
            }
            let sourceRange = sourceRanges[index]
            let startOffset = startOffsets[index]
            let holdsSingleFrame = CMTimeCompare(sourceRange.duration, frameDuration) <= 0
            let insertionRange = holdsSingleFrame
                ? CMTimeRange(start: sourceRange.start, duration: frameDuration)
                : sourceRange
            try compositionTrack.insertTimeRange(insertionRange, of: videoTracks[index], at: startOffset)

            let desiredDisplayedDuration = CMTimeMaximum(
                frameDuration,
                CMTimeSubtract(timelineDuration, startOffset)
            )
            let displayedDuration: CMTime
            if holdsSingleFrame {
                displayedDuration = desiredDisplayedDuration
                compositionTrack.scaleTimeRange(
                    CMTimeRange(start: startOffset, duration: frameDuration),
                    toDuration: displayedDuration
                )
            } else {
                let extensionDuration = CMTimeSubtract(
                    desiredDisplayedDuration,
                    sourceRange.duration
                )
                if CMTimeCompare(extensionDuration, .zero) > 0 {
                    let heldFrameDuration = CMTimeMinimum(
                        CMTime(seconds: 1, preferredTimescale: 600),
                        sourceRange.duration
                    )
                    var remainingDuration = extensionDuration
                    var insertionTime = CMTimeAdd(startOffset, sourceRange.duration)
                    while CMTimeCompare(remainingDuration, .zero) > 0 {
                        let repeatedDuration = CMTimeMinimum(heldFrameDuration, remainingDuration)
                        let heldFrameRange = CMTimeRange(
                            start: CMTimeSubtract(CMTimeRangeGetEnd(sourceRange), repeatedDuration),
                            duration: repeatedDuration
                        )
                        try compositionTrack.insertTimeRange(
                            heldFrameRange,
                            of: videoTracks[index],
                            at: insertionTime
                        )
                        insertionTime = CMTimeAdd(insertionTime, repeatedDuration)
                        remainingDuration = CMTimeSubtract(remainingDuration, repeatedDuration)
                    }
                }
                displayedDuration = desiredDisplayedDuration
            }
            endTime = CMTimeMaximum(endTime, CMTimeAdd(startOffset, displayedDuration))

            let preferredTransform = try await videoTracks[index].load(.preferredTransform)
            let naturalSize = try await videoTracks[index].load(.naturalSize)
            let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            let targetFrame = layout.frames[index]
            let normalized = preferredTransform.concatenating(
                CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY)
            )
            let fittedScale = min(
                targetFrame.width / max(orientedSizes[index].width, 1),
                targetFrame.height / max(orientedSizes[index].height, 1)
            )
            let fittedSize = CGSize(
                width: orientedSizes[index].width * fittedScale,
                height: orientedSizes[index].height * fittedScale
            )
            let fittedOrigin = CGPoint(
                x: targetFrame.minX + (targetFrame.width - fittedSize.width) / 2,
                y: targetFrame.minY + (targetFrame.height - fittedSize.height) / 2
            )
            let transform = normalized
                .concatenating(CGAffineTransform(scaleX: fittedScale, y: fittedScale))
                .concatenating(CGAffineTransform(
                    translationX: fittedOrigin.x,
                    y: fittedOrigin.y
                ))
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
            layerInstruction.setTransform(transform, at: startOffset)
            layerInstructions.append(layerInstruction)
        }

        var compositionAudioTracks: [AVMutableCompositionTrack] = []
        for index in sources.indices {
            let includedVideoRange = sourceRanges[index]
            let includedMediaEnd = CMTimeAdd(
                includedVideoRange.start,
                sourceMediaDurations[index]
            )
            for audioTrack in try await assets[index].loadTracks(withMediaType: .audio) {
                let rawAudioRange = try await audioTrack.load(.timeRange)
                let audioStart = CMTimeMaximum(rawAudioRange.start, includedVideoRange.start)
                let audioEnd = CMTimeMinimum(CMTimeRangeGetEnd(rawAudioRange), includedMediaEnd)
                let duration = CMTimeSubtract(audioEnd, audioStart)
                guard CMTimeCompare(duration, .zero) > 0,
                      let compositionTrack = composition.addMutableTrack(
                          withMediaType: .audio,
                          preferredTrackID: kCMPersistentTrackID_Invalid
                      ) else { continue }

                let relativeStart = CMTimeSubtract(audioStart, includedVideoRange.start)
                let insertionTime = CMTimeAdd(startOffsets[index], relativeStart)
                let availableTimelineDuration = CMTimeSubtract(endTime, insertionTime)
                let clippedDuration = CMTimeMinimum(duration, availableTimelineDuration)
                guard CMTimeCompare(clippedDuration, .zero) > 0 else { continue }
                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: audioStart, duration: clippedDuration),
                    of: audioTrack,
                    at: insertionTime
                )
                compositionAudioTracks.append(compositionTrack)
            }
        }

        var insertedSupplementalAudioCount = 0
        for source in supplementalAudio {
            let asset = AVURLAsset(url: source.url)
            for audioTrack in try await asset.loadTracks(withMediaType: .audio) {
                let rawRange = try await audioTrack.load(.timeRange)
                let hostOffset = source.startedAt.timeIntervalSince(timelineOrigin)
                let trimSeconds = max(0, -hostOffset)
                let insertionTime = CMTime(
                    seconds: max(0, hostOffset),
                    preferredTimescale: 600
                )
                let sourceStart = CMTimeAdd(
                    rawRange.start,
                    CMTime(seconds: trimSeconds, preferredTimescale: 600)
                )
                let availableSourceDuration = CMTimeSubtract(CMTimeRangeGetEnd(rawRange), sourceStart)
                let availableTimelineDuration = CMTimeSubtract(endTime, insertionTime)
                let duration = CMTimeMinimum(availableSourceDuration, availableTimelineDuration)
                guard CMTimeCompare(duration, .zero) > 0,
                      let compositionTrack = composition.addMutableTrack(
                          withMediaType: .audio,
                          preferredTrackID: kCMPersistentTrackID_Invalid
                      ) else { continue }

                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: sourceStart, duration: duration),
                    of: audioTrack,
                    at: insertionTime
                )
                compositionAudioTracks.append(compositionTrack)
                insertedSupplementalAudioCount += 1
            }
        }
        if !supplementalAudio.isEmpty, insertedSupplementalAudioCount == 0 {
            throw FileOperationError.commandFailed("The Mac microphone recording did not contain usable audio.")
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: endTime)
        instruction.backgroundColor = CGColor.black
        instruction.layerInstructions = layerInstructions.reversed()
        videoComposition.instructions = [instruction]

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw FileOperationError.commandFailed("The recording could not be prepared.")
        }
        exporter.videoComposition = videoComposition
        if !compositionAudioTracks.isEmpty {
            let gain = 1 / Float(compositionAudioTracks.count)
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = compositionAudioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(gain, at: .zero)
                return parameters
            }
            exporter.audioMix = audioMix
        }

        let outputPrefix = if sources.count > 1 {
            "Recording-Side-by-Side"
        } else if compositionAudioTracks.isEmpty {
            "Recording"
        } else {
            "Recording-With-Audio"
        }
        let outputURL = try captureOutputURL(prefix: outputPrefix, pathExtension: "mp4")
        do {
            try await exporter.export(to: outputURL, as: .mp4)
            let outputAsset = AVURLAsset(url: outputURL)
            guard !(try await outputAsset.loadTracks(withMediaType: .video)).isEmpty else {
                throw FileOperationError.commandFailed("The finished recording did not contain video.")
            }
            if !compositionAudioTracks.isEmpty,
               (try await outputAsset.loadTracks(withMediaType: .audio)).isEmpty {
                throw FileOperationError.commandFailed("The finished recording did not contain the selected audio.")
            }
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func captureOutputURL(prefix: String, pathExtension: String) throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "AndroidFileBrowserCaptures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        return directory.appending(path: "\(prefix)-\(formatter.string(from: Date())).\(pathExtension)")
    }
}
