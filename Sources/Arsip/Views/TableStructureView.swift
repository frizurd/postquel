import AppKit
import SwiftUI

/// Structure pane of a table tab: name and notes, then columns, indexes, constraints and triggers.
/// Edits are drafts until Save Changes runs them as one transaction.
struct TableStructureView: View {
    @Bindable var model: TableStructureModel

    var body: some View {
        Group {
            if !model.isLoaded {
                if let error = model.error {
                    ContentUnavailableView("Couldn't Load Structure", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    // Lazy, so a wide table only builds the column rows that are on screen.
                    LazyVStack(alignment: .leading, spacing: 26) {
                        tableHeader
                        columnsSection
                        if model.relation.kind == .table || !model.indexes.isEmpty { indexesSection }
                        if !model.constraints.isEmpty { constraintsSection }
                        if !model.triggers.isEmpty { triggersSection }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.isSaving)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task { await model.start() }
    }

    // MARK: Table

    private var tableHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: model.relation.kind.symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                TextField("Table name", text: $model.draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .disabled(!model.isEditable)
                if model.relation.schema != "public" {
                    Text(model.relation.schema)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quinary))
                }
            }
            TextField("Notes — what this table is for", text: $model.draftComment, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1...6)
                .disabled(!model.isEditable)
            if !model.isEditable {
                Label("\(kindName) structure can't be edited here. Change it with SQL in a query tab.",
                      systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var kindName: String {
        switch model.relation.kind {
        case .table: "Table"
        case .view: "View"
        case .materializedView: "Materialized view"
        case .foreignTable: "Foreign table"
        }
    }

    // MARK: Columns

    private var columnsSection: some View {
        section("Columns", count: model.columnDrafts.filter { !$0.isDropped }.count) {
            HStack(spacing: ColumnLayout.spacing) {
                Color.clear.frame(width: ColumnLayout.marker, height: 1)
                header("Name").frame(width: ColumnLayout.name, alignment: .leading)
                header("Type").frame(width: ColumnLayout.type, alignment: .leading)
                header("Not null").frame(width: ColumnLayout.notNull)
                header("Default").frame(width: ColumnLayout.defaultValue, alignment: .leading)
                header("Comment").frame(minWidth: ColumnLayout.comment, maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: ColumnLayout.actions, height: 1)
            }
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach($model.columnDrafts) { $draft in
                    ColumnRow(draft: $draft, isEditable: model.isEditable,
                              onDrop: { model.toggleDrop(draft.id) },
                              onRevert: { model.revertColumn(draft.id) })
                }
            }
        }
    }

    // MARK: Indexes

    private var indexesSection: some View {
        section("Indexes", count: model.indexes.count + model.newIndexes.count) {
            if model.indexes.isEmpty, model.newIndexes.isEmpty {
                emptyLine("No indexes")
            }
            ForEach(model.indexes, id: \.name) { index in
                let dropped = model.droppedIndexes.contains(index.name)
                ItemRow(isDropped: dropped, isNew: false) {
                    badge(index.isPrimary ? "Primary" : index.isUnique ? "Unique" : index.method.uppercased(),
                          color: index.isPrimary ? .orange : index.isUnique ? .purple : .secondary)
                    Text(index.name).fontWeight(.medium)
                    Text("(\(index.columns))")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                } trailing: {
                    if let constraint = index.constraint {
                        Text("via \(constraint)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .help("This index belongs to a constraint. Drop the constraint below to remove it.")
                    } else if model.isEditable {
                        dropButton(isDropped: dropped) { model.toggleDropIndex(index.name) }
                    }
                }
                .help(index.definition)
            }
            ForEach(model.newIndexes) { index in
                ItemRow(isDropped: false, isNew: true) {
                    badge(index.isUnique ? "Unique" : index.method.uppercased(), color: index.isUnique ? .purple : .secondary)
                    Text(index.name).fontWeight(.medium)
                    Text("(\(index.columns.joined(separator: ", ")))")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                } trailing: {
                    dropButton(isDropped: false) { model.removeNewIndex(index.id) }
                }
            }
        }
    }

    // MARK: Constraints

    private var constraintsSection: some View {
        section("Constraints", count: model.constraints.count) {
            ForEach(model.constraints, id: \.name) { constraint in
                let dropped = model.droppedConstraints.contains(constraint.name)
                ItemRow(isDropped: dropped, isNew: false) {
                    badge(constraint.typeName, color: constraint.type == "p" ? .orange : constraint.type == "f" ? .blue : .secondary)
                    Text(constraint.name).fontWeight(.medium)
                    Text(constraint.definition)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(constraint.definition)
                } trailing: {
                    if model.isEditable {
                        dropButton(isDropped: dropped) { model.toggleDropConstraint(constraint.name) }
                    }
                }
            }
        }
    }

    private var triggersSection: some View {
        section("Triggers", count: model.triggers.count) {
            ForEach(model.triggers, id: \.self) { trigger in
                Text(trigger)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous).fill(.quinary))
            }
        }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title).sectionLabel()
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            content()
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.tertiary)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }

