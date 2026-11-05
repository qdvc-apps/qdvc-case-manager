import Foundation

/// RFC 4180 CSV: fields quoted with `"` when they hold the separator, a
/// quote, a line break or leading/trailing space; quotes doubled. Files are
/// written with `\n` line ends and read with any.
public enum CSV {
    /// The rows of `text`. A trailing line break does not make an empty row;
    /// blank lines are skipped.
    public static func parse(_ text: String, separator: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldWasQuoted = false
        var chars = Array(text)
        // Drop a byte-order mark, which Excel likes to write.
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0

        func endField() {
            row.append(field)
            field = ""
            fieldWasQuoted = false
        }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty && !fieldWasQuoted {
                inQuotes = true
                fieldWasQuoted = true
            } else if c == separator {
                endField()
            } else if c == "\r\n" || c == "\n" || c == "\r" {
                endRow()
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty || fieldWasQuoted { endRow() }
        return rows
    }

    public static func escape(_ field: String, separator: Character = ",") -> String {
        let needsQuotes = field.contains(separator) || field.contains("\"") || field.contains("\n")
            || field.contains("\r") || field.hasPrefix(" ") || field.hasSuffix(" ")
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func render(_ rows: [[String]]) -> String {
        rows.map { $0.map { escape($0) }.joined(separator: ",") + "\n" }.joined()
    }

    /// The separator a file most likely uses: whichever of comma, semicolon,
    /// tab and pipe appears most often (outside quotes) on the first line.
    public static func detectSeparator(_ text: String) -> Character {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0, "|": 0]
        var inQuotes = false
        for c in text {
            if c == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if c == "\n" || c == "\r\n" || c == "\r" { break }
            if counts[c] != nil { counts[c]! += 1 }
        }
        var best: Character = ","
        var bestCount = 0
        for c in [",", ";", "\t", "|"] as [Character] where counts[c, default: 0] > bestCount {
            best = c
            bestCount = counts[c, default: 0]
        }
        return best
    }
}

/// Text from a file of unknown encoding: UTF-8 (with or without a BOM),
/// UTF-16 with a BOM, else Windows-1252 (what older Windows systems export).
public enum TextDecoding {
    public static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let s = String(data: data, encoding: .utf16) { return s }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A CSV file as a header row and records. Every record has exactly as many
/// fields as there are headers (short rows are padded, long rows trimmed).
public struct CSVTable: Equatable, Sendable {
    public var headers: [String]
    public var rows: [[String]]

    public init(headers: [String], rows: [[String]]) {
        self.headers = headers
        let n = headers.count
        self.rows = rows.map { row in
            if row.count == n { return row }
            if row.count < n { return row + Array(repeating: "", count: n - row.count) }
            return Array(row.prefix(n))
        }
    }

    public init(text: String) {
        let parsed = CSV.parse(text, separator: CSV.detectSeparator(text))
        var headers = parsed.first ?? []
        headers = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Give blank or repeated headers a usable name.
        var seen: [String: Int] = [:]
        for i in headers.indices {
            if headers[i].isEmpty { headers[i] = "Column \(i + 1)" }
            let key = headers[i].lowercased()
            if let n = seen[key] {
                seen[key] = n + 1
                headers[i] += " (\(n + 1))"
            } else {
                seen[key] = 1
            }
        }
        let body = parsed.dropFirst().filter { row in row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        self.init(headers: headers, rows: Array(body))
    }

    public init(data: Data) {
        self.init(text: TextDecoding.decode(data))
    }

    /// The column with this header: exact first, then ignoring case and
    /// surrounding space.
    public func index(of header: String) -> Int? {
        if let i = headers.firstIndex(of: header) { return i }
        let wanted = header.trimmingCharacters(in: .whitespaces).lowercased()
        return headers.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
    }

    public func value(_ row: Int, _ column: Int?) -> String {
        guard let column, rows.indices.contains(row), rows[row].indices.contains(column) else { return "" }
        let v = rows[row][column]
        // Most cells have nothing to trim; checking the ends first avoids
        // Foundation's trimming, which dominated reading a large export.
        guard let first = v.unicodeScalars.first, let last = v.unicodeScalars.last,
              first.properties.isWhitespace || last.properties.isWhitespace else { return v }
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func render() -> String { CSV.render([headers] + rows) }
}
