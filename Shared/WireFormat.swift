import Foundation

/// Framing shared by the broadcast extension (sender) and both viewers.
///
/// Every binary WebSocket message is one complete H.264 access unit prefixed by a
/// fixed 8-byte header. Keeping one access unit per message means the receiver never
/// has to re-assemble across message boundaries — WebSocket already guarantees
/// message framing — so the decoder can be fed the moment a message lands.
enum Wire {
    static let magic: UInt8 = 0x54 // 'T'
    static let headerSize = 8

    enum PayloadType: UInt8 {
        case h264AccessUnit = 1
    }

    struct Flags: OptionSet {
        let rawValue: UInt8
        static let keyframe = Flags(rawValue: 1 << 0)
    }

    /// How far the viewer must rotate the decoded picture to show it upright.
    ///
    /// Sent per frame rather than baked into the video: rotating on the sender would mean
    /// tearing down and rebuilding the encoder every time the phone turns, which costs
    /// a keyframe and CPU on a device that is already busy recording.
    enum Rotation: UInt8 {
        case none = 0
        case quarter = 1     // 90 degrees clockwise
        case half = 2        // 180
        case threeQuarter = 3 // 270

        var degrees: Int { Int(rawValue) * 90 }
    }

    struct Header {
        var type: PayloadType
        var flags: Flags
        var rotation: Rotation
        /// Presentation time in milliseconds since the broadcast began.
        var timestampMs: UInt32
    }

    static func encodeHeader(_ header: Header) -> Data {
        var data = Data(capacity: headerSize)
        data.append(magic)
        data.append(header.type.rawValue)
        data.append(header.flags.rawValue)
        data.append(header.rotation.rawValue)
        var be = header.timestampMs.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        return data
    }

    /// Returns the parsed header and the payload slice, or nil if the message is malformed.
    static func decode(_ data: Data) -> (header: Header, payload: Data)? {
        guard data.count > headerSize else { return nil }
        let bytes = [UInt8](data.prefix(headerSize))
        guard bytes[0] == magic, let type = PayloadType(rawValue: bytes[1]) else { return nil }
        let ts = (UInt32(bytes[4]) << 24) | (UInt32(bytes[5]) << 16)
               | (UInt32(bytes[6]) << 8) | UInt32(bytes[7])
        let header = Header(
            type: type,
            flags: Flags(rawValue: bytes[2]),
            rotation: Rotation(rawValue: bytes[3]) ?? .none,
            timestampMs: ts
        )
        return (header, data.suffix(from: data.startIndex + headerSize))
    }
}

/// Settings a viewer can push back to the sender. The free developer account rules out
/// App Groups, so the sender app cannot hand configuration to its own extension —
/// instead the viewer owns these and sends them over the same connection.
struct MirrorSettings: Codable, Equatable {
    var longEdge: Int = 1280
    var fps: Int = 30
    var bitrateKbps: Int = 3000

    static let `default` = MirrorSettings()

    /// Clamped to what the encoder and a phone's thermal budget can actually sustain.
    func sanitized() -> MirrorSettings {
        MirrorSettings(
            longEdge: min(max(longEdge, 320), 1920),
            fps: min(max(fps, 5), 60),
            bitrateKbps: min(max(bitrateKbps, 200), 12000)
        )
    }
}

/// Text messages multiplexed onto the same socket alongside the binary video frames.
enum ControlMessage {
    /// Sender -> viewer, once on connect and again whenever the video format changes.
    struct Hello: Codable {
        var width: Int
        var height: Int
        var settings: MirrorSettings
        var deviceName: String
    }

    /// Viewer -> sender.
    struct Configure: Codable {
        var settings: MirrorSettings
    }

    /// Declared at type scope: a generic type cannot be nested inside a generic function.
    private struct Envelope<Body: Encodable>: Encodable {
        let kind: String
        let body: Body
    }

    static func encode<T: Encodable>(_ value: T, kind: String) -> Data? {
        try? JSONEncoder().encode(Envelope(kind: kind, body: value))
    }
}
