import SwiftUI
import UIKit
import Vision
import VisionKit
import BudgetKit

/// Reads the text on a receipt photo with Apple's built-in text reader (Vision). It runs on the
/// phone, works offline and is free. The pieces of text it finds are put back into lines
/// (TextLines) and then parsed exactly like the web app does (ReceiptParser).
enum ReceiptReader {
    static func read(_ image: UIImage) async throws -> String {
        guard let cg = image.cgImage else { return "" }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Product names and codes are not dictionary words; "correcting" them makes it worse.
            request.usesLanguageCorrection = false
            // Vision has no Slovenian; German and English cover the Latin letters on Slovenian
            // receipts. Accents like č/š/ž may come out as c/s/z, which does not matter for
            // price tracking because item names are compared without accents.
            let supported = (try? request.supportedRecognitionLanguages()) ?? []
            request.recognitionLanguages = ["de-DE", "en-US", "hr-HR", "sl-SI"].filter { supported.contains($0) }
            try VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request])
            let pieces: [TextLines.Piece] = (request.results ?? []).compactMap { obs in
                guard let text = obs.topCandidates(1).first?.string else { return nil }
                // Vision measures from the bottom-left; TextLines wants the top-left.
                let b = obs.boundingBox
                let dx = obs.bottomRight.x - obs.bottomLeft.x
                let dy = obs.bottomRight.y - obs.bottomLeft.y
                let slope = dx > 0 ? -Double(dy / dx) : 0
                return TextLines.Piece(text: text, minX: b.minX, minY: 1 - b.maxY, maxX: b.maxX, maxY: 1 - b.minY, slope: slope)
            }
            return TextLines.assemble(pieces)
        }.value
    }
}

enum ReceiptImage {
    /// A JPEG of about 1600 px on the long side (200–400 KB), the same size the web app saves,
    /// so photos fit the free 1 GB of cloud storage (roughly 3,000 receipts).
    static func jpeg(_ image: UIImage, longSide: CGFloat = 1600) -> Data? {
        let size = image.size
        let scale = min(1, longSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        var quality: CGFloat = 0.7
        var data = resized.jpegData(compressionQuality: quality)
        // The cloud accepts at most 3 MB per photo.
        while let d = data, d.count > 2_800_000, quality > 0.3 {
            quality -= 0.15
            data = resized.jpegData(compressionQuality: quality)
        }
        return data
    }
}

/// Apple's document camera: finds the receipt's edges, straightens it and evens out the light.
struct ReceiptScanner: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIViewController {
        guard VNDocumentCameraViewController.isSupported else {
            // No document camera (for example in the simulator): fall back to the normal camera or photos.
            let picker = UIImagePickerController()
            picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
            picker.delegate = context.coordinator
            return picker
        }
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            done(scan.pageCount > 0 ? scan.imageOfPage(at: 0) : nil)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { done(nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { done(nil) }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
