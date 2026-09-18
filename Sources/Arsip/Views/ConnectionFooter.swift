import SwiftUI

/// Sidebar footer: which database you're in, switching, managing and disconnecting.
struct ConnectionFooter: View {
    @Bindable var session: SessionModel
    @State private var isHovered = false
    @State private var showsNewDatabase = false
    @State private var showsManager = false
    @State private var menuActions: AnyObject?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                showMenu()
            } label: {
                label
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .frame(height: 36)
        }
        .background(.bar)
        .onHover { isHovered = $0 }
        .sheet(isPresented: $showsNewDatabase) {
            NewDatabaseSheet(session: session)
        }
        .sheet(isPresented: $showsManager) {
            DatabaseManagerSheet(session: session)
        }
    }

    /// Same icon column, spacing and text position as the table rows above: the icon starts
    /// 18pt from the sidebar edge (6pt highlight inset + 12pt), the text 44pt.
    private var label: some View {
        HStack(spacing: 9) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 12))
                .foregroundStyle(.tint)
                .frame(width: 17, alignment: .center)
            Text(session.config.database)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous)
            .fill(isHovered ? AnyShapeStyle(.quinary) : AnyShapeStyle(Color.clear)))
        .contentShape(RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
        .help("\(session.config.user)@\(session.config.host) · \(session.connection?.serverVersion ?? "")")
    }

    /// An AppKit menu: a SwiftUI Menu imposes its own label insets, which broke the alignment
    /// with the rows above.
    private func showMenu() {
        let menu = NSMenu()
        let actions = MenuActions(session: session,
                                  newDatabase: { showsNewDatabase = true },
                                  manage: { showsManager = true })

        menu.addItem(withTitle: "Databases", action: nil, keyEquivalent: "").isEnabled = false
        for database in session.databases {
            let item = NSMenuItem(title: database.name, action: #selector(MenuActions.switchTo(_:)), keyEquivalent: "")
            item.target = actions
            item.representedObject = database.name
            item.state = database.name == session.config.database ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, selector) in [("New Database…", #selector(MenuActions.newDatabase(_:))),
                                  ("Manage Databases…", #selector(MenuActions.manageDatabases(_:))),
                                  ("Reload List", #selector(MenuActions.reload(_:)))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = actions
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let disconnect = NSMenuItem(title: "Disconnect", action: #selector(MenuActions.disconnect(_:)), keyEquivalent: "")
        disconnect.target = actions
        menu.addItem(disconnect)

        menuActions = actions  // keep the targets alive while the menu is open
        if let event = NSApp.currentEvent, let view = event.window?.contentView {
            menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
        }
    }
}

/// Targets for the AppKit menu items.
@MainActor
private final class MenuActions: NSObject {
    let session: SessionModel
    let newDatabaseHandler: () -> Void
    let manageHandler: () -> Void

    init(session: SessionModel, newDatabase: @escaping () -> Void, manage: @escaping () -> Void) {
        self.session = session
        newDatabaseHandler = newDatabase
        manageHandler = manage
    }

    @objc func switchTo(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Task { await session.switchDatabase(to: name) }
    }

    @objc func newDatabase(_ sender: Any?) { newDatabaseHandler() }
    @objc func manageDatabases(_ sender: Any?) { manageHandler() }
    @objc func reload(_ sender: Any?) { Task { await session.loadDatabases() } }
    @objc func disconnect(_ sender: Any?) { session.disconnect() }
}

private struct NewDatabaseSheet: View {
    let session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var isCreating = false

    var body: some View {
        SheetFrame(title: "New Database", error: error) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            Text("Created on \(session.config.host) and opened right away.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
        }
    }

    private func create() {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isCreating = true
        Task {
            error = await session.createDatabase(named: name)
            isCreating = false
            if error == nil { dismiss() }
        }
    }
}

private struct DatabaseManagerSheet: View {
    @Bindable var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var error: String?
    @State private var renaming: DatabaseInfo?
    @State private var dropping: DatabaseInfo?

    var body: some View {
        SheetFrame(title: "Databases on \(session.config.host)", error: error, width: 520) {
            List(session.databases, selection: $selection) { database in
                HStack(spacing: 10) {
                    Image(systemName: database.name == session.config.database ? "cylinder.split.1x2.fill" : "cylinder")
                        .foregroundStyle(database.name == session.config.database ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(database.name).fontWeight(database.name == session.config.database ? .semibold : .regular)
                        Text(database.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if database.connections > 0 {
                        Text("\(database.connections) open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(database.name)
                .contextMenu {
                    Button("Open") { open(database.name) }
                    Button("Rename…") { renaming = database }
                    Button("Drop…", role: .destructive) { dropping = database }
                }
            }
            .listStyle(.inset)
            .frame(height: 260)
        } actions: {
            Button("Open") { if let selection { open(selection) } }
                .disabled(selection == nil || selection == session.config.database)
            Button("Rename…") { renaming = selected }
                .disabled(selected == nil)
            Button("Drop…", role: .destructive) { dropping = selected }
                .disabled(selected == nil || selection == session.config.database)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .task { await session.loadDatabases() }
        .sheet(item: $renaming) { database in
            RenameDatabaseSheet(session: session, database: database) { error = $0 }
        }
        .sheet(item: $dropping) { database in
            DropDatabaseSheet(session: session, database: database) { error = $0 }
        }
    }

    private var selected: DatabaseInfo? {
        session.databases.first { $0.name == selection }
    }

    private func open(_ name: String) {
        Task { await session.switchDatabase(to: name) }
        dismiss()
    }
}

private struct RenameDatabaseSheet: View {
    let session: SessionModel
    let database: DatabaseInfo
    var onFinish: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        SheetFrame(title: "Rename \(database.name)", error: error) {
            TextField("New name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Rename", action: rename)
                .keyboardShortcut(.defaultAction)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { newName = database.name }
    }

    private func rename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != database.name else { return }
        Task {
            if let failure = await session.renameDatabase(database.name, to: name) {
                error = failure
            } else {
                onFinish(nil)
                dismiss()
            }
        }
    }
}

private struct DropDatabaseSheet: View {
    let session: SessionModel
    let database: DatabaseInfo
    var onFinish: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var closeConnections = false
    @State private var error: String?

    var body: some View {
        SheetFrame(title: "Drop \(database.name)?", error: error) {
            Text("This permanently deletes the database and everything in it (\(database.size)). It can't be undone.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Type \(database.name) to confirm", text: $confirmation)
                .textFieldStyle(.roundedBorder)
            if database.connections > 0 {
                Toggle("Close \(database.connections) open connections first", isOn: $closeConnections)
            }
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Drop Database", role: .destructive, action: drop)
                .disabled(confirmation != database.name)
        }
    }

    private func drop() {
        Task {
            if let failure = await session.dropDatabase(database.name, closingConnections: closeConnections) {
                error = failure
            } else {
                onFinish(nil)
                dismiss()
            }
        }
    }
}

/// Shared sheet layout: title, content, error line, buttons.
private struct SheetFrame<Content: View, Actions: View>: View {
    let title: String
    var error: String?
    var width: CGFloat = 340
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack { actions }
                .padding(.top, 2)
        }
        .padding(18)
        .frame(width: width)
    }
}

struct RenameQuerySheet: View {
    let name: String
    var onRename: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Query").font(.headline)
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 320)
        .onAppear { newName = name }
    }

    private func rename() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
        dismiss()
    }
}
