import SwiftUI

/// Polls the extension's own server over loopback to tell whether a broadcast is running.
///
/// Loopback connections are exempt from the Local Network permission, so this works
/// without prompting, and it is the only channel the app has into its extension — an
/// App Group would need a paid developer account.
@MainActor
final class BroadcastStatus: ObservableObject {
    @Published private(set) var isLive = false

    private var timer: Timer?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    func start() {
        stop()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { await self?.probe() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await probe() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func probe() async {
        let url = URL(string: "http://127.0.0.1:\(MirrorConstants.port)/")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let live: Bool
        do {
            let (_, response) = try await session.data(for: request)
            live = (response as? HTTPURLResponse)?.statusCode != nil
        } catch {
            live = false
        }
        if live != isLive { isLive = live }
    }
}

struct SendView: View {
    @StateObject private var status = BroadcastStatus()
    @State private var addresses = NetworkInterfaces.current()
    @State private var copied: String?

    private var primary: NetworkInterfaces.Address? { addresses.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    statusBadge

                    BroadcastButton(extensionBundleID: MirrorConstants.broadcastExtensionBundleID)
                        .padding(.horizontal)

                    if let primary {
                        qrCard(for: primary)
                    }

                    addressList

                    instructions
                }
                .padding(.vertical)
            }
            .navigationTitle("Send")
            .toolbar {
                Button {
                    addresses = NetworkInterfaces.current()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh addresses")
            }
        }
        .onAppear {
            addresses = NetworkInterfaces.current()
            status.start()
        }
        .onDisappear { status.stop() }
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status.isLive ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)
            Text(status.isLive ? "Mirroring is live" : "Not mirroring")
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary, in: Capsule())
    }

    private func qrCard(for address: NetworkInterfaces.Address) -> some View {
        VStack(spacing: 12) {
            if let image = QRCode.image(for: url(for: address), size: 480) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            Text("Scan from the monitoring device")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var addressList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OPEN ON THE OTHER DEVICE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 6)

            if addresses.isEmpty {
                Text("No network connection. Join a Wi-Fi network or turn on Personal Hotspot.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(addresses) { address in
                    Button {
                        UIPasteboard.general.string = url(for: address)
                        copied = address.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(address.label)
                                    .font(.subheadline.weight(.medium))
                                Text(url(for: address))
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: copied == address.id ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading)
                }
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Tap Start Mirroring, choose Screen Mirror, then Start Broadcast. "
                + "You can also start it from Control Centre's Screen Recording button.",
                systemImage: "1.circle"
            )
            Label(
                "Open the address above in any browser, or use the Watch tab on another "
                + "iPhone or iPad.",
                systemImage: "2.circle"
            )
            Label(
                "Encoding runs alongside whatever you are recording. On long takes the "
                + "phone will warm up and may throttle — fine for setting up a shot, "
                + "less so as a rolling monitor.",
                systemImage: "thermometer.medium"
            )
            .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.horizontal)
    }

    private func url(for address: NetworkInterfaces.Address) -> String {
        "http://\(address.ip):\(MirrorConstants.port)"
    }
}
