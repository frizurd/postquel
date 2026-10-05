import Darwin
import Foundation

/// Port forward run by the system `ssh` command: `ssh -N -L <local>:<dbHost>:<dbPort> user@host`.
/// Authentication is whatever ssh itself can do without prompting — agent keys, ~/.ssh/config,
/// or an identity file — so Postquel never handles the SSH passphrase.
final class SSHTunnel {
    let localPort: Int
    private let process = Process()
    private let errorOutput = LockedBuffer()

    init(localPort: Int) {
        self.localPort = localPort
    }

    /// Opens the tunnel and waits until the local port accepts connections.
    static func open(_ settings: SSHSettings, toHost remoteHost: String, port remotePort: Int) async throws -> SSHTunnel {
        guard !settings.host.isEmpty else { throw PGError("The SSH server is missing") }
        guard let localPort = freePort() else { throw PGError("No free local port for the SSH tunnel") }

        let tunnel = SSHTunnel(localPort: localPort)
        var arguments = [
            "-N",  // no remote command, just forwarding
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
            "-p", String(settings.port),
            "-o", "BatchMode=yes",  // never prompt; fail instead
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        if !settings.keyPath.isEmpty {
            arguments += ["-i", (settings.keyPath as NSString).expandingTildeInPath]
        }
        arguments.append("\(settings.user)@\(settings.host)")

        tunnel.process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        tunnel.process.arguments = arguments
        tunnel.process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        tunnel.process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [buffer = tunnel.errorOutput] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) }
        }

        do {
            try tunnel.process.run()
        } catch {
            throw PGError("Couldn't start ssh: \(error.localizedDescription)")
        }

        // ssh reports failures (bad host, refused key) by exiting; otherwise the port opens shortly.
        for _ in 0..<100 {
            if accepts(port: localPort) { return tunnel }
            if !tunnel.process.isRunning {
                let message = tunnel.errorOutput.text.trimmingCharacters(in: .whitespacesAndNewlines)
                throw PGError(message.isEmpty ? "The SSH tunnel closed immediately" : message)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        tunnel.close()
        throw PGError("The SSH tunnel didn't open within 10 seconds")
    }

    func close() {
        if process.isRunning { process.terminate() }
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    /// A port the system hands out, then releases for ssh to bind.
    private static func freePort() -> Int? {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return nil }
        defer { Darwin.close(handle) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return Int(assigned.sin_port.byteSwapped)
    }

    private static func accepts(port: Int) -> Bool {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { Darwin.close(handle) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).byteSwapped
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
