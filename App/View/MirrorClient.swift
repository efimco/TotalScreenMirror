import CoreMedia
import Foundation
import Network

/// Discovers senders on the local network and streams video from the one you pick.
///
/// Browsing for Bonjour services and opening outgoing connections to local addresses both
/// require the Local Network permission, which is why `NSLocalNetworkUsageDescription`
/// and `NSBonjourServices` are declared in the app's Info.plist. The sending side needs
/// neither, because listening and accepting do not.
@MainActor
final class MirrorClient: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case streaming
        case failed(String)
    }

    struct Sender: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    @Published private(set) var senders: [Sender] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var info: ControlMessage.Hello?
    @Published private(set) var framesPerSecond = 0
    /// Rotation the sender reports for its screen, in degrees clockwise.
    @Published private(set) var rotationDegrees = 0
    @Published var settings = MirrorSettings.default

    /// Called on the main actor for every decoded frame.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onFlushNeeded: (() -> Void)?
    var onRotationChanged: ((Int) -> Void)?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let decoder = H264StreamDecoder()
    private let queue = DispatchQueue(label: "tsmirror.client")
    private var frameCounter = 0
    private var statsTimer: Timer?

    init() {
        decoder.onFormatChanged = { [weak self] in
            self?.onFlushNeeded?()
        }
    }

    // MARK: - Discovery

    func startBrowsing() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: MirrorConstants.bonjourServiceType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Sender? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return Sender(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                self?.senders = found.sorted { $0.name < $1.name }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    // MARK: - Connection

    func connect(to sender: Sender) {
        connect(to: sender.endpoint)
    }

    func connect(toHost host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Accept "192.168.1.5", "192.168.1.5:8787" or a pasted "http://192.168.1.5:8787".
        var text = trimmed
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "ws://", with: "")
        if text.hasSuffix("/") { text.removeLast() }

        var port = MirrorConstants.port
        if let colon = text.lastIndex(of: ":"),
           let parsed = UInt16(text[text.index(after: colon)...]) {
            port = parsed
            text = String(text[text.startIndex ..< colon])
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        connect(to: .hostPort(host: NWEndpoint.Host(text), port: endpointPort))
    }

    private func connect(to endpoint: NWEndpoint) {
        disconnect()
        state = .connecting
        decoder.reset()

        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true

        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.state = .streaming
                    self.sendSettings()
                case let .failed(error):
                    self.state = .failed(error.localizedDescription)
                case .cancelled:
                    if self.state != .idle { self.state = .idle }
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        self.connection = connection
        receive(on: connection)
        startStats()
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        statsTimer?.invalidate()
        statsTimer = nil
        framesPerSecond = 0
        rotationDegrees = 0
        info = nil
        if state != .idle { state = .idle }
    }

    private nonisolated func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { return }

            if let data, !data.isEmpty {
                let metadata = context?.protocolMetadata(
                    definition: NWProtocolWebSocket.definition
                ) as? NWProtocolWebSocket.Metadata

                switch metadata?.opcode {
                case .text:
                    Task { @MainActor in self.handleControl(data) }
                case .binary:
                    self.handleVideo(data)
                default:
                    break
                }
            }
            self.receive(on: connection)
        }
    }

    private nonisolated func handleVideo(_ data: Data) {
        guard let (header, payload) = Wire.decode(data), header.type == .h264AccessUnit else { return }
        Task { @MainActor in
            let degrees = header.rotation.degrees
            if degrees != self.rotationDegrees {
                self.rotationDegrees = degrees
                self.onRotationChanged?(degrees)
            }
            guard let sampleBuffer = self.decoder.decode(
                accessUnit: payload, timestampMs: header.timestampMs
            ) else { return }
            self.frameCounter += 1
            self.onSampleBuffer?(sampleBuffer)
        }
    }

    private func handleControl(_ data: Data) {
        struct Envelope: Decodable {
            let kind: String
            let body: ControlMessage.Hello
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.kind == "hello"
        else { return }
        info = envelope.body
        settings = envelope.body.settings
    }

    // MARK: - Settings

    /// The viewer owns the encoding settings and pushes them to the sender, because the
    /// sender app has no way to hand configuration to its own extension without an App Group.
    func sendSettings() {
        guard let connection else { return }
        guard let payload = ControlMessage.encode(
            ControlMessage.Configure(settings: settings.sanitized()), kind: "configure"
        ) else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "configure", metadata: [metadata])
        connection.send(content: payload, contentContext: context, completion: .contentProcessed { _ in })
    }

    private func startStats() {
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.framesPerSecond = self.frameCounter
                self.frameCounter = 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }
}
