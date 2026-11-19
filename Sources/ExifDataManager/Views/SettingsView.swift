import AppKit
import ExifCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.backupDefaultsKey) private var createBackup = true
    @AppStorage(AppLanguage.defaultsKey) private var language: AppLanguage = .system

    var body: some View {
        TabView {
            Form {
                Toggle("Vor dem ersten Speichern eine Sicherungskopie anlegen", isOn: $createBackup)
                Text("Die unveränderte Originaldatei wird einmalig in den Unterordner „\(BackupService.folderName)“ neben dem Foto kopiert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                    .padding(.vertical, 4)

                Picker("Sprache", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .onChange(of: language) { _, newValue in newValue.apply() }

                if language != AppLanguage.atLaunch {
                    HStack {
                        Text("Die neue Sprache wird nach einem Neustart der App wirksam.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Jetzt neu starten") { AppLanguage.relaunch() }
                            .disabled(model.hasUnsavedChanges)
                            .help(model.hasUnsavedChanges
                                  ? "Bitte zuerst alle Änderungen speichern."
                                  : "Startet die App neu." as LocalizedStringKey)
                    }
                }
            }
            .padding()
            .tabItem { Label("Allgemein", systemImage: "gearshape") }

            SuggestionList(title: "Bekannte Personen", store: model.people)
                .tabItem { Label("Personen", systemImage: "person.2") }

            SuggestionList(title: "Bekannte Schlagwörter", store: model.keywords)
                .tabItem { Label("Schlagwörter", systemImage: "tag") }
        }
        .frame(width: 520, height: 380)
    }
}

private struct SuggestionList: View {
    let title: LocalizedStringKey
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

/// Sprache der Oberfläche. „System“ folgt der Sprache von macOS (bzw. der in
/// Systemeinstellungen › Allgemein › Sprache & Region › Apps gewählten).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case german = "de"
    case english = "en"

    static let defaultsKey = "appLanguage"

    /// Sprache, mit der die App gestartet wurde – zum Erkennen, ob ein Neustart nötig ist.
    static let atLaunch = AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system

    var id: String { rawValue }

    /// Sprachnamen bewusst in der jeweiligen Sprache, damit man sie immer findet.
    var label: String {
        switch self {
        case .system: return String(localized: "Wie System")
        case .german: return "Deutsch"
        case .english: return "English"
        }
    }

    /// macOS liest die bevorzugte Sprache einer App beim Start aus „AppleLanguages“.
    func apply() {
        let defaults = UserDefaults.standard
        switch self {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        case .german, .english: defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// Startet die App neu, damit die Sprache übernommen wird.
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
