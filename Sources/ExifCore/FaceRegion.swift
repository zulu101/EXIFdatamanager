import CoreGraphics
import Foundation

/// Ein markiertes Gesicht.
///
/// Koordinaten sind relativ (0…1) und beziehen sich auf das Bild **so wie es angezeigt wird**
/// (also nach Anwendung der EXIF-Orientierung), Ursprung oben links. Beim Speichern rechnet
/// `MetadataService` sie in das vom MWG-Standard verlangte Bezugssystem des gespeicherten
/// (ungedrehten) Bildes um.
public struct FaceRegion: Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(id: UUID = UUID(), name: String = "", x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(rect: CGRect, name: String = "") {
        self.init(name: name, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    public var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Auf den Bildbereich begrenzt; `nil`, wenn praktisch nichts übrig bleibt.
    func clamped() -> FaceRegion? {
        let r = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, r.width > 0.003, r.height > 0.003 else { return nil }
        var copy = self
        copy.x = r.minX
        copy.y = r.minY
        copy.width = r.width
        copy.height = r.height
        return copy
    }
}

extension FaceRegion: Equatable {
    /// Die ID ist nur für die Oberfläche da; verglichen werden Name und Position.
    public static func == (lhs: FaceRegion, rhs: FaceRegion) -> Bool {
        let tolerance = 0.001
        return lhs.name == rhs.name
            && abs(lhs.x - rhs.x) < tolerance && abs(lhs.y - rhs.y) < tolerance
            && abs(lhs.width - rhs.width) < tolerance && abs(lhs.height - rhs.height) < tolerance
    }
}

extension CGRect {
    /// Überlappung zweier Rechtecke (Intersection over Union), 0…1.
    public func overlapRatio(_ other: CGRect) -> Double {
        let i = intersection(other)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        let union = width * height + other.width * other.height - inter
        return union > 0 ? inter / union : 0
    }
}

/// Umrechnung zwischen angezeigtem Bild und gespeichertem Bild gemäß EXIF-Orientierung (1–8).
public enum ImageOrientation {
    /// Punkt im gespeicherten Bild (u, v) → Punkt im angezeigten Bild (x, y).
    static func toDisplay(_ u: Double, _ v: Double, _ orientation: Int) -> (Double, Double) {
        switch orientation {
        case 2: return (1 - u, v)
        case 3: return (1 - u, 1 - v)
        case 4: return (u, 1 - v)
        case 5: return (v, u)
        case 6: return (1 - v, u)
        case 7: return (1 - v, 1 - u)
        case 8: return (v, 1 - u)
        default: return (u, v)
        }
    }

    /// Punkt im angezeigten Bild (x, y) → Punkt im gespeicherten Bild (u, v).
    static func toStored(_ x: Double, _ y: Double, _ orientation: Int) -> (Double, Double) {
        switch orientation {
        case 2: return (1 - x, y)
        case 3: return (1 - x, 1 - y)
        case 4: return (x, 1 - y)
        case 5: return (y, x)
        case 6: return (y, 1 - x)
        case 7: return (1 - y, 1 - x)
        case 8: return (1 - y, x)
        default: return (x, y)
        }
    }

    public static func toStored(_ rect: CGRect, orientation: Int) -> CGRect {
        transform(rect) { toStored($0, $1, orientation) }
    }

    public static func toDisplay(_ rect: CGRect, orientation: Int) -> CGRect {
        transform(rect) { toDisplay($0, $1, orientation) }
    }

    private static func transform(_ rect: CGRect, _ f: (Double, Double) -> (Double, Double)) -> CGRect {
        let a = f(rect.minX, rect.minY)
        let b = f(rect.maxX, rect.maxY)
        return CGRect(x: min(a.0, b.0), y: min(a.1, b.1), width: abs(a.0 - b.0), height: abs(a.1 - b.1))
    }
}

// MARK: - Drehen um 90°

extension ImageOrientation {
    /// Neue EXIF-Orientierung, wenn das angezeigte Bild um 90° gedreht wird.
    /// (Gespiegelte Orientierungen bleiben gespiegelt.)
    public static func rotated(_ orientation: Int, clockwise: Bool) -> Int {
        let cw: [Int: Int] = [1: 6, 6: 3, 3: 8, 8: 1, 2: 7, 7: 4, 4: 5, 5: 2]
        let ccw: [Int: Int] = Dictionary(uniqueKeysWithValues: cw.map { ($1, $0) })
        return (clockwise ? cw : ccw)[orientation] ?? (clockwise ? 6 : 8)
    }

    /// Anzahl Vierteldrehungen im Uhrzeigersinn von `from` nach `to` (0…3), oder `nil`,
    /// wenn sich die beiden nicht nur durch Drehen unterscheiden.
    public static func quarterTurns(from: Int, to: Int) -> Int? {
        var current = from
        for turns in 0..<4 {
            if current == to { return turns }
            current = rotated(current, clockwise: true)
        }
        return nil
    }

    /// Relatives Rechteck im angezeigten Bild nach einer 90°-Drehung des Bildes.
    public static func rotate(_ rect: CGRect, clockwise: Bool) -> CGRect {
        // Im Uhrzeigersinn: (x, y) → (1 − y, x); gegen den Uhrzeigersinn: (x, y) → (y, 1 − x)
        if clockwise {
            return CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        } else {
            return CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        }
    }

    /// Dreht ein Bild um Vierteldrehungen im Uhrzeigersinn (nur für die Anzeige).
    public static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let w = image.width, h = image.height
        let (outW, outH) = turns % 2 == 0 ? (w, h) : (h, w)
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ?? CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CoreGraphics: Ursprung unten links, positive Winkel gegen den Uhrzeigersinn.
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }
}

extension FaceRegion {
    public func rotated(clockwise: Bool) -> FaceRegion {
        var copy = self
        let r = ImageOrientation.rotate(rect, clockwise: clockwise)
        copy.x = r.minX
        copy.y = r.minY
        copy.width = r.width
        copy.height = r.height
        return copy
    }
}
