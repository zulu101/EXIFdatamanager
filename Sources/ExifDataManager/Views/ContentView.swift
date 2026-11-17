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
                    Label("Alle speichern (\(model.dirtyItems.count))", systemImage: "square.and.arrow.down")
                }
                .labelStyle(.titleAndIcon)
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
    let item: PhotoItem

    var body: some View {
        HSplitView {
            ImagePreview(item: item)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            MetadataEditorView(item: item)
                .frame(minWidth: 380, idealWidth: 440, maxWidth: 560)
        }
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
