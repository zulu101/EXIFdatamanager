import ExifCore
import SwiftUI

/// Bearbeitung eines einzelnen Fotos.
struct MetadataEditorView: View {
    @Environment(AppModel.self) private var model
    @Bindable var item: PhotoItem

    var body: some View {
        Form {
            if let warning = item.saveWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Aufnahmedatum") {
                DateEditor(date: $item.edited.date)
            }

            Section("Aufnahmeort") {
                LocationEditor(metadata: $item.edited)
            }

            FacesSection(item: item)

            Section {
                TokenEditor(values: $item.edited.people, store: model.people,
                            placeholder: "Name eingeben und ⏎ drücken")
            } header: {
                Text("Abgebildete Personen")
            } footer: {
                Text("Tipp: Personen z. B. von links nach rechts eintragen und die Anordnung in der Beschreibung festhalten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Beschreibung") {
                TextField("Beschreibung", text: $item.edited.caption,
                          prompt: Text("Was ist auf dem Foto zu sehen? Anlass, Geschichte, …"),
                          axis: .vertical)
                    .lineLimit(3...10)
                    .labelsHidden()
            }

            Section("Schlagwörter") {
                TokenEditor(values: $item.edited.keywords, store: model.keywords,
                            placeholder: "z. B. Urlaub, Hochzeit, Weihnachten")
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity)
    }
}

/// Datum mit wählbarer Genauigkeit.
struct DateEditor: View {
    @Binding var date: PartialDate?
    @State private var remembered: PartialDate?

    var body: some View {
        Picker("Bekannt ist", selection: precision) {
            ForEach(DatePrecision.allCases) { p in
                Text(p.label).tag(p)
            }
        }

        if let current = date {
            switch current.precision {
            case .unknown, .year:
                yearField
            case .month:
                Picker("Monat", selection: component(\.month)) {
                    ForEach(1...12, id: \.self) { m in
                        Text(Calendar.current.monthSymbols[m - 1]).tag(m)
                    }
                }
                yearField
            case .day:
                DatePicker("Datum", selection: dateBinding, displayedComponents: .date)
                    .datePickerStyle(.field)
            case .dateTime:
                DatePicker("Datum & Uhrzeit", selection: dateBinding, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
            }

            LabeledContent("Ergebnis") {
                Text(current.displayString)
                    .foregroundStyle(.secondary)
            }
            if current.precision == .year || current.precision == .month {
                Text(current.precision == .year
                     ? "Programme ohne Teil-Datums-Unterstützung (z. B. Apple Fotos) zeigen den 1. Januar an. Die tatsächliche Genauigkeit bleibt in der Datei gespeichert."
                     : "Programme ohne Teil-Datums-Unterstützung (z. B. Apple Fotos) zeigen den 1. des Monats an. Die tatsächliche Genauigkeit bleibt in der Datei gespeichert." as LocalizedStringKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var yearField: some View {
        TextField("Jahr", value: component(\.year), format: .number.grouping(.never))
            .frame(maxWidth: 200)
    }

    private var precision: Binding<DatePrecision> {
        Binding(
            get: { date?.precision ?? .unknown },
            set: { newValue in
                if newValue == .unknown {
                    remembered = date
                    date = nil
                } else {
                    var d = date ?? remembered ?? .placeholder
                    d.precision = newValue
                    date = d
                }
            }
        )
    }

    private func component(_ keyPath: WritableKeyPath<PartialDate, Int>) -> Binding<Int> {
        Binding(
            get: { date?[keyPath: keyPath] ?? 0 },
            set: { date?[keyPath: keyPath] = $0 }
        )
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { date?.asDate ?? Date() },
            set: { date?.set(from: $0) }
        )
    }
}
