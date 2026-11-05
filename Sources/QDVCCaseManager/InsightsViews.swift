import CaseCore
import Charts
import SwiftUI

/// A heat map cell: one analyst in one month.
struct PivotCell: Hashable {
    var analyst: String
    var month: MonthKey
}

enum PivotSort: String, CaseIterable, Identifiable {
    case name, total, thisMonth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .total: return "Total"
        case .thisMonth: return "Latest Month"
        }
    }
}

struct WorkloadView: View {
    @Environment(AppModel.self) private var model
    @State private var span: Span = .twelve
    @State private var includeInactive = false
    @State private var sort: PivotSort = .name
    @State private var openCell: PivotCell?

    var body: some View {
        let months = model.months(span)
        let pivot = model.pivot(months: months, includeInactive: includeInactive)
        let analysts = ordered(pivot)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Workload").font(.title2.weight(.semibold))
                summary(pivot)
                GroupBox {
                    heatMap(pivot, analysts: analysts)
                        .padding(4)
                } label: {
                    HStack {
                        Text("Cases per analyst per month")
                        Spacer()
                        Text("Click a cell to see its cases").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    GroupBox("Cases allocated per month") { monthlyChart(pivot).frame(height: 220).padding(4) }
                    GroupBox("Total per analyst over the period") {
                        analystChart(pivot, analysts: analysts)
                            .frame(height: max(160, CGFloat(analysts.count) * 24)).padding(4)
                    }
                }
                GroupBox("How evenly the work is spread") {
                    VStack(alignment: .leading, spacing: 8) {
                        balanceChart(pivot).frame(height: 180)
                        Text("Coefficient of variation of each month's cases across the active pool: 0 means everyone had the same number; above 0.5 is markedly uneven. Analysts who joined or left part-way raise it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(4)
                }
                let uncounted = Workload.uncounted(model.book)
                if uncounted > 0 {
                    Label("\(uncounted) allocated case\(uncounted == 1 ? " is" : "s are") not counted: no allocation date or no analyst in the control sheet.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Period", selection: $span) {
                    ForEach(Span.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Include Inactive", isOn: $includeInactive)
                Picker("Sort", selection: $sort) {
                    ForEach(PivotSort.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 140)
                Button {
                    let names = Dictionary(model.data.analysts.map { ($0.shorthand, $0.name) }, uniquingKeysWith: { a, _ in a })
                    model.export(Export.pivot(pivot, names: names), name: "workload-\(model.today.iso).csv")
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .help("Save the pivot table as CSV")
            }
        }
    }

    private func ordered(_ p: WorkloadPivot) -> [String] {
        switch sort {
        case .name:
            return p.analysts.sorted { model.analystLabel($0).localizedStandardCompare(model.analystLabel($1)) == .orderedAscending }
        case .total:
            return p.analysts.sorted { p.rowTotal($0) > p.rowTotal($1) }
        case .thisMonth:
            guard let last = p.months.last else { return p.analysts }
            return p.analysts.sorted { p.count($0, last) > p.count($1, last) }
        }
    }

    private func activePool() -> [String] { model.data.analysts.filter(\.active).map(\.shorthand) }

    @ViewBuilder
    private func summary(_ p: WorkloadPivot) -> some View {
        let thisMonth = model.today.monthKey
        let pool = activePool()
        let counts = pool.map { (a: $0, n: model.metrics[$0]?.thisMonth ?? 0) }
        let total = counts.reduce(0) { $0 + $1.n }
        let busiest = counts.max { $0.n < $1.n }
        let lightest = counts.min { $0.n < $1.n }
        let year = pool.map { model.metrics[$0]?.past12 ?? 0 }
        let cv = Workload.coefficientOfVariation(year)
        HStack(spacing: 12) {
            StatCard(title: "Allocated in \(thisMonth.longLabel)", value: "\(total)",
                     detail: pool.isEmpty ? "" : String(format: "%.1f per active analyst", Double(total) / Double(pool.count)))
            StatCard(title: "Busiest this month", value: busiest.map { "\($0.a) · \($0.n)" } ?? "–",
                     detail: busiest.map { model.analystLabel($0.a) } ?? "")
            StatCard(title: "Lightest this month", value: lightest.map { "\($0.a) · \($0.n)" } ?? "–",
                     detail: lightest.map { model.analystLabel($0.a) } ?? "", tint: .teal)
            StatCard(title: "Balance, past 12 months", value: cv.map { String(format: "%.2f", $0) } ?? "–",
                     detail: cv.map { $0 < 0.25 ? "Even" : ($0 < 0.5 ? "Somewhat uneven" : "Uneven") } ?? "Not enough data",
                     tint: cv.map { $0 < 0.25 ? Color.green : ($0 < 0.5 ? Color.orange : Color.red) } ?? .primary)
            StatCard(title: "In the batch", value: "\(model.pendingCount)", detail: "prepared, not yet in the control sheet")
        }
    }

    // MARK: Heat map

    private func heatMap(_ p: WorkloadPivot, analysts: [String]) -> some View {
        let top = p.maxCell
        return ScrollView(.horizontal) {
            Grid(alignment: .center, horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    Text("Analyst").font(.caption.weight(.semibold)).gridColumnAlignment(.leading)
                    ForEach(p.months) { m in
                        Text(m.shortLabel).font(.caption2).foregroundStyle(.secondary).frame(width: 46)
                    }
                    Text("Total").font(.caption.weight(.semibold)).frame(width: 52)
                }
                ForEach(analysts, id: \.self) { a in
                    GridRow {
                        analystLabel(a)
                        ForEach(p.months) { m in heatCell(p, a, m, top: top) }
                        Text("\(p.rowTotal(a))").font(.callout.weight(.semibold)).monospacedDigit().frame(width: 52)
                    }
                }
                GridRow {
                    Text("Total").font(.caption.weight(.semibold)).gridColumnAlignment(.leading)
                    ForEach(p.months) { m in
                        Text("\(p.columnTotal(m))").font(.caption.weight(.semibold)).monospacedDigit().frame(width: 46)
                    }
                    Text("\(p.grandTotal)").font(.callout.weight(.bold)).monospacedDigit().frame(width: 52)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func analystLabel(_ a: String) -> some View {
        let analyst = model.book.analyst(for: a)
        return HStack(spacing: 6) {
            Text(a).font(Style.monoSmall).frame(width: 44, alignment: .leading)
            Text(analyst?.displayName ?? "Unknown shorthand").lineLimit(1)
                .foregroundStyle(analyst == nil ? Color.orange : (analyst!.active ? Color.primary : Color.secondary))
        }
        .frame(width: 210, alignment: .leading)
    }

    private func heatCell(_ p: WorkloadPivot, _ a: String, _ m: MonthKey, top: Int) -> some View {
        let n = p.count(a, m)
        let cell = PivotCell(analyst: a, month: m)
        return Button {
            openCell = cell
        } label: {
            Text(n == 0 ? "" : "\(n)")
                .font(.callout.weight(.medium)).monospacedDigit()
                .foregroundStyle(Style.heatText(n, max: top))
                .frame(width: 46, height: 26)
                .background(RoundedRectangle(cornerRadius: 4).fill(Style.heat(n, max: top)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(n == 0)
        .help("\(model.analystLabel(a)), \(m.label): \(n) case\(n == 1 ? "" : "s")")
        .popover(isPresented: Binding(get: { openCell == cell }, set: { if !$0 { openCell = nil } }),
                 arrowEdge: .bottom) {
            CellCasesPopover(model: model, analyst: a, month: m, caseIDs: p.cases(a, m)) { id in
                openCell = nil
                model.reveal(id)
            }
        }
    }

    // MARK: Charts

    private func monthlyChart(_ p: WorkloadPivot) -> some View {
        Chart(p.months) { m in
            BarMark(x: .value("Month", m.shortLabel), y: .value("Cases", p.columnTotal(m)))
                .foregroundStyle(Color.teal)
        }
    }

    private func analystChart(_ p: WorkloadPivot, analysts: [String]) -> some View {
        let active = analysts.filter { model.book.analyst(for: $0)?.active ?? false }
        let mean = active.isEmpty ? 0 : Double(active.reduce(0) { $0 + p.rowTotal($1) }) / Double(active.count)
        return Chart {
            ForEach(analysts, id: \.self) { a in
                BarMark(x: .value("Cases", p.rowTotal(a)), y: .value("Analyst", a))
                    .foregroundStyle(Double(p.rowTotal(a)) > mean * 1.25 ? Color.orange : Color.teal)
            }
            if mean > 0 {
                RuleMark(x: .value("Average", mean))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(String(format: "Average %.1f", mean)).font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
    }

    private func balanceChart(_ p: WorkloadPivot) -> some View {
        let pool = activePool()
        let points = p.months.compactMap { m in p.balance(m, pool: pool).map { BalancePoint(month: m, cv: $0) } }
        return Chart(points) { pt in
            LineMark(x: .value("Month", pt.month.shortLabel), y: .value("Variation", pt.cv))
                .foregroundStyle(Color.indigo)
            PointMark(x: .value("Month", pt.month.shortLabel), y: .value("Variation", pt.cv))
                .foregroundStyle(pt.cv < 0.25 ? Color.green : (pt.cv < 0.5 ? Color.orange : Color.red))
        }
    }
}

struct BalancePoint: Identifiable {
    var month: MonthKey
    var cv: Double
    var id: MonthKey { month }
}

/// The cases behind one heat map cell.
struct CellCasesPopover: View {
    var model: AppModel
    var analyst: String
    var month: MonthKey
    var caseIDs: [String]
    var show: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.analystLabel(analyst)) · \(month.longLabel)").font(.headline)
            Text("\(caseIDs.count) case\(caseIDs.count == 1 ? "" : "s"). Click one to show it in the catalogue.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(caseIDs, id: \.self) { id in
                        let row = model.book.row(id)
                        Button {
                            show(id)
                        } label: {
                            HStack(spacing: 8) {
                                Text(id).font(Style.monoSmall).frame(width: 110, alignment: .leading)
                                Text(row?.title ?? "").lineLimit(1)
                                Spacer(minLength: 8)
                                Text(row?.genre ?? "").font(.caption).foregroundStyle(.secondary)
                                Text(row?.allocationDate?.display ?? "").font(.caption).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3).padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(14)
        .frame(width: 520)
    }
}

// MARK: - Acceptance and refusal

struct RatePoint: Identifiable {
    var id: String { key + kind }
    var key: String
    var label: String
    var kind: String
    var count: Int
}

struct RatesView: View {
    @Environment(AppModel.self) private var model
    @State private var grouping: Rates.Grouping = .month
    @State private var span: Span = .twelve

    var body: some View {
        let months: [MonthKey]? = span == .all ? nil : model.months(span)
        let rows = Rates.rows(model.book, by: grouping, months: months)
        let total = Rates.overall(rows)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Acceptance & Refusal").font(.title2.weight(.semibold))
                HStack(spacing: 12) {
                    StatCard(title: "Acceptance rate  a / (a + r)", value: Style.percent(total.acceptanceRate),
                             detail: "\(total.accepted) accepted", tint: .green)
                    StatCard(title: "Refusal rate  r / (a + r)", value: Style.percent(total.refusalRate),
                             detail: "\(total.refused) refused & returned", tint: .red)
                    StatCard(title: "Shown separately", value: "\(total.other)",
                             detail: "projects and other outcomes, in neither rate")
                }
                if grouping == .month && !rows.isEmpty {
                    HStack(alignment: .top, spacing: 18) {
                        GroupBox("Decisions per month") { stackedChart(rows).frame(height: 220).padding(4) }
                        GroupBox("Rates per month") { rateChart(rows).frame(height: 220).padding(4) }
                    }
                }
                GroupBox {
                    rateTable(rows, total: total).padding(4)
                } label: {
                    Text(grouping.title)
                }
                Text("Each case counts once, by its latest decision in the control sheet. How each outcome code counts is set in Outcome Codes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Group", selection: $grouping) {
                    ForEach(Rates.Grouping.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Period", selection: $span) {
                    ForEach(Span.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 130)
                Button {
                    model.export(Export.rates(rows, heading: grouping.title), name: "rates-\(grouping.rawValue)-\(model.today.iso).csv")
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func stackedChart(_ rows: [RateRow]) -> some View {
        let points = rows.flatMap { r in
            [RatePoint(key: r.key, label: r.label, kind: "Accepted (a)", count: r.accepted),
             RatePoint(key: r.key, label: r.label, kind: "Refused (r)", count: r.refused),
             RatePoint(key: r.key, label: r.label, kind: "Other", count: r.other)]
        }
        return Chart(points) { p in
            BarMark(x: .value("Month", p.label), y: .value("Cases", p.count))
                .foregroundStyle(by: .value("Outcome", p.kind))
        }
        .chartForegroundStyleScale(["Accepted (a)": Color.green, "Refused (r)": Color.red, "Other": Color.gray])
    }

    private func rateChart(_ rows: [RateRow]) -> some View {
        let points = rows.flatMap { r -> [RatePoint] in
            guard let a = r.acceptanceRate, let f = r.refusalRate else { return [] }
            return [RatePoint(key: r.key, label: r.label, kind: "Acceptance", count: Int((a * 1000).rounded())),
                    RatePoint(key: r.key, label: r.label, kind: "Refusal", count: Int((f * 1000).rounded()))]
        }
        return Chart(points) { p in
            LineMark(x: .value("Month", p.label), y: .value("Rate (%)", Double(p.count) / 10))
                .foregroundStyle(by: .value("Rate", p.kind))
            PointMark(x: .value("Month", p.label), y: .value("Rate (%)", Double(p.count) / 10))
                .foregroundStyle(by: .value("Rate", p.kind))
        }
        .chartForegroundStyleScale(["Acceptance": Color.green, "Refusal": Color.red])
        .chartYScale(domain: 0...100)
    }

    private func rateTable(_ rows: [RateRow], total: RateRow) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 5) {
            GridRow {
                heading(grouping == .month ? "Month" : (grouping == .supervisor ? "Supervisor" : "Genre"))
                    .gridColumnAlignment(.leading)
                heading("a")
                heading("r")
                heading("Other")
                heading("Acceptance")
                heading("Refusal")
                Text("").gridColumnAlignment(.leading)
            }
            Divider()
            ForEach(rows + [total]) { r in
                let weight: Font.Weight = r.key == "total" ? .semibold : .regular
                GridRow {
                    Text(r.label).fontWeight(weight)
                    Text("\(r.accepted)").monospacedDigit().fontWeight(weight)
                    Text("\(r.refused)").monospacedDigit().fontWeight(weight)
                    Text("\(r.other)").monospacedDigit().fontWeight(weight).foregroundStyle(.secondary)
                    Text(Style.percent(r.acceptanceRate)).monospacedDigit().fontWeight(weight)
                    Text(Style.percent(r.refusalRate)).monospacedDigit().fontWeight(weight)
                    RateBar(row: r).frame(width: 140, height: 8)
                }
            }
        }
    }

    private func heading(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// Acceptance (green) against refusal (red) as one bar.
struct RateBar: View {
    var row: RateRow

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                Rectangle().fill(Color.green.opacity(0.75)).frame(width: g.size.width * (row.acceptanceRate ?? 0))
                Rectangle().fill(Color.red.opacity(0.7)).frame(width: g.size.width * (row.refusalRate ?? 0))
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}
