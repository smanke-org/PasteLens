import AppKit
import PasteLensKit
import Vision

/// Reads the text in image clippings, so screenshots can be searched and their words copied.
enum Recognizer {
    static func cgImage(from content: ClipContent) -> CGImage? {
        for type in UTI.imageTypes {
            guard let data = content.data(for: type) else { continue }
            if type == UTI.pdf {
                guard let page = NSPDFImageRep(data: data) else { continue }
                let image = NSImage(size: page.bounds.size)
                image.addRepresentation(page)
                return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        }
        return nil
    }

    static func text(in content: ClipContent) async -> String? {
        guard let image = cgImage(from: content) else { return nil }
        return await text(in: image)
    }

    static func text(in image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
