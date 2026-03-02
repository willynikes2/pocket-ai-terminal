import SwiftUI
import UniformTypeIdentifiers

/// Wraps UIDocumentPickerViewController for multi-file selection.
struct FilePickerView: UIViewControllerRepresentable {
    let allowedTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onPick: ([(filename: String, data: Data)]) -> Void

    init(
        allowedTypes: [UTType] = [.item],
        allowsMultipleSelection: Bool = true,
        onPick: @escaping ([(filename: String, data: Data)]) -> Void
    ) {
        self.allowedTypes = allowedTypes
        self.allowsMultipleSelection = allowsMultipleSelection
        self.onPick = onPick
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([(filename: String, data: Data)]) -> Void

        init(onPick: @escaping ([(filename: String, data: Data)]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            var files: [(filename: String, data: Data)] = []

            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }

                guard let data = try? Data(contentsOf: url) else { continue }
                files.append((filename: url.lastPathComponent, data: data))
            }

            onPick(files)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick([])
        }
    }
}
