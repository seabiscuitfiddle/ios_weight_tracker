import PhotosUI
import SwiftUI
import TallyCore
import UIKit

/// A photo the user has attached to the compose field, ready to send.
///
/// Both representations are kept because they answer different questions: `image` is what the
/// thumbnail draws, `jpeg` is what goes over the wire. Re-encoding at draw time would mean doing
/// the expensive work on every layout pass.
///
/// Not `Sendable`, deliberately: `UIImage` isn't, and this never leaves the main actor — only the
/// `jpeg` bytes travel, and `Data` carries itself.
struct CapturedPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
    let jpeg: Data

    /// - Returns: nil when the image can't be encoded, which the caller should treat as "the
    ///   attachment didn't happen" rather than sending something empty.
    init?(_ image: UIImage) {
        guard let jpeg = image.tallyJPEG() else { return nil }
        self.image = image
        self.jpeg = jpeg
    }
}

extension UIImage {
    /// Downscales and re-encodes for the parser.
    ///
    /// A phone camera produces an image far larger than any vision model reads at, and providers
    /// reject oversized requests outright — `NutritionParserError.requestTooLarge` exists because
    /// of it. A 1024pt long edge is plenty to identify a plate of food, and it turns a ~4 MB
    /// capture into a few hundred kilobytes.
    func tallyJPEG(maxEdge: CGFloat = 1024, quality: CGFloat = 0.7) -> Data? {
        let longest = max(size.width, size.height)
        guard longest > maxEdge, longest > 0 else { return jpegData(compressionQuality: quality) }

        let scale = maxEdge / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        // Scale 1 rather than the screen's: this is going into a request, not onto a display, so
        // a Retina multiplier would triple the bytes for no gain in what the model can read.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

/// The system camera, as a SwiftUI view.
///
/// `UIImagePickerController` rather than `PHPickerViewController`, because the latter reads the
/// library only — presenting the camera without building a capture session by hand still means
/// going through UIKit.
struct CameraPicker: UIViewControllerRepresentable {
    /// Called with the captured image, or nil when the user backed out. Either way the caller
    /// closes the presentation: the picker doesn't know how it was put on screen.
    let onFinish: @MainActor (UIImage?) -> Void

    /// False in the simulator and on any device without a usable camera, where offering "Take
    /// Photo" would present a black screen.
    @MainActor
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    /// Main-actor isolated because `UIImagePickerControllerDelegate` is, and because the closure
    /// it calls writes the presenting view's state.
    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        private let onFinish: @MainActor (UIImage?) -> Void

        init(onFinish: @escaping @MainActor (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onFinish(info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
