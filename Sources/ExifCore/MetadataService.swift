import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MetadataError: LocalizedError {
    case cannotRead(URL)
    case unsupportedFormat(URL)
    case writeFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .cannotRead(let url):
            return "„\(url.lastPathComponent)“ konnte nicht gelesen werden."
        case .unsupportedFormat(let url):
            return "Das Dateiformat von „\(url.lastPathComponent)“ kann nicht beschrieben werden."
        case .writeFailed(let url, let reason):
            return "„\(url.lastPathComponent)“ konnte nicht gespeichert werden: \(reason)"
        }
    }
}

/// Liest und schreibt Metadaten mit Apples ImageIO.
///
/// Geschrieben wird mit `CGImageDestinationCopyImageSource`: Dabei werden nur die Metadaten
/// ersetzt, die Bilddaten werden 1:1 übernommen (kein erneutes JPEG-Komprimieren).
public enum MetadataService {
    public static let supportedExtensions: Set<String> = ["jpg", "jpeg", "tif", "tiff", "png", "heic", "heif"]

    static let iptcExtNamespace = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
    static let iptcExtPrefix = "Iptc4xmpExt"
    static let dcNamespace = "http://purl.org/dc/elements/1.1/"

    // MARK: - Lesen

    public static func read(from url: URL) throws -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw MetadataError.cannotRead(url)
        }
        return read(source: source)
    }

    static func read(source: CGImageSource) -> PhotoMetadata {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil)

        var m = PhotoMetadata()

        // Datum: XMP (mit Genauigkeit) bevorzugen, solange es zum EXIF-Datum passt.
        let xmpDate = xmpString(xmp, "photoshop:DateCreated").flatMap(PartialDate.init(xmpString:))
        let exifDate = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)
            .flatMap(PartialDate.init(exifString:))
        switch (xmpDate, exifDate) {
        case let (x?, e?):
            m.date = x.isConsistent(with: e) ? x : e
        case let (x?, nil):
            m.date = x
        case let (nil, e?):
            m.date = e
        default:
            m.date = nil
        }

        // GPS
        if let lat = number(gps[kCGImagePropertyGPSLatitude as String]),
           let lon = number(gps[kCGImagePropertyGPSLongitude as String]) {
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N").uppercased()
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E").uppercased()
            m.latitude = latRef == "S" ? -abs(lat) : abs(lat)
            m.longitude = lonRef == "W" ? -abs(lon) : abs(lon)
        }

        // Ort als Text
        m.location = xmpString(xmp, "Iptc4xmpCore:Location")
            ?? clean(iptc[kCGImagePropertyIPTCSubLocation as String]) ?? ""
        m.city = xmpString(xmp, "photoshop:City")
            ?? clean(iptc[kCGImagePropertyIPTCCity as String]) ?? ""
        m.state = xmpString(xmp, "photoshop:State")
            ?? clean(iptc[kCGImagePropertyIPTCProvinceState as String]) ?? ""
        m.country = xmpString(xmp, "photoshop:Country")
            ?? clean(iptc[kCGImagePropertyIPTCCountryPrimaryLocationName as String]) ?? ""

        // Beschreibung
        m.caption = xmpString(xmp, "dc:description")
            ?? clean(iptc[kCGImagePropertyIPTCCaptionAbstract as String])
            ?? clean(tiff[kCGImagePropertyTIFFImageDescription as String]) ?? ""

        // Personen & Schlagwörter
        var people: [String] = []
        if let xmp, let tag = findTag(xmp, namespace: iptcExtNamespace, name: "PersonInImage") {
            people = stringValues(of: tag)
        }
        var subject: [String] = []
        if let xmp, let tag = findTag(xmp, namespace: dcNamespace, name: "subject") {
            subject = stringValues(of: tag)
        }
        if subject.isEmpty, let kw = iptc[kCGImagePropertyIPTCKeywords as String] as? [String] {
            subject = kw
        }
        m.people = people
        m.keywords = subject.filter { !people.contains($0) }

        return m.normalized()
    }

    // MARK: - Schreiben

    /// Schreibt die Metadaten in die Datei. Die Datei wird erst ersetzt, wenn die neue Version
    /// vollständig und lesbar geschrieben wurde.
    public static func write(_ metadata: PhotoMetadata, to url: URL) throws {
        let m = metadata.normalized()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) else {
            throw MetadataError.cannotRead(url)
        }

        // Vorhandene Metadaten vollständig übernehmen und nur unsere Felder ändern.
        let meta: CGMutableImageMetadata
        if let existing = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let copy = CGImageMetadataCreateMutableCopy(existing) {
            meta = copy
        } else {
            meta = CGImageMetadataCreateMutable()
        }
        apply(m, to: meta)

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else {
            throw MetadataError.unsupportedFormat(url)
        }

        let options: [String: Any] = [
            kCGImageDestinationMetadata as String: meta,
            // Wir übergeben die komplette (kopierte) Metadaten-Menge. Ohne Merge lassen sich
            // so auch Felder löschen.
            kCGImageDestinationMergeMetadata as String: false,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            try? FileManager.default.removeItem(at: tmp)
            let reason = error.map { ($0.takeRetainedValue() as Error).localizedDescription }
                ?? "Das Format unterstützt das verlustfreie Schreiben von Metadaten nicht."
            throw MetadataError.writeFailed(url, reason)
        }

        // Plausibilitätsprüfung der neuen Datei, bevor das Original ersetzt wird.
        guard let check = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              CGImageSourceGetCount(check) == CGImageSourceGetCount(source),
              pixelSize(check) == pixelSize(source) else {
            try? FileManager.default.removeItem(at: tmp)
            throw MetadataError.writeFailed(url, "Die neu geschriebene Datei war fehlerhaft. Das Original wurde nicht verändert.")
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw MetadataError.writeFailed(url, error.localizedDescription)
        }
    }

    static func apply(_ m: PhotoMetadata, to meta: CGMutableImageMetadata) {
        _ = CGImageMetadataRegisterNamespaceForPrefix(meta, iptcExtNamespace as CFString, iptcExtPrefix as CFString, nil)

        // Datum
        if let date = m.date {
            setProperty(meta, kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, date.exifString as CFString)
            setXMP(meta, "photoshop:DateCreated", date.xmpString)
        } else {
            removeProperty(meta, kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal)
            setXMP(meta, "photoshop:DateCreated", "")
        }

        // GPS
        if let lat = m.latitude, let lon = m.longitude {
            setProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, NSNumber(value: abs(lat)))
            setProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, (lat < 0 ? "S" : "N") as CFString)
            setProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, NSNumber(value: abs(lon)))
            setProperty(meta, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, (lon < 0 ? "W" : "E") as CFString)
        } else {
            for key in [kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef,
                        kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef] {
                removeProperty(meta, kCGImagePropertyGPSDictionary, key)
            }
        }

        // Ort als Text
        setXMP(meta, "Iptc4xmpCore:Location", m.location)
        setXMP(meta, "photoshop:City", m.city)
        setXMP(meta, "photoshop:State", m.state)
        setXMP(meta, "photoshop:Country", m.country)

        // Beschreibung (EXIF ImageDescription + XMP dc:description)
        if m.caption.isEmpty {
            removeProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription)
            setXMP(meta, "dc:description", "")
        } else {
            setProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, m.caption as CFString)
        }

        // Personen zusätzlich als Schlagwort – so findet man sie z. B. in Apple Fotos und Lightroom.
        let subject = PhotoMetadata.unique(m.keywords + m.people)
        setArray(meta, namespace: dcNamespace, prefix: "dc", name: "subject", values: subject)
        setArray(meta, namespace: iptcExtNamespace, prefix: iptcExtPrefix, name: "PersonInImage", values: m.people)
    }

    // MARK: - Vorschaubilder

    public static func thumbnail(for url: URL, maxPixelSize: Int, allowEmbedded: Bool = true) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let fromImageKey = allowEmbedded
            ? kCGImageSourceCreateThumbnailFromImageIfAbsent
            : kCGImageSourceCreateThumbnailFromImageAlways
        let options: [String: Any] = [
            fromImageKey as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: maxPixelSize,
            kCGImageSourceShouldCacheImmediately as String: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Hilfsfunktionen

    private static func setProperty(_ meta: CGMutableImageMetadata, _ dictionary: CFString, _ key: CFString, _ value: CFTypeRef) {
        removeProperty(meta, dictionary, key)
        _ = CGImageMetadataSetValueMatchingImageProperty(meta, dictionary, key, value)
    }

    private static func removeProperty(_ meta: CGMutableImageMetadata, _ dictionary: CFString, _ key: CFString) {
        guard let tag = CGImageMetadataCopyTagMatchingImageProperty(meta, dictionary, key),
              let prefix = CGImageMetadataTagCopyPrefix(tag),
              let name = CGImageMetadataTagCopyName(tag) else { return }
        _ = CGImageMetadataRemoveTagWithPath(meta, nil, "\(prefix as String):\(name as String)" as CFString)
    }

    private static func setXMP(_ meta: CGMutableImageMetadata, _ path: String, _ value: String) {
        _ = CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString)
        guard !value.isEmpty else { return }
        _ = CGImageMetadataSetValueWithPath(meta, nil, path as CFString, value as CFString)
    }

    private static func setArray(_ meta: CGMutableImageMetadata, namespace: String, prefix: String, name: String, values: [String]) {
        // Vorhandenes Feld entfernen – auch wenn eine andere Software ein anderes Präfix verwendet.
        if let existing = findTag(meta, namespace: namespace, name: name),
           let existingPrefix = CGImageMetadataTagCopyPrefix(existing) {
            _ = CGImageMetadataRemoveTagWithPath(meta, nil, "\(existingPrefix as String):\(name)" as CFString)
        }
        _ = CGImageMetadataRemoveTagWithPath(meta, nil, "\(prefix):\(name)" as CFString)
        guard !values.isEmpty,
              let tag = CGImageMetadataTagCreate(namespace as CFString, prefix as CFString, name as CFString,
                                                 .arrayUnordered, values as CFArray) else { return }
        _ = CGImageMetadataSetTagWithPath(meta, nil, "\(prefix):\(name)" as CFString, tag)
    }

    static func findTag(_ meta: CGImageMetadata, namespace: String, name: String) -> CGImageMetadataTag? {
        var found: CGImageMetadataTag?
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, nil) { _, tag in
            if (CGImageMetadataTagCopyNamespace(tag) as String?) == namespace,
               (CGImageMetadataTagCopyName(tag) as String?) == name {
                found = tag
                return false
            }
            return true
        }
        return found
    }

    static func stringValues(of tag: CGImageMetadataTag) -> [String] {
        guard let value = CGImageMetadataTagCopyValue(tag) else { return [] }
        if let s = value as? String { return [s] }
        guard let array = value as? [AnyObject] else { return [] }
        return array.compactMap { element -> String? in
            if let s = element as? String { return s }
            if CFGetTypeID(element) == CGImageMetadataTagGetTypeID() {
                let child = element as! CGImageMetadataTag
                return CGImageMetadataTagCopyValue(child) as? String
            }
            return nil
        }
    }

    private static func xmpString(_ meta: CGImageMetadata?, _ path: String) -> String? {
        guard let meta, let value = CGImageMetadataCopyStringValueWithPath(meta, nil, path as CFString) else {
            return nil
        }
        return clean(value as String)
    }

    private static func clean(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func pixelSize(_ source: CGImageSource) -> [Int] {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        return [props[kCGImagePropertyPixelWidth as String] as? Int ?? -1,
                props[kCGImagePropertyPixelHeight as String] as? Int ?? -1]
    }
}

/// Legt vor dem ersten Speichern eine unveränderte Kopie des Originals an.
public enum BackupService {
    public static let folderName = "Originale (Backup)"

    public static func backupIfNeeded(_ url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        let target = dir.appendingPathComponent(url.lastPathComponent)
        guard !fm.fileExists(atPath: target.path) else { return }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.copyItem(at: url, to: target)
    }
}
