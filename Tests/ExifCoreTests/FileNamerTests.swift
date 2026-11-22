import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ExifCore

final class FileNamerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Datum

    func testDateComponentFillsUnknownPartsWithZero() {
        XCTAssertEqual(FileNamer.dateComponent(nil), "0000-00-00_00-00")
        XCTAssertEqual(FileNamer.dateComponent(PartialDate(precision: .year, year: 1985, month: 7, day: 14)), "1985-00-00_00-00")
        XCTAssertEqual(FileNamer.dateComponent(PartialDate(precision: .month, year: 1985, month: 7, day: 14)), "1985-07-00_00-00")
        XCTAssertEqual(FileNamer.dateComponent(PartialDate(precision: .day, year: 1985, month: 7, day: 14)), "1985-07-14_00-00")
        XCTAssertEqual(FileNamer.dateComponent(PartialDate(precision: .dateTime, year: 1985, month: 7, day: 14, hour: 9, minute: 5)),
                       "1985-07-14_09-05")
    }

    func testDateNamesSortChronologically() {
        let names = [
            PartialDate(precision: .dateTime, year: 1985, month: 7, day: 14, hour: 15, minute: 30),
            PartialDate(precision: .year, year: 1985),
            PartialDate(precision: .day, year: 1985, month: 7, day: 14),
            PartialDate(precision: .month, year: 1985, month: 7),
            PartialDate(precision: .day, year: 1984, month: 12, day: 24),
        ].map { FileNamer.dateComponent($0) }
        XCTAssertEqual(names.sorted(), [
            "1984-12-24_00-00", "1985-00-00_00-00", "1985-07-00_00-00", "1985-07-14_00-00", "1985-07-14_15-30",
        ])
    }

    // MARK: - Muster

    private func sample() -> PhotoMetadata {
        var m = PhotoMetadata()
        m.date = PartialDate(precision: .day, year: 1985, month: 7, day: 14)
        m.city = "Sylt"
        m.country = "Deutschland"
        m.people = ["Erika Mustermann", "Max Mustermann"]
        m.caption = "Urlaub: Strand/Dünen"
        return m
    }

    func testPatternWithTokens() {
        let m = sample()
        XCTAssertEqual(FileNamer.baseName(pattern: "{date}_{place}", metadata: m, originalName: "scan-0815", counter: 1),
                       "1985-07-14_00-00_Sylt")
        XCTAssertEqual(FileNamer.baseName(pattern: "{date}_{people}", metadata: m, originalName: "scan-0815", counter: 1),
                       "1985-07-14_00-00_Erika Mustermann, Max Mustermann")
        XCTAssertEqual(FileNamer.baseName(pattern: "{date}_{original}", metadata: m, originalName: "scan-0815", counter: 1),
                       "1985-07-14_00-00_scan-0815")
        XCTAssertEqual(FileNamer.baseName(pattern: "{date}_{counter}", metadata: m, originalName: "x", counter: 7),
                       "1985-07-14_00-00_007")
    }

    func testLocationNameIsPreferredForPlace() {
        var m = sample()
        m.location = "Haus der Großeltern"
        XCTAssertEqual(FileNamer.baseName(pattern: "{date}_{place}", metadata: m, originalName: "x", counter: 1),
                       "1985-07-14_00-00_Haus der Großeltern")
    }

    func testEmptyTokensLeaveNoStraySeparators() {
        var m = PhotoMetadata()
        m.date = PartialDate(precision: .year, year: 1962)
        XCTAssertEqual(FileNamer.baseName(pattern: "{date}_{place}_{people}", metadata: m, originalName: "x", counter: 1),
                       "1962-00-00_00-00")
        XCTAssertEqual(FileNamer.baseName(pattern: "{place}_{date}", metadata: m, originalName: "x", counter: 1),
                       "1962-00-00_00-00")
    }

    func testForbiddenCharactersAreRemoved() {
        let m = sample()
        let name = FileNamer.baseName(pattern: "{date}_{description}", metadata: m, originalName: "x", counter: 1)
        XCTAssertEqual(name, "1985-07-14_00-00_Urlaub Strand Dünen")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func testEmptyResultFallsBackToOriginalName() {
        XCTAssertEqual(FileNamer.baseName(pattern: "{place}", metadata: PhotoMetadata(), originalName: "scan-0815", counter: 1),
                       "scan-0815")
    }

    // MARK: - Planung

    func testPlanResolvesConflicts() {
        let m = sample()
        let a = dir.appendingPathComponent("scan-1.jpg")
        let b = dir.appendingPathComponent("scan-2.JPG")
        let existing = dir.appendingPathComponent("1985-07-14_00-00_Sylt.jpg")
        let targets = FileNamer.plan([(a, m), (b, m)], pattern: "{date}_{place}",
                                     fileExists: { $0.path.lowercased() == existing.path.lowercased() })
        XCTAssertEqual(targets.map(\.lastPathComponent), ["1985-07-14_00-00_Sylt_2.jpg", "1985-07-14_00-00_Sylt_3.JPG"])
    }

    func testPlanKeepsAlreadyCorrectName() {
        let m = sample()
        let a = dir.appendingPathComponent("1985-07-14_00-00_Sylt.jpg")
        let targets = FileNamer.plan([(a, m)], pattern: "{date}_{place}", fileExists: { _ in true })
        XCTAssertEqual(targets, [a])
    }

    func testOriginalUsesPreservedFileName() {
        var m = sample()
        m.preservedFileName = "scan-0815.tif"
        let a = dir.appendingPathComponent("1985-07-14_00-00_Sylt.tif")
        let targets = FileNamer.plan([(a, m)], pattern: "{date}_{original}", fileExists: { _ in false })
        XCTAssertEqual(targets.first?.lastPathComponent, "1985-07-14_00-00_scan-0815.tif")
    }

    // MARK: - Dateisystem

    private func makeJPEG(_ name: String) -> URL {
        let ctx = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testRenameMovesBackupToo() throws {
        let source = makeJPEG("scan-1.jpg")
        try BackupService.backupIfNeeded(source)
        let target = dir.appendingPathComponent("1985-07-14_00-00_Sylt.jpg")
        try FileNamer.rename(source, to: target)

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertTrue(fm.fileExists(atPath: target.path))
        let backups = dir.appendingPathComponent(BackupService.folderName)
        XCTAssertTrue(fm.fileExists(atPath: backups.appendingPathComponent("1985-07-14_00-00_Sylt.jpg").path))
        XCTAssertFalse(fm.fileExists(atPath: backups.appendingPathComponent("scan-1.jpg").path))
    }

    func testCaseOnlyRename() throws {
        let source = makeJPEG("scan.jpg")
        let target = dir.appendingPathComponent("Scan.jpg")
        try FileNamer.rename(source, to: target)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains("Scan.jpg"), "\(names)")
    }

    func testSetCreationDate() throws {
        let url = makeJPEG("date.jpg")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try FileNamer.setCreationDate(of: url, to: PartialDate(precision: .month, year: 1985, month: 7))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let created = attributes[.creationDate] as? Date
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: created ?? Date())
        XCTAssertEqual(parts.year, 1985)
        XCTAssertEqual(parts.month, 7)
        XCTAssertEqual(parts.day, 1)
        XCTAssertEqual(attributes[.modificationDate] as? Date, before, "Änderungsdatum muss unverändert bleiben")
    }

    func testPreservedFileNameRoundtrip() throws {
        let url = makeJPEG("scan-0815.jpg")
        var m = try MetadataService.read(from: url)
        XCTAssertNil(m.preservedFileName)
        m.preservedFileName = "scan-0815.jpg"
        try MetadataService.write(m, to: url)
        XCTAssertEqual(try MetadataService.read(from: url).preservedFileName, "scan-0815.jpg")
    }
}
