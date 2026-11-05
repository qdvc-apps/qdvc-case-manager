import CaseCore
import SwiftUI

/// The rows prepared in Decision Support, in the control sheet's own
/// columns, ready to paste into the Allocation Control Sheet upstream.
struct BatchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Set<String> = []
    @State private var copied = false

    var body: some View {
        let rows = model.prepared
        VStack(spacing: 0) {
            header
            if model.landedCount > 0 { landedBanner }
            Divider()
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("The Batch Is Empty", systemImage: "tray")
                } description: {
                    Text("Double-click a case awaiting allocation to open it in Decision Support, choose an analyst (or refuse it), and add it to the batch. Work through a dozen or so, then copy the rows here and paste them into the Allocation Control Sheet.")
                } actions: {
                    Button("Show Cases Awaiting Allocation") { model.page = .cases(.awaiting) }
                }
            } else {
                VSplitView {
                    table(rows)
                        .frame(minHeight: 180)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("As it will be pasted").font(.headline)
                            Text("— every column of the control sheet, in its order; columns the app doesn't map are left blank.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        SheetGrid(headers: model.batchHeaders, rows: rows.filter { $0.state == .pending }.map(\.values))
                    }
                    .frame(minHeight: 140)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Copy Rows with Header Row") { copy(header: true) }
                    Button("Copy Rows as CSV") { model.copyBatch(tabSeparated: false); flash() }
                    Divider()
                    Button("Save Rows as CSV…") {
                        model.export(Batch.pasteText(model.prepared.filter { $0.state == .pending }, headers: model.batchHeaders,
                                                     tabSeparated: false, includeHeader: true),
                                     name: "allocation-batch-\(model.today.iso).csv")
                    }
                    Divider()
                    Button("Remove Landed Rows") { model.removeLanded() }.disabled(model.landedCount == 0)
                    Button("Clear Batch…") { model.clearBatch() }.disabled(rows.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                Button {
                    copy(header: false)
                } label: {
                    Label(copied ? "Copied" : "Copy Rows", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                }
                .help("Copy the rows still to paste, as spreadsheet cells (⇧⌘C)")
                .disabled(model.pendingCount == 0)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Batch").font(.title2.weight(.semibold))
                Text("\(model.pendingCount) row\(model.pendingCount == 1 ? "" : "s") ready to paste into the Allocation Control Sheet. After pasting, export the updated sheet upstream and import it here: rows that have landed are recognised.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.supervisorName.isEmpty {
                Label(model.supervisorName, systemImage: "person.crop.circle").foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var landedBanner: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("\(model.landedCount) row\(model.landedCount == 1 ? " is" : "s are") now in the control sheet.")
            Spacer()
            Button("Remove Landed Rows") { model.removeLanded() }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
    }

    private func table(_ rows: [PreparedRow]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("#") { r in Text("\(r.decision.order)").monospacedDigit().foregroundStyle(.secondary) }
                .width(28)
            TableColumn("State") { r in
                Label(r.state.title, systemImage: Style.symbol(r.state))
                    .foregroundStyle(Style.tint(r.state))
                    .help(helpText(r))
            }
            .width(min: 120, ideal: 150)
            TableColumn("Case ID") { r in Text(r.caseID).font(Style.monoSmall) }
                .width(min: 100, ideal: 130)
            TableColumn("Title") { r in Text(model.book.row(r.caseID)?.title ?? "").lineLimit(1) }
                .width(min: 120, ideal: 240)
            TableColumn("Outcome") { r in Text(r.decision.outcome).font(Style.monoSmall) }
                .width(min: 50, ideal: 70)
            TableColumn("Analyst") { r in Text(model.analystLabel(r.decision.analyst)).lineLimit(1) }
                .width(min: 80, ideal: 170)
            TableColumn("Note") { r in Text(r.decision.note).lineLimit(1).help(r.decision.note) }
                .width(min: 100, ideal: 220)
            TableColumn("Date") { r in Text(LocalDate(iso: r.decision.date)?.display ?? r.decision.date).monospacedDigit() }
                .width(min: 80, ideal: 96)
            TableColumn("Supervisor") { r in Text(r.decision.supervisor) }
                .width(min: 70, ideal: 110)
            TableColumn("Check") { r in
                if r.problems.isEmpty {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                } else {
                    Label(r.problems.joined(separator: " "), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).lineLimit(1).help(r.problems.joined(separator: "\n"))
                }
            }
            .width(min: 60, ideal: 160)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Open in Decision Support…") { openWindow(id: DecisionWindow.id, value: id) }
                Button("Show Case") { model.reveal(id) }
                Divider()
                Button("Move Up") { model.moveBatchRow(id, by: -1) }
                Button("Move Down") { model.moveBatchRow(id, by: 1) }
                Divider()
            }
            if !ids.isEmpty {
                Button("Copy \(ids.count == 1 ? "Row" : "\(ids.count) Rows")") { model.copyBatch(only: ids); flash() }
                Button("Remove from Batch") { for id in ids { model.unprepare(id) } }
            }
        } primaryAction: { ids in
            if let id = ids.first { openWindow(id: DecisionWindow.id, value: id) }
        }
    }

    private func helpText(_ r: PreparedRow) -> String {
        switch r.state {
        case .pending: return "Not in the control sheet yet: copy and paste it upstream."
        case .landed: return "The imported control sheet has this decision. Remove it from the batch when you're ready."
        case .landedDifferently:
            let row = model.book.row(r.caseID)
            return "The control sheet records \(row?.latest?.outcome ?? "?") \(row?.analystKey ?? "") instead of what was prepared."
        }
    }

    private func copy(header: Bool) {
        model.copyBatch(includeHeader: header)
        flash()
    }

    private func flash() {
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
