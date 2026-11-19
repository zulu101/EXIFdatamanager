import CoreGraphics
import Foundation
import ImageIO

/// Lesen und Schreiben von Gesichtsregionen in zwei offenen Standards:
///
/// * **MWG Regions** (Metadata Working Group, `mwg-rs:Regions`): weit verbreitet, z. B. in
///   Lightroom Classic, digiKam und ExifTool. Rechteck über Mittelpunkt, Breite und Höhe.
/// * **IPTC Image Region** (`Iptc4xmpExt:ImageRegion`, IPTC Photo Metadata 2019.1+): der
///   offizielle IPTC-Standard. Rechteck über linke obere Ecke, Breite und Höhe.
///
/// Beide Formate beziehen sich auf das gespeicherte Bild vor Anwendung der EXIF-Orientierung.
/// Regionen anderer Art (z. B. Haustiere, Fokusbereiche) aus anderen Programmen bleiben erhalten.
enum RegionMetadata {
    static let mwg = "http://www.metadataworkinggroup.com/schemas/regions/"
    static let stArea = "http://ns.adobe.com/xmp/sType/Area#"
    static let stDim = "http://ns.adobe.com/xap/1.0/sType/Dimensions#"
    static let iptc = MetadataService.iptcExtNamespace
    static let humanType = "http://cv.iptc.org/newscodes/imageregiontype/human"

    struct Contents {
        var faces: [FaceRegion] = []
        /// Regionen, die keine Gesichter sind – werden unverändert zurückgeschrieben.
        var otherMWG: [XMPItem] = []
        var otherIPTC: [XMPItem] = []
        var isEmpty: Bool { faces.isEmpty && otherMWG.isEmpty && otherIPTC.isEmpty }
    }

    // MARK: - Lesen

    static func read(_ fields: [XMPField], orientation: Int, storedSize: CGSize) -> Contents {
        var contents = Contents()
        let root = XMPNode.structure(fields)

        // MWG
        for item in root.field(mwg, "Regions")?.field(mwg, "RegionList")?.items ?? [] {
            let region = item.value
            let type = region.field(mwg, "Type")?.stringValue ?? ""
            guard type.caseInsensitiveCompare("Face") == .orderedSame,
                  let area = region.field(mwg, "Area"),
                  let cx = area.field(stArea, "x")?.doubleValue, let cy = area.field(stArea, "y")?.doubleValue,
                  let w = area.field(stArea, "w")?.doubleValue, let h = area.field(stArea, "h")?.doubleValue,
                  (area.field(stArea, "unit")?.stringValue ?? "normalized") == "normalized" else {
                contents.otherMWG.append(item)
                continue
            }
            let stored = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            let display = ImageOrientation.toDisplay(stored, orientation: orientation)
            let name = region.field(mwg, "Name")?.stringValue ?? ""
            if let face = FaceRegion(rect: display, name: name).clamped() {
                contents.faces.append(face)
            }
        }

        // IPTC – ergänzt Gesichter, die nur dort stehen (z. B. von anderer Software geschrieben).
        for item in root.field(iptc, "ImageRegion")?.items ?? [] {
            let region = item.value
            guard isPersonRegion(region),
                  let boundary = region.field(iptc, "RegionBoundary"),
                  boundary.field(iptc, "rbShape")?.stringValue == "rectangle",
                  var x = boundary.field(iptc, "rbX")?.doubleValue, var y = boundary.field(iptc, "rbY")?.doubleValue,
                  var w = boundary.field(iptc, "rbW")?.doubleValue, var h = boundary.field(iptc, "rbH")?.doubleValue else {
                contents.otherIPTC.append(item)
                continue
            }
            if boundary.field(iptc, "rbUnit")?.stringValue == "pixel" {
                guard storedSize.width > 0, storedSize.height > 0 else {
                    contents.otherIPTC.append(item)
                    continue
                }
                x /= storedSize.width; w /= storedSize.width
                y /= storedSize.height; h /= storedSize.height
            }
            let display = ImageOrientation.toDisplay(CGRect(x: x, y: y, width: w, height: h), orientation: orientation)
            let name = region.field(iptc, "PersonInImage")?.strings.first
                ?? region.field(iptc, "Name")?.stringValue ?? ""
            if let index = contents.faces.firstIndex(where: { $0.rect.overlapRatio(display) > 0.6 }) {
                if contents.faces[index].name.isEmpty { contents.faces[index].name = name }
            } else if let face = FaceRegion(rect: display, name: name).clamped() {
                contents.faces.append(face)
            }
        }
        return contents
    }

    /// Ist eine IPTC-Region eine Person? (Inhaltstyp „human“, eingetragene Person, oder – wie
    /// ExifTool sie aus MWG-Gesichtern erzeugt – nur ein Name ohne weitere Typangabe.)
    private static func isPersonRegion(_ region: XMPNode) -> Bool {
        if !(region.field(iptc, "PersonInImage")?.strings.isEmpty ?? true) { return true }
        if let types = region.field(iptc, "rCtype") {
            return types.items.contains { item in
                item.value.field(iptc, "Identifier")?.strings.contains(humanType) ?? false
            }
        }
        return region.field(iptc, "rRole") == nil && region.field(iptc, "Name") != nil
    }

