import Foundation

/// One registration year in the Year filter.
public struct YearSummary: Identifiable, Equatable, Sendable {
    /// The year for cases with no readable registration date.
    public static let undated = 0

    public var year: Int
    public var cases = 0
    public var awaiting = 0
    public var id: Int { year }

    public init(year: Int, cases: Int = 0, awaiting: Int = 0) {
        self.year = year
        self.cases = cases
        self.awaiting = awaiting
    }

    public var title: String { year == YearSummary.undated ? "No date" : String(year) }

    /// "2026 — 412 cases, 9 awaiting".
    public var menuTitle: String {
        var s = "\(title) — \(cases) case\(cases == 1 ? "" : "s")"
        if awaiting > 0 { s += ", \(awaiting) awaiting" }
        return s
    }
}

/// How the heat map's analysts are ordered.
public enum WorkloadSort: String, CaseIterable, Sendable, Identifiable {
    case total, latest, name
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .total: return "Total"
        case .latest: return "Latest Month"
        case .name: return "Name"
        }
    }
}

/// Which workload view: the number of months ending this month (nil for
/// all), and whether inactive analysts are in the pool.
public struct WorkloadKey: Hashable, Sendable {
    public var months: Int?
    public var includeInactive: Bool

    public init(months: Int?, includeInactive: Bool) {
        self.months = months
        self.includeInactive = includeInactive
    }
}

public struct BalancePoint: Identifiable, Sendable, Equatable {
    public var month: MonthKey
    public var cv: Double
    public var id: MonthKey { month }
}

/// Everything the Workload dashboard draws for one `WorkloadKey`.
public struct WorkloadSnapshot: Sendable, Equatable {
    public var pivot: WorkloadPivot
    public var order: [WorkloadSort: [String]]
    /// The average total of the active analysts in view.
    public var activeMean: Double
    public var balance: [BalancePoint]
    public var maxCell: Int

    public func analysts(_ sort: WorkloadSort) -> [String] { order[sort] ?? pivot.analysts }
}

public struct AnalystCount: Sendable, Equatable {
    public var shorthand: String
    public var count: Int
}

/// The Workload dashboard's headline figures (this month, active pool).
public struct WorkloadSummary: Sendable, Equatable {
    public var month: MonthKey
    public var total = 0
    public var poolSize = 0
    public var busiest: AnalystCount?
    public var lightest: AnalystCount?
    /// Coefficient of variation of the past 12 months across the pool.
    public var balance12: Double?
    public var uncounted = 0
}

public struct RatesKey: Hashable, Sendable {
    public var grouping: Rates.Grouping
    public var months: Int?

    public init(grouping: Rates.Grouping, months: Int?) {
        self.grouping = grouping
        self.months = months
    }
}

/// Everything the Acceptance & Refusal dashboard draws for one `RatesKey`.
public struct RatesSnapshot: Sendable, Equatable {
    /// Months oldest first; the others by number of decisions.
    public var rows: [RateRow]
    public var total: RateRow
}

/// Everything derived from the workspace data. Computed in one go (off the
/// main thread, in the app) whenever the data changes, so pages and
/// dashboards only look things up.
public struct Derived: Sendable {
    public var today: LocalDate
    public var book = CaseBook()
    public var prepared: [PreparedRow] = []
    public var events: [WorkloadEvent] = []
    public var metrics: [String: AnalystMetrics] = [:]
    public var pendingLoad: [String: Int] = [:]
    /// Newest first; always includes this year.
    public var years: [YearSummary] = []
    /// Cases missing from each project's worksheet.
    public var missingCounts: [String: Int] = [:]
    public var workload: [WorkloadKey: WorkloadSnapshot] = [:]
    public var workloadSummary: WorkloadSummary
    public var rates: [RatesKey: RatesSnapshot] = [:]

    /// The dashboards' periods, in months (nil: all).
    public static let spans: [Int?] = [6, 12, 24, nil]

