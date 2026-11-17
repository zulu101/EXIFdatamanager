import Foundation

/// Wie genau ist das Aufnahmedatum bekannt? Bei alten Fotos weiß man oft nur das Jahr.
public enum DatePrecision: String, CaseIterable, Identifiable, Sendable {
    case unknown
    case year
    case month
    case day
    case dateTime

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .unknown: return "Unbekannt"
        case .year: return "Nur Jahr"
        case .month: return "Monat & Jahr"
        case .day: return "Genauer Tag"
        case .dateTime: return "Tag & Uhrzeit"
        }
    }

    var rank: Int {
        switch self {
        case .unknown: return 0
        case .year: return 1
        case .month: return 2
        case .day: return 3
        case .dateTime: return 4
        }
    }
}

/// Ein (ggf. unvollständiges) Datum.
///
/// Gespeichert wird es zweifach:
/// * EXIF `DateTimeOriginal` – braucht immer ein vollständiges Datum. Fehlende Teile
///   werden mit 1. Januar bzw. 12:00 Uhr aufgefüllt (Mittag vermeidet Datumssprünge
///   durch Zeitzonen-Umrechnungen in manchen Programmen).
/// * XMP `photoshop:DateCreated` – erlaubt laut Standard Teil-Daten wie „1985“ oder
///   „1985-07“. Darüber bleibt die Genauigkeit dauerhaft erhalten.
public struct PartialDate: Sendable, Equatable {
    public var precision: DatePrecision
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int
    public var second: Int

    public init(precision: DatePrecision = .day,
                year: Int,
                month: Int = 1,
                day: Int = 1,
                hour: Int = 12,
                minute: Int = 0,
                second: Int = 0) {
        self.precision = precision == .unknown ? .year : precision
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    public static let placeholder = PartialDate(precision: .year, year: 1980)

    // Zwei Daten sind gleich, wenn sie im Rahmen ihrer Genauigkeit übereinstimmen.
    public static func == (lhs: PartialDate, rhs: PartialDate) -> Bool {
        lhs.xmpString == rhs.xmpString
    }

    // MARK: - Serialisierung

    /// XMP / ISO 8601, gekürzt auf die bekannte Genauigkeit.
    public var xmpString: String {
        switch precision {
        case .unknown, .year:
            return String(format: "%04ld", year)
        case .month:
            return String(format: "%04ld-%02ld", year, month)
        case .day:
            return String(format: "%04ld-%02ld-%02ld", year, month, day)
        case .dateTime:
            return String(format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld", year, month, day, hour, minute, second)
        }
    }

    /// EXIF-Format `JJJJ:MM:TT HH:MM:SS`.
    public var exifString: String {
        let m = precision.rank >= DatePrecision.month.rank ? month : 1
        let d = precision.rank >= DatePrecision.day.rank ? day : 1
        let (h, mi, s) = precision == .dateTime ? (hour, minute, second) : (12, 0, 0)
        return String(format: "%04ld:%02ld:%02ld %02ld:%02ld:%02ld", year, m, d, h, mi, s)
    }

    public init?(exifString: String) {
        let n = PartialDate.numbers(in: exifString)
        guard n.count >= 3, PartialDate.isValid(year: n[0], month: n[1], day: n[2]) else { return nil }
        if n.count >= 5 {
            self.init(precision: .dateTime, year: n[0], month: n[1], day: n[2],
                      hour: n[3], minute: n[4], second: n.count > 5 ? n[5] : 0)
        } else {
            self.init(precision: .day, year: n[0], month: n[1], day: n[2])
        }
    }

    public init?(xmpString raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Zeitzone (Z, +01:00, -05:00) hinter der Uhrzeit abschneiden.
        if let t = s.firstIndex(of: "T") {
            let timePart = s[s.index(after: t)...]
            if let tz = timePart.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
                s = String(s[..<tz])
            }
        }
        let n = Array(PartialDate.numbers(in: s).prefix(6))
        guard let year = n.first, year > 0, year < 10000 else { return nil }
        switch n.count {
        case 1:
            self.init(precision: .year, year: year)
        case 2:
            guard (1...12).contains(n[1]) else { return nil }
            self.init(precision: .month, year: year, month: n[1])
        case 3:
            guard PartialDate.isValid(year: year, month: n[1], day: n[2]) else { return nil }
            self.init(precision: .day, year: year, month: n[1], day: n[2])
        default:
            guard PartialDate.isValid(year: year, month: n[1], day: n[2]) else { return nil }
            self.init(precision: .dateTime, year: year, month: n[1], day: n[2],
                      hour: n[3], minute: n.count > 4 ? n[4] : 0, second: n.count > 5 ? n[5] : 0)
        }
    }

    /// Passt dieses (XMP-)Datum zu einem EXIF-Datum? Wenn ein anderes Programm später nur das
    /// EXIF-Datum geändert hat, soll das EXIF-Datum gewinnen.
    public func isConsistent(with exif: PartialDate) -> Bool {
        guard year == exif.year else { return false }
        if precision.rank >= DatePrecision.month.rank && month != exif.month { return false }
        if precision.rank >= DatePrecision.day.rank && day != exif.day { return false }
        if precision == .dateTime && (hour != exif.hour || minute != exif.minute) { return false }
        return true
    }

    // MARK: - Darstellung & Umrechnung

    private static let calendar = Calendar(identifier: .gregorian)

    public var asDate: Date? {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        c.minute = minute
        c.second = second
        return PartialDate.calendar.date(from: c)
    }

    /// Übernimmt Jahr/Monat/Tag (und bei `.dateTime` die Uhrzeit) aus einem `Date`.
    public mutating func set(from date: Date) {
        let c = PartialDate.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        year = c.year ?? year
        month = c.month ?? month
        day = c.day ?? day
        if precision == .dateTime {
            hour = c.hour ?? hour
            minute = c.minute ?? minute
            second = 0
        }
    }

    public var displayString: String {
        switch precision {
        case .unknown, .year:
            return String(year)
        default:
            break
        }
        guard let date = asDate else { return xmpString }
        let f = DateFormatter()
        switch precision {
        case .month:
            f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        case .day:
            f.dateStyle = .long
        default:
            f.dateStyle = .long
            f.timeStyle = .short
        }
        return f.string(from: date)
    }

    // MARK: - Hilfsfunktionen

    static func numbers(in s: String) -> [Int] {
        s.split(whereSeparator: { !("0"..."9").contains($0) }).compactMap { Int($0) }
    }

    static func isValid(year: Int, month: Int, day: Int) -> Bool {
        year > 0 && (1...12).contains(month) && (1...31).contains(day)
    }
}
