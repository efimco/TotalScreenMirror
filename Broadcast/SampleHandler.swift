import CoreMedia
import Foundation
import ReplayKit
import UIKit

/// Entry point for the broadcast upload extension.
///
/// This process is the only one alive during a broadcast — the container app is not
/// running — so the server, the encoder and the connection state all live here.
class SampleHandler: RPBroadcastSampleHandler {
    private let server = WebSocketServer()
    private let pipeline = VideoPipeline()

    private var broadcastStart: CMTime = .invalid

    /// Written from the server queue and read from ReplayKit's capture queue, so it needs
    /// a lock. Caching it here rather than calling into the server keeps the capture
    /// callback from ever blocking behind a socket write.
    private let viewerLock = NSLock()
    private var viewerCount = 0
    private var hasViewers: Bool {
        viewerLock.lock()
        defer { viewerLock.unlock() }
        return viewerCount > 0
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        pipeline.onEncodedFrame = { [weak self] accessUnit, isKeyframe, rotation, presentationTime in
            self?.publish(
                accessUnit, isKeyframe: isKeyframe, rotation: rotation, presentationTime: presentationTime
            )
        }

        server.onClientCountChanged = { [weak self] count in
            guard let self else { return }
            self.viewerLock.lock()
            self.viewerCount = count
            self.viewerLock.unlock()
            guard count > 0 else { return }
            // A viewer that just joined has no parameter sets yet, so start it off with a
            // keyframe instead of making it wait out the interval on a black screen.
            self.pipeline.requestKeyframe()
            self.sendHello()
        }

        server.onControlMessage = { [weak self] data in
            self?.handleControlMessage(data)
        }

        // Reported as a visible broadcast error rather than left to hang: a listener that
        // fails after start produces no crash and no log, so without this the broadcast
        // just spins forever with nothing to diagnose.
        server.onFailure = { [weak self] reason in
            self?.finishBroadcastWithError(NSError(
                domain: "TotalScreenMirror",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: reason]
            ))
        }

        do {
            try server.start(serviceName: UIDevice.current.name)
        } catch {
            finishBroadcastWithError(NSError(
                domain: "TotalScreenMirror",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Could not start the mirror server on port \(WebSocketServer.defaultPort): "
                    + "\(error.localizedDescription)"]
            ))
        }
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {
        pipeline.requestKeyframe()
    }

    override func broadcastFinished() {
        server.stop()
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard sampleBufferType == .video else { return }
        // No point heating the phone up encoding for nobody — this runs alongside a camera
        // app that needs the thermal headroom more than we do.
        guard hasViewers else { return }

        if !broadcastStart.isValid {
            broadcastStart = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }
        pipeline.encode(sampleBuffer, rotation: Self.rotation(of: sampleBuffer))
    }

    // MARK: - Wire

    /// ReplayKit keeps delivering buffers in the display's native orientation and reports
    /// the current rotation as an attachment, so this is what tells a viewer which way up
    /// the picture belongs. On iOS versions where the buffer dimensions swap instead, the
    /// attachment stays `.up` and the encoder rebuild handles it — both paths work.
    private static func rotation(of sampleBuffer: CMSampleBuffer) -> Wire.Rotation {
        guard let attachment = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber, let orientation = CGImagePropertyOrientation(rawValue: attachment.uint32Value)
        else { return .none }

        // CGImagePropertyOrientation describes where the source's first row and column
        // ended up, which is the inverse of the turn a viewer has to apply. Verified
        // against the device: `.right` needs three quarter turns clockwise, not one.
        switch orientation {
        case .up: return .none
        case .down: return .half
        case .right: return .threeQuarter
        case .left: return .quarter
        default: return .none
        }
    }

    private func publish(
        _ accessUnit: Data, isKeyframe: Bool, rotation: Wire.Rotation, presentationTime: CMTime
    ) {
        var flags: Wire.Flags = []
        if isKeyframe { flags.insert(.keyframe) }

        let elapsed = broadcastStart.isValid
            ? CMTimeSubtract(presentationTime, broadcastStart).seconds
            : 0
        let header = Wire.Header(
            type: .h264AccessUnit,
            flags: flags,
            rotation: rotation,
            timestampMs: UInt32(truncatingIfNeeded: Int(max(0, elapsed) * 1000))
        )

        var message = Wire.encodeHeader(header)
        message.append(accessUnit)
        server.broadcast(binary: message)
    }

    private func sendHello() {
        let hello = ControlMessage.Hello(
            width: pipeline.outputWidth,
            height: pipeline.outputHeight,
            settings: pipeline.settings,
            deviceName: UIDevice.current.name
        )
        if let data = ControlMessage.encode(hello, kind: "hello") {
            server.broadcast(text: data)
        }
    }

    private func handleControlMessage(_ data: Data) {
        struct Envelope: Decodable {
            let kind: String
            let body: ControlMessage.Configure
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.kind == "configure"
        else { return }
        pipeline.update(settings: envelope.body.settings)
        sendHello()
    }
}
