import CoreGraphics
import Foundation
@preconcurrency import Vision

/// 把截图里的文字读出来。全部走 Vision 本地识别，不联网。
package enum OCRService {

    package enum Outcome: Sendable {
        case text(String)
        case noText
        case failed
    }

    package static func recognize(image: CGImage, completion: @escaping @MainActor @Sendable (Outcome) -> Void) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let payload = VisionPayload(request: request, handler: handler)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try payload.handler.perform([payload.request])
            } catch {
                Task { @MainActor in completion(.failed) }
                return
            }

            let observations = payload.request.results ?? []
            let lines: [(box: CGRect, text: String)] = observations.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return (observation.boundingBox, text)
            }

            // Vision 的 boundingBox 原点在左下角：先按屏幕从上到下排，同一行再从左到右。
            let sorted = lines.sorted { lhs, rhs in
                if abs(lhs.box.maxY - rhs.box.maxY) > 0.012 {
                    return lhs.box.maxY > rhs.box.maxY
                }
                return lhs.box.minX < rhs.box.minX
            }
            let text = sorted.map(\.text).joined(separator: "\n")

            Task { @MainActor in
                completion(text.isEmpty ? .noText : .text(text))
            }
        }
    }

    /// Serializable bridge for Vision objects, which are not annotated `Sendable`.
    private struct VisionPayload: @unchecked Sendable {
        let request: VNRecognizeTextRequest
        let handler: VNImageRequestHandler
    }
}
