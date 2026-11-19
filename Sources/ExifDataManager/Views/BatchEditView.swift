import ExifCore
import SwiftUI

/// Gleiche Angaben für viele Fotos auf einmal setzen – z. B. für einen ganzen Film.
struct BatchEditView: View {
    @Environment(AppModel.self) private var model
    let items: [PhotoItem]

    @State private var applyDate = false
    @State private var date: PartialDate? = .placeholder
    @State private var applyPlace = false
    @State private var place = PhotoMetadata()
    @State private var addPeople: [String] = []
    @State private var addKeywords: [String] = []
    @State private var applyCaption = false
    @State private var caption = ""
    @State private var faceMessage: String?

    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(items) { item in
                            Group {
                                if let thumb = item.thumbnail {
                                    Image(nsImage: thumb).resizable().scaledToFill()
                                } else {
                                    Rectangle().fill(.quaternary)
                                }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .help(item.fileName)
                        }
                    }
                }
            } header: {
                Text("\(items.count) Fotos ausgewählt")
            } footer: {
                Text("Nur die eingeschalteten Bereiche werden übernommen. Personen und Schlagwörter werden ergänzt, nicht ersetzt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Aufnahmedatum") {
                Toggle("Datum für alle setzen", isOn: $applyDate)
                if applyDate {
                    DateEditor(date: $date)
                }
            }

            Section("Aufnahmeort") {
                Toggle("Ort für alle setzen", isOn: $applyPlace)
                if applyPlace {
                    LocationEditor(metadata: $place)
                }
            }

            Section {
                HStack {
                    Button {
                        Task { faceMessage = await model.detectFaces(in: items) }
                    } label: {
                        Label("Gesichter in \(items.count) Fotos erkennen", systemImage: "person.crop.rectangle.stack")
                    }
                    .disabled(model.isAnalyzingFaces)
                    if model.isAnalyzingFaces {
                        ProgressView(value: model.faceProgress)
                            .frame(width: 120)
                    }
                }
                if let faceMessage {
                    Text(faceMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Gesichter")
            } footer: {
                Text("Markiert gefundene Gesichter sofort mit einem Rahmen (ohne Namen). Benennen kannst du sie anschließend in der Einzelansicht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Personen hinzufügen") {
                TokenEditor(values: $addPeople, store: model.people, placeholder: "Name eingeben und ⏎ drücken")
            }

            Section("Schlagwörter hinzufügen") {
                TokenEditor(values: $addKeywords, store: model.keywords, placeholder: "z. B. Urlaub Italien 1978")
            }

            Section("Beschreibung") {
                Toggle("Beschreibung für alle setzen (ersetzt vorhandene)", isOn: $applyCaption)
                if applyCaption {
                    TextField("Beschreibung", text: $caption, axis: .vertical)
                        .lineLimit(3...8)
                        .labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActionBar {
                EmptyView()
            } trailing: {
                Button {
                    apply()
                } label: {
                    Label("Auf \(items.count) Fotos übernehmen", systemImage: "square.stack.3d.down.forward")
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.large)
                .disabled(!hasChanges)
                .help("Die eingeschalteten Angaben bei allen ausgewählten Fotos eintragen. Gespeichert wird erst mit „Speichern“.")
            }
        }
    }

    private var hasChanges: Bool {
        applyDate || applyPlace || applyCaption || !addPeople.isEmpty || !addKeywords.isEmpty
    }

    private func apply() {
        for item in items where item.isLoaded {
            if applyDate {
                item.edited.date = date
            }
            if applyPlace {
                item.edited.location = place.location
                item.edited.city = place.city
                item.edited.state = place.state
                item.edited.country = place.country
                item.edited.latitude = place.latitude
                item.edited.longitude = place.longitude
            }
            for person in addPeople where !item.edited.people.contains(person) {
                item.edited.people.append(person)
            }
            for keyword in addKeywords where !item.edited.keywords.contains(keyword) {
                item.edited.keywords.append(keyword)
            }
            if applyCaption {
                item.edited.caption = caption
            }
        }
    }
}
