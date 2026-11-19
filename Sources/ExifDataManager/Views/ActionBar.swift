import SwiftUI

/// Leiste am unteren Fensterrand – immer sichtbar, unabhängig davon, wie lang das Formular ist.
/// Zeigt den Speicherstatus und den Speichern-Button; dazu kontextabhängige Aktionen.
struct ActionBar<Leading: View, Trailing: View>: View {
    @Environment(AppModel.self) private var model
    private let leading: Leading
    private let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer(minLength: 8)
            status
            trailing
            Button {
                Task { await model.saveAll() }
            } label: {
                Label(saveTitle, systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.hasUnsavedChanges || model.isSaving)
            .help("Alle Änderungen in die Bilddateien schreiben (⌘S)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var saveTitle: LocalizedStringKey {
        let count = model.dirtyItems.count
        return count > 1 ? "Alle speichern (\(count))" : "Speichern"
    }

    @ViewBuilder
    private var status: some View {
        let count = model.dirtyItems.count
        if model.isSaving {
            HStack(spacing: 6) {
                ProgressView(value: model.saveProgress)
                    .frame(width: 80)
                Text("Speichere …")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if count > 0 {
            Label(count == 1 ? "1 Foto ungespeichert" : "\(count) Fotos ungespeichert" as LocalizedStringKey,
                  systemImage: "circle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .labelStyle(StatusLabelStyle())
        } else {
            Label("Alles gespeichert", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .labelStyle(StatusLabelStyle())
        }
    }
}

/// Kleines Symbol vor dem Text, damit der Status kompakt bleibt.
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title.foregroundStyle(.primary)
        }
        .fixedSize()
    }
}
