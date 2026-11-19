import SwiftUI

/// Eingabe für Listen wie Personen oder Schlagwörter – mit Vorschlägen aus bereits verwendeten Namen.
struct TokenEditor: View {
    @Binding var values: [String]
    let store: SuggestionStore
    let placeholder: LocalizedStringKey

    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        if !values.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    TokenChip(text: value) {
                        values.removeAll { $0 == value }
                    }
                }
            }
        }

        TextField(placeholder, text: $input)
            .focused($focused)
            .onSubmit { add(input) }

        let suggestions = Array(store.suggestions(matching: input, excluding: values).prefix(12))
        if (focused || !input.isEmpty) && !suggestions.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        add(suggestion)
                    } label: {
                        Label(suggestion, systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func add(_ text: String) {
        // Mehrere Einträge können mit Komma oder Semikolon getrennt eingegeben werden.
        let parts = text
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for part in parts where !values.contains(part) {
            values.append(part)
        }
        input = ""
        focused = true
    }
}

struct TokenChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("„\(text)“ entfernen")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

/// Einfacher Zeilenumbruch-Layout für Chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .infinity
        let rows = arrange(subviews, maxWidth: maxWidth)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: maxWidth.isFinite ? maxWidth : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth && !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
