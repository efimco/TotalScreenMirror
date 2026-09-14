import CoreMedia
import Foundation

/// Conversion between the two H.264 bitstream packagings.
///
/// VideoToolbox produces and consumes AVCC (each NAL unit prefixed by its big-endian
/// length). WebCodecs' Annex-B mode and most wire protocols want start codes. Parameter
/// sets live outside the bitstream in AVCC and inline in Annex-B, so the conversion also
/// has to splice SPS/PPS in front of every keyframe — that is what lets a viewer join a
/// broadcast already in progress and decode from the next keyframe onward.
enum AnnexB {
    static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    // MARK: - Encode side (broadcast extension)

    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first
        else { return true }
        // A sample is a keyframe unless it is explicitly marked "not sync".
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// SPS/PPS from the format description, each as a bare NAL unit (no start code).
    static func parameterSets(from formatDescription: CMFormatDescription) -> [Data] {
        var count = 0
        var headerLength: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        ) == noErr else { return [] }

        var sets: [Data] = []
        for index in 0 ..< count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { continue }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
    }

    /// Full Annex-B access unit for an encoded sample, with parameter sets on keyframes.
    static func accessUnit(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return nil }

        var headerLength: Int32 = 4
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        )

        // The block buffer can be non-contiguous, so copy rather than take a data pointer.
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return nil }
        var avcc = Data(count: totalLength)
        let copyStatus = avcc.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: totalLength, destination: base
            )
        }
        guard copyStatus == noErr else { return nil }

        var output = Data(capacity: totalLength + 256)
        if isKeyframe(sampleBuffer) {
            for set in parameterSets(from: formatDescription) {
                output.append(startCode)
                output.append(set)
            }
        }

        let lengthSize = Int(headerLength)
        var offset = 0
        avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while offset + lengthSize <= totalLength {
                var naluLength = 0
                for byte in 0 ..< lengthSize {
                    naluLength = (naluLength << 8) | Int(base[offset + byte])
                }
                offset += lengthSize
                guard naluLength > 0, offset + naluLength <= totalLength else { break }
                output.append(startCode)
                output.append(UnsafeBufferPointer(start: base + offset, count: naluLength))
                offset += naluLength
            }
        }
        return output.count > 0 ? output : nil
    }

    // MARK: - Decode side (iOS viewer)

    /// Splits an Annex-B buffer into bare NAL units, dropping the start codes.
    /// Handles both 3-byte and 4-byte start codes.
    static func nalUnits(in data: Data) -> [Data] {
        var units: [Data] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = data.count
            var starts: [(offset: Int, size: Int)] = []
            var index = 0
            while index + 3 <= count {
                if base[index] == 0, base[index + 1] == 0 {
                    if base[index + 2] == 1 {
                        starts.append((index, 3))
                        index += 3
                        continue
                    } else if index + 4 <= count, base[index + 2] == 0, base[index + 3] == 1 {
                        starts.append((index, 4))
                        index += 4
                        continue
                    }
                }
                index += 1
            }
            for (position, start) in starts.enumerated() {
                let payloadStart = start.offset + start.size
                let payloadEnd = position + 1 < starts.count ? starts[position + 1].offset : count
                guard payloadEnd > payloadStart else { continue }
                units.append(Data(bytes: base + payloadStart, count: payloadEnd - payloadStart))
            }
        }
        return units
    }

    static func naluType(_ unit: Data) -> UInt8 {
        guard let first = unit.first else { return 0 }
        return first & 0x1F
    }

    static let spsType: UInt8 = 7
    static let ppsType: UInt8 = 8

    static func formatDescription(sps: Data, pps: Data) -> CMFormatDescription? {
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return -1 }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        return status == noErr ? description : nil
    }

    /// Repackages picture NAL units as AVCC and wraps them in a sample buffer ready to
    /// hand to an `AVSampleBufferDisplayLayer`.
    static func sampleBuffer(
        pictureUnits: [Data],
        formatDescription: CMFormatDescription,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        var avcc = Data()
        for unit in pictureUnits {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }
        guard !avcc.isEmpty else { return nil }

        // CMBlockBufferCreateWithMemoryBlock does not copy, so hand it a heap allocation it
        // can own. The block is freed with kCFAllocatorMalloc, which calls free(), so it
        // has to come from malloc rather than Swift's allocator.
        guard let bytes = malloc(avcc.count) else { return nil }
        avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            bytes.copyMemory(from: base, byteCount: avcc.count)
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: bytes,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            free(bytes)
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid
        )
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        // Tell the display layer to show the frame as soon as it is decoded rather than
        // scheduling it against a timebase — this is what keeps monitoring latency low.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}
