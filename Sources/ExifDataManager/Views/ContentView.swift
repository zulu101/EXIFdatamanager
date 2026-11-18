import ExifCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            PhotoListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            DetailView()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.showOpenPanel()
                } label: {
                    Label("Fotos hinzufügen", systemImage: "plus")
                }
                .help("Fotos oder Ordner hinzufügen (⌘O)")

                if model.isSaving {
                    ProgressView(value: model.saveProgress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }

                Button {
                    Task { await model.saveAll() }
                } label: {
                    Label("Alle speichern", systemImage: "square.and.arrow.down")
                }
                .disabled(!model.hasUnsavedChanges || model.isSaving)
                .help("Alle Änderungen in die Bilddateien schreiben (⌘S)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls)
            return true
        }
        .alert("Hinweis", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.selectedItems
        switch selected.count {
        case 0:
            ContentUnavailableView {
                Label("Kein Foto ausgewählt", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Ziehe eingescannte Fotos oder ganze Ordner in dieses Fenster oder wähle „Fotos hinzufügen“.\nMit ⇧ oder ⌘ kannst du mehrere Fotos gleichzeitig bearbeiten.")
            } actions: {
                Button("Fotos hinzufügen …") { model.showOpenPanel() }
            }
        case 1:
            PhotoDetailView(item: selected[0])
                .id(selected[0].id)
        default:
            BatchEditView(items: selected)
        }
    }
}

struct PhotoDetailView: View {
    @Environment(AppModel.self) private var model
    let item: PhotoItem

    var body: some View {
        // Bewusst HStack statt HSplitView: HSplitView übernimmt die volle Höhe des Formulars,
        // wodurch das Fenster zu hoch werden und die Aktionsleiste unten verschwinden kann.
        HStack(spacing: 0) {
            ImagePreview(item: item)
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            MetadataEditorView(item: item)
                .frame(width: 420)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActionBar {
                copyFromPreviousMenu
            } trailing: {
                Button("Zurücksetzen") { item.revert() }
                    .controlSize(.large)
                    .disabled(!item.isDirty)
                    .help("Ungespeicherte Änderungen an diesem Foto verwerfen")
            }
        }
    }

    private var copyFromPreviousMenu: some View {
        let previous = model.previous(of: item)
        return Menu {
            Button("Datum") { if let p = previous { item.edited.date = p.edited.date } }
            Button("Ort") { if let p = previous { copyPlace(from: p.edited) } }
            Button("Personen") { if let p = previous { item.edited.people = p.edited.people } }
            Button("Schlagwörter") { if let p = previous { item.edited.keywords = p.edited.keywords } }
            Divider()
            Button("Datum, Ort, Personen & Schlagwörter") {
                guard let p = previous else { return }
                item.edited.date = p.edited.date
                copyPlace(from: p.edited)
                item.edited.people = p.edited.people
                item.edited.keywords = p.edited.keywords
            }
        } label: {
            Label("Vom vorherigen Foto", systemImage: "arrow.up.doc.on.clipboard")
        }
        .controlSize(.large)
        .fixedSize()
        .disabled(previous == nil)
        .help("Angaben vom Foto darüber in der Liste übernehmen – praktisch bei Bildern vom selben Film.")
    }

    private func copyPlace(from source: PhotoMetadata) {
        item.edited.location = source.location
        item.edited.city = source.city
        item.edited.state = source.state
        item.edited.country = source.country
        item.edited.latitude = source.latitude
        item.edited.longitude = source.longitude
    }
}

struct ImagePreview: View {
    let item: PhotoItem
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .shadow(radius: 4)
                } else if let error = item.loadError {
                    ContentUnavailableView("Bild kann nicht gelesen werden", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
            .help("Doppelklick öffnet das Bild in der Vorschau-App")

            Text(item.url.path(percentEncoded: false))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding()
        .background(Color(nsColor: .underPageBackgroundColor))
        .task(id: item.id) {
            let url = item.url
            let cg = await Task.detached(priority: .userInitiated) {
                MetadataService.thumbnail(for: url, maxPixelSize: 2400, allowEmbedded: false)
            }.value
            if let cg {
                image = NSImage(cgImage: cg, size: .zero)
            }
        }
    }
}