    // MARK: - Schreiben

    static func fields(for faces: [FaceRegion], preserving other: Contents,
                       orientation: Int, storedSize: CGSize) -> [XMPField] {
        var result: [XMPField] = []
        let number: (Double) -> XMPNode = { .text(String(format: "%.6f", $0)) }

        // MWG
        let mwgFaces: [XMPItem] = faces.map { face in
            let r = ImageOrientation.toStored(face.rect, orientation: orientation)
            var fields: [XMPField] = [
                XMPField(mwg, "Area", .structure([
                    XMPField(stArea, "x", number(r.midX)),
                    XMPField(stArea, "y", number(r.midY)),
                    XMPField(stArea, "w", number(r.width)),
                    XMPField(stArea, "h", number(r.height)),
                    XMPField(stArea, "unit", .text("normalized")),
                ])),
                XMPField(mwg, "Type", .text("Face")),
            ]
            if !face.name.isEmpty { fields.append(XMPField(mwg, "Name", .text(face.name))) }
            return XMPItem(value: .structure(fields))
        }
        let mwgItems = mwgFaces + other.otherMWG
        if !mwgItems.isEmpty {
            result.append(XMPField(mwg, "Regions", .structure([
                XMPField(mwg, "AppliedToDimensions", .structure([
                    XMPField(stDim, "w", .text(String(Int(storedSize.width)))),
                    XMPField(stDim, "h", .text(String(Int(storedSize.height)))),
                    XMPField(stDim, "unit", .text("pixel")),
                ])),
                XMPField(mwg, "RegionList", .array(.bag, mwgItems)),
            ])))
        }

        // IPTC
        let iptcFaces: [XMPItem] = faces.enumerated().map { index, face in
            let r = ImageOrientation.toStored(face.rect, orientation: orientation)
            var fields: [XMPField] = [
                XMPField(iptc, "RegionBoundary", .structure([
                    XMPField(iptc, "rbShape", .text("rectangle")),
                    XMPField(iptc, "rbUnit", .text("relative")),
                    XMPField(iptc, "rbX", number(r.minX)),
                    XMPField(iptc, "rbY", number(r.minY)),
                    XMPField(iptc, "rbW", number(r.width)),
                    XMPField(iptc, "rbH", number(r.height)),
                ])),
                XMPField(iptc, "rId", .text("face\(index + 1)")),
                XMPField(iptc, "rCtype", .array(.bag, [XMPItem(value: .structure([
                    XMPField(iptc, "Identifier", .array(.bag, [XMPItem(value: .text(humanType))])),
                    XMPField(iptc, "Name", .array(.alt, [XMPItem(lang: "x-default", value: .text("Human"))])),
                ]))])),
            ]
            if !face.name.isEmpty {
                fields.append(XMPField(iptc, "Name", .array(.alt, [XMPItem(lang: "x-default", value: .text(face.name))])))
                fields.append(XMPField(iptc, "PersonInImage", .array(.bag, [XMPItem(value: .text(face.name))])))
            }
            return XMPItem(value: .structure(fields))
        }
        let iptcItems = iptcFaces + other.otherIPTC
        if !iptcItems.isEmpty {
            result.append(XMPField(iptc, "ImageRegion", .array(.bag, iptcItems)))
        }
        return result
    }

    /// Ersetzt die Regions-Einträge in den Metadaten durch `fields`.
    static func replace(in meta: CGMutableImageMetadata, with fields: [XMPField]) {
        for (namespace, name) in [(mwg, "Regions"), (iptc, "ImageRegion")] {
            if let existing = MetadataService.findTag(meta, namespace: namespace, name: name),
               let prefix = CGImageMetadataTagCopyPrefix(existing) {
                _ = CGImageMetadataRemoveTagWithPath(meta, nil, "\(prefix as String):\(name)" as CFString)
            }
        }
        guard !fields.isEmpty else { return }

        let (data, prefixes) = XMP.serialize(fields)
        for (namespace, prefix) in prefixes {
            _ = CGImageMetadataRegisterNamespaceForPrefix(meta, namespace as CFString, prefix as CFString, nil)
        }
        guard let parsed = CGImageMetadataCreateFromXMPData(data as CFData) else { return }
        CGImageMetadataEnumerateTagsUsingBlock(parsed, nil, nil) { _, tag in
            if let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag) {
                _ = CGImageMetadataSetTagWithPath(meta, nil, "\(prefix as String):\(name as String)" as CFString, tag)
            }
            return true
        }
    }

    /// Alle XMP-Eigenschaften der obersten Ebene (über ImageIOs eigene XMP-Ausgabe).
    static func topLevelFields(_ meta: CGImageMetadata?) -> [XMPField] {
        guard let meta, let data = CGImageMetadataCreateXMPData(meta, nil) else { return [] }
        return XMP.parse(data as Data)
    }
}
