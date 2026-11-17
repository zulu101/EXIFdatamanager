import CoreLocation
import ExifCore
import MapKit
import SwiftUI

/// Ort per Suche, Klick in die Karte oder aus den zuletzt verwendeten Orten.
struct LocationEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var metadata: PhotoMetadata

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var position: MapCameraPosition = .region(LocationEditor.defaultRegion)

    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 51.1657, longitude: 10.4515),
        span: MKCoordinateSpan(latitudeDelta: 9, longitudeDelta: 9)
    )

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = metadata.latitude, let lon = metadata.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        HStack {
            TextField("Ort suchen", text: $query, prompt: Text("Ort oder Adresse suchen …"))
                .onSubmit { Task { await search() } }
            if isSearching {
                ProgressView().controlSize(.small)
            }
            recentPlacesMenu
        }

        if let searchError {
            Text(searchError).font(.caption).foregroundStyle(.red)
        }

        if !results.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(results.prefix(6).enumerated()), id: \.offset) { _, item in
                    Button {
                        select(item)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.name ?? "Unbenannt")
                            Text(item.placemark.title ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("Ergebnisse ausblenden") { results = [] }
                    .font(.caption)
            }
        }

        MapReader { proxy in
            Map(position: $position) {
                if let coordinate {
                    Marker("Aufnahmeort", coordinate: coordinate)
                }
            }
            .mapControls {
                MapZoomStepper()
                MapCompass()
            }
            .onTapGesture { point in
                guard let c = proxy.convert(point, from: .local) else { return }
                metadata.latitude = c.latitude
                metadata.longitude = c.longitude
                Task { await reverseGeocode(c) }
            }
        }
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear { centerOnCoordinate() }

        HStack {
            if let c = coordinate {
                Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Ortsnamen aus Pin ermitteln") { Task { await reverseGeocode(c) } }
                    .font(.caption)
                Button("Pin entfernen") {
                    metadata.latitude = nil
                    metadata.longitude = nil
                }
                .font(.caption)
            } else {
                Text("Klicke in die Karte, um den Aufnahmeort zu setzen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        TextField("Ortsbezeichnung", text: $metadata.location, prompt: Text("z. B. Haus der Großeltern"))
        TextField("Stadt / Gemeinde", text: $metadata.city)
        TextField("Bundesland / Region", text: $metadata.state)
        TextField("Land", text: $metadata.country)
    }

    private var recentPlacesMenu: some View {
        Menu {
            if model.places.places.isEmpty {
                Text("Noch keine gespeicherten Orte")
            }
            ForEach(model.places.places) { place in
                Button(place.title) {
                    place.apply(to: &metadata)
                    centerOnCoordinate()
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Zuletzt verwendete Orte")
    }

    private func centerOnCoordinate() {
        if let coordinate {
            position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 4000, longitudinalMeters: 4000))
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        do {
            let response = try await MKLocalSearch(request: request).start()
            results = response.mapItems
            if results.isEmpty { searchError = "Nichts gefunden." }
        } catch {
            results = []
            searchError = "Suche fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func select(_ item: MKMapItem) {
        let placemark = item.placemark
        metadata.latitude = placemark.coordinate.latitude
        metadata.longitude = placemark.coordinate.longitude
        apply(placemark)
        if let name = item.name, name != placemark.locality, metadata.location.isEmpty {
            metadata.location = name
        }
        results = []
        query = ""
        centerOnCoordinate()
    }

    private func reverseGeocode(_ c: CLLocationCoordinate2D) async {
        let location = CLLocation(latitude: c.latitude, longitude: c.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return }
        // Nur übernehmen, wenn der Pin inzwischen nicht woanders gesetzt wurde.
        guard metadata.latitude == c.latitude, metadata.longitude == c.longitude else { return }
        apply(placemark)
    }

    private func apply(_ placemark: CLPlacemark) {
        metadata.city = placemark.locality ?? placemark.subAdministrativeArea ?? ""
        metadata.state = placemark.administrativeArea ?? ""
        metadata.country = placemark.country ?? ""
    }
}
