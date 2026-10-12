#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct TerminalFilePicker: UIViewControllerRepresentable {
    let complete: ([URL]?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(complete: complete) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let complete: ([URL]?) -> Void
        init(complete: @escaping ([URL]?) -> Void) { self.complete = complete }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            complete(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { complete(nil) }
    }
}
#endif
