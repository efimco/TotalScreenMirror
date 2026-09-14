import SwiftUI

struct ViewerView: View {
    @StateObject private var client = MirrorClient()
    @State private var manualHost = ""
    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch client.state {
            case .idle, .failed:
                picker
            case .connecting, .streaming:
                monitor
            }
        }
        .onAppear { client.startBrowsing() }
        .onDisappear {
            client.stopBrowsing()
            client.disconnect()
        }
    }

    // MARK: - Picking a sender

    private var picker: some View {
        NavigationStack {
            List {
                Section {
                    if client.senders.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for devices…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(client.senders) { sender in
                            Button {
                                client.connect(to: sender)
                            } label: {
                                Label(sender.name, systemImage: "iphone.gen3.radiowaves.left.and.right")
                            }
                        }
                    }
                } header: {
                    Text("On this network")
                } footer: {
                    Text("The other device must be broadcasting from the Send tab.")
                }

                Section {
                    HStack {
                        TextField("192.168.1.5", text: $manualHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit { client.connect(toHost: manualHost) }
                        Button("Connect") {
                            client.connect(toHost: manualHost)
                        }
                        .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Or enter an address")
                } footer: {
                    Text("Use this when discovery fails — common on hotspots and on networks "
                         + "that block Bonjour. The address is shown on the sender's Send tab.")
                }

                if case let .failed(reason) = client.state {
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Watch")
        }
    }

    // MARK: - Monitoring

    private var monitor: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            SampleBufferDisplayView(client: client)
                .ignoresSafeArea()

            if client.state == .connecting || client.framesPerSecond == 0 {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(client.state == .connecting ? "Connecting…" : "Waiting for video…")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            if showsControls {
                controls.transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(showsControls ? .automatic : .hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            scheduleHide()
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button {
                    client.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                }
                Spacer()
                if let info = client.info {
                    Text("\(info.deviceName) · \(info.width)×\(info.height) · \(client.framesPerSecond) fps")
                        .font(.caption.monospacedDigit())
                }
            }
            .padding()
            .foregroundStyle(.white)
            .background(.black.opacity(0.45))

            Spacer()

            HStack(spacing: 16) {
                Picker("Quality", selection: $client.settings.longEdge) {
                    Text("480p").tag(854)
                    Text("720p").tag(1280)
                    Text("1080p").tag(1920)
                }
                Picker("Rate", selection: $client.settings.fps) {
                    Text("15 fps").tag(15)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            .background(.black.opacity(0.45))
            .onChange(of: client.settings) { _ in
                client.sendSettings()
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() }
        if showsControls { scheduleHide() }
    }

    /// Controls fade out on their own so nothing sits over the image you are judging.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { showsControls = false }
        }
    }
}
