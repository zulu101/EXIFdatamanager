import ExifCore
import SwiftUI

/// Liste der markierten Gesichter eines Fotos mit Namen, Erkennung und Vorschlägen.
struct FacesSection: View {
    @Environment(AppModel.self) private var model
    @Bindable var item: PhotoItem
    @FocusState private var focusedFace: UUID?
    @State private var message: String?

    var body: some View {
        Section {
            if !item.supportsFaceRegions {
                Label("In PNG-Dateien können keine Gesichtsrahmen gespeichert werden. Trage die Personen unten als Namen ein – oder speichere den Scan als JPEG oder TIFF.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
            HStack(spacing: 8) {
                Button {
                    Task { message = await model.detectFaces(in: [item]) }
                } label: {
                    Label("Gesichter erkennen", systemImage: "person.crop.rectangle.stack")
                }
                .help("Sucht Gesichter im Bild (lokal auf dem Mac) und markiert sie mit einem Rahmen.")

                Button {
                    Task { message = await model.suggestNames(for: item) }
                } label: {
                    Label("Namen vorschlagen", systemImage: "wand.and.stars")
                }
                .disabled(!item.edited.faces.contains { $0.name.isEmpty })
                .help("Experimentell: vergleicht unbenannte Gesichter mit bereits benannten Gesichtern in den geladenen Fotos.")

                if model.isAnalyzingFaces {
                    ProgressView(value: model.faceProgress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
            }
            .disabled(model.isAnalyzingFaces || item.previewImage == nil)

            if let message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if item.edited.faces.isEmpty {
                Text("Ziehe im Bild mit der Maus einen Rahmen um ein Gesicht – oder lass Gesichter automatisch erkennen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(item.edited.faces.enumerated()), id: \.element.id) { index, face in
                row(number: index + 1, face: face)
            }
            }
        } header: {
            Text("Gesichter markieren")
        } footer: {
            Text("Rahmen und Namen werden in offenen Standards in der Bilddatei gespeichert (MWG-Regionen und IPTC-Bildregionen) und z. B. von Lightroom Classic und digiKam gelesen. Apple Fotos zeigt sie nicht an, übernimmt aber die Namen als Schlagwörter.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: item.selectedFaceID) { _, id in
            if focusedFace != id { focusedFace = id }
        }
        .onChange(of: focusedFace) { _, id in
            if let id, item.selectedFaceID != id { item.selectedFaceID = id }
        }
    }

    private func row(number: Int, face: FaceRegion) -> some View {
        let isSelected = item.selectedFaceID == face.id
        return HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(isSelected ? Color.accentColor : Color.secondary))

            crop(of: face)

            TextField("Name", text: nameBinding(face.id), prompt: Text("Wer ist das?"))
                .labelsHidden()
                .focused($focusedFace, equals: face.id)
                .onSubmit { item.name(face: face.id, as: item.edited.faces.first { $0.id == face.id }?.name ?? "") }

            if let suggestion = item.faceSuggestions[face.id] {
                Button("\(suggestion)?") { item.name(face: face.id, as: suggestion) }
                    .buttonStyle(.bordered)
                    .tint(.purple)
                    .controlSize(.small)
                    .help("Vorschlag (experimentell) – zum Übernehmen klicken")
            }

            Menu {
                let known = PhotoMetadataPeople.candidates(item: item, store: model.people)
                if known.isEmpty { Text("Noch keine bekannten Personen") }
                ForEach(known, id: \.self) { person in
                    Button(person) { item.name(face: face.id, as: person) }
                }
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Bekannte Person auswählen")

            Button {
                item.removeFace(face.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Rahmen entfernen")
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : nil)
    }

    @ViewBuilder
    private func crop(of face: FaceRegion) -> some View {
        if let cg = item.previewImage,
           let cropped = cg.cropping(to: CGRect(x: face.x * Double(cg.width), y: face.y * Double(cg.height),
                                                width: face.width * Double(cg.width),
                                                height: face.height * Double(cg.height)).integral) {
            Image(nsImage: NSImage(cgImage: cropped, size: .zero))
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 36, height: 36)
        }
    }

    private func nameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { item.edited.faces.first { $0.id == id }?.name ?? "" },
            set: { newValue in
                if let index = item.edited.faces.firstIndex(where: { $0.id == id }) {
                    item.edited.faces[index].name = newValue
                    item.faceSuggestions[id] = nil
                }
            }
        )
    }
}

enum PhotoMetadataPeople {
    /// Personen dieses Fotos zuerst, danach alle bekannten Personen.
    @MainActor
    static func candidates(item: PhotoItem, store: SuggestionStore) -> [String] {
        var seen = Set<String>()
        return (item.edited.people + store.values).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
