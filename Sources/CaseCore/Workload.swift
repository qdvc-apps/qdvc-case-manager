import Foundation

/// One unit of workload: a case counted against an analyst in a month.
public struct WorkloadEvent: Sendable, Equatable {
    public let caseID: String
    public let analyst: String
    public let month: MonthKey
    public let date: LocalDate
    public let genre: String
}

/// Cases per analyst per month: the pivot table of the spreadsheet system.
public struct WorkloadPivot: Sendable, Equatable {
    public var months: [MonthKey]
    public var analysts: [String]
    public var counts: [String: [MonthKey: Int]]
    public var cases: [String: [MonthKey: [String]]]
    /// Cases in range against analysts not in the pool, by shorthand: not
    /// listed, nor in any total.
    public var unlisted: [String: Int] = [:]

    public func count(_ analyst: String, _ month: MonthKey) -> Int { counts[analyst]?[month] ?? 0 }
    public func cases(_ analyst: String, _ month: MonthKey) -> [String] { cases[analyst]?[month] ?? [] }
    public func rowTotal(_ analyst: String) -> Int { months.reduce(0) { $0 + count(analyst, $1) } }
    public func columnTotal(_ month: MonthKey) -> Int { analysts.reduce(0) { $0 + count($1, month) } }
    public var grandTotal: Int { analysts.reduce(0) { $0 + rowTotal($1) } }
    public var maxCell: Int { analysts.flatMap { a in months.map { count(a, $0) } }.max() ?? 0 }

    /// How evenly a month's cases were spread across `pool` (coefficient of
    /// variation: 0 is perfectly even).
    public func balance(_ month: MonthKey, pool: [String]) -> Double? {
        Workload.coefficientOfVariation(pool.map { count($0, month) })
    }
}

/// An analyst's numbers for the decision support screen.
public struct AnalystMetrics: Sendable, Equatable {
    public var thisMonth = 0
    public var lastMonth = 0
    public var past12 = 0
    /// The 12 months ending this month, oldest first.
    public var monthly: [Int] = []
    public var lastAllocation: LocalDate?
    /// Cases of each genre in the past 12 months.
    public var genres: [String: Int] = [:]
    /// Open proposals in the app not yet in the control sheet.
    public var proposed = 0

    public init() {}
}

public enum Workload {
    /// The workload events: each case's latest allocation, if its outcome
    /// counts as workload, it names an analyst and has a date.
    public static func events(_ book: CaseBook) -> [WorkloadEvent] {
        book.rows.compactMap { row in
            guard let latest = row.latest, let date = latest.allocationDate, !row.analystKey.isEmpty else { return nil }
            guard row.outcome?.countsAsWorkload ?? true else { return nil }
            return WorkloadEvent(caseID: row.caseID, analyst: row.analystKey, month: date.monthKey, date: date,
                                 genre: row.genre)
        }
    }

    /// Cases allocated in the control sheet but not counted (no date, or no analyst).
    public static func uncounted(_ book: CaseBook) -> Int {
        book.rows.filter { row in
            guard let latest = row.latest, row.outcome?.countsAsWorkload ?? true, row.status != .refused else { return false }
            return latest.allocationDate == nil || row.analystKey.isEmpty
        }.count
    }

    public static func pivot(_ events: [WorkloadEvent], months: [MonthKey], analysts: [String]) -> WorkloadPivot {
        let wanted = Set(months)
        let pool = Set(analysts)
        var counts: [String: [MonthKey: Int]] = [:]
        var cases: [String: [MonthKey: [String]]] = [:]
        var unlisted: [String: Int] = [:]
        for e in events where wanted.contains(e.month) {
            // Only the pool is listed: an analyst not on the Analysts page
            // (or inactive, when they're left out) is counted aside.
            guard pool.contains(e.analyst) else {
                unlisted[e.analyst, default: 0] += 1
                continue
            }
            counts[e.analyst, default: [:]][e.month, default: 0] += 1
            cases[e.analyst, default: [:]][e.month, default: []].append(e.caseID)
        }
        return WorkloadPivot(months: months, analysts: analysts, counts: counts, cases: cases, unlisted: unlisted)
    }

    public static func metrics(_ events: [WorkloadEvent], today: LocalDate) -> [String: AnalystMetrics] {
        let thisMonth = today.monthKey
        let window = thisMonth.trailing(12)
        let first = window.first!
        var out: [String: AnalystMetrics] = [:]
        for e in events {
            var m = out[e.analyst] ?? { var x = AnalystMetrics(); x.monthly = Array(repeating: 0, count: 12); return x }()
            if e.month == thisMonth { m.thisMonth += 1 }
            if e.month == thisMonth.adding(months: -1) { m.lastMonth += 1 }
            if e.month >= first && e.month <= thisMonth {
                m.past12 += 1
                let i = (e.month.year - first.year) * 12 + (e.month.month - first.month)
                m.monthly[i] += 1
                if !e.genre.isEmpty { m.genres[e.genre, default: 0] += 1 }
            }
            if m.lastAllocation == nil || e.date > m.lastAllocation! { m.lastAllocation = e.date }
            out[e.analyst] = m
        }
        return out
    }

    /// Standard deviation over mean; nil when there is nothing to compare.
    public static func coefficientOfVariation(_ values: [Int]) -> Double? {
        guard values.count > 1 else { return nil }
        let mean = Double(values.reduce(0, +)) / Double(values.count)
        guard mean > 0 else { return nil }
        let variance = values.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(values.count)
        return variance.squareRoot() / mean
    }

