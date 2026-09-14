import CoreMedia
import Foundation

/// Turns the Annex-B access units off the wire into sample buffers an
/// `AVSampleBufferDisplayLayer` can display.
///
/// No `VTDecompressionSession` is involved: the display layer decodes internally, which
/// is both less code and one fewer copy of every frame.
final class H264StreamDecoder {
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMFormatDescription?

    /// Set when the stream's parameter sets change, so the display layer can be flushed.
    var onFormatChanged: (() -> Void)?

    func reset() {
        sps = nil
        pps = nil
        formatDescription = nil
    }

    func decode(accessUnit: Data, timestampMs: UInt32) -> CMSampleBuffer? {
        var pictureUnits: [Data] = []
        var parameterSetsChanged = false

        for unit in AnnexB.nalUnits(in: accessUnit) {
            switch AnnexB.naluType(unit) {
            case AnnexB.spsType:
                if sps != unit { sps = unit; parameterSetsChanged = true }
            case AnnexB.ppsType:
                if pps != unit { pps = unit; parameterSetsChanged = true }
            case 6: // SEI — nothing here needs it.
                continue
            default:
                pictureUnits.append(unit)
            }
        }

        if parameterSetsChanged, let sps, let pps {
            formatDescription = AnnexB.formatDescription(sps: sps, pps: pps)
            onFormatChanged?()
        }

        // Frames arriving before the first keyframe have no parameter sets yet and cannot
        // be decoded; dropping them is correct, the next keyframe resyncs.
        guard let formatDescription, !pictureUnits.isEmpty else { return nil }

        return AnnexB.sampleBuffer(
            pictureUnits: pictureUnits,
            formatDescription: formatDescription,
            presentationTime: CMTime(value: CMTimeValue(timestampMs), timescale: 1000)
        )
    }
}
