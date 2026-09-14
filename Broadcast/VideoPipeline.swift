import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Downscales ReplayKit's full-resolution screen buffers and encodes them to H.264.
///
/// Everything here is chosen to stay well under the broadcast extension's ~50 MB memory
/// cap: `VTPixelTransferSession` does the scaling on the hardware scaler rather than
/// going through Core Image, and the destination buffers come from the compression
/// session's own pool so no extra allocation happens per frame.
final class VideoPipeline {
    /// Encoded access unit, whether it was a keyframe, its rotation, and its timestamp.
    var onEncodedFrame: ((Data, Bool, Wire.Rotation, CMTime) -> Void)?

    private(set) var settings: MirrorSettings
    private(set) var outputWidth = 0
    private(set) var outputHeight = 0

    private var transferSession: VTPixelTransferSession?
    private var compressionSession: VTCompressionSession?
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var lastEncodedTime: CMTime = .invalid
    private var forceKeyframe = false

    init(settings: MirrorSettings = .default) {
        self.settings = settings
    }

    deinit { teardown() }

    // MARK: - Configuration

    func update(settings newSettings: MirrorSettings) {
        let sanitized = newSettings.sanitized()
        guard sanitized != settings else { return }
        settings = sanitized
        // Resolution changes need a new session; bitrate and frame rate can be set live.
        teardown()
    }

    /// Forces the next encoded frame to be a keyframe. Called when a viewer joins so it
    /// does not have to wait up to the full keyframe interval for a decodable picture.
    func requestKeyframe() {
        forceKeyframe = true
    }

    // MARK: - Encoding

    func encode(_ sampleBuffer: CMSampleBuffer, rotation: Wire.Rotation) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Rotating the device swaps the buffer dimensions, which the encoder cannot absorb.
        if width != sourceWidth || height != sourceHeight || compressionSession == nil {
            teardown()
            guard prepare(sourceWidth: width, sourceHeight: height) else { return }
        }

        // Drop frames above the target rate before doing any work on them.
        if lastEncodedTime.isValid {
            let elapsed = CMTimeSubtract(presentationTime, lastEncodedTime).seconds
            let minimumInterval = 1.0 / Double(settings.fps)
            // Allow a small tolerance so a 60 Hz source cleanly halves to 30 fps rather
            // than landing just under the threshold and dropping every other frame twice.
            guard elapsed >= minimumInterval * 0.9 else { return }
        }

        guard let compressionSession,
              let transferSession,
              let pool = VTCompressionSessionGetPixelBufferPool(compressionSession)
        else { return }

        var scaledBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &scaledBuffer) == kCVReturnSuccess,
              let scaledBuffer
        else { return }

        guard VTPixelTransferSessionTransferImage(transferSession, from: pixelBuffer, to: scaledBuffer) == noErr
        else { return }

        lastEncodedTime = presentationTime

        var properties: CFDictionary?
        if forceKeyframe {
            forceKeyframe = false
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: scaledBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard let self, status == noErr, let encoded,
                  CMSampleBufferDataIsReady(encoded),
                  let accessUnit = AnnexB.accessUnit(from: encoded)
            else { return }
            // Captured per frame, so a frame encoded across a rotation still carries the
            // orientation it was captured with.
            self.onEncodedFrame?(
                accessUnit,
                AnnexB.isKeyframe(encoded),
                rotation,
                CMSampleBufferGetPresentationTimeStamp(encoded)
            )
        }
    }

    // MARK: - Session setup

    private func prepare(sourceWidth: Int, sourceHeight: Int) -> Bool {
        guard sourceWidth > 0, sourceHeight > 0 else { return false }
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight

        let (targetWidth, targetHeight) = Self.targetSize(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight, longEdge: settings.longEdge
        )
        outputWidth = targetWidth
        outputHeight = targetHeight

        var transfer: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer) == noErr,
              let transfer
        else { return false }
        // Letterbox rather than stretch: the target size is derived from the source aspect,
        // so the two agree to within a pixel and this only guards against rounding.
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        // Averaging matters when shrinking a Retina screen by 3x — nearest-neighbour makes
        // small UI text in a camera app unreadable, which is the whole point of the preview.
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DownsamplingMode, value: kVTDownsamplingMode_Average)
        transferSession = transfer

        var compression: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(targetWidth),
            height: Int32(targetHeight),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, // Using the block-based encode call instead.
            refcon: nil,
            compressionSessionOut: &compression
        )
        guard status == noErr, let compression else { return false }

        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // Main profile compresses screen content noticeably better than Baseline at the
        // same bitrate; frame reordering stays off because B-frames would add a frame of
        // latency for no benefit here.
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: settings.fps * 2))
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: settings.fps))
        VTSessionSetProperty(compression, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: settings.bitrateKbps * 1000))
        // A hard one-second ceiling at 1.5x the average keeps a sudden scene change from
        // bursting far enough to blow past the congestion threshold on the socket.
        let byteLimit = settings.bitrateKbps * 1000 / 8 * 3 / 2
        VTSessionSetProperty(
            compression,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: [NSNumber(value: byteLimit), NSNumber(value: 1)] as CFArray
        )
        VTCompressionSessionPrepareToEncodeFrames(compression)

        compressionSession = compression
        lastEncodedTime = .invalid
        forceKeyframe = true
        return true
    }

    private func teardown() {
        if let compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compressionSession)
        }
        compressionSession = nil
        transferSession = nil
        sourceWidth = 0
        sourceHeight = 0
        lastEncodedTime = .invalid
    }

    /// Scales the long edge down to the target, preserving aspect ratio and keeping both
    /// dimensions even as the encoder requires for 4:2:0 chroma.
    static func targetSize(sourceWidth: Int, sourceHeight: Int, longEdge: Int) -> (Int, Int) {
        let longest = max(sourceWidth, sourceHeight)
        let scale = longest > longEdge ? Double(longEdge) / Double(longest) : 1.0
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(Double(sourceWidth) * scale), even(Double(sourceHeight) * scale))
    }
}
