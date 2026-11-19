import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ExifCore

final class FaceRegionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeImage(_ type: UTType, ext: String, orientation: Int = 1, width: Int = 80, height: Int = 60) -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent("faces-\(orientation).\(ext)")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!,
                                   [kCGImagePropertyOrientation as String: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func sampleFaces() -> [FaceRegion] {
        [FaceRegion(name: "Erika Mustermann", x: 0.2, y: 0.3, width: 0.25, height: 0.2),
         FaceRegion(name: "", x: 0.6, y: 0.1, width: 0.1, height: 0.15)]
    }

    private func xmpFields(_ url: URL) -> [XMPField] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return RegionMetadata.topLevelFields(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
    }

    // MARK: - Orientierung

    func testOrientationRoundtrip() {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25)
        for orientation in 1...8 {
            let stored = ImageOrientation.toStored(rect, orientation: orientation)
            let back = ImageOrientation.toDisplay(stored, orientation: orientation)
            XCTAssertEqual(back.minX, rect.minX, accuracy: 1e-9, "Orientierung \(orientation)")
            XCTAssertEqual(back.minY, rect.minY, accuracy: 1e-9, "Orientierung \(orientation)")
            XCTAssertEqual(back.width, rect.width, accuracy: 1e-9, "Orientierung \(orientation)")
            XCTAssertEqual(back.height, rect.height, accuracy: 1e-9, "Orientierung \(orientation)")
        }
    }

    func testOrientation6StoredCoordinates() {
        // Orientierung 6 = 90° im Uhrzeigersinn drehen zum Anzeigen. Ein Rahmen oben links im
        // angezeigten Bild liegt im gespeicherten Bild unten links.
        let stored = ImageOrientation.toStored(CGRect(x: 0, y: 0, width: 0.2, height: 0.1), orientation: 6)
        XCTAssertEqual(stored.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(stored.minY, 0.8, accuracy: 1e-9)
        XCTAssertEqual(stored.width, 0.1, accuracy: 1e-9)
        XCTAssertEqual(stored.height, 0.2, accuracy: 1e-9)
    }

    // MARK: - XMP

    func testXMPSerializeParseRoundtrip() {
        let fields = [
            XMPField("http://example.com/a/", "Struct", .structure([
                XMPField("http://example.com/a/", "Text", .text("Ä & <b>")),
                XMPField("http://example.com/b/", "List", .array(.bag, [
                    XMPItem(value: .text("eins")),
                    XMPItem(value: .structure([XMPField("http://example.com/b/", "x", .text("1"))])),
                ])),
                XMPField("http://example.com/a/", "Lang", .array(.alt, [XMPItem(lang: "x-default", value: .text("Hallo"))])),
            ])),
        ]
        let (data, _) = XMP.serialize(fields)
        XCTAssertEqual(XMP.parse(data), fields)
    }

    // MARK: - Schreiben & Lesen

    private func roundtrip(_ type: UTType, ext: String) throws {
        let url = makeImage(type, ext: ext)
        var m = PhotoMetadata()
        m.faces = sampleFaces()
        try MetadataService.write(m, to: url)

        let read = try MetadataService.read(from: url)
        XCTAssertEqual(read.differences(from: m.normalized()), [], "\(ext): \(read.faces)")
        XCTAssertTrue(read.people.contains("Erika Mustermann"), ext)

        // Beide Standards sind in der Datei vorhanden und korrekt umgerechnet.
        let root = XMPNode.structure(xmpFields(url))
        let mwgList = root.field(RegionMetadata.mwg, "Regions")?.field(RegionMetadata.mwg, "RegionList")?.items ?? []
        XCTAssertEqual(mwgList.count, 2, ext)
        let area = mwgList.first?.value.field(RegionMetadata.mwg, "Area")
        XCTAssertEqual(area?.field(RegionMetadata.stArea, "x")?.doubleValue ?? -1, 0.325, accuracy: 1e-6, ext)
        XCTAssertEqual(area?.field(RegionMetadata.stArea, "y")?.doubleValue ?? -1, 0.4, accuracy: 1e-6, ext)
        let dims = root.field(RegionMetadata.mwg, "Regions")?.field(RegionMetadata.mwg, "AppliedToDimensions")
        XCTAssertEqual(dims?.field(RegionMetadata.stDim, "w")?.stringValue, "80", ext)

        let iptcList = root.field(RegionMetadata.iptc, "ImageRegion")?.items ?? []
        XCTAssertEqual(iptcList.count, 2, ext)
        let boundary = iptcList.first?.value.field(RegionMetadata.iptc, "RegionBoundary")
        XCTAssertEqual(boundary?.field(RegionMetadata.iptc, "rbX")?.doubleValue ?? -1, 0.2, accuracy: 1e-6, ext)
        XCTAssertEqual(iptcList.first?.value.field(RegionMetadata.iptc, "PersonInImage")?.strings, ["Erika Mustermann"], ext)

        // Gesichter entfernen.
        var cleared = read
        cleared.faces = []
        try MetadataService.write(cleared, to: url)
        XCTAssertEqual(try MetadataService.read(from: url).faces, [], ext)
        let after = XMPNode.structure(xmpFields(url))
        XCTAssertNil(after.field(RegionMetadata.mwg, "Regions"), ext)
        XCTAssertNil(after.field(RegionMetadata.iptc, "ImageRegion"), ext)
    }

    func testJPEGFaces() throws { try roundtrip(.jpeg, ext: "jpg") }
    func testTIFFFaces() throws { try roundtrip(.tiff, ext: "tif") }
    func testPNGFaces() throws { try roundtrip(.png, ext: "png") }

    func testRotatedImageStoresUnrotatedCoordinates() throws {
        let url = makeImage(.jpeg, ext: "jpg", orientation: 6)
        var m = PhotoMetadata()
        m.faces = [FaceRegion(name: "Max", x: 0, y: 0, width: 0.2, height: 0.1)]
        try MetadataService.write(m, to: url)

        XCTAssertEqual(try MetadataService.read(from: url).faces, m.faces)
        let area = XMPNode.structure(xmpFields(url))
            .field(RegionMetadata.mwg, "Regions")?.field(RegionMetadata.mwg, "RegionList")?.items.first?
            .value.field(RegionMetadata.mwg, "Area")
        // Gespeichert: x 0…0.1, y 0.8…1.0 → Mittelpunkt (0.05, 0.9)
        XCTAssertEqual(area?.field(RegionMetadata.stArea, "x")?.doubleValue ?? -1, 0.05, accuracy: 1e-6)
        XCTAssertEqual(area?.field(RegionMetadata.stArea, "y")?.doubleValue ?? -1, 0.9, accuracy: 1e-6)
    }

    func testForeignRegionsArePreserved() throws {
        let url = makeImage(.jpeg, ext: "jpg")
        // Eine Haustier-Region (MWG) und einen Fokusbereich (IPTC) „von anderer Software“ anlegen.
        let pet = XMPItem(value: .structure([
            XMPField(RegionMetadata.mwg, "Area", .structure([
                XMPField(RegionMetadata.stArea, "x", .text("0.5")), XMPField(RegionMetadata.stArea, "y", .text("0.5")),
                XMPField(RegionMetadata.stArea, "w", .text("0.2")), XMPField(RegionMetadata.stArea, "h", .text("0.2")),
                XMPField(RegionMetadata.stArea, "unit", .text("normalized")),
            ])),
            XMPField(RegionMetadata.mwg, "Type", .text("Pet")),
            XMPField(RegionMetadata.mwg, "Name", .text("Bello")),
        ]))
        let focus = XMPItem(value: .structure([
            XMPField(RegionMetadata.iptc, "rRole", .array(.bag, [XMPItem(value: .structure([
                XMPField(RegionMetadata.iptc, "Identifier", .array(.bag, [XMPItem(value: .text("http://cv.iptc.org/newscodes/imageregionrole/mainSubjectArea"))])),
            ]))])),
        ]))
        let foreign = RegionMetadata.Contents(faces: [], otherMWG: [pet], otherIPTC: [focus])
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let meta = CGImageMetadataCreateMutable()
        RegionMetadata.replace(in: meta, with: RegionMetadata.fields(for: [], preserving: foreign,
                                                                     orientation: 1, storedSize: CGSize(width: 80, height: 60)))
        let tmp = dir.appendingPathComponent("foreign.jpg")
        let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        XCTAssertTrue(CGImageDestinationCopyImageSource(dest, source, [kCGImageDestinationMetadata as String: meta] as CFDictionary, nil))

        // Gesichter hinzufügen und wieder entfernen – fremde Regionen müssen bleiben.
        var m = try MetadataService.read(from: tmp)
        XCTAssertEqual(m.faces, [])
        m.faces = sampleFaces()
        try MetadataService.write(m, to: tmp)
        var root = XMPNode.structure(xmpFields(tmp))
        XCTAssertEqual(root.field(RegionMetadata.mwg, "Regions")?.field(RegionMetadata.mwg, "RegionList")?.items.count, 3)
        XCTAssertEqual(root.field(RegionMetadata.iptc, "ImageRegion")?.items.count, 3)

        m = try MetadataService.read(from: tmp)
        m.faces = []
        try MetadataService.write(m, to: tmp)
        root = XMPNode.structure(xmpFields(tmp))
        let mwgItems = root.field(RegionMetadata.mwg, "Regions")?.field(RegionMetadata.mwg, "RegionList")?.items ?? []
        XCTAssertEqual(mwgItems.count, 1)
        XCTAssertEqual(mwgItems.first?.value.field(RegionMetadata.mwg, "Name")?.stringValue, "Bello")
        XCTAssertEqual(root.field(RegionMetadata.iptc, "ImageRegion")?.items.count, 1)
    }

    func testNamedFacesAreAddedToPeople() {
        var m = PhotoMetadata()
        m.people = ["Max"]
        m.faces = [FaceRegion(name: " Erika ", x: 0.1, y: 0.1, width: 0.1, height: 0.1)]
        XCTAssertEqual(m.normalized().people, ["Max", "Erika"])
    }

    // MARK: - Vision

    func testFaceDetectionRunsOnImageWithoutFaces() throws {
        let ctx = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        XCTAssertEqual(try FaceDetector.detectFaces(in: ctx.makeImage()!), [])
    }

    func testFeaturePrintOfSameRegionIsIdentical() throws {
        let ctx = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for i in 0..<20 {
            ctx.setFillColor(CGColor(red: CGFloat(i) / 20, green: 0.3, blue: 1 - CGFloat(i) / 20, alpha: 1))
            ctx.fill(CGRect(x: i * 10, y: 0, width: 10, height: 150))
        }
        let image = ctx.makeImage()!
        let region = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.5)
        guard let a = try FaceDetector.featurePrint(of: image, region: region),
              let b = try FaceDetector.featurePrint(of: image, region: region) else {
            throw XCTSkip("Vision liefert in dieser Umgebung keine Merkmale")
        }
        XCTAssertEqual(FaceDetector.distance(a, b) ?? -1, 0, accuracy: 1e-4)
    }

    func testSuggestionNeedsClearWinner() {
        XCTAssertEqual(FaceDetector.rank(["Erika": 0.3, "Max": 0.8], ratio: 0.85), "Erika")
        XCTAssertNil(FaceDetector.rank(["Erika": 0.7, "Max": 0.75], ratio: 0.85), "zu knapp")
        XCTAssertNil(FaceDetector.rank(["Erika": 0.1], ratio: 0.85), "nur eine Person bekannt")
    }

    // MARK: - Beispieldatei für die Gegenprüfung mit ExifTool (nur in CI)

    func testWriteSampleForExifTool() throws {
        guard let out = ProcessInfo.processInfo.environment["EXIF_SAMPLE_DIR"] else {
            throw XCTSkip("Nur für die ExifTool-Gegenprüfung in CI")
        }
        let url = makeImage(.jpeg, ext: "jpg", width: 400, height: 300)
        var m = PhotoMetadata()
        m.faces = sampleFaces()
        try MetadataService.write(m, to: url)
        let target = URL(fileURLWithPath: out).appendingPathComponent("faces.jpg")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: url, to: target)
    }
}