    /// The months from the earliest event to `today`'s month.
    public static func allMonths(_ events: [WorkloadEvent], today: LocalDate) -> [MonthKey] {
        guard let first = events.map(\.month).min() else { return today.monthKey.trailing(12) }
        return first.through(max(today.monthKey, events.map(\.month).max()!))
    }
}

// MARK: - Acceptance and refusal rates

/// Accepted (a) and refused (r) decisions for one month, supervisor or genre.
public struct RateRow: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var accepted = 0
    public var refused = 0
    /// Special decisions (sp): neither a nor r.
    public var special = 0
    /// Decisions counted in neither (project and other outcomes, shown separately).
    public var other = 0

    public var decided: Int { accepted + refused }
    public var total: Int { accepted + refused + special + other }
    /// a / (a + r).
    public var acceptanceRate: Double? { decided == 0 ? nil : Double(accepted) / Double(decided) }
    /// r / (a + r).
    public var refusalRate: Double? { decided == 0 ? nil : Double(refused) / Double(decided) }
}

public enum Rates {
    public enum Grouping: String, CaseIterable, Sendable, Identifiable {
        case month, supervisor, genre
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .month: return "By Month"
            case .supervisor: return "By Supervisor"
            case .genre: return "By Genre"
            }
        }
    }

    /// One row per group, from each case's latest decision. Months run
    /// oldest first; the others by number of decisions. `months` limits
    /// every grouping to decisions dated in those months.
    public static func rows(_ book: CaseBook, by grouping: Grouping, months: [MonthKey]? = nil) -> [RateRow] {
        let wanted = months.map(Set.init)
        var rows: [String: RateRow] = [:]
        for row in book.rows {
            guard let latest = row.latest else { continue }
            let outcome = row.outcome ?? OutcomeCode(code: latest.outcome, kind: .other)
            let month = latest.allocationDate?.monthKey
            if let wanted {
                guard let month, wanted.contains(month) else { continue }
            }
            let key: String
            let label: String
            switch grouping {
            case .month:
                guard let month else { continue }
                key = month.iso
                label = month.label
            case .supervisor:
                key = latest.supervisor.isEmpty ? "—" : latest.supervisor
                label = key
            case .genre:
                key = row.genre.isEmpty ? "—" : row.genre
                label = key
            }
            var r = rows[key] ?? RateRow(key: key, label: label)
            switch outcome.rates {
            case .accepted: r.accepted += 1
            case .refused: r.refused += 1
            case .special: r.special += 1
            case .excluded: r.other += 1
            }
            rows[key] = r
        }
        if grouping == .month, let months {
            return months.map { rows[$0.iso] ?? RateRow(key: $0.iso, label: $0.label) }
        }
        let values = Array(rows.values)
        if grouping == .month { return values.sorted { $0.key < $1.key } }
        return values.sorted { $0.total == $1.total ? $0.label < $1.label : $0.total > $1.total }
    }

    public static func overall(_ rows: [RateRow]) -> RateRow {
        var t = RateRow(key: "total", label: "Total")
        for r in rows {
            t.accepted += r.accepted
            t.refused += r.refused
            t.special += r.special
            t.other += r.other
        }
        return t
    }
}

// MARK: - Searching expertise

/// A search through analysts' expertise: words and "quoted phrases",
/// matched ignoring case and accents.
public struct ExpertiseQuery: Sendable, Equatable {
    public var terms: [String]
    public var matchAll: Bool

    public init(_ text: String, matchAll: Bool = true) {
        self.matchAll = matchAll
        var terms: [String] = []
        var current = ""
        var quoted = false
        for ch in text {
            if ch == "\"" || ch == "“" || ch == "”" {
                if quoted { if !current.isEmpty { terms.append(current) }; current = "" }
                else if !current.isEmpty { terms.append(current); current = "" }
                quoted.toggle()
            } else if !quoted && (ch.isWhitespace || ch == "," || ch == ";") {
                if !current.isEmpty { terms.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { terms.append(current) }
        self.terms = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public var isEmpty: Bool { terms.isEmpty }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Every match of every term, as character offsets, sorted and merged.
    public func matches(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for term in terms {
            var start = text.startIndex
            while start < text.endIndex, let r = text.range(of: term, options: ExpertiseQuery.options, range: start..<text.endIndex) {
                let lo = text.distance(from: text.startIndex, to: r.lowerBound)
                let hi = text.distance(from: text.startIndex, to: r.upperBound)
                ranges.append(lo..<hi)
                start = r.upperBound > r.lowerBound ? r.upperBound : text.index(after: r.lowerBound)
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for r in ranges {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// How many distinct terms the text contains.
    public func matchedTerms(in text: String) -> Int {
        terms.filter { text.range(of: $0, options: ExpertiseQuery.options) != nil }.count
    }

    public func accepts(_ text: String) -> Bool {
        if terms.isEmpty { return true }
        let n = matchedTerms(in: text)
        return matchAll ? n == terms.count : n > 0
    }

    /// The text of the first match, as written in `text` (to copy as an
    /// allocation note).
    public func firstMatch(in text: String) -> String? {
        for term in terms {
            if let r = text.range(of: term, options: ExpertiseQuery.options) { return String(text[r]) }
        }
        return nil
    }
}

/// Expertise text split into phrases (at semicolons, commas, line breaks
/// and bullets), for picking an allocation note.
public enum ExpertisePhrases {
    public static func split(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ";,\n•|")
        var seen = Set<String>()
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-–"))) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
