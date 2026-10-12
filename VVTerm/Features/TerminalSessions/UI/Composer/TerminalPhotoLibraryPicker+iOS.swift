#if os(iOS)
import PhotosUI
import SwiftUI

/// Native picker content; the enclosing sheet owns dismissal and input restoration.
struct TerminalPhotoLibraryPicker: UIViewControllerRepresentable {
    let complete: ([NSItemProvider]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = TerminalAttachmentLimits.maximumCount
        configuration.selection = .ordered
        configuration.filter = .any(of: [.images, .videos])
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(complete: complete) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let complete: ([NSItemProvider]) -> Void
        init(complete: @escaping ([NSItemProvider]) -> Void) { self.complete = complete }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            complete(results.map(\.itemProvider))
        }
    }
}
#endif