    public init(today: LocalDate = LocalDate.today()) {
        self.today = today
        self.workloadSummary = WorkloadSummary(month: today.monthKey)
        self.years = [YearSummary(year: today.year)]
    }

    public static func compute(_ data: WorkspaceData, today: LocalDate) -> Derived {
        var d = Derived(today: today)
        let book = CaseBook.build(data)
        d.book = book
        d.prepared = Batch.rows(data, book: book)
        d.events = Workload.events(book)
        d.metrics = Workload.metrics(d.events, today: today)
        d.pendingLoad = Batch.pendingLoad(d.prepared, settings: data.settings, book: book)

        var years: [Int: YearSummary] = [today.year: YearSummary(year: today.year)]
        var missing: [String: Int] = [:]
        for r in book.rows {
            let y = r.registrationDate?.year ?? YearSummary.undated
            years[y, default: YearSummary(year: y)].cases += 1
            if r.status == .awaiting { years[y]!.awaiting += 1 }
            for f in r.flags { if case .missingFromWorksheet(let p) = f { missing[p, default: 0] += 1 } }
        }
        d.years = years.values.sorted { $0.year > $1.year }
        d.missingCounts = missing

        // Workload: every period, with and without inactive analysts.
        let active = data.analysts.filter(\.active).map(\.shorthand)
        let everyone = data.analysts.map(\.shorthand)
        let activeSet = Set(active)
        func label(_ s: String) -> String { book.analyst(for: s)?.displayName ?? s }
        for months in spans {
            let range = months.map { today.monthKey.trailing($0) } ?? Workload.allMonths(d.events, today: today)
            for includeInactive in [false, true] {
                let p = Workload.pivot(d.events, months: range, analysts: includeInactive ? everyone : active)
                let totals = Dictionary(uniqueKeysWithValues: p.analysts.map { ($0, p.rowTotal($0)) })
                let latest = range.last
                var order: [WorkloadSort: [String]] = [:]
                order[.total] = p.analysts.sorted { a, b in
                    totals[a]! == totals[b]! ? a < b : totals[a]! > totals[b]!
                }
                order[.latest] = p.analysts.sorted { a, b in
                    let x = latest.map { p.count(a, $0) } ?? 0, y = latest.map { p.count(b, $0) } ?? 0
                    return x == y ? totals[a]! > totals[b]! : x > y
                }
                order[.name] = p.analysts.sorted { label($0).localizedStandardCompare(label($1)) == .orderedAscending }
                let inView = p.analysts.filter { activeSet.contains($0) }
                let mean = inView.isEmpty ? 0 : Double(inView.reduce(0) { $0 + totals[$1]! }) / Double(inView.count)
                let balance = range.compactMap { m in p.balance(m, pool: active).map { BalancePoint(month: m, cv: $0) } }
                d.workload[WorkloadKey(months: months, includeInactive: includeInactive)] =
                    WorkloadSnapshot(pivot: p, order: order, activeMean: mean, balance: balance, maxCell: p.maxCell)
            }
        }

        var summary = WorkloadSummary(month: today.monthKey)
        let counts = active.map { AnalystCount(shorthand: $0, count: d.metrics[$0]?.thisMonth ?? 0) }
        summary.total = counts.reduce(0) { $0 + $1.count }
        summary.poolSize = active.count
        summary.busiest = counts.max { $0.count < $1.count }
        summary.lightest = counts.min { $0.count < $1.count }
        summary.balance12 = Workload.coefficientOfVariation(active.map { d.metrics[$0]?.past12 ?? 0 })
        summary.uncounted = Workload.uncounted(book)
        d.workloadSummary = summary

        // Rates: every grouping and period.
        for grouping in Rates.Grouping.allCases {
            for months in spans {
                let rows = Rates.rows(book, by: grouping, months: months.map { today.monthKey.trailing($0) })
                d.rates[RatesKey(grouping: grouping, months: months)] = RatesSnapshot(rows: rows, total: Rates.overall(rows))
            }
        }
        return d
    }
}