    private func dropButton(isDropped: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isDropped ? "arrow.uturn.backward" : "trash")
        }
        .buttonStyle(TitlebarIconButtonStyle())
        .help(isDropped ? "Keep it" : "Remove when saving")
    }
}

/// Fixed widths, so the lazily built column rows line up without a Grid measuring every row.
private enum ColumnLayout {
    static let spacing: CGFloat = 10
    static let marker: CGFloat = 14
    static let name: CGFloat = 180
    static let type: CGFloat = 210
    static let notNull: CGFloat = 54
    static let defaultValue: CGFloat = 190
    static let comment: CGFloat = 140
    static let actions: CGFloat = 60
}

/// One column in the Structure grid: every attribute editable in place.
private struct ColumnRow: View {
    @Binding var draft: ColumnDraft
    let isEditable: Bool
    var onDrop: () -> Void
    var onRevert: () -> Void

    private static let commonTypes = [
        "text", "varchar(255)", "integer", "bigint", "smallint", "numeric(12,2)", "boolean", "uuid",
        "timestamptz", "timestamp", "date", "time", "interval", "jsonb", "json", "bytea", "text[]", "integer[]",
    ]

    /// Type suggestions for what's typed so far; all of them while the field still holds a full type.
    private func matches(_ type: String) -> Bool {
        let typed = draft.type.trimmingCharacters(in: .whitespaces).lowercased()
        return typed.isEmpty || type.hasPrefix(typed) && type != typed
    }

    /// Dropped columns stay visible, dimmed and locked, until restored or saved.
    private var isLocked: Bool { !isEditable || draft.isDropped }

