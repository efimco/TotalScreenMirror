import AVFoundation
import SwiftUI
import UIKit

/// Hosts an `AVSampleBufferDisplayLayer` for SwiftUI.
///
/// Frames are enqueued with `DisplayImmediately` set rather than scheduled against a
/// timebase: a monitor wants the newest frame on screen now, not a smoothly paced
/// playback of a stream that may be arriving unevenly over Wi-Fi.
final class SampleBufferView: UIView {
    /// A sublayer rather than the view's backing layer, because rotating a view's own
    /// backing layer fights UIKit's frame management. As a sublayer its bounds, position
    /// and transform are ours to set outright.
    private let displayLayer = AVSampleBufferDisplayLayer()

    /// How far to turn the picture so it appears upright, from the sender's frame header.
    var rotationDegrees = 0 {
        didSet { if oldValue != rotationDegrees { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Implicit animations would make every rotation and every viewer resize visibly
        // slide, which reads as lag on a monitor.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.transform = CATransform3DIdentity

        // A quarter turn swaps which of our edges the video has to fit, so the layer is
        // laid out in the pre-rotation orientation and then turned about its centre.
        let swapped = rotationDegrees % 180 != 0
        displayLayer.bounds = CGRect(
            origin: .zero,
            size: swapped
                ? CGSize(width: bounds.height, height: bounds.width)
                : bounds.size
        )
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        if rotationDegrees != 0 {
            displayLayer.transform = CATransform3DMakeRotation(
                CGFloat(rotationDegrees) * .pi / 180, 0, 0, 1
            )
        }
        CATransaction.commit()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // A decode error puts the layer in a failed state where it silently ignores
        // everything until flushed, which otherwise looks like a frozen picture.
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    func flush() {
        displayLayer.flush()
    }
}

struct SampleBufferDisplayView: UIViewRepresentable {
    let client: MirrorClient

    func makeUIView(context: Context) -> SampleBufferView {
        let view = SampleBufferView(frame: .zero)
        client.onSampleBuffer = { [weak view] sampleBuffer in
            view?.enqueue(sampleBuffer)
        }
        client.onFlushNeeded = { [weak view] in
            view?.flush()
        }
        client.onRotationChanged = { [weak view] degrees in
            view?.rotationDegrees = degrees
        }
        return view
    }

    func updateUIView(_ uiView: SampleBufferView, context: Context) {
        // Covers the case where the client already knows the rotation before this view
        // existed, such as reconnecting to a sender that is already sideways.
        uiView.rotationDegrees = client.rotationDegrees
    }

    static func dismantleUIView(_ uiView: SampleBufferView, coordinator: ()) {
        uiView.flush()
    }
}
