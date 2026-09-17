#if canImport(UIKit)
import SwiftUI
import UIKit

/// A minimal camera capture for the photo path (spec §5.3), gated to UIKit.
/// Optional by design: the screen works from an existing photo with no camera at
/// all (`PhotosPicker`), so this is only offered when a camera exists. Returns
/// encoded JPEG `Data` (or nil on cancel) to the photo screen, which never sees a
/// `UIImage`.
///
/// Ported from `WorkoutChatLog/Features/OCRCamera.swift` at
/// `workout-logger@5bffddfb80fc`.
///
/// NOT COMPILED HERE (no UIKit on Linux). The camera permission prompt
/// (`NSCameraUsageDescription`, whose reason string is the true one — "To read
/// ingredients off a page") and the capture itself are device steps.
struct PhotoCamera: UIViewControllerRepresentable {
    /// Whether this device has a usable camera; the screen hides the option
    /// otherwise, so a camera-less device degrades to import-only.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    let onCapture: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data?) -> Void

        init(onCapture: @escaping (Data?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            // 0.9: OCR wants detail, and the bytes never leave memory anyway.
            onCapture(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
#endif
