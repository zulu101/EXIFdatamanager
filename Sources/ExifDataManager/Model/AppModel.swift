import AppKit
import ExifCore
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    var items: [PhotoItem] = []
    var selection: Set<PhotoItem.ID> = []
    var errorMessage: String?
    var isSaving = false
    var saveProgress: Double = 0

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
        panel.title = "Fotos oder Ordner auswählen"
        panel.prompt = "Hinzufügen"
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
                } else {
                    item.edited = metadata
                    item.saveWarning = "Nicht korrekt gespeichert: " + diffs.joined(separator: ", ")
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
