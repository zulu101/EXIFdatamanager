import ExifCore
import SwiftUI

struct PhotoListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                PhotoRow(item: item)
                    .tag(item.id)
            }
        }
        .contextMenu(forSelectionType: PhotoItem.ID.self) { ids in
            Button("Im Finder zeigen") {
                let urls = model.items.filter { ids.contains($0.id) }.map(\.url)
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            Button("Änderungen verwerfen") {
                model.items.filter { ids.contains($0.id) }.forEach { $0.revert() }
            }
            Divider()
            Button("Aus Liste entfernen") { model.remove(ids) }
        }
        .onDeleteCommand { model.remove(model.selection) }
        .overlay {
            if model.items.isEmpty {
                ContentUnavailableView("Keine Fotos", systemImage: "photo.stack",
                                       description: Text("Fotos oder Ordner hierher ziehen."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.items.isEmpty {
                let done = model.items.filter { $0.edited.date != nil && $0.edited.hasLocation }.count
                Text("\(model.items.count) Fotos · \(done) mit Datum & Ort")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(.bar)
            }
        }
    }
}

struct PhotoRow: View {
    let item: PhotoItem

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !item.edited.people.isEmpty {
                    Text(item.edited.people.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
            statusIcon
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let date = item.edited.date { parts.append(date.displayString) }
        let place = item.edited.placeSummary
        if !place.isEmpty { parts.append(place) }
        return parts.isEmpty
            ? (item.isLoaded ? String(localized: "Noch keine Angaben") : String(localized: "Wird geladen …"))
            : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        if item.loadError != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(item.loadError ?? "")
        } else if item.saveWarning != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .help(item.saveWarning ?? "")
        } else if item.isDirty {
            Circle()
                .fill(.orange)
                .frame(width: 8, height: 8)
                .help("Ungespeicherte Änderungen")
        } else if item.isLoaded && item.edited.date != nil && item.edited.hasLocation {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Datum und Ort sind eingetragen")
        }
    }
}
