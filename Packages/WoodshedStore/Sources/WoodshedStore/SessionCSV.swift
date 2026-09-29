import Foundation
import GRDB

extension WoodshedStore {
    /// Stable UTF-8 CSV: one row per current session, UTC dates, exact seconds
    /// converted to decimal minutes, and RFC 4180 quoting.
    public func sessionCSV() throws -> Data {
        let text = try db.read { reader -> String in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            func field(_ value: String) -> String {
                "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            func minutes(_ start: Date, _ end: Date) -> String {
                String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), max(0, end.timeIntervalSince(start)) / 60)
            }
            var lines = ["date,instrument,piece,splits,minutes,tempos,note"]
            let sessions = try Row.fetchAll(reader, sql: """
                SELECT s.*, p.title AS piece_title, i.name AS instrument_name
                FROM sessions s JOIN pieces p ON p.id = s.piece_id
                JOIN instruments i ON i.id = p.instrument_id
                WHERE s.committed_at = (SELECT MAX(c.committed_at) FROM sessions c WHERE c.id = s.id)
                ORDER BY s.started_at, s.id
                """)
            for row in sessions {
                let id: String = row["id"]
                let pieceID: String = row["piece_id"]
                let start: Date = row["started_at"]
                let end: Date = row["ended_at"]
                let committed: Date = row["committed_at"]
                let splits = try Row.fetchAll(reader, sql: """
                    SELECT sp.* FROM session_splits sp WHERE sp.session_id = ? AND sp.session_committed_at = ?
                    AND sp.committed_at = (SELECT MAX(c.committed_at) FROM session_splits c WHERE c.id = sp.id)
                    ORDER BY sp.started_at, sp.id
                    """, arguments: [id, committed])
                let splitText = splits.map { split -> String in
                    let a: Date = split["started_at"]
                    let b: Date = split["ended_at"]
                    return "\(split["label"] as String): \(minutes(a, b)) min"
                }.joined(separator: "; ")
                let tempos = try Row.fetchAll(reader, sql: """
                    SELECT bpm FROM tempo_logs WHERE piece_id = ? AND logged_at >= ? AND logged_at <= ?
                    AND committed_at = (SELECT MAX(c.committed_at) FROM tempo_logs c WHERE c.id = tempo_logs.id)
                    ORDER BY logged_at, id
                    """, arguments: [pieceID, start, end])
                let tempoText = tempos.map { "\($0["bpm"] as Int) BPM" }.joined(separator: "; ")
                let day = Calendar(identifier: .gregorian)
                var utc = day
                utc.timeZone = TimeZone(secondsFromGMT: 0)!
                let dayStart = utc.startOfDay(for: start)
                let nextDay = utc.date(byAdding: .day, value: 1, to: dayStart)!
                let notes = try Row.fetchAll(reader, sql: """
                    SELECT text FROM practice_notes WHERE piece_id = ? AND written_at >= ? AND written_at < ?
                    AND committed_at = (SELECT MAX(c.committed_at) FROM practice_notes c WHERE c.id = practice_notes.id)
                    ORDER BY written_at, id
                    """, arguments: [pieceID, dayStart, nextDay])
                let noteText = notes.map { $0["text"] as String }.joined(separator: "; ")
                lines.append([formatter.string(from: start), row["instrument_name"] as String,
                              row["piece_title"] as String, splitText, minutes(start, end), tempoText, noteText]
                    .map(field).joined(separator: ","))
            }
            return lines.joined(separator: "\r\n") + "\r\n"
        }
        return Data(text.utf8)
    }
}
