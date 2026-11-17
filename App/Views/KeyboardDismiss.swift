import SwiftUI
import UIKit

extension View {
    /// Hides the keyboard when the user taps anywhere outside a text field.
    /// Taps still reach buttons and switches as usual.
    func dismissesKeyboardOnTap() -> some View {
        background(KeyboardDismissInstaller().allowsHitTesting(false))
    }
}

private struct KeyboardDismissInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        private weak var installedOn: UIWindow?

        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            installedOn?.removeGestureRecognizer(recognizer)
            installedOn = window
            window?.addGestureRecognizer(recognizer)
        }

        @objc private func tapped() {
            window?.endEditing(true)
        }

        /// Taps inside a text field or text editor keep the keyboard open.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextView || current is UITextField { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
