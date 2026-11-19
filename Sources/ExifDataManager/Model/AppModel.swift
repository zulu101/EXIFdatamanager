import AppKit
import ExifCore
import Observation
import UniformTypeIdentifiers
import Vision

@MainActor
@Observable
final class AppModel {
    var items: [PhotoItem] = []
    var selection: Set<PhotoItem.ID> = []
    var errorMessage: String?
    var isSaving = false
    var saveProgress: Double = 0
    var isAnalyzingFaces = false
    var faceProgress: Double = 0
    /// Nur im Arbeitsspeicher; wird nie in Dateien geschrieben.
    @ObservationIgnored var featurePrintCache: [String: VNFeaturePrintObservation] = [:]

    let people = SuggestionStore(key: "knownPeople")
    let keywords = SuggestionStore(key: "knownKeywords")
    let places = RecentPlacesStore()

    static let backupDefaultsKey = "createBackup"

    var selectedItems: [PhotoItem] {
        items.filter { selection.contains($0.id) }
    }

    var dirtyItems: [PhotoItem] {
        items.filter(\.isDirty)
    }

    var hasUnsavedChanges: Bool {
        items.contains(where: \.isDirty)
    }

    // MARK: - Fotos hinzufügen / entfernen

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Fotos oder Ordner auswählen")
        panel.prompt = String(localized: "Hinzufügen")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder]
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }

    func add(urls: [URL]) {
        let known = Set(items.map { $0.url.standardizedFileURL })
        let files = expand(urls)
            .map(\.standardizedFileURL)
            .filter { !known.contains($0) }
        let unique = Array(Set(files))
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !unique.isEmpty else { return }

        let newItems = unique.map { PhotoItem(url: $0) }
        items.append(contentsOf: newItems)
        if selection.isEmpty, let first = newItems.first {
            selection = [first.id]
        }
        Task {
            for item in newItems {
                await item.load()
                learn(from: item.original)
            }
        }
    }

    func remove(_ ids: Set<PhotoItem.ID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    /// Ordner rekursiv nach unterstützten Bildern durchsuchen (ohne den Backup-Ordner).
    private func expand(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if MetadataService.supportedExtensions.contains(url.pathExtension.lowercased()) {
                    result.append(url)
                }
                continue
            }
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in enumerator {
                let isDirectory = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    if file.lastPathComponent == BackupService.folderName {
                        enumerator.skipDescendants()
                    }
                } else if MetadataService.supportedExtensions.contains(file.pathExtension.lowercased()) {
                    result.append(file)
                }
            }
        }
        return result
    }

    // MARK: - Navigation

    func previous(of item: PhotoItem) -> PhotoItem? {
        guard let index = items.firstIndex(where: { $0.id == item.id }), index > 0 else { return nil }
        return items[index - 1]
    }

    func selectNeighbour(offset: Int) {
        guard !items.isEmpty else { return }
        let current = items.lastIndex(where: { selection.contains($0.id) }) ?? -1
        let next = min(max(current + offset, 0), items.count - 1)
        selection = [items[next].id]
    }

    // MARK: - Speichern

    func saveAll() async {
        await save(items)
    }

    func save(_ targets: [PhotoItem]) async {
        let dirty = targets.filter(\.isDirty)
        guard !dirty.isEmpty, !isSaving else { return }
        isSaving = true
        saveProgress = 0
        defer { isSaving = false }

        let backup = UserDefaults.standard.object(forKey: Self.backupDefaultsKey) as? Bool ?? true
        var failures: [String] = []

        for (index, item) in dirty.enumerated() {
            let url = item.url
            let metadata = item.edited.normalized()
            let result = await Task.detached(priority: .userInitiated) { () -> Result<PhotoMetadata, Error> in
                Result {
                    if backup { try BackupService.backupIfNeeded(url) }
                    try MetadataService.write(metadata, to: url)
                    return try MetadataService.read(from: url)
                }
            }.value

            switch result {
            case .success(let reread):
                // Kontrolle: Steht jetzt wirklich das in der Datei, was eingegeben wurde?
                let diffs = metadata.differences(from: reread)
                item.original = reread
                if diffs.isEmpty {
                    item.edited = reread
                    item.saveWarning = nil
                    item.faceSuggestions = [:]
                } else {
                    item.edited = metadata
                    item.saveWarning = String(localized: "Nicht korrekt gespeichert: \(diffs.joined(separator: ", "))")
                    failures.append("\(item.fileName): \(item.saveWarning!)")
                }
                learn(from: metadata)
                places.remember(metadata)
            case .failure(let error):
                failures.append(error.localizedDescription)
            }
            saveProgress = Double(index + 1) / Double(dirty.count)
        }

        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }
    }

    private func learn(from metadata: PhotoMetadata) {
        people.learn(metadata.people)
        keywords.learn(metadata.keywords)
    }
}

