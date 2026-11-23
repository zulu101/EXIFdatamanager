import Foundation

/// Erzeugt Dateinamen aus Metadaten, z. B. `1985-07-14_00-00_Sylt.jpg`.
///
/// Das Datum hat immer das Format `JJJJ-MM-TT_HH-MM`. Unbekannte Teile werden mit `00`
/// aufgefüllt (`1985-00-00_00-00` = nur das Jahr ist bekannt). Da es keinen Monat oder Tag 00
/// gibt, ist „unbekannt“ eindeutig erkennbar, und alle Namen sortieren chronologisch.
public enum FileNamer {
    /// Bausteine für das Namensmuster. Die Platzhalter sind sprachunabhängig.
    public enum Token: String, CaseIterable, Identifiable, Sendable {
        case date
        case place
        case city
        case country
        case people
        case description
        case original
        case counter

        public var id: String { rawValue }
        public var placeholder: String { "{\(rawValue)}" }

        public var label: String {
            switch self {
            case .date: return String(localized: "Datum")
            case .place: return String(localized: "Ort")
            case .city: return String(localized: "Stadt")
            case .country: return String(localized: "Land")
            case .people: return String(localized: "Personen")
            case .description: return String(localized: "Beschreibung")
            case .original: return String(localized: "Originalname")
            case .counter: return String(localized: "Zähler")
            }
        }
    }

    public static let defaultPattern = "{date}_{place}"
    /// Grenze für den Namen ohne Endung (macOS erlaubt 255 Bytes inkl. Endung).
    static let maxBaseLength = 180

    // MARK: - Datum

    /// `JJJJ-MM-TT_HH-MM`, Unbekanntes als `00`.
    public static func dateComponent(_ date: PartialDate?) -> String {
        guard let d = date else { return "0000-00-00_00-00" }
        let rank = d.precision
        let month = rank == .year || rank == .unknown ? 0 : d.month
        let day = rank == .day || rank == .dateTime ? d.day : 0
        let hour = rank == .dateTime ? d.hour : 0
        let minute = rank == .dateTime ? d.minute : 0
        return String(format: "%04ld-%02ld-%02ld_%02ld-%02ld", d.year, month, day, hour, minute)
    }

    // MARK: - Name aus Muster

    /// Name ohne Endung. Leere Bausteine verschwinden samt überflüssiger Trennzeichen.
    public static func baseName(pattern: String, metadata m: PhotoMetadata,
                                originalName: String, counter: Int, counterWidth: Int = 3) -> String {
        var values: [Token: String] = [
            .date: dateComponent(m.date),
            .place: m.location.isEmpty ? m.city : m.location,
            .city: m.city,
            .country: m.country,
            .people: m.people.joined(separator: ", "),
            .description: String(m.caption.prefix(60)),
            .original: originalName,
            .counter: String(format: "%0\(max(counterWidth, 1))ld", counter),
        ]
        for (token, value) in values where token != .date && token != .counter {
            values[token] = sanitize(value)
        }

        var result = pattern
        for token in Token.allCases {
            result = result.replacingOccurrences(of: token.placeholder, with: values[token] ?? "")
        }
        result = sanitize(result)
        result = collapseSeparators(result)
        if result.count > maxBaseLength {
            result = String(result.prefix(maxBaseLength))
            result = collapseSeparators(result)
        }
        return result.isEmpty ? sanitize(originalName) : result
    }

