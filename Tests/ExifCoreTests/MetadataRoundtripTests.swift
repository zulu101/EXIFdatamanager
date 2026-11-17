import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ExifCore

final class MetadataRoundtripTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Testdaten

    private func sample() -> PhotoMetadata {
        var m = PhotoMetadata()
        m.date = PartialDate(precision: .day, year: 1985, month: 7, day: 14)
        m.latitude = -33.856784
        m.longitude = 151.215297
        m.location = "Opernhaus"
        m.city = "Sydney"
        m.state = "New South Wales"
        m.country = "Australien"
        m.people = ["Erika Mustermann", "Max Mustermann"]
        m.keywords = ["Urlaub", "Familie"]
        m.caption = "Urlaub in Australien – Oma & Opa vor der Oper"
        return m
    }

    /// Erzeugt ein Testbild mit etwas „Scanner-EXIF“, das erhalten bleiben muss.
    private func makeImage(_ type: UTType, ext: String) throws -> URL {
        let width = 64, height = 48
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<width {
            ctx.setFillColor(CGColor(red: CGFloat(x) / CGFloat(width), green: 0.5, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let image = ctx.makeImage()!
        let url = dir.appendingPathComponent("scan.\(ext)")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        let props: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeDigitized as String: "2024:02:03 10:11:12",
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "TestScanner",
            ],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func pixels(_ url: URL) -> [UInt8] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    private func properties(_ url: URL) -> [String: Any] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    }

    // MARK: - Tests

    private func roundtrip(_ type: UTType, ext: String) throws {
        let url = try makeImage(type, ext: ext)
        let before = pixels(url)
        let expected = sample()

        try MetadataService.write(expected, to: url)
        let read = try MetadataService.read(from: url)
        XCTAssertEqual(read.differences(from: expected), [], "\(ext): \(read)")

        // Bilddaten unverändert (kein erneutes Komprimieren).
        XCTAssertEqual(pixels(url), before, "\(ext): Pixel wurden verändert")

        // Echte EXIF-/GPS-Felder (nicht nur XMP), damit z. B. Apple Fotos sie findet.
        let props = properties(url)
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String, "1985:07:14 12:00:00", ext)
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        XCTAssertEqual(gps?[kCGImagePropertyGPSLatitudeRef as String] as? String, "S", ext)
        XCTAssertEqual(gps?[kCGImagePropertyGPSLongitudeRef as String] as? String, "E", ext)

        // Vorhandene Scanner-Angaben bleiben erhalten.
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeDigitized as String] as? String, "2024:02:03 10:11:12", ext)
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake as String] as? String, "TestScanner", ext)

        // Ändern …
        var changed = expected
        changed.date = PartialDate(precision: .year, year: 1962)
        changed.latitude = 47.3769
        changed.longitude = -8.5417
        changed.caption = "Neue Beschreibung"
        changed.people = ["Erika Mustermann"]
        changed.city = ""
        try MetadataService.write(changed, to: url)
        let read2 = try MetadataService.read(from: url)
        XCTAssertEqual(read2.differences(from: changed.normalized()), [], "\(ext): \(read2)")
        XCTAssertEqual(read2.date?.precision, .year, ext)

        // … und alles löschen.
        try MetadataService.write(PhotoMetadata(), to: url)
        let read3 = try MetadataService.read(from: url)
        XCTAssertEqual(read3.differences(from: PhotoMetadata()), [], "\(ext): \(read3)")
        XCTAssertEqual(pixels(url), before, "\(ext): Pixel wurden verändert")
    }

    func testJPEGRoundtrip() throws {
        try roundtrip(.jpeg, ext: "jpg")
    }

    func testJPEGContainsRealExifDate() throws {
        let url = try makeImage(.jpeg, ext: "jpg")
        try MetadataService.write(sample(), to: url)
        let data = try Data(contentsOf: url)
        // Im EXIF-Block steht das Datum im Format „JJJJ:MM:TT“, in XMP dagegen „JJJJ-MM-TT“.
        XCTAssertNotNil(data.range(of: Data("1985:07:14 12:00:00".utf8)))
    }

    func testTIFFRoundtrip() throws {
        try roundtrip(.tiff, ext: "tif")
    }

    func testPNGRoundtrip() throws {
        try roundtrip(.png, ext: "png")
    }

    func testBackupIsCreatedOnce() throws {
        let url = try makeImage(.jpeg, ext: "jpg")
        try BackupService.backupIfNeeded(url)
        try MetadataService.write(sample(), to: url)
        try BackupService.backupIfNeeded(url)
        let backup = dir.appendingPathComponent(BackupService.folderName).appendingPathComponent("scan.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertNil(try MetadataService.read(from: backup).date, "Backup muss das unveränderte Original sein")
    }
}
