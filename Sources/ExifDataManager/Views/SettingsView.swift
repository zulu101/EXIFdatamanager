import ExifCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.backupDefaultsKey) private var createBackup = true

    var body: some View {
        TabView {
            Form {
                Toggle("Vor dem ersten Speichern eine Sicherungskopie anlegen", isOn: $createBackup)
                Text("Die unveränderte Originaldatei wird einmalig in den Unterordner „\(BackupService.folderName)“ neben dem Foto kopiert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .tabItem { Label("Allgemein", systemImage: "gearshape") }

            SuggestionList(title: "Bekannte Personen", store: model.people)
                .tabItem { Label("Personen", systemImage: "person.2") }

            SuggestionList(title: "Bekannte Schlagwörter", store: model.keywords)
                .tabItem { Label("Schlagwörter", systemImage: "tag") }
        }
        .frame(width: 480, height: 360)
    }
}

private struct SuggestionList: View {
    let title: String
    let store: SuggestionStore

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            Text("Diese Liste wird nur für Vorschläge verwendet. Entfernen ändert keine Fotos.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(store.values, id: \.self) { value in
                    HStack {
                        Text(value)
                        Spacer()
                        Button {
                            store.remove(value)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding()
    }
}
