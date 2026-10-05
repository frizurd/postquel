import SwiftUI

/// Saved servers on the left, their settings on the right.
struct ConnectView: View {
    @Bindable var session: SessionModel
    @State private var connections: [SavedConnection] = []
    @State private var selection: UUID?

    private var selectedIndex: Int? {
        connections.firstIndex { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            list
            Divider()
            detail
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            connections = ConnectionStore.load()
            if connections.isEmpty { connections = ConnectionStore.seed() }
            selection = connections.first?.id
        }
        .onChange(of: connections) { ConnectionStore.save(connections) }
    }

    // MARK: Saved list

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    ForEach(connections) { connection in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connection.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(connection.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 3)
                        .tag(connection.id)
                        .contextMenu {
                            Button("Duplicate") { duplicate(connection) }
                            Button("Delete", role: .destructive) { delete(connection) }
                        }
                    }
                } header: {
                    Text("Connections").sectionLabel()
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 36)

            Divider()
            HStack(spacing: 2) {
                Button { add() } label: { Image(systemName: "plus") }
                    .help("New connection")
                Button { if let selected { delete(selected) } } label: { Image(systemName: "minus") }
                    .disabled(selection == nil || connections.count <= 1)
                    .help("Delete connection")
                Spacer()
            }
            .buttonStyle(TitlebarIconButtonStyle())
            .padding(.horizontal, 6)
            .frame(height: Theme.barHeight)
        }
        .frame(width: 230)
        .background(.regularMaterial)
    }

    // MARK: Settings

    @ViewBuilder
    private var detail: some View {
        if let index = selectedIndex {
            let connection = $connections[index]
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("", text: connection.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .semibold))

                    group("Server") {
                        row("Host", text: connection.host)
                        row("Port", value: connection.port)
                        row("Database", text: connection.database)
                    }

                    group("Login") {
                        row("User", text: connection.user)
                        row("Password", text: $session.config.password, secure: true,
                            prompt: session.config.password.isEmpty ? "Saved in Keychain, or not required" : nil)
                        Toggle("Remember password in Keychain", isOn: connection.rememberPassword)
                        Toggle("Require SSL", isOn: connection.useSSL)
                    }

                    group("SSH Tunnel") {
                        Toggle("Connect through an SSH server", isOn: connection.ssh.isEnabled)
                        if connection.ssh.isEnabled.wrappedValue {
                            row("SSH host", text: connection.ssh.host)
                            row("SSH port", value: connection.ssh.port)
                            row("SSH user", text: connection.ssh.user)
                            row("Key file", text: connection.ssh.keyPath, prompt: "~/.ssh/id_ed25519 — leave empty to use your agent")
                            Text("Arsip runs `ssh -N -L` with your keys or agent. Keys with a passphrase must be unlocked first (`ssh-add`).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let error = session.connectError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .floatingBar(edge: .bottom) {
                HStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .opacity(session.isConnecting ? 1 : 0)
                        .frame(width: 14)
                    Button("Connect") {
                        Task { await session.connect(connections[index]) }
                    }
                    .softButtonStyle(prominent: true)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.isConnecting || connections[index].host.isEmpty)
                }
                .padding(.horizontal, 24)
                .frame(height: 56)
            }
        } else {
            ContentUnavailableView("No Connection Selected", systemImage: "cylinder.split.1x2")
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).sectionLabel()
            content()
        }
    }

    private func row(_ title: String, text: Binding<String>, secure: Bool = false, prompt: String? = nil) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            Group {
                if secure {
                    SecureField("", text: text, prompt: prompt.map(Text.init))
                } else {
                    TextField("", text: text, prompt: prompt.map(Text.init))
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)
        }
    }

    private func row(_ title: String, value: Binding<Int>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
            Spacer()
        }
    }

    // MARK: List actions

    private var selected: SavedConnection? {
        connections.first { $0.id == selection }
    }

    private func add() {
        var connection = SavedConnection()
        connection.name = "New Connection"
        connections.append(connection)
        selection = connection.id
    }

    private func duplicate(_ connection: SavedConnection) {
        var copy = connection
        copy.id = UUID()
        copy.name += " Copy"
        connections.append(copy)
        selection = copy.id
    }

    private func delete(_ connection: SavedConnection) {
        connections.removeAll { $0.id == connection.id }
        Keychain.deletePassword(account: connection.accountKey(database: connection.database))
        if selection == connection.id { selection = connections.first?.id }
    }
}
