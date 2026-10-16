import AVFoundation
import CoreMedia
import RecorderCore

/// SPEC §5/§6 timeline audio lane: peak-extracts a project's mic track (else system) with
/// `AVAssetReader` into an in-memory cache, for drawing inside clip blocks mapped through
/// `TimeMap` (wired by the timeline view later).
/// // ponytail: computed on open, not cached on disk.
enum Waveform {
    /// Peaks per second of audio (SPEC: "min/max peaks at 200/s").
    static let peaksPerSecond = 200

    nonisolated(unsafe) private static var cache: [URL: [Float]] = [:]
    private static let cacheLock = NSLock()

    static func audioURL(in packageURL: URL, file: String) -> URL? {
        let root = packageURL.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(file).resolvingSymlinksInPath().standardizedFileURL
        guard !file.hasPrefix("/"), url.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// `mic.m4a` if the project package has one, else `system.m4a`, else `nil`.
    static func audioURL(in packageURL: URL) -> URL? {
        for name in ["mic.m4a", "system.m4a"] {
            if let url = audioURL(in: packageURL, file: name) { return url }
        }
        return nil
    }

    /// Peak (max absolute sample across channels) per `peaksPerSecond`-of-a-second bucket, for the
    /// whole duration of the audio file at `url`. Cached in memory per `url` for the process lifetime.
    static func peaks(for url: URL) async throws -> [Float] {
        if let cached = cacheLock.withLock({ cache[url] }) { return cached }
        let result = try await extractPeaks(from: url)
        cacheLock.withLock { cache[url] = result }
        return result
    }

    /// SPEC "Voice": silent source-time spans of the mic track (shared by the timeline hatching and Split at Pauses).
    static func silent(in url: URL) async -> [TimeRange] {
        let peaks = (try? await peaks(for: url)) ?? []
        return silentRanges(levels: peaks, perSecond: Double(peaksPerSecond))
    }

    private static func extractPeaks(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var peaks: [Float] = []
        var sampleRate = 0.0
        var channels = 1
        var bucketPeak: Float = 0
        var bucketFrames = 0
        var totalFrames = 0

        while let sampleBuffer = reader.status == .reading ? output.copyNextSampleBuffer() : nil {
            if sampleRate == 0,
               let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
                channels = max(1, Int(asbd.pointee.mChannelsPerFrame))
                sampleRate = max(Double(peaksPerSecond), asbd.pointee.mSampleRate)
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            let floatCount = byteCount / MemoryLayout<Float>.size
            var samples = [Float](repeating: 0, count: floatCount)
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: &samples)

            var frame = 0
            while frame < floatCount {
                var frameMax: Float = 0
                for c in 0..<channels where frame + c < floatCount { frameMax = max(frameMax, abs(samples[frame + c])) }
                bucketPeak = max(bucketPeak, frameMax)
                bucketFrames += 1
                totalFrames += 1
                frame += channels
                if Double(totalFrames) * Double(peaksPerSecond) >= Double(peaks.count + 1) * sampleRate {
                    peaks.append(bucketPeak)
                    bucketPeak = 0
                    bucketFrames = 0
                }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        if bucketFrames > 0 { peaks.append(bucketPeak) }
        return peaks
    }
}
