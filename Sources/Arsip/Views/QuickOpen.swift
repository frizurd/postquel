import SwiftUI

/// ⌘P palette: fuzzy-find a table, ↑↓ to move, ↩ to open.
struct QuickOpenView: View {
    let relations: [RelationRef]
    var onOpen: (RelationRef, _ inNewTab: Bool) -> Void
    var onClose: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    private var matches: [FuzzyMatch<RelationRef>] {
        FuzzyMatch.rank(relations, query: query) { "\($0.schema).\($0.name)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a table or view", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .onSubmit { open(newTab: false) }
                    .onChange(of: query) { selection = 0 }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)

            Divider()

            if matches.isEmpty {
                Text(relations.isEmpty ? "No tables" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.value.id) { index, match in
                                row(match, isSelected: index == selection)
                                    .id(match.value.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onOpen(match.value, false) }
                                    .onHover { if $0 { selection = index } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selection) {
                        proxy.scrollTo(matches[min(selection, matches.count - 1)].value.id)
                    }
                }
            }

            Divider()
            HStack(spacing: 12) {
                hint("↩", "Open")
                hint("⌘↩", "New tab")
                hint("esc", "Close")
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
        }
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
        .onAppear { isFocused = true }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onKeyPress(keys: [.return]) { press in
            open(newTab: press.modifiers.contains(.command))
            return .handled
        }
    }

    private func row(_ match: FuzzyMatch<RelationRef>, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: match.value.kind.symbol)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 16)
            Text(match.highlighted)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(match.value.schema)
                .font(.caption)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear)))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quinary))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        selection = (selection + delta + matches.count) % matches.count
        return .handled
    }

    private func open(newTab: Bool) {
        guard matches.indices.contains(selection) else { return }
        onOpen(matches[selection].value, newTab)
    }
}
