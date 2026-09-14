import CoreImage.CIFilterBuiltins
import UIKit

/// Renders a URL as a QR code so the monitoring device can open the viewer by pointing
/// its camera at the sender, rather than someone typing an IP address on set.
enum QRCode {
    static func image(for string: String, size: CGFloat) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // The generator emits roughly one pixel per module, so scale up before rasterising
        // to avoid a blurry code that a camera struggles to lock onto.
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
