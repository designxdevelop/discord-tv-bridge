import Foundation
import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

/// Feeds ScreenCaptureKit window video and application audio into the publisher. Callbacks arrive on `queue`.
final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.designxdevelop.tvbridge.capture", qos: .userInteractive)
    private let publisher: Publisher
    private let onFailure: @Sendable (String) -> Void

    init(publisher: Publisher, onFailure: @escaping @Sendable (String) -> Void) {
        self.publisher = publisher
        self.onFailure = onFailure
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let pixels = sampleBuffer.imageBuffer else { return }
            publisher.push(pixels)
        case .audio:
            publisher.audio.enqueue(Self.monoSamples(sampleBuffer))
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) { onFailure(error.localizedDescription) }

    /// ScreenCaptureKit delivers 48 kHz Float32 (normally planar stereo, as configured below).
    static func monoSamples(_ sampleBuffer: CMSampleBuffer) -> [Int16] {
        guard let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, Int(format.mSampleRate) == PCMAudioDevice.sampleRate else { return [] }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? Int(format.mChannelsPerFrame) : 1
        return (try? sampleBuffer.withAudioBufferList { list, _ in
            let channels = list.map { buffer in
                UnsafeBufferPointer(start: buffer.mData?.assumingMemoryBound(to: Float.self),
                                    count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            }
            return AudioConversion.monoInt16(channels: channels, interleaved: interleaved)
        }) ?? []
    }
}

/// Window video in one stream; audio in a second stream scoped to the window's app *and its helpers*
/// (Discord plays audio from "Discord Helper" processes, which a window filter would miss).
@MainActor
final class WindowCapture {
    private var streams: [SCStream] = []

    func start(window: SCWindow, content: SCShareableContent, output: CaptureOutput) async throws {
        let scale = NSScreen.screens.first { $0.frame.intersects(window.frame) }?.backingScaleFactor ?? 2
        let width = min(1920, Int(window.frame.width * scale)) / 2 * 2
        let height = max(2, Int(Double(width) * window.frame.height / max(window.frame.width, 1)) / 2 * 2)

        let video = SCStreamConfiguration()
        video.width = width
        video.height = height
        video.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        video.queueDepth = 5
        video.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // what VideoToolbox encodes natively
        video.showsCursor = false
        let videoStream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: video, delegate: output)
        try videoStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)

        let owner = window.owningApplication
        let ownerPath = owner.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.bundleURL?.path }
        let apps = content.applications.filter { app in
            AudioScope.includes(bundleID: app.bundleIdentifier,
                                bundlePath: NSRunningApplication(processIdentifier: app.processID)?.bundleURL?.path,
                                ownerID: owner?.bundleIdentifier ?? "", ownerPath: ownerPath)
        }
        guard let display = content.displays.first, !apps.isEmpty else { throw CaptureError.noAudioSource }
        let audio = SCStreamConfiguration()
        audio.capturesAudio = true
        audio.sampleRate = PCMAudioDevice.sampleRate
        audio.channelCount = 2
        audio.excludesCurrentProcessAudio = true
        audio.width = 2  // video from this stream is ignored; keep it tiny and slow
        audio.height = 2
        audio.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let audioStream = SCStream(filter: SCContentFilter(display: display, including: apps, exceptingWindows: []),
                                   configuration: audio, delegate: output)
        try audioStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)

        streams = [videoStream, audioStream]
        try await videoStream.startCapture()
        try await audioStream.startCapture()
    }

    func stop() async {
        for stream in streams { try? await stream.stopCapture() }
        streams = []
    }

    enum CaptureError: LocalizedError {
        case noAudioSource
        var errorDescription: String? { "Could not find the selected window's app for audio capture. Refresh and try again." }
    }
}

/// Deterministic test source: moving picture with a frame counter and a 440 Hz tone, at 30 fps.
final class DemoFeeder: @unchecked Sendable {
    private let timer: DispatchSourceTimer

    init(publisher: Publisher) {
        let pool = DemoPattern.makePool()
        var index = 0
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.designxdevelop.tvbridge.demo", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(1))
        timer.setEventHandler {
            if let pool, let frame = DemoPattern.frame(index & 0xFFFF, pool: pool) { publisher.push(frame) }
            publisher.audio.enqueue(DemoPattern.tone(startingAt: index * 1_600, count: 1_600))
            index += 1
        }
        timer.resume()
    }

    func stop() { timer.cancel() }
}
