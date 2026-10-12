#if os(iOS)
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated struct TerminalPhotoLibraryAttachment: Transferable {
    let payload: TerminalAttachmentPayload

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie, importing: load)
        FileRepresentation(importedContentType: .image, importing: load)
    }

    @MainActor
    static func payloads(from providers: [NSItemProvider]) async throws -> [TerminalAttachmentPayload] {
        guard providers.count <= TerminalAttachmentLimits.maximumCount else {
            throw TerminalAttachmentError.limitExceeded
        }
        var payloads: [TerminalAttachmentPayload] = []
        for provider in providers {
            try Task.checkCancellation()
            let attachment: Self = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadTransferable(type: Self.self) { result in
                    continuation.resume(with: result)
                }
            }
            try Task.checkCancellation()
            payloads.append(attachment.payload)
            try TerminalAttachmentLimits.validate(payloads)
        }
        return payloads
    }

    private static func load(_ file: ReceivedTransferredFile) async throws -> Self {
        // Read within the import callback: Photos owns the temporary file's lifetime.
        // The shared loader checks size before reading a potentially large video.
        let payloads = try await TerminalAttachmentLoader.files([file.file])
        guard let payload = payloads.first else { throw TerminalAttachmentError.unreadable }
        return Self(payload: payload)
    }
}
#endif
