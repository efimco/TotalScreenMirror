import ReplayKit
import UIKit

/// Broadcast Setup UI extension.
///
/// This mirror needs no setup — the viewer chooses quality and frame rate, and there is
/// nothing to sign into — so this screen completes itself as soon as it appears. It
/// exists because the system pairs an upload extension with a setup UI extension when
/// listing broadcast destinations; without it the app is not offered in the picker.
class BroadcastSetupViewController: UIViewController {
    private var didComplete = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Shown only if the automatic completion below does not take effect, so a stalled
        // setup screen still has a way forward instead of spinning indefinitely.
        let button = UIButton(type: .system)
        button.setTitle("Start Mirroring", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.addTarget(self, action: #selector(finish), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Completing from viewDidLoad is too early: the extension context is not fully
        // connected yet, so the call is dropped and the system sheet spins forever.
        finish()
    }

    @objc private func finish() {
        guard !didComplete else { return }
        didComplete = true
        let setupInfo: [String: NSCoding & NSObjectProtocol] = [:]
        extensionContext?.completeRequest(
            withBroadcast: URL(string: "https://localhost/tsmirror")!,
            setupInfo: setupInfo
        )
    }
}