    /// Entfernt Zeichen, die in Dateinamen auf macOS, Windows oder Linux Probleme machen.
    public static func sanitize(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = value.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        return cleaned
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    /// Mehrere Trennzeichen hintereinander (durch leere Bausteine) auf eines reduzieren und
    /// Trennzeichen am Anfang und Ende entfernen.
    static func collapseSeparators(_ value: String) -> String {
        let separators: Set<Character> = ["_", "-", " ", ",", "."]
        var out = ""
        var run = ""
        for ch in value {
            if separators.contains(ch) {
                run.append(ch)
            } else {
                if !run.isEmpty {
                    out += out.isEmpty ? "" : normalizedRun(run)
                    run = ""
                }
                out.append(ch)
            }
        }
        return out
    }

    /// Ein Lauf aus Trennzeichen: einzelne bleiben wie sie sind, längere werden zu „_“,
    /// außer es ist ein gewolltes „, “ (Personenliste) oder ein Bindestrich mit Leerzeichen.
    private static func normalizedRun(_ run: String) -> String {
        if run.count == 1 { return run }
        if run == ", " || run == " - " { return run }
        return run.contains("_") ? "_" : (run.contains("-") ? "-" : " ")
    }

    // MARK: - Planung

    /// Neue Namen für alle Dateien. Namenskonflikte (mit vorhandenen Dateien oder untereinander)
    /// werden mit „_2“, „_3“ … gelöst. Vergleich ohne Groß-/Kleinschreibung, wie auf APFS üblich.
    public static func plan(_ inputs: [(url: URL, metadata: PhotoMetadata)], pattern: String,
                            fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [URL] {
        let width = max(3, String(inputs.count).count)
        var taken = Set<String>()
        var result: [URL] = []
        let sources = Set(inputs.map { $0.url.standardizedFileURL.path.lowercased() })

        for (index, input) in inputs.enumerated() {
            let dir = input.url.deletingLastPathComponent()
            let ext = input.url.pathExtension
            let original = (input.metadata.preservedFileName.map { ($0 as NSString).deletingPathExtension })
                ?? input.url.deletingPathExtension().lastPathComponent
            let base = baseName(pattern: pattern, metadata: input.metadata, originalName: original,
                                counter: index + 1, counterWidth: width)

            var attempt = 1
            while true {
                let name = attempt == 1 ? base : "\(base)_\(attempt)"
                let candidate = dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
                let key = candidate.standardizedFileURL.path.lowercased()
                let isSelf = key == input.url.standardizedFileURL.path.lowercased()
                // Belegt: bereits vergeben, oder eine fremde vorhandene Datei. Andere Dateien aus
                // dieser Umbenennung gelten als belegt, damit nichts überschrieben wird.
                let occupied = taken.contains(key)
                    || (!isSelf && (sources.contains(key) || fileExists(candidate)))
                if !occupied {
                    taken.insert(key)
                    result.append(candidate)
                    break
                }
                attempt += 1
            }
        }
        return result
    }

    // MARK: - Dateisystem

    /// Setzt das Erstelldatum der Datei auf das Aufnahmedatum (Unbekanntes = 1. Januar bzw. 00:00).
    /// Das Änderungsdatum bleibt bewusst unverändert, damit Backup-Programme Änderungen weiterhin
    /// erkennen.
    public static func setCreationDate(of url: URL, to date: PartialDate) throws {
        var c = DateComponents()
        c.year = date.year
        c.month = date.precision == .year ? 1 : date.month
        c.day = (date.precision == .day || date.precision == .dateTime) ? date.day : 1
        c.hour = date.precision == .dateTime ? date.hour : 0
        c.minute = date.precision == .dateTime ? date.minute : 0
        guard let value = Calendar(identifier: .gregorian).date(from: c) else { return }
        try FileManager.default.setAttributes([.creationDate: value], ofItemAtPath: url.path)
    }

    /// Benennt eine Datei um und – falls vorhanden – auch ihre Sicherungskopie.
    public static func rename(_ source: URL, to target: URL) throws {
        guard source.standardizedFileURL != target.standardizedFileURL else { return }
        let fm = FileManager.default
        if source.path.lowercased() == target.path.lowercased() {
            // Nur Groß-/Kleinschreibung geändert: über einen Zwischennamen umbenennen.
            let temp = source.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
            try fm.moveItem(at: source, to: temp)
            try fm.moveItem(at: temp, to: target)
        } else {
            try fm.moveItem(at: source, to: target)
        }

        let backupDir = source.deletingLastPathComponent().appendingPathComponent(BackupService.folderName)
        let oldBackup = backupDir.appendingPathComponent(source.lastPathComponent)
        let newBackup = backupDir.appendingPathComponent(target.lastPathComponent)
        if fm.fileExists(atPath: oldBackup.path), !fm.fileExists(atPath: newBackup.path) {
            try? fm.moveItem(at: oldBackup, to: newBackup)
        }
    }
}
