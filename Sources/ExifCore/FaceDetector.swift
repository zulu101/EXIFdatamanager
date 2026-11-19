import CoreGraphics
import Foundation
import Vision

/// Gesichter finden und (experimentell) ähnliche Gesichter vorschlagen – mit Apples
/// Vision-Framework, vollständig lokal auf dem Mac, ohne Internet.
///
/// Wichtig: Gespeichert werden nur die Rahmen und Namen in offenen Standards. Die
/// „Merkmale“ für Vorschläge werden bei Bedarf neu berechnet und nirgends abgelegt.
public enum FaceDetector {
    /// Gefundene Gesichter als relative Rechtecke (Ursprung oben links) im übergebenen Bild.
    public static func detectFaces(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        return (request.results ?? [])
            .filter { $0.confidence >= 0.5 }
            .map { observation in
                // Vision: Ursprung unten links → umrechnen auf oben links.
                let b = observation.boundingBox
                let r = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                // Vision rahmt sehr knapp; etwas Rand macht die Markierung natürlicher.
                return r.insetBy(dx: -r.width * 0.12, dy: -r.height * 0.18).intersection(unit)
            }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            .sorted { $0.minX < $1.minX }
    }

    /// Merkmalsvektor eines Bildausschnitts (für Ähnlichkeitsvergleiche).
    public static func featurePrint(of image: CGImage, region: CGRect) throws -> VNFeaturePrintObservation? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pixels = CGRect(x: region.minX * w, y: region.minY * h, width: region.width * w, height: region.height * h)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !pixels.isNull, pixels.width >= 8, pixels.height >= 8,
              let crop = image.cropping(to: pixels) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
        return request.results?.first
    }

    public static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var d: Float = 0
        do {
            try a.computeDistance(&d, to: b)
            return d
        } catch {
            return nil
        }
    }

    /// Schlägt einen Namen vor, wenn das Gesicht einer bekannten Person deutlich ähnlicher ist
    /// als allen anderen. Bewusst vorsichtig: lieber kein Vorschlag als ein falscher.
    /// Braucht Beispiele von mindestens zwei verschiedenen Personen.
    public static func suggestName(for query: VNFeaturePrintObservation,
                                   references: [(name: String, print: VNFeaturePrintObservation)],
                                   ratio: Float = 0.85) -> String? {
        var best: [String: Float] = [:]
        for ref in references {
            guard let d = distance(query, ref.print) else { continue }
            best[ref.name] = min(best[ref.name] ?? .greatestFiniteMagnitude, d)
        }
        return rank(best, ratio: ratio)
    }

    /// Kern der Entscheidung, getrennt testbar: kleinste Distanz je Person → Vorschlag.
    static func rank(_ distances: [String: Float], ratio: Float) -> String? {
        let sorted = distances.sorted { $0.value < $1.value }
        guard sorted.count >= 2 else { return nil }
        return sorted[0].value < sorted[1].value * ratio ? sorted[0].key : nil
    }
}
