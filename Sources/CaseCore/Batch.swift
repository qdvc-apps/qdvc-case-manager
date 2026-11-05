import Foundation

/// How an export writes its dates, so prepared rows can be written the same
/// way: 2026-11-05, 05/11/2026, 5-Nov-26…
public struct DateStyle: Equatable, Sendable {
    public enum Order: String, Sendable { case ymd, dmy, mdy }

    public var order: Order = .ymd
    public var separators: [String] = ["-", "-"]
    public var padDay = true
    public var padMonth = true
    public var twoDigitYear = false
    public var monthName = false

    public init() {}

    public static let iso = DateStyle()

    public func format(_ d: LocalDate) -> String {
        let y = twoDigitYear ? String(format: "%02d", d.year % 100) : String(d.year)
        let m = monthName ? MonthKey.shortNames[d.month - 1] : (padMonth ? String(format: "%02d", d.month) : String(d.month))
        let day = padDay ? String(format: "%02d", d.day) : String(d.day)
        let parts: [String]
        switch order {
        case .ymd: parts = [y, m, day]
        case .dmy: parts = [day, m, y]
        case .mdy: parts = [m, day, y]
        }
        return parts[0] + separators[0] + parts[1] + separators[1] + parts[2]
    }

    /// The first three runs of letters or digits and the two gaps between them.
    static func tokens(_ s: String) -> (tokens: [String], separators: [String])? {
        var tokens: [String] = []
        var gaps: [String] = []
        var current = ""
        var currentIsDigit = false
        var gap = ""
        for ch in s.trimmingCharacters(in: .whitespaces) {
            let isDigit = ch.isASCII && ch.isNumber
            if isDigit || ch.isLetter {
                if !current.isEmpty && isDigit != currentIsDigit {
                    tokens.append(current)
                    gaps.append("")
                    current = ""
                } else if current.isEmpty && !tokens.isEmpty {
                    gaps.append(gap)
                }
                gap = ""
                current.append(ch)
                currentIsDigit = isDigit
            } else {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                gap.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        guard tokens.count >= 3, gaps.count >= 2 else { return nil }
        return (Array(tokens.prefix(3)), Array(gaps.prefix(2)))
    }

    /// The style of the dates in `samples` (ISO if none can be read).
    public static func infer(_ samples: [String], order: DateOrder) -> DateStyle {
        var style: DateStyle?
        var sawShortDay = false, sawShortMonth = false
        var seen = 0
        for s in samples where !s.isEmpty {
            guard seen < 300, let d = DateParser.parse(s, order: order), let (t, seps) = tokens(s) else { continue }
            seen += 1
            var st = DateStyle()
            st.separators = seps
            let nameIndex = t.firstIndex { Int($0) == nil }
            st.monthName = nameIndex != nil
            var dayToken = "", monthToken = ""
            if t[0].count == 4 {
                st.order = .ymd
                monthToken = t[1]; dayToken = t[2]
            } else {
                st.twoDigitYear = t[2].count == 2
                if let i = nameIndex {
                    st.order = i == 0 ? .mdy : .dmy
                } else if let a = Int(t[0]), let b = Int(t[1]), a != b {
                    st.order = (a == d.day && b == d.month) ? .dmy : .mdy
                } else {
                    st.order = order == .monthFirst ? .mdy : .dmy
                }
                dayToken = st.order == .dmy ? t[0] : t[1]
                monthToken = st.order == .dmy ? t[1] : t[0]
            }
            if dayToken.count == 1 { sawShortDay = true }
            if !st.monthName && monthToken.count == 1 { sawShortMonth = true }
            if style == nil { style = st }
        }
        guard var result = style else { return .iso }
        result.padDay = !sawShortDay
        result.padMonth = !sawShortMonth
        return result
    }

    /// The style of a column of a table.
    public static func infer(_ table: CSVTable?, header: String?, order: DateOrder) -> DateStyle {
        guard let table, let header, let col = table.index(of: header) else { return .iso }
        // The latest rows are the best guide to how the sheet is written now.
        return infer(table.rows.indices.reversed().map { table.value($0, col) }, order: order)
    }
}

/// Where a prepared row stands against the latest control sheet.
public enum PreparedState: String, Sendable {
    /// Not yet in the control sheet.
    case pending
    /// The control sheet now has this decision.
    case landed
    /// The control sheet has a decision for the case, but not this one.
    case landedDifferently

    public var title: String {
        switch self {
        case .pending: return "Ready to paste"
        case .landed: return "In the control sheet"
        case .landedDifferently: return "Decided differently"
        }
    }
}

/// A row prepared for the Allocation Control Sheet.
public struct PreparedRow: Identifiable, Sendable, Equatable {
    public var id: String { caseID }
    public var caseID: String
    public var decision: CaseDecision
    public var state: PreparedState
    /// One value per control sheet column, in its order.
    public var values: [String]
    public var problems: [String]
}

/// The batch: the rows prepared in the decision support window, ready to be
/// pasted into the upstream Allocation Control Sheet.
public enum Batch {
    /// The control sheet's columns, in order (from the last import, or the
    /// mapped fields if there has been none).
    public static func headers(_ data: WorkspaceData) -> [String] {
        if let h = data.tables[.controlSheet]?.headers, !h.isEmpty { return h }
        let m = data.mappings[.controlSheet] ?? ColumnMapping()
        return MappedField.allCases.map { m.header($0) ?? $0.title }
    }

    public static func rows(_ data: WorkspaceData, book: CaseBook) -> [PreparedRow] {
        let headers = headers(data)
        let mapping = data.mappings[.controlSheet] ?? ColumnMapping()
        let table = data.tables[.controlSheet]
        let probe = CSVTable(headers: headers, rows: [])
        var fieldAt: [Int: MappedField] = [:]
        for f in MappedField.allCases {
            if let h = mapping.header(f), let i = probe.index(of: h) { fieldAt[i] = f }
        }
        if data.tables[.controlSheet] == nil {
            for (i, f) in MappedField.allCases.enumerated() { fieldAt[i] = f }
        }
        let allocStyle = DateStyle.infer(table, header: mapping.header(.allocationDate), order: mapping.dateOrder)
        let regStyle = DateStyle.infer(table, header: mapping.header(.registrationDate), order: mapping.dateOrder)
        let templates = Set(data.templates.map { $0.name.uppercased() })

        let prepared = data.decisions.filter { $0.value.isPrepared }
            .sorted { $0.value.order == $1.value.order ? $0.key < $1.key : $0.value.order < $1.value.order }
        return prepared.map { caseID, d in
            let row = book.row(caseID)
            var state = PreparedState.pending
            if let row, row.status != .awaiting, let latest = row.latest {
                let same = latest.outcome.caseInsensitiveCompare(d.outcome) == .orderedSame
                    && book.canonical(latest.analyst) == book.canonical(d.analyst)
                state = same ? .landed : .landedDifferently
            }
            var problems: [String] = []
            let outcome = data.settings.outcome(for: d.outcome)
            if row == nil { problems.append("The case is not in the catalogue.") }
            if outcome == nil { problems.append("\"\(d.outcome)\" is not a known outcome code.") }
            if outcome?.kind == .allocated && d.analyst.isEmpty { problems.append("No analyst chosen.") }
            if outcome?.kind == .refused && !templates.contains(d.note.uppercased()) {
                problems.append("The note is not a return-to-sender template.")
            }
            if LocalDate(iso: d.date) == nil { problems.append("No allocation date.") }
            if d.supervisor.isEmpty { problems.append("No allocation supervisor.") }

            let values = headers.indices.map { i -> String in
                guard let f = fieldAt[i] else { return "" }
                switch f {
                case .caseID: return row?.caseID ?? caseID
                case .title: return row?.title ?? ""
                case .genre: return row?.genre ?? ""
                case .registrationDate: return row?.registrationDate.map(regStyle.format) ?? (row?.registrationText ?? "")
                case .supervisor: return d.supervisor
                case .allocationDate: return LocalDate(iso: d.date).map(allocStyle.format) ?? d.date
                case .outcome: return d.outcome
                case .note: return d.note
                case .analyst: return d.analyst
                }
            }
            return PreparedRow(caseID: caseID, decision: d, state: state, values: values, problems: problems)
        }
    }

    /// The rows as text to paste into a spreadsheet: tab-separated (cells),
    /// or CSV.
    public static func pasteText(_ rows: [PreparedRow], headers: [String], tabSeparated: Bool, includeHeader: Bool) -> String {
        let all = (includeHeader ? [headers] : []) + rows.map(\.values)
        if tabSeparated {
            return all.map { r in
                r.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
                    .joined(separator: "\t")
            }.joined(separator: "\n") + "\n"
        }
        return CSV.render(all)
    }

    /// Pending rows per analyst (canonical shorthand) that will count as
    /// workload once they land.
    public static func pendingLoad(_ rows: [PreparedRow], settings: WorkspaceSettings, book: CaseBook) -> [String: Int] {
        var out: [String: Int] = [:]
        for r in rows where r.state == .pending && !r.decision.analyst.isEmpty {
            guard settings.outcome(for: r.decision.outcome)?.countsAsWorkload ?? true else { continue }
            out[book.canonical(r.decision.analyst), default: 0] += 1
        }
        return out
    }

    /// The order for the next row added to the batch.
    public static func nextOrder(_ data: WorkspaceData) -> Int {
        (data.decisions.values.filter(\.isPrepared).map(\.order).max() ?? 0) + 1
    }
}

/// How current an imported export is.
public struct Freshness: Sendable, Equatable {
    /// When it was imported into the workspace.
    public var importedAt: LocalDate?
    /// The latest date in it (registrations or allocations).
    public var latestDate: LocalDate?
    public var rows: Int

    public init(importedAt: LocalDate?, latestDate: LocalDate?, rows: Int) {
        self.importedAt = importedAt
        self.latestDate = latestDate
        self.rows = rows
    }

    public static func of(_ source: SourceKind, data: WorkspaceData, book: CaseBook) -> Freshness? {
        guard let table = data.tables[source] else { return nil }
        let imported = data.mappings[source].flatMap { LocalDate(iso: String($0.importedAt.prefix(10))) }
        let latest = source == .catalogue ? book.latestRegistration : book.latestAllocation
        return Freshness(importedAt: imported, latestDate: latest, rows: table.rows.count)
    }

    /// Days since import (nil if unknown).
    public func age(today: LocalDate) -> Int? { importedAt.map { today.dayNumber - $0.dayNumber } }

    /// "today", "yesterday", "3 days ago".
    public static func describe(age: Int) -> String {
        switch age {
        case ..<1: return "today"
        case 1: return "yesterday"
        default: return "\(age) days ago"
        }
    }
}
