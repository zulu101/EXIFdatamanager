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

                Button {
                    model.rotateSelection(clockwise: false)
                } label: {
                    Label("Nach links drehen", systemImage: "rotate.left")
                }
                .disabled(model.selection.isEmpty)
                .help("Ausgewählte Fotos um 90° nach links drehen (⌘L)")

                Button {
                    model.rotateSelection(clockwise: true)
                } label: {
                    Label("Nach rechts drehen", systemImage: "rotate.right")
                }
                .disabled(model.selection.isEmpty)
                .help("Ausgewählte Fotos um 90° nach rechts drehen (⌘R)")

                Button {
                    model.requestRename()
                } label: {
                    Label("Umbenennen", systemImage: "character.textbox")
                }
                .disabled(model.items.isEmpty)
                .help("Dateien anhand von Datum, Ort, Personen … umbenennen (⇧⌘R)")

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
        .sheet(isPresented: Binding(get: { model.isShowingRename },
                                    set: { model.isShowingRename = $0 })) {
            RenameSheet(items: model.renameTargets)
                .environment(model)
        }
        .task {
            // Abgelaufene Sicherungskopien beim Start in den Papierkorb legen.
            model.cleanUpBackups(quitting: false)
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
