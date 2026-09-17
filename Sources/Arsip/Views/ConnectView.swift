import SwiftUI

struct ConnectView: View {
    @Bindable var session: SessionModel

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                Text("Arsip").font(.largeTitle.weight(.semibold))
                Text("Connect to a PostgreSQL server").foregroundStyle(.secondary)
            }

            Form {
                TextField("Host", text: $session.config.host)
                TextField("Port", value: $session.config.port, format: .number.grouping(.never))
                TextField("User", text: $session.config.user)
                SecureField("Password", text: $session.config.password, prompt: Text("Saved or not required"))
                TextField("Database", text: $session.config.database)
                Toggle("Remember password in Keychain", isOn: $session.config.rememberPassword)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 420, height: 290)
            .disabled(session.isConnecting)

            if let error = session.connectError {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack {
                if session.isConnecting { ProgressView().controlSize(.small) }
                Button("Connect") { Task { await session.connect() } }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(session.isConnecting || session.config.host.isEmpty)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
