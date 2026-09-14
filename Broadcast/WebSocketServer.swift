import CryptoKit
import Foundation
import Network

/// A minimal HTTP/1.1 + WebSocket server built directly on `NWListener`.
///
/// Two constraints forced hand-rolling this rather than using `NWProtocolWebSocket`:
///
/// 1. The same port has to serve a plain `GET /` (the browser viewer page) *and* accept
///    WebSocket upgrades. `NWProtocolWebSocket` upgrades every connection automatically,
///    so a plain HTTP GET would fail its handshake.
/// 2. This runs inside a broadcast upload extension under a hard ~50 MB memory cap, so
///    the whole thing needs to stay small and allocate as little per frame as possible.
///
/// Server-sent frames are never masked, which is most of why the framing code is short.
final class WebSocketServer {
    /// Only *outgoing* connections to local addresses need the Local Network entitlement;
    /// listening and accepting do not. Making the sender the server is what keeps the
    /// extension free of a permission prompt it could never present anyway.
    static let defaultPort = MirrorConstants.port

    /// Stop queueing frames once this much data is still in flight to a client. Dropping
    /// frames under congestion is what keeps latency bounded — buffering them would trade
    /// a dropped frame for permanently accumulated delay, which is useless for a monitor.
    private static let congestionThreshold = 512 * 1024

    private let port: UInt16
    private let queue = DispatchQueue(label: "tsmirror.server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]

    /// Called on the server queue when a viewer sends a control message.
    var onControlMessage: ((Data) -> Void)?
    /// Called on the server queue when the first viewer connects or the last disconnects.
    var onClientCountChanged: ((Int) -> Void)?
    /// Called if the listener fails after starting. Without this, a listener that never
    /// reaches `.ready` fails completely silently: no crash, no port, no diagnosis.
    var onFailure: ((String) -> Void)?

    init(port: UInt16 = WebSocketServer.defaultPort) {
        self.port = port
    }

    // MARK: - Lifecycle

    /// `advertise` publishes a Bonjour service for the iOS viewer to discover.
    ///
    /// It defaults to off inside the broadcast extension: advertising a Bonjour service
    /// requires the Local Network permission (only plain listening is exempt), and an
    /// extension has no way to present that prompt — the listener just fails to start.
    /// Viewers connect by address instead, which is what the browser does anyway.
    func start(serviceName: String, advertise: Bool = false) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true // Nagle would batch small frames and add latency.
        }

