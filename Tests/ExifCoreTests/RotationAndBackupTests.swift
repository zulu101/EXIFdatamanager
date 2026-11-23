import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ExifCore

final class RotationAndBackupTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Bild 80 × 40 mit rotem Pixelblock oben links.
    private func makeImage(_ type: UTType, ext: String, name: String = "scan") -> URL {
        let ctx = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 30, width: 10, height: 10)) // CoreGraphics: y oben = 30…40
        let url = dir.appendingPathComponent("\(name).\(ext)")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // `data` beginnt mit der obersten Zeile.
        let i = (y * image.width + x) * 4
        return (data[i], data[i + 1], data[i + 2])
    }

    // MARK: - Mathematik

    func testRotatingFourTimesReturnsToStart() {
        for start in 1...8 {
            var o = start
            for _ in 0..<4 { o = ImageOrientation.rotated(o, clockwise: true) }
            XCTAssertEqual(o, start)
            XCTAssertEqual(ImageOrientation.rotated(ImageOrientation.rotated(start, clockwise: true), clockwise: false), start)
        }
        XCTAssertEqual(ImageOrientation.rotated(1, clockwise: true), 6)
        XCTAssertEqual(ImageOrientation.rotated(1, clockwise: false), 8)
        XCTAssertEqual(ImageOrientation.quarterTurns(from: 1, to: 3), 2)
        XCTAssertNil(ImageOrientation.quarterTurns(from: 1, to: 2))
    }

    /// Die Drehung muss zur Anzeige-Umrechnung passen: Orientierung 6 = Bild 90° nach rechts.
    func testRotatedOrientationMatchesDisplayTransform() {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        for start in 1...8 {
            for clockwise in [true, false] {
                let stored = ImageOrientation.toStored(rect, orientation: start)
                let newOrientation = ImageOrientation.rotated(start, clockwise: clockwise)
                let expected = ImageOrientation.rotate(rect, clockwise: clockwise)
                let actual = ImageOrientation.toDisplay(stored, orientation: newOrientation)
                XCTAssertEqual(actual.minX, expected.minX, accuracy: 1e-9, "\(start) \(clockwise)")
                XCTAssertEqual(actual.minY, expected.minY, accuracy: 1e-9, "\(start) \(clockwise)")
                XCTAssertEqual(actual.width, expected.width, accuracy: 1e-9, "\(start) \(clockwise)")
                XCTAssertEqual(actual.height, expected.height, accuracy: 1e-9, "\(start) \(clockwise)")
            }
        }
    }

    func testImageRotationForDisplay() throws {
        let source = CGImageSourceCreateWithURL(makeImage(.png, ext: "png") as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        XCTAssertEqual(pixel(image, x: 2, y: 2).r, 255)
        XCTAssertEqual(pixel(image, x: 2, y: 2).g, 0)

        let right = try XCTUnwrap(ImageOrientation.rotate(image, quarterTurns: 1))
        XCTAssertEqual(right.width, 40)
        XCTAssertEqual(right.height, 80)
        XCTAssertEqual(pixel(right, x: 37, y: 2).g, 0, "Nach Rechtsdrehung liegt Rot oben rechts")

        let left = try XCTUnwrap(ImageOrientation.rotate(image, quarterTurns: -1))
        XCTAssertEqual(pixel(left, x: 2, y: 77).g, 0, "Nach Linksdrehung liegt Rot unten links")
    }

    // MARK: - Speichern

    private func rotateAndSave(_ type: UTType, ext: String) throws {
        let url = makeImage(type, ext: ext)
        var m = try MetadataService.read(from: url)
        XCTAssertEqual(m.orientation, 1)
        m.faces = [FaceRegion(name: "Erika", x: 0.0, y: 0.0, width: 0.125, height: 0.25)]
        try MetadataService.write(m, to: url)

        m = try MetadataService.read(from: url)
        m.rotate(clockwise: true)
        try MetadataService.write(m, to: url)

        let read = try MetadataService.read(from: url)
        XCTAssertEqual(read.orientation, 6, ext)
        // Rahmen oben links liegt nach Rechtsdrehung oben rechts.
        XCTAssertEqual(read.faces.first?.x ?? -1, 0.75, accuracy: 0.001, ext)
        XCTAssertEqual(read.faces.first?.y ?? -1, 0.0, accuracy: 0.001, ext)

        // Die angezeigte Vorschau ist hochkant.
        let thumb = try XCTUnwrap(MetadataService.thumbnail(for: url, maxPixelSize: 200, allowEmbedded: false))
        XCTAssertGreaterThan(thumb.height, thumb.width, ext)

        // Zurückdrehen.
        var back = read
        back.rotate(clockwise: false)
        try MetadataService.write(back, to: url)
        let final = try MetadataService.read(from: url)
        XCTAssertEqual(final.orientation, 1, ext)
        XCTAssertEqual(final.faces.first?.x ?? -1, 0.0, accuracy: 0.001, ext)
    }

    func testRotateJPEG() throws { try rotateAndSave(.jpeg, ext: "jpg") }
    func testRotateTIFF() throws { try rotateAndSave(.tiff, ext: "tif") }

    func testRotatePNG() throws {
        let url = makeImage(.png, ext: "png")
        var m = try MetadataService.read(from: url)
        m.rotate(clockwise: false)
        try MetadataService.write(m, to: url)
        XCTAssertEqual(try MetadataService.read(from: url).orientation, 8)
    }

    // MARK: - Sicherungskopien

    func testBackupGetsCurrentCreationDate() throws {
        let url = makeImage(.jpeg, ext: "jpg")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: url.path)
        let folder = try XCTUnwrap(try BackupService.backupIfNeeded(url))
        let created = BackupService.backups(in: [folder]).first?.created ?? .distantPast
        XCTAssertLessThan(abs(created.timeIntervalSinceNow), 60)
        XCTAssertNil(try BackupService.backupIfNeeded(url), "Zweite Sicherung wird nicht angelegt")
    }

    func testCleanupRemovesOnlyExpiredBackups() throws {
        let old = makeImage(.jpeg, ext: "jpg", name: "old")
        let fresh = makeImage(.jpeg, ext: "jpg", name: "fresh")
        let folder = try XCTUnwrap(try BackupService.backupIfNeeded(old))
        try BackupService.backupIfNeeded(fresh)
        let oldBackup = folder.appendingPathComponent("old.jpg")
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-40 * 24 * 3600)],
                                              ofItemAtPath: oldBackup.path)

        let cutoff = try XCTUnwrap(BackupService.Retention.thirtyDays.cutoff(quitting: false))
        let result = BackupService.cleanUp(folders: [folder], olderThan: cutoff)
        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertEqual(result.remainingFolders, [folder])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldBackup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("fresh.jpg").path))

        // „Beim Beenden“: alles weg, Ordner ebenfalls.
        let all = try XCTUnwrap(BackupService.Retention.untilQuit.cutoff(quitting: true))
        let final = BackupService.cleanUp(folders: [folder], olderThan: all)
        XCTAssertEqual(final.removedFiles, 1)
        XCTAssertEqual(final.remainingFolders, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        // Originale bleiben unangetastet.
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testRetentionCutoffs() {
        XCTAssertNil(BackupService.Retention.forever.cutoff(quitting: true))
        XCTAssertNil(BackupService.Retention.untilQuit.cutoff(quitting: false))
        XCTAssertNotNil(BackupService.Retention.sevenDays.cutoff(quitting: false))
    }

    func testCleanupIgnoresFoldersWithOtherNames() throws {
        let other = dir.appendingPathComponent("Urlaub")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let file = other.appendingPathComponent("a.jpg")
        FileManager.default.createFile(atPath: file.path, contents: Data([1]))
        _ = BackupService.cleanUp(folders: [other], olderThan: .distantFuture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Nur Ordner „\(BackupService.folderName)“ werden aufgeräumt")
    }
}
