import Foundation
import ExifCore
import Observation

/// Merkt sich bereits verwendete Namen (Personen, Schlagwörter) für schnelle Vorschläge.
@MainActor
@Observable
final class SuggestionStore {
    private(set) var values: [String]
    private let key: String

    init(key: String) {
        self.key = key
        self.values = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func learn(_ new: [String]) {
        let additions = new.filter { !$0.isEmpty && !values.contains($0) }
        guard !additions.isEmpty else { return }
        values = (values + additions).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        persist()
    }

    func remove(_ value: String) {
        values.removeAll { $0 == value }
        persist()
    }

    func suggestions(matching input: String, excluding: [String]) -> [String] {
        let query = input.trimmingCharacters(in: .whitespaces)
        return values.filter { candidate in
            !excluding.contains(candidate)
                && (query.isEmpty || candidate.localizedStandardContains(query))
        }
    }

    private func persist() {
        UserDefaults.standard.set(values, forKey: key)
    }
}

/// Ein gespeicherter Ort, z. B. „Haus der Großeltern“, zum schnellen Wiederverwenden.
struct RecentPlace: Codable, Identifiable, Equatable {
    var location: String
    var city: String
    var state: String
    var country: String
    var latitude: Double?
    var longitude: Double?

    var id: String {
        "\(location)|\(city)|\(country)|\(latitude ?? 0)|\(longitude ?? 0)"
    }

    var title: String {
        let parts = [location, city, country].filter { !$0.isEmpty }
        return parts.isEmpty ? String(format: "%.4f, %.4f", latitude ?? 0, longitude ?? 0) : parts.joined(separator: ", ")
    }

    init?(_ m: PhotoMetadata) {
        guard m.hasLocation else { return nil }
        location = m.location
        city = m.city
        state = m.state
        country = m.country
        latitude = m.latitude
        longitude = m.longitude
    }

    func apply(to m: inout PhotoMetadata) {
        m.location = location
        m.city = city
        m.state = state
        m.country = country
        m.latitude = latitude
        m.longitude = longitude
    }
}

@MainActor
@Observable
final class RecentPlacesStore {
    private(set) var places: [RecentPlace] = []
    private let key = "recentPlaces"
    private let limit = 40

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([RecentPlace].self, from: data) {
            places = decoded
        }
    }

    func remember(_ metadata: PhotoMetadata) {
        guard let place = RecentPlace(metadata) else { return }
        places.removeAll { $0.id == place.id }
        places.insert(place, at: 0)
        if places.count > limit { places.removeLast(places.count - limit) }
        persist()
    }

    func remove(_ place: RecentPlace) {
        places.removeAll { $0.id == place.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