// MARK: - Gesichter

extension AppModel {
    /// Sucht Gesichter in den Fotos und ergänzt neue Rahmen (ohne Namen).
    /// Bereits markierte Gesichter bleiben unverändert. Gibt eine Meldung für die Oberfläche zurück.
    func detectFaces(in targets: [PhotoItem]) async -> String {
        guard !isAnalyzingFaces else { return "" }
        isAnalyzingFaces = true
        faceProgress = 0
        defer { isAnalyzingFaces = false }

        var added = 0
        var failed = 0
        let loaded = targets.filter { $0.isLoaded && $0.supportsFaceRegions }
        for (index, item) in loaded.enumerated() {
            if let image = await image(for: item) {
                let found = await Task.detached(priority: .userInitiated) {
                    try? FaceDetector.detectFaces(in: image)
                }.value
                if let found {
                    for rect in found where !item.edited.faces.contains(where: { $0.rect.overlapRatio(rect) > 0.3 }) {
                        item.edited.faces.append(FaceRegion(rect: rect))
                        added += 1
                    }
                } else {
                    failed += 1
                }
            } else {
                failed += 1
            }
            faceProgress = Double(index + 1) / Double(max(loaded.count, 1))
        }

        var message: String
        switch added {
        case 0: message = String(localized: "Keine neuen Gesichter gefunden.")
        case 1: message = String(localized: "1 Gesicht gefunden.")
        default: message = String(localized: "\(added) Gesichter gefunden.")
        }
        if failed > 0 { message += " " + String(localized: "\(failed) Foto(s) konnten nicht analysiert werden.") }
        return message
    }

    /// Experimentell: schlägt Namen für unbenannte Gesichter vor, basierend auf Ähnlichkeit zu
    /// bereits benannten Gesichtern in allen geladenen Fotos.
    func suggestNames(for item: PhotoItem) async -> String {
        let unnamed = item.edited.faces.filter { $0.name.isEmpty }
        guard !unnamed.isEmpty else { return String(localized: "Alle Gesichter haben bereits einen Namen.") }
        guard !isAnalyzingFaces else { return "" }
        isAnalyzingFaces = true
        faceProgress = 0
        defer { isAnalyzingFaces = false }

        // Vergleichsbeispiele: benannte Gesichter aus allen geladenen Fotos.
        var references: [(name: String, print: VNFeaturePrintObservation)] = []
        let sources = items.filter { $0.isLoaded && $0.edited.faces.contains { !$0.name.isEmpty } }
        for (index, other) in sources.enumerated() {
            let named = other.edited.faces.filter { !$0.name.isEmpty }
            let prints = await featurePrints(for: other, faces: named)
            for (face, print) in zip(named, prints) {
                if let print { references.append((face.name, print)) }
            }
            faceProgress = Double(index + 1) / Double(sources.count + 1)
        }
        guard Set(references.map(\.name)).count >= 2 else {
            return String(localized: "Für Vorschläge müssen zuerst mindestens zwei verschiedene Personen auf geladenen Fotos benannt sein.")
        }

        let queries = await featurePrints(for: item, faces: unnamed)
        var count = 0
        for (face, print) in zip(unnamed, queries) {
            guard let print, let name = FaceDetector.suggestName(for: print, references: references) else { continue }
            item.faceSuggestions[face.id] = name
            count += 1
        }
        faceProgress = 1
        return count == 0
            ? String(localized: "Keine sicheren Vorschläge gefunden.")
            : String(localized: "\(count) Vorschlag/Vorschläge – bitte prüfen und mit Klick übernehmen.")
    }

    private func image(for item: PhotoItem) async -> CGImage? {
        if let preview = item.previewImage { return preview }
        let url = item.url
        return await Task.detached(priority: .userInitiated) {
            MetadataService.thumbnail(for: url, maxPixelSize: 2000, allowEmbedded: false)
        }.value
    }

    /// Merkmale je Gesicht, zwischengespeichert nur im Arbeitsspeicher.
    private func featurePrints(for item: PhotoItem, faces: [FaceRegion]) async -> [VNFeaturePrintObservation?] {
        let keys = faces.map { face in
            "\(item.url.path)|" + String(format: "%.3f|%.3f|%.3f|%.3f", face.x, face.y, face.width, face.height)
        }
        let missing = zip(keys, faces).filter { featurePrintCache[$0.0] == nil }
        if !missing.isEmpty, let image = await image(for: item) {
            let regions = missing.map(\.1.rect)
            let computed = await Task.detached(priority: .userInitiated) {
                regions.map { try? FaceDetector.featurePrint(of: image, region: $0) }
            }.value
            for ((key, _), print) in zip(missing, computed) {
                if let print { featurePrintCache[key] = print }
            }
        }
        return keys.map { featurePrintCache[$0] }
    }
}
