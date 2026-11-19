import XCTest
@testable import ExifCore

final class PartialDateTests: XCTestCase {
    func testXMPStrings() {
        XCTAssertEqual(PartialDate(precision: .year, year: 1985).xmpString, "1985")
        XCTAssertEqual(PartialDate(precision: .month, year: 1985, month: 7).xmpString, "1985-07")
        XCTAssertEqual(PartialDate(precision: .day, year: 1985, month: 7, day: 14).xmpString, "1985-07-14")
        XCTAssertEqual(PartialDate(precision: .dateTime, year: 1985, month: 7, day: 14, hour: 9, minute: 5).xmpString,
                       "1985-07-14T09:05:00")
    }

    func testExifStringsFillMissingParts() {
        XCTAssertEqual(PartialDate(precision: .year, year: 1985, month: 7, day: 14).exifString, "1985:01:01 00:00:00")
        XCTAssertEqual(PartialDate(precision: .month, year: 1985, month: 7, day: 14).exifString, "1985:07:01 00:00:00")
        XCTAssertEqual(PartialDate(precision: .day, year: 1985, month: 7, day: 14).exifString, "1985:07:14 00:00:00")
        XCTAssertEqual(PartialDate(precision: .dateTime, year: 1985, month: 7, day: 14, hour: 18, minute: 30).exifString,
                       "1985:07:14 18:30:00")
    }

    func testParseXMP() {
        XCTAssertEqual(PartialDate(xmpString: "1962")?.precision, .year)
        XCTAssertEqual(PartialDate(xmpString: "1962-03")?.precision, .month)
        XCTAssertEqual(PartialDate(xmpString: "1962-03-21")?.precision, .day)
        let full = PartialDate(xmpString: "1962-03-21T14:15:16+01:00")
        XCTAssertEqual(full?.precision, .dateTime)
        XCTAssertEqual(full?.hour, 14)
        XCTAssertEqual(full?.second, 16)
        XCTAssertNil(PartialDate(xmpString: ""))
        XCTAssertNil(PartialDate(xmpString: "1962-13"))
    }

    func testParseExif() {
        let d = PartialDate(exifString: "1975:12:24 19:00:00")
        XCTAssertEqual(d?.precision, .dateTime)
        XCTAssertEqual(d?.day, 24)
        XCTAssertNil(PartialDate(exifString: "0000:00:00 00:00:00"))
    }

    func testConsistency() {
        let exif = PartialDate(exifString: "1985:01:01 00:00:00")!
        XCTAssertTrue(PartialDate(xmpString: "1985")!.isConsistent(with: exif))
        XCTAssertFalse(PartialDate(xmpString: "1986")!.isConsistent(with: exif))
        XCTAssertFalse(PartialDate(xmpString: "1985-07")!.isConsistent(with: exif))
    }

    func testEqualityRespectsPrecision() {
        XCTAssertEqual(PartialDate(precision: .year, year: 1985, month: 3),
                       PartialDate(precision: .year, year: 1985, month: 9))
        XCTAssertNotEqual(PartialDate(precision: .month, year: 1985, month: 3),
                          PartialDate(precision: .month, year: 1985, month: 9))
    }

    func testParseXMPCoordinate() {
        XCTAssertEqual(MetadataService.parseXMPCoordinate("33,51.5S")!, -33.858333, accuracy: 0.00001)
        XCTAssertEqual(MetadataService.parseXMPCoordinate("8,30,36W")!, -8.51, accuracy: 0.00001)
        XCTAssertEqual(MetadataService.parseXMPCoordinate("48,8.4N")!, 48.14, accuracy: 0.00001)
    }
}
