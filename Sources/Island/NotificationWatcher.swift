import AppKit
import SQLite3

/// Lit les notifications reçues dans la base du Centre de notifications.
/// macOS n'offre aucune API publique pour ça : il faut l'accès complet au disque.
final class NotificationWatcher {
    var onNotification: ((Banner) -> Void)?
    private(set) var isAuthorized = false

    private let path = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
    private let focusPath = NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json"
    private var db: OpaquePointer?
    private var lastID: Int64 = 0
    private var timer: Timer?
    private var lastAttempt = Date.distantPast

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.3
        poll()
    }

    private func open() -> Bool {
        if db != nil { return true }
        // Sans autorisation, on réessaie de temps en temps seulement.
        guard Date().timeIntervalSince(lastAttempt) > 5 else { return false }
        lastAttempt = Date()

        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let maxID = query(handle, "SELECT IFNULL(MAX(rec_id), 0) FROM record", { sqlite3_column_int64($0, 0) }).first else {
            sqlite3_close(handle)
            isAuthorized = false
            return false
        }
        db = handle
        lastID = maxID
        isAuthorized = true
        log.notice("Notifications : base ouverte")
        return true
    }

    private func poll() {
        guard open() else { return }
        let sql = """
            SELECT r.rec_id, a.identifier, r.data FROM record r
            LEFT JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > \(lastID) ORDER BY r.rec_id
            """
        var latest: Banner?
        let rows: [Int64]? = queryOrNil(db, sql) { row in
            let id = sqlite3_column_int64(row, 0)
            let app = sqlite3_column_text(row, 1).map { String(cString: $0) }
            if let blob = sqlite3_column_blob(row, 2) {
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(row, 2)))
                latest = Self.banner(from: data, app: app) ?? latest
            }
            return id
        }
        guard let rows else {
            // Base remplacée ou devenue illisible : on rouvrira.
            sqlite3_close(db)
            db = nil
            return
        }
        lastID = rows.max() ?? lastID
        if let latest, !focusIsActive() {
            onNotification?(latest)
        }
    }

    private static func banner(from data: Data, app: String?) -> Banner? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let request = plist["req"] as? [String: Any] ?? [:]
        let title = request["titl"] as? String ?? ""
        let subtitle = request["subt"] as? String ?? ""
        let body = request["body"] as? String ?? ""
        guard !title.isEmpty || !body.isEmpty else { return nil }

        let bundleID = plist["app"] as? String ?? app
        let appURL = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        return Banner(
            title: title.isEmpty ? appURL.map { FileManager.default.displayName(atPath: $0.path) } ?? "" : title,
            body: [subtitle, body].filter { !$0.isEmpty }.joined(separator: " · "),
            bundleID: bundleID,
            icon: appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        )
    }

    /// Un mode de concentration est actif : on reste discret, comme macOS.
    private func focusIsActive() -> Bool {
        guard let data = FileManager.default.contents(atPath: focusPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else { return false }
        return entries.contains { ($0["storeAssertionRecords"] as? [Any])?.isEmpty == false }
    }

    // MARK: - SQLite

    private func query<T>(_ db: OpaquePointer?, _ sql: String, _ read: (OpaquePointer) -> T) -> [T] {
        queryOrNil(db, sql, read) ?? []
    }

    private func queryOrNil<T>(_ db: OpaquePointer?, _ sql: String, _ read: (OpaquePointer) -> T) -> [T]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(read(statement))
            case SQLITE_DONE: return rows
            default: return nil
            }
        }
    }
}