        let listener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(rawValue: port) ?? .any
        )
        if advertise {
            listener.service = NWListener.Service(
                name: serviceName, type: MirrorConstants.bonjourServiceType
            )
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error):
                self?.onFailure?("The mirror server could not start: \(error.localizedDescription)")
            case let .waiting(error):
                // Usually the port is still held by a previous broadcast that has not
                // finished tearing down.
                self?.onFailure?("The mirror server is stuck waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.async {
            for client in self.clients.values { client.close() }
            self.clients.removeAll()
            self.listener?.cancel()
            self.listener = nil
        }
    }

    // MARK: - Sending

    /// Sends a binary frame to every connected viewer, skipping any that are congested.
    /// Returns true if at least one viewer accepted it.
    @discardableResult
    func broadcast(binary data: Data) -> Bool {
        var delivered = false
        queue.sync {
            for client in clients.values where client.isUpgraded && !client.isCongested {
                client.send(payload: data, opcode: .binary)
                delivered = true
            }
        }
        return delivered
    }

    func broadcast(text data: Data) {
        queue.async {
            for client in self.clients.values where client.isUpgraded {
                client.send(payload: data, opcode: .text)
            }
        }
    }

    var hasViewers: Bool {
        queue.sync { clients.values.contains { $0.isUpgraded } }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection, queue: queue)
        clients[ObjectIdentifier(client)] = client

        client.onControlMessage = { [weak self] data in
            self?.onControlMessage?(data)
        }
        client.onUpgrade = { [weak self] in
            guard let self else { return }
            self.onClientCountChanged?(self.clients.values.filter(\.isUpgraded).count)
        }
        client.onClose = { [weak self] in
            guard let self else { return }
            self.clients.removeValue(forKey: ObjectIdentifier(client))
            self.onClientCountChanged?(self.clients.values.filter(\.isUpgraded).count)
        }
        client.start()
    }

    // MARK: - Client

    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    final class Client {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private var inbox = Data()
        private var inFlightBytes = 0
        private var closed = false
        private(set) var isUpgraded = false

        var onControlMessage: ((Data) -> Void)?
        var onUpgrade: (() -> Void)?
        var onClose: (() -> Void)?

        var isCongested: Bool { inFlightBytes > WebSocketServer.congestionThreshold }

        init(connection: NWConnection, queue: DispatchQueue) {
            self.connection = connection
            self.queue = queue
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.handleClosed()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            receive()
        }

        func close() {
            guard !closed else { return }
            closed = true
            connection.cancel()
        }

        private func handleClosed() {
            guard !closed else { return }
            closed = true
            onClose?()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.inbox.append(data)
                    self.isUpgraded ? self.drainFrames() : self.drainHandshake()
                }
                if isComplete || error != nil {
                    self.handleClosed()
                    return
                }
                self.receive()
            }
        }

        // MARK: HTTP

        private func drainHandshake() {
            // Cap the pre-upgrade buffer so a malformed client cannot grow it without bound.
            guard inbox.count < 64 * 1024 else { close(); return }
            guard let headerEnd = inbox.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerData = inbox[inbox.startIndex ..< headerEnd.lowerBound]
            inbox.removeSubrange(inbox.startIndex ..< headerEnd.upperBound)

            guard let request = String(data: headerData, encoding: .utf8) else { close(); return }
            let lines = request.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { close(); return }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else {
                sendHTTP(status: "405 Method Not Allowed", body: Data("Method not allowed".utf8))
                return
            }
            let path = String(parts[1])

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[line.startIndex ..< colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }

            // Any path with a WebSocket key is treated as an upgrade. The browser viewer
            // asks for /ws, but the iOS viewer connects straight to a Bonjour service
            // endpoint, which carries no path — accepting both avoids resolving the
            // service to a host and port just to spell out a URL.
            if let key = headers["sec-websocket-key"] {
                upgrade(key: key)
            } else if path == "/" || path == "/index.html" {
                sendHTTP(
                    status: "200 OK",
                    contentType: "text/html; charset=utf-8",
                    body: Data(ViewerPage.html.utf8)
                )
            } else {
                sendHTTP(status: "404 Not Found", body: Data("Not found".utf8))
            }
        }

        private func sendHTTP(
            status: String,
            contentType: String = "text/plain; charset=utf-8",
            body: Data
        ) {
            var response = "HTTP/1.1 \(status)\r\n"
            response += "Content-Type: \(contentType)\r\n"
            response += "Content-Length: \(body.count)\r\n"
            response += "Cache-Control: no-store\r\n"
            response += "Connection: close\r\n\r\n"
            var payload = Data(response.utf8)
            payload.append(body)
            connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }

        private func upgrade(key: String) {
            // RFC 6455: accept = base64(SHA1(key + magic GUID)).
            let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
            let accept = Data(digest).base64EncodedString()

            var response = "HTTP/1.1 101 Switching Protocols\r\n"
            response += "Upgrade: websocket\r\n"
            response += "Connection: Upgrade\r\n"
            response += "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })

            isUpgraded = true
            onUpgrade?()
            drainFrames()
        }

        // MARK: WebSocket framing

        func send(payload: Data, opcode: Opcode) {
            guard !closed else { return }
            var frame = Data(capacity: payload.count + 10)
            frame.append(0x80 | opcode.rawValue) // FIN set, never fragmented.

            // Server-to-client frames must not be masked, so the length byte carries no mask bit.
            if payload.count < 126 {
                frame.append(UInt8(payload.count))
            } else if payload.count <= 0xFFFF {
                frame.append(126)
                var length = UInt16(payload.count).bigEndian
                withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
            } else {
                frame.append(127)
                var length = UInt64(payload.count).bigEndian
                withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
            }
            frame.append(payload)

            let byteCount = frame.count
            inFlightBytes += byteCount
            connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
                self?.inFlightBytes -= byteCount
            })
        }

        private func drainFrames() {
            while let frame = nextFrame() {
                switch frame.opcode {
                case .text, .binary:
                    onControlMessage?(frame.payload)
                case .ping:
                    send(payload: frame.payload, opcode: .pong)
                case .close:
                    close()
                    return
                default:
                    break
                }
            }
        }

        private struct Frame {
            let opcode: Opcode
            let payload: Data
        }

        /// Parses one complete frame off the front of `inbox`, or returns nil if more bytes
        /// are needed. Viewers only ever send small single-frame control messages, so
        /// fragmented continuation frames are tolerated but not reassembled.
        private func nextFrame() -> Frame? {
            let bytes = [UInt8](inbox)
            guard bytes.count >= 2 else { return nil }

            let opcodeRaw = bytes[0] & 0x0F
            let isMasked = (bytes[1] & 0x80) != 0
            var length = Int(bytes[1] & 0x7F)
            var cursor = 2

            if length == 126 {
                guard bytes.count >= cursor + 2 else { return nil }
                length = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
                cursor += 2
            } else if length == 127 {
                guard bytes.count >= cursor + 8 else { return nil }
                length = 0
                for offset in 0 ..< 8 { length = (length << 8) | Int(bytes[cursor + offset]) }
                cursor += 8
            }
            // A viewer has no reason to send anything large; refuse to buffer it.
            guard length <= 1 << 20 else { close(); return nil }

            var mask: [UInt8] = []
            if isMasked {
                guard bytes.count >= cursor + 4 else { return nil }
                mask = Array(bytes[cursor ..< cursor + 4])
                cursor += 4
            }
            guard bytes.count >= cursor + length else { return nil }

            var payload = Array(bytes[cursor ..< cursor + length])
            if isMasked {
                for index in 0 ..< payload.count { payload[index] ^= mask[index % 4] }
            }
            inbox.removeFirst(cursor + length)

            guard let opcode = Opcode(rawValue: opcodeRaw) else { return nil }
            return Frame(opcode: opcode, payload: Data(payload))
        }
    }
}
