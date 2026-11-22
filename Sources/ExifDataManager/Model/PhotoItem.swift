import AppKit
import ExifCore
import Observation

/// Ein Foto in der Liste – mit den Metadaten aus der Datei (`original`) und den
/// bearbeiteten, noch nicht gespeicherten Werten (`edited`).
@MainActor
@Observable
final class PhotoItem: Identifiable {
    let id = UUID()
    /// Ändert sich nur beim Umbenennen.
    var url: URL

    var original = PhotoMetadata()
    var edited = PhotoMetadata()
    var isLoaded = false
    var loadError: String?
    var saveWarning: String?
    var thumbnail: NSImage?

    // Nur für die Oberfläche, wird nicht gespeichert:
    /// Großes Vorschaubild (nur solange das Foto angezeigt wird).
    var previewImage: CGImage?
    /// Ausgewählter Gesichtsrahmen.
    var selectedFaceID: UUID?
    /// Namensvorschläge für unbenannte Gesichter (experimentell).
    var faceSuggestions: [UUID: String] = [:]

    init(url: URL) {
        self.url = url
    }

    var fileName: String { url.lastPathComponent }
    /// Gesichtsrahmen sind nicht in allen Formaten möglich (PNG nicht).
    var supportsFaceRegions: Bool { MetadataService.supportsFaceRegions(url: url) }
    var isDirty: Bool { isLoaded && edited.normalized() != original }

    func revert() {
        edited = original
        faceSuggestions = [:]
        selectedFaceID = nil
    }

    /// Gesicht benennen und die Person auch in die Personenliste aufnehmen.
    func name(face id: UUID, as name: String) {
        guard let index = edited.faces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.faces[index].name = trimmed
        faceSuggestions[id] = nil
        if !trimmed.isEmpty && !edited.people.contains(trimmed) {
            edited.people.append(trimmed)
        }
    }

    func removeFace(_ id: UUID) {
        edited.faces.removeAll { $0.id == id }
        faceSuggestions[id] = nil
        if selectedFaceID == id { selectedFaceID = nil }
    }

    func load() async {
        let url = self.url
        let (result, thumb) = await Task.detached(priority: .userInitiated) { () -> (Result<PhotoMetadata, Error>, CGImage?) in
            let result = Result { try MetadataService.read(from: url) }
            let thumb = MetadataService.thumbnail(for: url, maxPixelSize: 160)
            return (result, thumb)
        }.value

        if let thumb {
            thumbnail = NSImage(cgImage: thumb, size: .zero)
        }
        switch result {
        case .success(let metadata):
            original = metadata
            edited = metadata
            isLoaded = true
        case .failure(let error):
            loadError = error.localizedDescription
        }
    }
}
