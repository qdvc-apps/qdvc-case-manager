import CaseCore
import SwiftUI

struct CaseListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var sortOrder = [KeyPathComparator(\CaseRow.registrationSort, order: .reverse)]

    var body: some View {
        @Bindable var model = model
        Group {
            if model.data.tables[.catalogue] == nil && model.data.tables[.controlSheet] == nil {
                NothingImportedView()
            } else {
                CaseTable(rows: model.visibleRows.sorted(using: sortOrder), sortOrder: $sortOrder)
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "ID, title, genre, analyst, note")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Genre", selection: $model.genreFilter) {
                    Text("All Genres").tag("")
                    Divider()
                    ForEach(model.book.genres, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 170)
                .help("Show one genre")

                Button {
                    if let id = model.selectedCaseIDs.first { openWindow(id: DecisionWindow.id, value: id) }
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
        .inspector(isPresented: $model.inspectorShown) {
            CaseInspector()
                .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        }
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
        Table(rows, selection: $model.selectedCaseIDs, sortOrder: $sortOrder) {
            TableColumn("Case ID", value: \.caseID) { row in CaseIDCell(row: row) }
                .width(min: 110, ideal: 140)
            TableColumn("Title", value: \.title) { row in
                Text(row.title).lineLimit(1).help(row.title)
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
                Text(row.analystKey).font(Style.monoSmall).help(row.analystName)
            }
            .width(min: 50, ideal: 64)
            TableColumn("Allocated", value: \.allocationSort) { row in
                Text(row.allocationDate?.display ?? (row.latest?.allocationText ?? "")).monospacedDigit()
            }
            .width(min: 80, ideal: 96)
            TableColumn("Supervisor", value: \.supervisor)
                .width(min: 70, ideal: 110)
            TableColumn("Note", value: \.note) { row in NoteCell(row: row) }
                .width(min: 100, ideal: 220)
            TableColumn("Projects", value: \.projectsSort) { row in ProjectTags(row: row) }
                .width(min: 50, ideal: 80)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Decision Support…") { openWindow(id: DecisionWindow.id, value: id) }
                Divider()
                Button("Copy Case ID") { Platform.copy(id) }
            } else if !ids.isEmpty {
                Button("Copy \(ids.count) Case IDs") { Platform.copy(ids.sorted().joined(separator: "\n")) }
            }
        } primaryAction: { ids in
            if let id = ids.first { openWindow(id: DecisionWindow.id, value: id) }
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
            Text(row.caseID).font(Style.monoSmall).textSelection(.enabled)
        }
        .help(row.flags.map(Export.describe).joined(separator: "\n"))
    }
}

struct StatusCell: View {
    @Environment(AppModel.self) private var model
    var row: CaseRow

    var body: some View {
        if row.isInBatch, let d = row.decision {
            Label {
                Text(d.analyst.isEmpty ? "In batch: \(d.outcome)" : "In batch → \(d.analyst)")
            } icon: {
                Image(systemName: "tray.full.fill").foregroundStyle(.teal)
            }
            .help("Prepared in the batch, not yet in the control sheet")
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
        .help(row.note.isEmpty ? "" : "\(row.note)\n\(row.noteKind.title)")
    }
}

struct ProjectTags: View {
    @Environment(AppModel.self) private var model
    var row: CaseRow

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Set(row.projects + row.claimedBy)).sorted(), id: \.self) { id in
                if let p = model.project(id) {
                    ProjectTag(definition: p.definition, listed: row.projects.contains(id))
                }
            }
        }
    }
}

// MARK: - Inspector

struct CaseInspector: View {
    @Environment(AppModel.self) private var model
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
                    openWindow(id: DecisionWindow.id, value: row.caseID)
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
