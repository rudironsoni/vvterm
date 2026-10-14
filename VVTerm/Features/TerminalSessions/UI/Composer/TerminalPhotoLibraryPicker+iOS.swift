#if os(iOS)
import PhotosUI
import SwiftUI
import UIKit

/// Keep the native picker outside SwiftUI's sheet layout and measurement views.
struct TerminalPhotoLibraryPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let willPresent: () -> Void
    let onDismiss: () -> Void
    let complete: ([NSItemProvider]) -> Void

    func makeUIViewController(context: Context) -> PresentationController {
        PresentationController(isPresented: $isPresented, willPresent: willPresent,
                               onDismiss: onDismiss, complete: complete)
    }

    func updateUIViewController(_ controller: PresentationController, context: Context) {
        controller.update(isPresented: $isPresented, willPresent: willPresent,
                          onDismiss: onDismiss, complete: complete)
    }

    static func dismantleUIViewController(_ controller: PresentationController, coordinator: ()) {
        controller.tearDown()
    }

    final class PresentationController: UIViewController, PHPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
        private var isPresented: Binding<Bool>
        private var willPresent: () -> Void
        private var onDismiss: () -> Void
        private var complete: ([NSItemProvider]) -> Void
        private var picker: PHPickerViewController?

        init(isPresented: Binding<Bool>, willPresent: @escaping () -> Void, onDismiss: @escaping () -> Void,
             complete: @escaping ([NSItemProvider]) -> Void) {
            self.isPresented = isPresented
            self.willPresent = willPresent
            self.onDismiss = onDismiss
            self.complete = complete
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() {
            view = UIView(frame: .zero)
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            reconcilePresentation()
        }

        func update(isPresented: Binding<Bool>, willPresent: @escaping () -> Void, onDismiss: @escaping () -> Void,
                    complete: @escaping ([NSItemProvider]) -> Void) {
            self.isPresented = isPresented
            self.willPresent = willPresent
            self.onDismiss = onDismiss
            self.complete = complete
            // UIKit presentation must start after the SwiftUI update ends.
            DispatchQueue.main.async { [weak self] in self?.reconcilePresentation() }
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard self.picker === picker else { return }
            complete(results.map(\.itemProvider))
            reconcilePresentation()
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard let picker, presentationController.presentedViewController === picker else { return }
            isPresented.wrappedValue = false
            finishDismissal(of: picker)
        }

        func tearDown() {
            guard let picker else { return }
            self.picker = nil
            picker.delegate = nil
            picker.presentationController?.delegate = nil
            picker.dismiss(animated: false)
            // A replacement host can continue the same pending request.
            if !isPresented.wrappedValue { onDismiss() }
        }

        private func reconcilePresentation() {
            guard isViewLoaded, view.window != nil else { return }
            if isPresented.wrappedValue {
                guard picker == nil, presentedViewController == nil else { return }
                var configuration = PHPickerConfiguration()
                configuration.selectionLimit = TerminalAttachmentLimits.maximumCount
                configuration.selection = .ordered
                configuration.filter = .any(of: [.images, .videos])
                configuration.preferredAssetRepresentationMode = .current
                let picker = PHPickerViewController(configuration: configuration)
                picker.delegate = self
                self.picker = picker
                willPresent()
                present(picker, animated: true) { [weak self] in self?.reconcilePresentation() }
                picker.presentationController?.delegate = self
            } else if let picker, !picker.isBeingPresented, !picker.isBeingDismissed {
                picker.dismiss(animated: true) { [weak self] in self?.finishDismissal(of: picker) }
            }
        }

        private func finishDismissal(of picker: PHPickerViewController) {
            guard self.picker === picker else { return }
            self.picker = nil
            onDismiss()
            reconcilePresentation()
        }
    }
}
#endif
