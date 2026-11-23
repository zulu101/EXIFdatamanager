import AppKit
import SwiftUI

@main
struct ExifDataManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("EXIF Data Manager", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { appDelegate.model = model }
        }
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Fotos öffnen …") { model.showOpenPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Alle Änderungen speichern") { Task { await model.saveAll() } }
                .keyboardShortcut("s")
        }
        CommandMenu("Foto") {
            Button("Vorheriges Foto") { model.selectNeighbour(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command])
            Button("Nächstes Foto") { model.selectNeighbour(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command])
            Divider()
            Button("Nach links drehen") { model.rotateSelection(clockwise: false) }
                .keyboardShortcut("l")
            Button("Nach rechts drehen") { model.rotateSelection(clockwise: true) }
                .keyboardShortcut("r")
            Divider()
            Button("Umbenennen …") { model.requestRename() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Änderungen der Auswahl verwerfen") {
                model.selectedItems.forEach { $0.revert() }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nötig, wenn die App direkt per `swift run` gestartet wird.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard model.hasUnsavedChanges else {
            model.cleanUpBackups(quitting: true)
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "Ungespeicherte Änderungen")
        alert.informativeText = String(localized: "\(model.dirtyItems.count) Foto(s) haben Änderungen, die noch nicht in die Dateien geschrieben wurden.")
        alert.addButton(withTitle: String(localized: "Speichern"))
        alert.addButton(withTitle: String(localized: "Nicht speichern"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await model.saveAll()
                let canQuit = !model.hasUnsavedChanges
                if canQuit { model.cleanUpBackups(quitting: true) }
                NSApp.reply(toApplicationShouldTerminate: canQuit)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            model.cleanUpBackups(quitting: true)
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
