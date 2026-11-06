import CaseCore
import SwiftUI

struct CaseListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        @Bindable var model = model
        Group {
            if model.data.tables[.catalogue] == nil && model.data.tables[.controlSheet] == nil {
                NothingImportedView()
            } else {
                // Filtered and sorted by the model when the search, year,
                // page or data change, not on every redraw.
                CaseTable(rows: model.caseRows, sortOrder: model.binding(\.caseSort))
            }
        }
        .searchable(text: model.binding(\.searchText), placement: .toolbar, prompt: "ID, title, genre, analyst, note")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                YearPicker(model: model)

                Button {
                    if let id = model.selectedCaseIDs.first { model.openDecision(id, with: openWindow) }
                } label: {
                    Label("Decision Support", systemImage: "person.crop.rectangle.stack")
                }
                .help("Open the selected case in Decision Support (⌘D, or double-click)")
                .disabled(model.selectedCaseIDs.count != 1)

                Button {
                    model.inspectorShown.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the case inspector")
            }
        }
        .inspector(isPresented: model.binding(\.inspectorShown)) {
            CaseInspector(model: model)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        }
    }
}

/// The global filter on the year cases were registered. There is no "all
/// years": one year at a time keeps the tables manageable.
struct YearPicker: View {
    var model: AppModel

    var body: some View {
        Picker("Year", selection: model.binding(\.selectedYear)) {
            ForEach(model.yearSummaries) { y in
                Text(y.menuTitle).tag(y.year)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 150)
        .help("Show cases registered in one year")
    }
}

struct NothingImportedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("No Cases Yet", systemImage: "tray")
        } description: {
            Text("Import the case catalogue and the allocation control sheet exported from upstream. You'll be asked which columns hold what; the app remembers for next time.")
        } actions: {
            Button("Import Case Catalogue…") { model.beginImport(.catalogue) }
            Button("Import Allocation Control Sheet…") { model.beginImport(.controlSheet) }
        }
    }
}

/// The table of cases, also used on project pages.
struct CaseTable: View {
    var rows: [CaseRow]
    @Binding var sortOrder: [KeyPathComparator<CaseRow>]
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        // Cells are given plain values: none reads the model or carries a
        // tooltip (docs/MAINTENANCE.md §2.2).
        let projects = Dictionary(model.data.projects.map { ($0.id, $0.definition) }, uniquingKeysWith: { a, _ in a })
        Table(rows, selection: model.binding(\.selectedCaseIDs), sortOrder: $sortOrder) {
            TableColumn("Case ID", value: \.caseID) { row in CaseIDCell(row: row) }
                .width(min: 110, ideal: 140)
            TableColumn("Title", value: \.title) { row in
                Text(row.title).lineLimit(1)
            }
            .width(min: 160, ideal: 300)
            TableColumn("Genre", value: \.genre)
                .width(min: 80, ideal: 140)
            TableColumn("Registered", value: \.registrationSort) { row in
                Text(row.registrationDate?.display ?? row.registrationText).monospacedDigit()
            }
            .width(min: 80, ideal: 96)
            TableColumn("Status", value: \.statusSort) { row in StatusCell(row: row) }
                .width(min: 110, ideal: 160)
            TableColumn("Analyst", value: \.analystKey) { row in
                ShorthandText(text: row.analystKey, minWidth: 0)
            }
            .width(min: 64, ideal: 72)
            TableColumn("Allocated", value: \.allocationSort) { row in
                Text(row.allocationDate?.display ?? (row.latest?.allocationText ?? "")).monospacedDigit()
            }
            .width(min: 80, ideal: 96)
            TableColumn("Supervisor", value: \.supervisor)
                .width(min: 70, ideal: 110)
            TableColumn("Note", value: \.note) { row in NoteCell(row: row) }
                .width(min: 100, ideal: 220)
            TableColumn("Projects", value: \.projectsSort) { row in ProjectTags(definitions: projects, row: row) }
                .width(min: 50, ideal: 80)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Decision Support…") { model.openDecision(id, with: openWindow) }
                Divider()
                Button("Copy Case ID") { Platform.copy(id) }
            } else if !ids.isEmpty {
                Button("Copy \(ids.count) Case IDs") { Platform.copy(ids.sorted().joined(separator: "\n")) }
            }
        } primaryAction: { ids in
            if let id = ids.first { model.openDecision(id, with: openWindow) }
        }
        // Edit › Copy (⌘C) copies the selected rows' case IDs.
        .onCopyCommand {
            let ids = model.selectedCaseIDs.sorted()
            return ids.isEmpty ? [] : [NSItemProvider(object: ids.joined(separator: "\n") as NSString)]
        }
    }
}

