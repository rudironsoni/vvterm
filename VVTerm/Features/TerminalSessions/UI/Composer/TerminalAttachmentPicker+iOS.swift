#if os(iOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct TerminalAttachmentPicker: View {
    @ObservedObject var composer: TerminalComposerStore
    let onPasteText: (String) -> Void

    var body: some View {
        Color.clear
            .fullScreenCover(isPresented: isPresented(.camera), onDismiss: composer.attachmentPickerDidDismiss) {
                TerminalCameraCapture { result in
                    composer.attachmentSource = nil
                    if let result { composer.load { [try result.get()] } }
                }
            }
            .sheet(isPresented: libraryOrFilesPresented, onDismiss: composer.attachmentPickerDidDismiss) {
                switch composer.attachmentSource ?? composer.presentedAttachmentSource {
                case .photos:
                    TerminalPhotoLibraryPicker { providers in
                        composer.attachmentSource = nil
                        guard !providers.isEmpty else { return }
                        composer.load { @MainActor in
                            try await TerminalPhotoLibraryAttachment.payloads(from: providers)
                        }
                    }
                    .ignoresSafeArea()
                case .files:
                    TerminalFilePicker { urls in
                        composer.attachmentSource = nil
                        guard let urls else { return }
                        composer.load { try await TerminalAttachmentLoader.files(urls) }
                    }
                    .ignoresSafeArea()
                default:
                    EmptyView()
                }
            }
            .onChange(of: composer.attachmentSource) { source in
                composer.attachmentPickerWillPresent()
                guard source == .paste else { return }
                composer.attachmentSource = nil
                let images = Clipboard.attachmentPayloads()
                let urls = (UIPasteboard.general.urls ?? []).filter(\.isFileURL)
                if let text = UIPasteboard.general.string,
                   !urls.contains(where: { $0.absoluteString == text || $0.path == text }) {
                    onPasteText(text)
                }
                guard !images.isEmpty || !urls.isEmpty else { return }
                composer.load {
                    let files = try await TerminalAttachmentLoader.files(urls)
                    return images + files
                }
            }
            .preference(key: TerminalRouteModalPresentationPreferenceKey.self,
                        value: composer.isAttachmentPickerPresented)
    }

    private var libraryOrFilesPresented: Binding<Bool> {
        Binding(get: { composer.attachmentSource == .photos || composer.attachmentSource == .files },
                set: { presented in
            if !presented, composer.attachmentSource == .photos || composer.attachmentSource == .files {
                composer.attachmentSource = nil
            }
        })
    }

    private func isPresented(_ source: TerminalComposerStore.AttachmentSource) -> Binding<Bool> {
        Binding(get: { composer.attachmentSource == source }, set: { presented in
            if presented { composer.attachmentSource = source }
            else if composer.attachmentSource == source { composer.attachmentSource = nil }
        })
    }


}

extension TerminalComposerStore.AttachmentSource {
    var title: String {
        switch self {
        case .camera: String(localized: "Camera")
        case .photos: String(localized: "Photos")
        case .files: String(localized: "Files")
        case .paste: String(localized: "Paste")
        }
    }
    var symbol: String {
        switch self {
        case .camera: "camera"
        case .photos: "photo.on.rectangle"
        case .files: "folder"
        case .paste: "doc.on.clipboard"
        }
    }
    var accessibilityIdentifier: String { "vvterm.attachments.\(self)" }
}
#endif
