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
            return String(localized: "„\(url.lastPathComponent)“ konnte nicht gelesen werden.")
        case .unsupportedFormat(let url):
            return String(localized: "Das Dateiformat von „\(url.lastPathComponent)“ kann nicht beschrieben werden.")
        case .writeFailed(let url, let reason):
            return String(localized: "„\(url.lastPathComponent)“ konnte nicht gespeichert werden: \(reason)")
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
        } else if let xmp,
                  let lat = xmpCoordinate(xmp, kCGImagePropertyGPSLatitude),
                  let lon = xmpCoordinate(xmp, kCGImagePropertyGPSLongitude) {
            // Manche Programme speichern GPS nur in XMP.
            m.latitude = lat
            m.longitude = lon
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
        m.preservedFileName = xmpString(xmp, "xmpMM:PreservedFileName")
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

        // Gesichtsregionen (MWG + IPTC)
        let geometry = imageGeometry(props)
        m.faces = RegionMetadata.read(RegionMetadata.topLevelFields(xmp),
                                      orientation: geometry.orientation, storedSize: geometry.size).faces

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

        // Gesichtsregionen: nur anfassen, wenn es welche gibt oder gab – und nur in Formaten,
        // in denen ImageIO sie zuverlässig speichert (nicht PNG, siehe `supportsFaceRegions`).
        let sourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let geometry = imageGeometry(sourceProps)
        let existing = RegionMetadata.read(RegionMetadata.topLevelFields(meta),
                                           orientation: geometry.orientation, storedSize: geometry.size)
        let regionsSupported = supportsFaceRegions(type: type as String)
        var expected = m
        if !regionsSupported {
            expected.faces = existing.faces
        } else if !m.faces.isEmpty || !existing.isEmpty {
            let fields = RegionMetadata.fields(for: m.faces, preserving: existing,
                                               orientation: geometry.orientation, storedSize: geometry.size)
            RegionMetadata.replace(in: meta, with: fields)
        }

        // Schreibwege je Format. Bei PNG verhält sich ImageIO je nach Datei unterschiedlich,
        // daher werden dort beide Wege probiert – übernommen wird nur ein vollständig korrektes
        // Ergebnis.
        let utType = UTType(type as String)
        let strategies: [WriteStrategy]
        if utType?.conforms(to: .tiff) ?? false {
            strategies = [.reencode]
        } else if utType?.conforms(to: .png) ?? false {
            strategies = [.copy, .reencode]
        } else {
            strategies = [.copy]
        }

        var lastError: Error = MetadataError.unsupportedFormat(url)
        var written: URL?
        for strategy in strategies {
            do {
                written = try attempt(strategy, source: source, type: type, meta: meta,
                                      metadata: m, expected: expected, url: url)
                break
            } catch {
                lastError = error
            }
        }
        guard let tmp = written else { throw lastError }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw MetadataError.writeFailed(url, error.localizedDescription)
        }
    }

    enum WriteStrategy {
        /// Nur Metadaten ersetzen, Bilddaten 1:1 übernehmen (JPEG, HEIC, PNG).
        case copy
        /// Bild verlustfrei neu schreiben, mit expliziten EXIF/GPS-Angaben (TIFF, PNG).
        case reencode
    }

    /// Schreibt eine temporäre Datei und prüft sie vollständig. Gibt sie nur zurück, wenn alle
    /// Angaben korrekt darin stehen; sonst wird sie gelöscht und ein Fehler geworfen.
    private static func attempt(_ strategy: WriteStrategy, source: CGImageSource, type: CFString,
                                meta: CGMutableImageMetadata, metadata m: PhotoMetadata,
                                expected: PhotoMetadata, url: URL) throws -> URL {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else {
            throw MetadataError.unsupportedFormat(url)
        }
        let fail: (String) -> MetadataError = { reason in
            try? FileManager.default.removeItem(at: tmp)
            return MetadataError.writeFailed(url, reason)
        }

        switch strategy {
        case .reencode:
            // TIFF: `CopyImageSource` legt dort keinen GPS-Block an. Verlustfreie Formate
            // werden daher mit expliziten Angaben neu geschrieben (Pixel bleiben identisch).
            guard CGImageSourceGetCount(source) == 1,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw fail(String(localized: "Mehrseitige bzw. animierte Bilddateien werden nicht unterstützt."))
            }
            let properties = updatedProperties(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:], with: m)
            CGImageDestinationAddImageAndMetadata(destination, image, meta, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw fail(String(localized: "Die Datei konnte nicht geschrieben werden."))
            }
        case .copy:
            let options: [String: Any] = [
                kCGImageDestinationMetadata as String: meta,
                // Wir übergeben die komplette (kopierte) Metadaten-Menge. Ohne Merge lassen sich
                // so auch Felder löschen.
                kCGImageDestinationMergeMetadata as String: false,
            ]
            var error: Unmanaged<CFError>?
            guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
                let reason = error.map { ($0.takeRetainedValue() as Error).localizedDescription }
                    ?? String(localized: "Das Format unterstützt das verlustfreie Schreiben von Metadaten nicht.")
                throw fail(reason)
            }
        }

        // Technische Prüfung der neuen Datei.
        guard let check = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              CGImageSourceGetCount(check) == CGImageSourceGetCount(source),
              pixelSize(check) == pixelSize(source) else {
            throw fail(String(localized: "Die neu geschriebene Datei war fehlerhaft. Das Original wurde nicht verändert."))
        }

        // Inhaltliche Prüfung: Steht wirklich alles in der neuen Datei? Erst dann darf sie das
        // Original ersetzen – sonst bleibt es unverändert.
        let missing = expected.differences(from: read(source: check))
        guard missing.isEmpty else {
            throw fail(String(localized: "Diese Angaben wären nicht korrekt gespeichert worden: \(missing.joined(separator: ", ")). Das Original wurde nicht verändert."))
        }
        return tmp
    }

    /// Klassische Property-Dictionaries (EXIF, GPS, TIFF, IPTC) passend zu den Metadaten anpassen.
    static func updatedProperties(_ original: [String: Any], with m: PhotoMetadata) -> [String: Any] {
        var props = original

        var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal as String] = m.date?.exifString
        props[kCGImagePropertyExifDictionary as String] = exif

        var gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        if let lat = m.latitude, let lon = m.longitude {
            gps[kCGImagePropertyGPSLatitude as String] = abs(lat)
            gps[kCGImagePropertyGPSLatitudeRef as String] = lat < 0 ? "S" : "N"
            gps[kCGImagePropertyGPSLongitude as String] = abs(lon)
            gps[kCGImagePropertyGPSLongitudeRef as String] = lon < 0 ? "W" : "E"
        } else {
            for key in [kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef,
                        kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef] {
                gps[key as String] = nil
            }
        }
        props[kCGImagePropertyGPSDictionary as String] = gps.isEmpty ? nil : gps

        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFImageDescription as String] = m.caption.isEmpty ? nil : m.caption
        props[kCGImagePropertyTIFFDictionary as String] = tiff

        // Einen vorhandenen IPTC-IIM-Block konsistent halten, aber keinen neuen anlegen.
        if var iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            let value: (String) -> String? = { $0.isEmpty ? nil : $0 }
            // Das Datum ist in XMP `photoshop:DateCreated` maßgeblich; ein IPTC-Datum würde es
            // sonst beim Löschen wiederherstellen.
            iptc[kCGImagePropertyIPTCDateCreated as String] = nil
            iptc[kCGImagePropertyIPTCTimeCreated as String] = nil
            iptc[kCGImagePropertyIPTCSubLocation as String] = value(m.location)
            iptc[kCGImagePropertyIPTCCity as String] = value(m.city)
            iptc[kCGImagePropertyIPTCProvinceState as String] = value(m.state)
            iptc[kCGImagePropertyIPTCCountryPrimaryLocationName as String] = value(m.country)
            iptc[kCGImagePropertyIPTCCaptionAbstract as String] = value(m.caption)
            let subject = PhotoMetadata.unique(m.keywords + m.people)
            iptc[kCGImagePropertyIPTCKeywords as String] = subject.isEmpty ? nil : subject
            props[kCGImagePropertyIPTCDictionary as String] = iptc
        }
        return props
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

        // Ursprünglicher Dateiname (XMP Media Management) – bleibt beim Umbenennen erhalten.
        setXMP(meta, "xmpMM:PreservedFileName", m.preservedFileName ?? "")

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
        // Mehrfach, falls mehrere XMP-Felder auf dieselbe Eigenschaft abgebildet sind.
        for _ in 0..<4 {
            guard let tag = CGImageMetadataCopyTagMatchingImageProperty(meta, dictionary, key),
                  let prefix = CGImageMetadataTagCopyPrefix(tag),
                  let name = CGImageMetadataTagCopyName(tag),
                  CGImageMetadataRemoveTagWithPath(meta, nil, "\(prefix as String):\(name as String)" as CFString)
            else { return }
        }
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

    /// XMP-Koordinate wie „33,51.40704S“ oder „33,51,24S“ in Dezimalgrad umrechnen.
    private static func xmpCoordinate(_ meta: CGImageMetadata, _ key: CFString) -> Double? {
        guard let tag = CGImageMetadataCopyTagMatchingImageProperty(meta, kCGImagePropertyGPSDictionary, key),
              let raw = CGImageMetadataTagCopyValue(tag) as? String else { return nil }
        return parseXMPCoordinate(raw)
    }

    static func parseXMPCoordinate(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard let ref = s.last, "NSEW".contains(ref) else { return Double(s) }
        s.removeLast()
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        var value = parts[0]
        if parts.count > 1 { value += parts[1] / 60 }
        if parts.count > 2 { value += parts[2] / 3600 }
        return (ref == "S" || ref == "W") ? -value : value
    }

    /// Gesichtsrahmen werden nur in Formaten gespeichert, in denen ImageIO die verschachtelten
    /// XMP-Strukturen zuverlässig schreibt. Bei PNG war das in Tests nicht der Fall.
    public static func supportsFaceRegions(type: String) -> Bool {
        !(UTType(type)?.conforms(to: .png) ?? false)
    }

    public static func supportsFaceRegions(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return true }
        return supportsFaceRegions(type: type.identifier)
    }

    /// EXIF-Orientierung und Größe des gespeicherten (ungedrehten) Bildes.
    static func imageGeometry(_ props: [String: Any]) -> (orientation: Int, size: CGSize) {
        let orientation = (props[kCGImagePropertyOrientation as String] as? Int) ?? 1
        let width = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        return ((1...8).contains(orientation) ? orientation : 1, CGSize(width: width, height: height))
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