struct CaseIDCell: View {
    var row: CaseRow

    var body: some View {
        HStack(spacing: 5) {
            if row.hasWarning {
                Emblem(kind: .warning)
            } else if row.needsAttention {
                Emblem(kind: .info)
            }
            Text(row.caseID).font(Style.monoSmall)
        }
    }
}

/// Table cells are hosted one by one and don't reliably inherit the
/// environment, so cell views never read `AppModel` from it: those that need
/// the model are handed it (docs/MAINTENANCE.md §2.2).
struct StatusCell: View {
    var row: CaseRow

    var body: some View {
        if row.isInBatch, let d = row.decision {
            Label {
                Text(d.analyst.isEmpty ? "In batch: \(d.outcome)" : "In batch → \(d.analyst)")
            } icon: {
                Image(systemName: "tray.full.fill").foregroundStyle(.teal)
            }
        } else {
            Label {
                Text(row.outcome?.kind == .project ? row.outcome!.displayLabel : row.status.title).lineLimit(1)
            } icon: {
                Image(systemName: Style.symbol(row.status)).foregroundStyle(Style.tint(row.status))
            }
        }
    }
}

struct NoteCell: View {
    var row: CaseRow

    var body: some View {
        HStack(spacing: 4) {
            if let symbol = Style.symbol(row.noteKind) {
                Image(systemName: symbol).foregroundStyle(Style.tint(row.noteKind)).imageScale(.small)
            }
            Text(row.note).lineLimit(1)
        }
    }
}

struct ProjectTags: View {
    var definitions: [String: ProjectDefinition]
    var row: CaseRow
    var showsHelp = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Set(row.projects + row.claimedBy)).sorted(), id: \.self) { id in
                if let d = definitions[id] {
                    ProjectTag(definition: d, listed: row.projects.contains(id), showsHelp: showsHelp)
                }
            }
        }
    }
}

// MARK: - Inspector

