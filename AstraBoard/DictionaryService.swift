import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)


final class DictionaryService {
    static let shared = DictionaryService()

    private var db: OpaquePointer?

    private init() {
        openDatabase()
    }

    private func openDatabase() {
        guard let url = Bundle.main.url(forResource: "wordnet", withExtension: "sqlite") else {
            print("❌ wordnet.sqlite not found in app bundle")
            return
        }

        // Open read-only (safer for bundle)
        let flags = SQLITE_OPEN_READONLY

        if sqlite3_open_v2(url.path, &db, flags, nil) != SQLITE_OK {
            print("❌ Failed to open SQLite DB")
            db = nil
        } else {
            print("✅ Dictionary DB opened")
        }
    }

    func define(_ input: String, limit: Int = 3) -> [String] {
        guard let db else { return [] }

        let word = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty else { return [] }

        let sql = """
        SELECT definition
        FROM entries
        WHERE word = ?
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        var results: [String] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    results.append(String(cString: cStr))
                }
            }
        }

        sqlite3_finalize(stmt)
        return Array(Set(results)) // remove duplicates
    }
}
