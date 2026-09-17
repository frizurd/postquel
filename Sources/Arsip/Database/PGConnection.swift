import CLibPQ
import Foundation

struct PGError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct PGColumn: Hashable {
    let name: String
    let typeOID: UInt32

    var typeName: String { PGTypes.name(for: typeOID) }
    var isNumeric: Bool { PGTypes.numeric.contains(typeOID) }
    var isJSON: Bool { typeOID == 114 || typeOID == 3802 }
    var isBool: Bool { typeOID == 16 }
}

/// Owns a libpq result. Results are read-only once created, so cells can be
/// read lazily from any thread (the grid reads them on demand while scrolling).
final class PGResult: @unchecked Sendable {
    private let handle: OpaquePointer
    let rowCount: Int
    let columns: [PGColumn]

    init(taking handle: OpaquePointer) {
        self.handle = handle
        rowCount = Int(PQntuples(handle))
        columns = (0..<PQnfields(handle)).map { i in
            PGColumn(name: String(cString: PQfname(handle, i)), typeOID: PQftype(handle, i))
        }
    }

    deinit { PQclear(handle) }

    func value(row: Int, column: Int) -> String? {
        if PQgetisnull(handle, Int32(row), Int32(column)) == 1 { return nil }
        return String(cString: PQgetvalue(handle, Int32(row), Int32(column)))
    }
}

struct StatementResult: Identifiable {
    let id = UUID()
    /// Server command tag, e.g. "SELECT 42" or "UPDATE 3".
    let status: String
    let rows: PGResult?
    let affectedRows: Int?
}

struct ExecutionOutcome {
    var results: [StatementResult] = []
    var error: String?
    var duration: TimeInterval = 0
}

/// A single libpq connection. All libpq calls are serialized on a private queue;
/// only `cancel()` may be called concurrently (PQcancel is thread-safe).
final class PGConnection: @unchecked Sendable {
    private let conn: OpaquePointer
    private let cancelHandle: OpaquePointer?
    private let queue = DispatchQueue(label: "arsip.pg.connection", qos: .userInitiated)
    let serverVersion: String

    private init(conn: OpaquePointer) {
        self.conn = conn
        cancelHandle = PQgetCancel(conn)
        let v = Int(PQserverVersion(conn))
        serverVersion = "PostgreSQL \(v / 10000).\(v % 100)"
    }

    deinit {
        if let cancelHandle { PQfreeCancel(cancelHandle) }
        PQfinish(conn)
    }

    static func connect(_ config: ConnectionConfig) async throws -> PGConnection {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var params: [(String, String)] = [
                    ("host", config.host),
                    ("port", String(config.port)),
                    ("user", config.user),
                    ("dbname", config.database),
                    ("application_name", "Arsip"),
                    ("client_encoding", "UTF8"),
                    ("connect_timeout", "10"),
                ]
                if !config.password.isEmpty { params.append(("password", config.password)) }

                let conn = withCStringArray(params.map { Optional($0.0) } + [nil]) { keys in
                    withCStringArray(params.map { Optional($0.1) } + [nil]) { values in
                        PQconnectdbParams(keys, values, 0)
                    }
                }
                guard let conn else {
                    continuation.resume(throwing: PGError("Could not allocate connection"))
                    return
                }
                guard PQstatus(conn) == CONNECTION_OK else {
                    let message = errorMessage(conn)
                    PQfinish(conn)
                    continuation.resume(throwing: PGError(message))
                    return
                }
                continuation.resume(returning: PGConnection(conn: conn))
            }
        }
    }

    /// Runs `sql`. Without params it may contain multiple statements; with params
    /// it must be a single statement ($1, $2, ... placeholders, text values).
    func execute(_ sql: String, params: [String?] = []) async -> ExecutionOutcome {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.executeSync(sql, params: params))
            }
        }
    }

    func cancel() {
        guard let cancelHandle else { return }
        var buffer = [CChar](repeating: 0, count: 256)
        _ = PQcancel(cancelHandle, &buffer, 256)
    }

    private func executeSync(_ sql: String, params: [String?]) -> ExecutionOutcome {
        let started = Date()
        var outcome = ExecutionOutcome()
        defer { outcome.duration = Date().timeIntervalSince(started) }

        if PQstatus(conn) != CONNECTION_OK {
            PQreset(conn)
            guard PQstatus(conn) == CONNECTION_OK else {
                outcome.error = "Connection lost: \(Self.errorMessage(conn))"
                return outcome
            }
        }

        let sent: Int32 = params.isEmpty
            ? PQsendQuery(conn, sql)
            : withCStringArray(params) { values in
                PQsendQueryParams(conn, sql, Int32(params.count), nil, values, nil, nil, 0)
            }
        guard sent == 1 else {
            outcome.error = Self.errorMessage(conn)
            return outcome
        }

        // One PGresult per statement; must drain until nil.
        while let res = PQgetResult(conn) {
            let status = PQresultStatus(res)
            let tag = String(cString: PQcmdStatus(res))
            switch status {
            case PGRES_TUPLES_OK:
                outcome.results.append(StatementResult(status: tag, rows: PGResult(taking: res), affectedRows: nil))
            case PGRES_COMMAND_OK:
                let affected = Int(String(cString: PQcmdTuples(res)))
                outcome.results.append(StatementResult(status: tag, rows: nil, affectedRows: affected))
                PQclear(res)
            case PGRES_EMPTY_QUERY:
                PQclear(res)
            case PGRES_COPY_IN:
                PQclear(res)
                _ = PQputCopyEnd(conn, "COPY FROM STDIN is not supported")
            case PGRES_COPY_OUT:
                PQclear(res)
                var buffer: UnsafeMutablePointer<CChar>?
                while PQgetCopyData(conn, &buffer, 0) > 0 { PQfreemem(buffer) }
                outcome.error = "COPY TO STDOUT is not supported"
            default:
                let message = String(cString: PQresultErrorMessage(res)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !message.isEmpty { outcome.error = message }
                PQclear(res)
            }
        }
        return outcome
    }

    private static func errorMessage(_ conn: OpaquePointer) -> String {
        String(cString: PQerrorMessage(conn)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func quoteIdent(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

/// Calls `body` with a C array of C strings (nil entries stay NULL). `strings` must be non-empty.
private func withCStringArray<T>(_ strings: [String?], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> T) -> T {
    let owned: [UnsafeMutablePointer<CChar>?] = strings.map { $0.flatMap { strdup($0) } }
    defer { owned.forEach { free($0) } }
    let pointers: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

enum PGTypes {
    static let numeric: Set<UInt32> = [20, 21, 23, 26, 700, 701, 790, 1700]

    static func name(for oid: UInt32) -> String {
        switch oid {
        case 16: "bool"
        case 17: "bytea"
        case 19: "name"
        case 20: "int8"
        case 21: "int2"
        case 23: "int4"
        case 25: "text"
        case 26: "oid"
        case 114: "json"
        case 700: "float4"
        case 701: "float8"
        case 1042: "char"
        case 1043: "varchar"
        case 1082: "date"
        case 1083: "time"
        case 1114: "timestamp"
        case 1184: "timestamptz"
        case 1186: "interval"
        case 1700: "numeric"
        case 2950: "uuid"
        case 3802: "jsonb"
        default: "oid \(oid)"
        }
    }
}
