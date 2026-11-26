#if os(iOS)
import SwiftUI
import UIKit

// CameraCapture.swift - a minimal in-app camera for the 75 Hard progress photo (iPhone only).
//
// Wraps the system camera (`UIImagePickerController`). The photo is handed back as JPEG bytes and is
// never written to the photo library or sent anywhere; the caller stores it on the device. The whole
// file is iOS-only because the Mac build shares the screens that use it and has no such camera sheet.

struct CameraCapture: UIViewControllerRepresentable {
    /// Called with the captured photo as JPEG bytes, or nil when the user cancels.
    let onFinish: (Data?) -> Void

    /// False on devices with no camera (the Simulator), so the caller can hide the button.
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onFinish: (Data?) -> Void

        init(onFinish: @escaping (Data?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onFinish(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
#endif
