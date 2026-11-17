import Foundation

/// Die Metadaten, die die App liest und schreibt.
public struct PhotoMetadata: Equatable, Sendable {
    public var date: PartialDate?

    public var latitude: Double?
    public var longitude: Double?

    /// Freie Ortsbezeichnung, z. B. „Haus der Großeltern“ (IPTC Sublocation).
    public var location: String = ""
    public var city: String = ""
    public var state: String = ""
    public var country: String = ""

    /// Abgebildete Personen (IPTC Extension „PersonInImage“, zusätzlich als Schlagwort).
    public var people: [String] = []
    /// Weitere Schlagwörter, ohne die Personen.
    public var keywords: [String] = []
    /// Beschreibung / Bildunterschrift.
    public var caption: String = ""

    public init() {}

    public var hasCoordinate: Bool { latitude != nil && longitude != nil }

    public var hasLocation: Bool {
        hasCoordinate || !location.isEmpty || !city.isEmpty || !country.isEmpty
    }

    /// Kurze Zusammenfassung des Ortes für Listen.
    public var placeSummary: String {
        let parts = [location, city, country].filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.prefix(2).joined(separator: ", ") }
        if let lat = latitude, let lon = longitude {
            return String(format: "%.4f, %.4f", lat, lon)
        }
        return ""
    }

    /// Leerzeichen entfernen, leere/doppelte Einträge streichen.
    public func normalized() -> PhotoMetadata {
        var m = self
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        m.location = trim(location)
        m.city = trim(city)
        m.state = trim(state)
        m.country = trim(country)
        m.caption = trim(caption)
        m.people = PhotoMetadata.unique(people.map(trim))
        m.keywords = PhotoMetadata.unique(keywords.map(trim)).filter { !m.people.contains($0) }
        if latitude == nil || longitude == nil {
            m.latitude = nil
            m.longitude = nil
        }
        return m
    }

    /// Welche Felder unterscheiden sich (für die Kontrolle nach dem Speichern)?
    public func differences(from other: PhotoMetadata) -> [String] {
        var d: [String] = []
        if date != other.date { d.append("Datum") }
        if !coordinatesMatch(other) { d.append("Koordinaten") }
        if location != other.location { d.append("Ortsbezeichnung") }
        if city != other.city { d.append("Stadt") }
        if state != other.state { d.append("Region") }
        if country != other.country { d.append("Land") }
        if Set(people) != Set(other.people) { d.append("Personen") }
        if Set(keywords) != Set(other.keywords) { d.append("Schlagwörter") }
        if caption != other.caption { d.append("Beschreibung") }
        return d
    }

    private func coordinatesMatch(_ other: PhotoMetadata) -> Bool {
        switch (latitude, longitude, other.latitude, other.longitude) {
        case (nil, nil, nil, nil):
            return true
        case let (a?, b?, c?, d?):
            return abs(a - c) < 0.00001 && abs(b - d) < 0.00001
        default:
            return false
        }
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