struct CaseInspector: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.selectedCaseIDs.count == 1, let id = model.selectedCaseIDs.first, let row = model.book.row(id) {
            Form {
                header(row)
                if !row.flags.isEmpty { flags(row) }
                if !row.discrepancies.isEmpty { comparison(row) }
                details(row)
                if !row.allocations.isEmpty { history(row) }
                if let d = row.decision, !d.isEmpty { batch(row, d) }
                ForEach(row.projects, id: \.self) { pid in projectSection(row, pid) }
                rawColumns(row)
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(model.selectedCaseIDs.isEmpty ? "No Case Selected" : "\(model.selectedCaseIDs.count) Cases Selected",
                                   systemImage: "doc.text.magnifyingglass",
                                   description: Text("Select a case to see its details. Double-click to open it in Decision Support."))
        }
    }

    private func header(_ row: CaseRow) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.caseID).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                Text(row.title).font(.headline).textSelection(.enabled)
                StatusCell(row: row)
                Button {
                    model.openDecision(row.caseID, with: openWindow)
                } label: {
                    Label("Decision Support…", systemImage: "person.crop.rectangle.stack")
                }
                .padding(.top, 4)
            }
        }
    }

    private func flags(_ row: CaseRow) -> some View {
        Section("Needs Attention") {
            ForEach(row.flags, id: \.self) { flag in
                HStack(alignment: .top, spacing: 6) {
                    Emblem(kind: flag.isWarning ? .warning : .info)
                    Text(Export.describe(flag))
                }
            }
        }
    }

    private func comparison(_ row: CaseRow) -> some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Catalogue").font(.caption).foregroundStyle(.secondary)
                    Text("Control sheet").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(row.discrepancies.enumerated()), id: \.offset) { _, d in
                    GridRow {
                        Text(d.field.title).font(.caption.weight(.medium))
                        Text(d.catalogue.isEmpty ? "—" : d.catalogue).textSelection(.enabled)
                        Text(d.controlSheet).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("Catalogue and Control Sheet Differ")
        } footer: {
            Text("The case ID is authoritative: the catalogue's details are shown everywhere else.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func details(_ row: CaseRow) -> some View {
        Section("Details") {
            LabeledContent("Genre", value: row.genre)
            LabeledContent("Registered", value: row.registrationDate?.display ?? row.registrationText)
            if row.latest != nil {
                LabeledContent("Outcome", value: row.latest?.outcome ?? "")
                LabeledContent("Analyst", value: model.analystLabel(row.analystKey))
                LabeledContent("Supervisor", value: row.supervisor)
                LabeledContent("Allocated", value: row.allocationDate?.display ?? (row.latest?.allocationText ?? ""))
                LabeledContent("Note") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(row.note).multilineTextAlignment(.trailing).textSelection(.enabled)
                        if row.noteKind != .none {
                            Text(row.noteKind.title).font(.caption).foregroundStyle(Style.tint(row.noteKind))
                        }
                    }
                }
            }
        }
    }

    private func history(_ row: CaseRow) -> some View {
        Section(row.allocations.count == 1 ? "Control Sheet Row" : "Control Sheet Rows (\(row.allocations.count))") {
            ForEach(row.allocations.reversed()) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(a.allocationDate?.display ?? a.allocationText).monospacedDigit()
                        Text(a.outcome).font(Style.monoSmall).padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)))
                        if !a.analyst.isEmpty { Text(a.analyst).font(Style.monoSmall) }
                        Spacer()
                        Text(a.supervisor).foregroundStyle(.secondary)
                    }
                    if !a.note.isEmpty { Text(a.note).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func batch(_ row: CaseRow, _ d: CaseDecision) -> some View {
        Section("Decision Support") {
            if !d.shortlist.isEmpty {
                LabeledContent("Shortlist", value: d.shortlist.joined(separator: ", "))
            }
            if d.isPrepared {
                LabeledContent("Prepared row", value: [d.outcome, d.analyst, d.note].filter { !$0.isEmpty }.joined(separator: " · "))
                if let p = model.prepared.first(where: { $0.caseID == row.caseID }) {
                    Label(p.state.title, systemImage: Style.symbol(p.state)).foregroundStyle(Style.tint(p.state))
                }
            }
        }
    }

    @ViewBuilder
    private func projectSection(_ row: CaseRow, _ pid: String) -> some View {
        if let p = model.project(pid), let r = p.caseRows[row.key] {
            Section {
                ForEach(p.table.headers.indices, id: \.self) { c in
                    let v = p.table.value(r, c)
                    if !v.isEmpty && c != p.caseIDColumnIndex { LabeledContent(p.table.headers[c], value: v) }
                }
            } header: {
                HStack {
                    ProjectTag(definition: p.definition)
                    Text("\(p.definition.name) Worksheet")
                }
            }
        }
    }

    @ViewBuilder
    private func rawColumns(_ row: CaseRow) -> some View {
        if let record = row.record, let table = model.data.tables[.catalogue] {
            Section {
                DisclosureGroup("All catalogue columns") {
                    ForEach(table.headers.indices, id: \.self) { c in
                        LabeledContent(table.headers[c], value: table.value(record.row, c))
                    }
                }
            }
        }
    }
}
