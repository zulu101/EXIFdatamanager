import AppKit
import ExifCore
import Observation

/// Ein Foto in der Liste – mit den Metadaten aus der Datei (`original`) und den
/// bearbeiteten, noch nicht gespeicherten Werten (`edited`).
@MainActor
@Observable
final class PhotoItem: Identifiable {
    let id = UUID()
    let url: URL

    var original = PhotoMetadata()
    var edited = PhotoMetadata()
    var isLoaded = false
    var loadError: String?
    var saveWarning: String?
    var thumbnail: NSImage?

    init(url: URL) {
        self.url = url
    }

    var fileName: String { url.lastPathComponent }
    var isDirty: Bool { isLoaded && edited.normalized() != original }

    func revert() {
        edited = original
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