    var body: some View {
        HStack(spacing: ColumnLayout.spacing) {
            marker
            TextField("name", text: $draft.name)
                .frame(width: ColumnLayout.name)
                .fontWeight(draft.original?.isPrimaryKey == true ? .semibold : .regular)
                .modifier(Locked(isLocked: isLocked, isDropped: draft.isDropped))
            // Suggestions come from the field itself rather than a menu button per row: a per-row
            // AppKit popup made switching to this view slow on wide tables.
            TextField("type", text: $draft.type)
                .font(.system(.body, design: .monospaced))
                .textInputSuggestions {
                    ForEach(Self.commonTypes.filter { matches($0) }, id: \.self) { type in
                        Text(type).textInputCompletion(type)
                    }
                }
                .frame(width: ColumnLayout.type)
            .modifier(Locked(isLocked: isLocked, isDropped: draft.isDropped))
            Button { draft.notNull.toggle() } label: {
                Image(systemName: draft.notNull ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(draft.notNull ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: ColumnLayout.notNull, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Not null")
            .accessibilityValue(draft.notNull ? "On" : "Off")
                .modifier(Locked(isLocked: isLocked, isDropped: draft.isDropped))
            defaultField
                .frame(width: ColumnLayout.defaultValue, alignment: .leading)
                .modifier(Locked(isLocked: isLocked, isDropped: draft.isDropped))
            TextField("", text: $draft.comment, prompt: Text("—"))
                .frame(minWidth: ColumnLayout.comment, maxWidth: .infinity)
                .modifier(Locked(isLocked: isLocked, isDropped: draft.isDropped))
            actions
        }
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private var defaultField: some View {
        if let identity = draft.original?.identity {
            Text(identity.replacingOccurrences(of: "GENERATED ", with: "").lowercased())
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(identity)
        } else if let generated = draft.original?.generated {
            Text("generated: \(generated)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("GENERATED ALWAYS AS (\(generated)) STORED")
        } else {
            TextField("", text: $draft.defaultValue, prompt: Text("no default"))
                .font(.system(.body, design: .monospaced))
        }
    }

    /// Key for the primary key, a dot for unsaved edits, a plus for new columns.
    @ViewBuilder
    private var marker: some View {
        Group {
            if draft.isNew {
                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
            } else if draft.isModified, !draft.isDropped {
                Circle().fill(.tint).frame(width: 6, height: 6)
            } else if draft.original?.isPrimaryKey == true {
                Image(systemName: "key.fill").foregroundStyle(.orange)
            } else {
                Color.clear
            }
        }
        .font(.caption)
        .frame(width: 14)
        .help(draft.isNew ? "New column" : draft.isModified ? "Changed" : draft.original?.isPrimaryKey == true ? "Primary key" : "")
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if draft.isModified, !draft.isNew, !draft.isDropped {
                Button(action: onRevert) { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo changes to this column")
            }
            if isEditable {
                Button(action: onDrop) { Image(systemName: draft.isDropped ? "arrow.uturn.backward" : "trash") }
                    .help(draft.isDropped ? "Keep this column" : draft.isNew ? "Remove" : "Drop this column when saving")
            }
        }
        .buttonStyle(TitlebarIconButtonStyle())
        .frame(width: ColumnLayout.actions, alignment: .trailing)
    }
}

private struct Locked: ViewModifier {
    let isLocked: Bool
    let isDropped: Bool

    func body(content: Content) -> some View {
        content
            .disabled(isLocked)
            .strikethrough(isDropped)
            .opacity(isDropped ? 0.45 : 1)
    }
}

/// An index or constraint line: a rounded row, struck through when it will be dropped.
private struct ItemRow<Leading: View, Trailing: View>: View {
    let isDropped: Bool
    let isNew: Bool
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if isNew {
                Image(systemName: "plus.circle.fill").foregroundStyle(.green).font(.caption)
            }
            HStack(spacing: 8) { leading }
                .strikethrough(isDropped)
                .opacity(isDropped ? 0.5 : 1)
            Spacer(minLength: 8)
            trailing
        }
        .font(.callout)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .fill(isNew ? AnyShapeStyle(Color.green.opacity(0.08)) : AnyShapeStyle(.quinary)))
    }
}

/// Add Index: pick columns in order, unique or not, and the access method.
struct AddIndexSheet: View {
    let model: TableStructureModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String] = []
    @State private var isUnique = false
    @State private var method = "btree"
    @State private var name = ""
    @State private var nameEdited = false

    private var columnNames: [String] {
        model.columnDrafts.filter { !$0.isDropped }.map { $0.name.trimmingCharacters(in: .whitespaces) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Index").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Columns, in order").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(columnNames, id: \.self) { column in
                            Toggle(isOn: Binding(
                                get: { selected.contains(column) },
                                set: { on in
                                    if on { selected.append(column) } else { selected.removeAll { $0 == column } }
                                    if !nameEdited { name = model.suggestedIndexName(columns: selected) }
                                }
                            )) {
                                HStack {
                                    Text(column)
                                    if let position = selected.firstIndex(of: column), selected.count > 1 {
                                        Text("\(position + 1)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(CGFloat(columnNames.count) * 22 + 8, 200))
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Method").foregroundStyle(.secondary)
                    Picker("", selection: $method) {
                        ForEach(["btree", "hash", "gin", "gist", "brin"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Toggle("Unique", isOn: $isUnique).disabled(method != "btree")
                }
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    model.addIndex(IndexDraft(name: name.trimmingCharacters(in: .whitespaces), columns: selected,
                                              isUnique: isUnique && method == "btree", method: method))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Added to the pending changes. Nothing runs until you save.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(width: 360)
    }
}

/// DDL pane: the SQL that recreates this table, highlighted like the editor.
struct TableDDLView: View {
    let model: TableStructureModel

    var body: some View {
        Group {
            if model.isLoaded {
                ScrollView {
                    Text(model.highlightedDDL)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                }
            } else if let error = model.error {
                ContentUnavailableView("Couldn't Load DDL", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task { await model.start() }
    }
}
