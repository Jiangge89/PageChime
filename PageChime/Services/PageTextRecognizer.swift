import UIKit
import Vision

protocol PageTextRecognizing {
    /// The text on photographed book pages, in reading order. Recognition
    /// runs on device; no image leaves the phone.
    func recognizeText(in pages: [UIImage], language: ReadingLanguage) async throws -> String
}

enum PageTextError: LocalizedError {
    case unreadableImage

    var errorDescription: String? { "The photo couldn't be read." }
}

/// Apple Vision text recognition.
final class VisionTextRecognizer: PageTextRecognizing {
    func recognizeText(in pages: [UIImage], language: ReadingLanguage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try pages.map { try Self.recognize($0, language: language) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }.value
    }

    private static func recognize(_ page: UIImage, language: ReadingLanguage) throws -> String {
        guard let image = page.cgImage else { throw PageTextError.unreadableImage }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = language == .chinese ? ["zh-Hans", "en-US"] : ["en-US"]

        let handler = VNImageRequestHandler(cgImage: image, orientation: page.imageOrientation.cgOrientation)
        try handler.perform([request])

        // Top to bottom, then left to right. Vision's origin is bottom-left;
        // lines whose centres are within half a line height count as one row.
        let lines = (request.results ?? []).compactMap { observation -> (box: CGRect, text: String)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (observation.boundingBox, text)
        }
        let sorted = lines.sorted { a, b in
            let rowTolerance = min(a.box.height, b.box.height) / 2
            if abs(a.box.midY - b.box.midY) > rowTolerance { return a.box.midY > b.box.midY }
            return a.box.minX < b.box.minX
        }
        return sorted.map(\.text).joined(separator: "\n")
    }
}

private extension UIImage.Orientation {
    var cgOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
