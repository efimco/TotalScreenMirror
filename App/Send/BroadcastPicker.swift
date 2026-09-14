import ReplayKit
import SwiftUI

/// Wraps `RPSystemBroadcastPickerView`, which is the only sanctioned way to start a
/// broadcast from inside an app.
///
/// The system view renders its own small button that cannot be restyled, so it is hidden
/// behind a normal SwiftUI button and driven programmatically. There is no public API for
/// this, so the button is located by walking the picker's own subtree — and if that ever
/// stops working, `BroadcastButton` falls back to showing the system control directly
/// rather than silently doing nothing.
final class BroadcastPickerContainer: UIView {
    private let picker: RPSystemBroadcastPickerView

    init(extensionBundleID: String) {
        picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        super.init(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = extensionBundleID
        picker.showsMicrophoneButton = false
        picker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        NSLayoutConstraint.activate([
            picker.centerXAnchor.constraint(equalTo: centerXAnchor),
            picker.centerYAnchor.constraint(equalTo: centerYAnchor),
            picker.widthAnchor.constraint(equalToConstant: 60),
            picker.heightAnchor.constraint(equalToConstant: 60),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Returns false if the system control could not be driven, so the caller can degrade
    /// to something the user can actually tap.
    @discardableResult
    func present() -> Bool {
        guard let button = Self.firstButton(in: picker) else { return false }
        button.sendActions(for: .touchUpInside)
        return true
    }

    /// The button is a direct subview today, but has been nested a level deeper in past
    /// releases, so search the whole subtree rather than just `subviews`.
    private static func firstButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for subview in view.subviews {
            if let found = firstButton(in: subview) { return found }
        }
        return nil
    }
}

/// Holds the container so a SwiftUI button can drive it. A plain class, not an
/// `ObservableObject`: nothing here changes the view, it only forwards a tap.
final class BroadcastPickerController {
    weak var container: BroadcastPickerContainer?

    func present() -> Bool {
        container?.present() ?? false
    }
}

private struct BroadcastPickerRepresentable: UIViewRepresentable {
    let extensionBundleID: String
    let controller: BroadcastPickerController
    /// When true the system control is shown as-is, for the case where driving it failed.
    let visible: Bool

    func makeUIView(context: Context) -> BroadcastPickerContainer {
        let container = BroadcastPickerContainer(extensionBundleID: extensionBundleID)
        // Held here, where the picker is actually created. The previous version searched
        // for it through a sibling `.background` view, which SwiftUI does not guarantee
        // is reachable — so it silently found nothing and the button did nothing.
        controller.container = container
        return container
    }

    func updateUIView(_ uiView: BroadcastPickerContainer, context: Context) {
        uiView.alpha = visible ? 1 : 0.02
        uiView.isUserInteractionEnabled = visible
    }
}

struct BroadcastButton: View {
    let extensionBundleID: String

    @State private var controller = BroadcastPickerController()
    @State private var needsFallback = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                BroadcastPickerRepresentable(
                    extensionBundleID: extensionBundleID,
                    controller: controller,
                    visible: needsFallback
                )
                .frame(width: 60, height: 60)

                if !needsFallback {
                    Button {
                        if !controller.present() { needsFallback = true }
                    } label: {
                        Label("Start Mirroring", systemImage: "dot.radiowaves.left.and.right")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if needsFallback {
                Text("Tap the broadcast button above, then choose Screen Mirror. "
                     + "You can also start it from Control Centre's Screen Recording button.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
