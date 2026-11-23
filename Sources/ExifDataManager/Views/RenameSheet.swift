import ExifCore
import SwiftUI

/// Dateien anhand der Metadaten umbenennen – mit Vorschau vor dem Ausführen.
struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [PhotoItem]

    @AppStorage(AppModel.renamePatternDefaultsKey) private var pattern = FileNamer.defaultPattern
    @AppStorage(AppModel.fileDateDefaultsKey) private var setFileDate = false
    @State private var isRenaming = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(items.count == 1 ? "1 Foto umbenennen" : "\(items.count) Fotos umbenennen" as LocalizedStringKey)
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Namensmuster")
                    .font(.headline)
                TextField("Namensmuster", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .labelsHidden()
                HStack(spacing: 6) {
                    Text("Einfügen:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(FileNamer.Token.allCases) { token in
                        Button(token.label) { insert(token) }
                            .controlSize(.small)
                            .help(token.placeholder)
                    }
                    Spacer()
                    Button("Standard") { pattern = FileNamer.defaultPattern }
                        .controlSize(.small)
                        .buttonStyle(.link)
                }
                Text("Das Datum hat immer die Form JJJJ-MM-TT_HH-MM. Unbekannte Teile werden mit 00 aufgefüllt, z. B. 1985-07-00_00-00, wenn nur Monat und Jahr bekannt sind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Vorschau")
                    .font(.headline)
                List {
                    ForEach(Array(zip(items, preview).prefix(200).enumerated()), id: \.offset) { _, pair in
                        HStack(spacing: 8) {
                            Text(pair.0.fileName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.tertiary)
                            Text(pair.1.lastPathComponent)
                                .fontWeight(pair.1 == pair.0.url ? .regular : .medium)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.callout)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(minHeight: 180)
            }

            Toggle("Erstelldatum der Datei auf das Aufnahmedatum setzen", isOn: $setFileDate)
            Text("Damit sortiert auch der Finder nach „Erstellt am“ chronologisch. Gilt auch beim späteren Speichern. Das Änderungsdatum bleibt unverändert, damit Backup-Programme Änderungen weiterhin erkennen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Ungespeicherte Änderungen werden vorher gespeichert. Der bisherige Dateiname bleibt in der Datei erhalten (XMP „PreservedFileName“), Sicherungskopien werden mit umbenannt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let result {
                Label(result, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            HStack {
                if isRenaming {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(result == nil ? "Abbrechen" : "Fertig" as LocalizedStringKey) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        isRenaming = true
                        result = await model.rename(items, pattern: pattern)
                        isRenaming = false
                    }
                } label: {
                    Text(changedCount == 1 ? "1 Datei umbenennen" : "\(changedCount) Dateien umbenennen" as LocalizedStringKey)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isRenaming || model.isSaving || changedCount == 0 || result != nil)
            }
        }
        .padding(20)
        .frame(width: 640)
        .frame(minHeight: 520)
    }

    private var preview: [URL] {
        model.renamePreview(for: items, pattern: pattern)
    }

    private var changedCount: Int {
        zip(items, preview).filter { $0.0.url != $0.1 }.count
    }

    private func insert(_ token: FileNamer.Token) {
        if pattern.isEmpty || pattern.hasSuffix("_") || pattern.hasSuffix("-") || pattern.hasSuffix(" ") {
            pattern += token.placeholder
        } else {
            pattern += "_" + token.placeholder
        }
    }
}
