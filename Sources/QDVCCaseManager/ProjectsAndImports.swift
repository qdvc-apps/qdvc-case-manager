import CaseCore
import SwiftUI

// MARK: - Project page

enum ProjectTab: String, CaseIterable, Identifiable {
    case worksheet, cases, completeness
    var id: String { rawValue }
    var title: String {
        switch self {
        case .worksheet: return "Worksheet"
        case .cases: return "Cases"
        case .completeness: return "Completeness"
        }
    }
}

struct ProjectView: View {
    var id: String
    @Environment(AppModel.self) private var model
    @State private var tab: ProjectTab = .worksheet
    @State private var sortOrder = [KeyPathComparator(\CaseRow.caseID)]

    var body: some View {
        if let p = model.project(id) {
            let missing = model.book.rows.filter { $0.flags.contains(.missingFromWorksheet(id)) }
            let orphans = model.book.worksheetOrphans[id] ?? []
            VStack(alignment: .leading, spacing: 0) {
                header(p, missing: missing.count, orphans: orphans.count)
                Picker("", selection: $tab) {
                    ForEach(ProjectTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                Divider()
                switch tab {
                case .worksheet: worksheet(p)
                case .cases:
                    CaseTable(rows: model.book.rows.filter { $0.projects.contains(id) || $0.claimedBy.contains(id) }
                        .sorted(using: sortOrder), sortOrder: $sortOrder)
                case .completeness: completeness(p, missing: missing, orphans: orphans)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.updateWorksheet(id) } label: {
                        Label("Update Worksheet", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Import a newer copy of this worksheet")
                    Button { model.editProject(id) } label: {
                        Label("Edit Project", systemImage: "slider.horizontal.3")
                    }
                }
            }
        } else {
            ContentUnavailableView("No Such Project", systemImage: "folder.badge.questionmark")
        }
    }

    private func header(_ p: ProjectWorksheet, missing: Int, orphans: Int) -> some View {
        let d = p.definition
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(Style.colour(d.colour))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(d.name).font(.title2.weight(.semibold))
                    ProjectTag(definition: d)
                }
                Text("\(d.leaderTitle): \(d.leader.isEmpty ? "not set" : model.analystLabel(d.leader))")
                    .foregroundStyle(.secondary)
                Text(worksheetLine(d, rows: p.table.rows.count)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                StatCard(title: "On the worksheet", value: "\(p.caseRows.count)")
                    .frame(width: 130)
                StatCard(title: "Missing from it", value: "\(missing)", tint: missing > 0 ? .orange : .primary)
                    .frame(width: 130)
                StatCard(title: "Not in the exports", value: "\(orphans)", tint: orphans > 0 ? .orange : .primary)
                    .frame(width: 130)
            }
        }
        .padding(16)
    }

    private func worksheetLine(_ d: ProjectDefinition, rows: Int) -> String {
        var parts = ["\(rows) rows"]
        if !d.originalFilename.isEmpty { parts.append("from “\(d.originalFilename)”") }
        if let date = LocalDate(iso: d.importedAt) {
            parts.append("imported \(Freshness.describe(age: model.today.dayNumber - date.dayNumber))")
        }
        return parts.joined(separator: " · ")
    }

    private func worksheet(_ p: ProjectWorksheet) -> some View {
        let col = p.caseIDColumnIndex
        let headers = ["In catalogue", "Status", "Analyst"] + p.table.headers
        let rows = p.table.rows.indices.map { r -> [String] in
            let caseRow = model.book.row(p.table.value(r, col))
            let status = caseRow.map { $0.isInBatch ? "In batch" : $0.status.title } ?? "—"
            return [caseRow == nil ? "✗ No" : (caseRow!.inCatalogue ? "✓" : "✗ Control sheet only"), status,
                    caseRow?.analystKey ?? ""] + p.table.rows[r]
        }
        return SheetGrid(headers: headers, rows: rows) { r in
            let id = p.table.value(r, col)
            if model.book.row(id) != nil { model.reveal(id) }
        }
    }

    private func completeness(_ p: ProjectWorksheet, missing: [CaseRow], orphans: [String]) -> some View {
        let d = p.definition
        return Form {
            Section {
                if missing.isEmpty {
                    Label("Every case the exports put in this project is on the worksheet.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                ForEach(missing) { row in
                    HStack {
                        Text(row.caseID).font(Style.monoSmall)
                        Text(row.title).lineLimit(1)
                        Spacer()
                        Text(row.latest?.outcome ?? "").font(Style.monoSmall).foregroundStyle(.secondary)
                        Button("Show") { model.reveal(row.caseID) }.controlSize(.small)
                    }
                }
            } header: {
                Text("In the project by outcome or note, but not on the worksheet")
            } footer: {
                Text("A case belongs to this project when its outcome is \(d.outcomeCodes.isEmpty ? "(none set)" : d.outcomeCodes.joined(separator: ", ")) or its note mentions \(d.noteKeywords.isEmpty ? "(none set)" : d.noteKeywords.joined(separator: ", ")). Change this in Edit Project.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("On the worksheet, but in neither export") {
                if orphans.isEmpty {
                    Label("Every case ID on the worksheet is known.", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                ForEach(orphans, id: \.self) { id in
                    Text(id).font(Style.monoSmall).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Import sheet (column mapping)

struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @State var draft: ImportDraft

    private var headers: [String] { draft.table.headers }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.fileURL == nil ? "\(draft.source.title) Columns" : "Import \(draft.source.title)")
                    .font(.title2.weight(.semibold))
                Text("\(draft.fileURL?.lastPathComponent ?? draft.mapping.originalFilename) · \(draft.table.rows.count) rows · \(headers.count) columns")
                    .foregroundStyle(.secondary)
                Text("Choose which column holds each field. Your choices are kept in the workspace and reused for the next export with the same columns.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Form {
                Section("Columns") {
                    ForEach(draft.source.fields) { field in fieldRow(field) }
                }
                Section("Dates") {
                    Picker("Numeric dates are written", selection: $draft.mapping.dateOrder) {
                        ForEach(DateOrder.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Names of months, ISO dates and Excel serial numbers are read whatever this says.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if draft.mapping.header(.caseID) == nil {
                    Label("Choose the case ID column.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(draft.fileURL == nil ? "Save" : "Import") { model.confirmImport(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.mapping.header(.caseID) == nil)
            }
        }
        .padding(20)
        .frame(width: 680, height: 640)
    }

    private func fieldRow(_ field: MappedField) -> some View {
        let binding = Binding<String>(
            get: { draft.mapping.columns[field] ?? "" },
            set: { draft.mapping.columns[field] = $0.isEmpty ? nil : $0 })
        let col = draft.mapping.header(field).flatMap { draft.table.index(of: $0) }
        let samples = col.map { c in draft.table.rows.indices.prefix(200).map { draft.table.value($0, c) }.filter { !$0.isEmpty } } ?? []
        return VStack(alignment: .leading, spacing: 3) {
            Picker(selection: binding) {
                Text("Not in this file").tag("")
                Divider()
                ForEach(headers, id: \.self) { Text($0).tag($0) }
            } label: {
                HStack(spacing: 4) {
                    Text(field.title)
                    if field.isRequired { Text("required").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            if col != nil {
                Text(sampleLine(field, samples)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func sampleLine(_ field: MappedField, _ samples: [String]) -> String {
        if samples.isEmpty { return "Empty in the first rows" }
        if field.isDate {
            let parsed = samples.map { DateParser.parse($0, order: draft.mapping.dateOrder) }
            let bad = parsed.filter { $0 == nil }.count
            let shown = zip(samples, parsed).prefix(3).map { "\($0) → \($1?.display ?? "?")" }.joined(separator: ",  ")
            return bad == 0 ? shown : "\(shown)  ·  \(bad) of \(samples.count) unreadable"
        }
        return samples.prefix(4).joined(separator: "  ·  ")
    }
}

// MARK: - Project sheet

struct ProjectSheet: View {
    @Environment(AppModel.self) private var model
    @State var draft: ProjectDraft
    @State private var codesText = ""
    @State private var keywordsText = ""

    var body: some View {
        let col = draft.table.index(of: draft.definition.caseIDColumn)
        let matched = col.map { c in draft.table.rows.indices.filter { model.book.row(draft.table.value($0, c)) != nil }.count } ?? 0
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.isNew ? "New Project" : "Edit \(draft.definition.name)").font(.title2.weight(.semibold))
            if let file = draft.fileURL {
                Text("Worksheet: \(file.lastPathComponent) · \(draft.table.rows.count) rows · \(draft.table.headers.count) columns")
                    .foregroundStyle(.secondary)
            }
            Form {
                Section("Project") {
                    TextField("Name", text: $draft.definition.name)
                    TextField("Badge", text: $draft.definition.badge, prompt: Text(draft.definition.displayBadge))
                    Picker("Colour", selection: $draft.definition.colour) {
                        ForEach(ProjectDefinition.colours, id: \.self) { c in
                            Label { Text(c.capitalized) } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(Style.colour(c))
                            }
                            .tag(c)
                        }
                    }
                }
                Section("Leader") {
                    Picker("Analyst", selection: $draft.definition.leader) {
                        Text("Not set").tag("")
                        ForEach(model.data.analysts) { a in Text("\(a.shorthand) — \(a.displayName)").tag(a.shorthand) }
                    }
                    HStack {
                        TextField("Title", text: $draft.definition.leaderTitle)
                        Menu {
                            ForEach(["Captain", "Team Leader", "Principal Analyst", "Lead Analyst", "Coordinator"], id: \.self) { t in
                                Button(t) { draft.definition.leaderTitle = t }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                Section {
                    Picker("Case ID column", selection: $draft.definition.caseIDColumn) {
                        ForEach(draft.table.headers, id: \.self) { Text($0).tag($0) }
                    }
                    Text("\(matched) of \(draft.table.rows.count) rows match a known case")
                        .font(.caption).foregroundStyle(matched == 0 ? Color.orange : Color.secondary)
                } header: {
                    Text("Worksheet")
                }
                Section {
                    TextField("Outcome codes", text: $codesText, prompt: Text("e.g. Operation Waymaker"))
                    TextField("Note keywords", text: $keywordsText, prompt: Text("e.g. Waymaker"))
                } header: {
                    Text("Which Cases Belong Here")
                } footer: {
                    Text("Comma-separated. Cases with one of these outcomes, or a note containing one of these words, are expected on the worksheet; those missing are flagged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Notes") {
                    TextField("Notes", text: $draft.definition.notes, axis: .vertical).lineLimit(2...5)
                }
            }
            .formStyle(.grouped)
            HStack {
                if !draft.isNew {
                    Button("Remove Project…", role: .destructive) { model.deleteProject(draft.definition.id) }
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add Project" : "Save") {
                    var d = draft
                    d.definition.outcomeCodes = split(codesText)
                    d.definition.noteKeywords = split(keywordsText)
                    d.definition.name = d.definition.name.trimmingCharacters(in: .whitespaces)
                    model.confirmProject(d)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.definition.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600, height: 700)
        .onAppear {
            codesText = draft.definition.outcomeCodes.joined(separator: ", ")
            keywordsText = draft.definition.noteKeywords.joined(separator: ", ")
            if draft.isNew && codesText.isEmpty {
                // Suggest an outcome code with the project's name, if the control sheet uses one.
                let name = draft.definition.name.lowercased()
                if let code = model.book.outcomeCounts.keys.first(where: { $0.lowercased() == name }) { codesText = code }
            }
        }
    }

    private func split(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Data sources

struct DataSourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var specialNotes = ""

    var body: some View {
        Form {
            ForEach(SourceKind.allCases) { source in sourceSection(source) }

            if !model.book.dataIssues.isEmpty || !model.data.issues.isEmpty {
                Section("Data Checks") {
                    ForEach(model.data.issues) { issue in
                        Label("\(issue.relativePath): \(issue.message)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                    ForEach(model.book.dataIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Toggle("Ignore case, accents and extra spaces when comparing titles and genres",
                       isOn: Binding(get: { model.data.settings.lenientComparison },
                                     set: { v in model.updateSettings { $0.lenientComparison = v } }))
            } header: {
                Text("Comparing the Catalogue and the Control Sheet")
            } footer: {
                Text("Where a case's title, genre or registration date differ between the two exports, the case ID decides and the case is flagged (!).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $specialNotes)
                    .font(.body)
                    .frame(minHeight: 70)
                    .onChange(of: specialNotes) { _, text in
                        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        if lines != model.data.settings.specialNotes { model.updateSettings { $0.specialNotes = lines } }
                    }
            } header: {
                Text("Special Allocation Notes")
            } footer: {
                Text("One per line, e.g. “As per Protocol 67”. Allocation notes containing one of these are shown as special notes rather than as phrases missing from the analyst's expertise.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Workspace") {
                TextField("Title", text: Binding(get: { model.data.settings.title },
                                                 set: { v in model.updateSettings { $0.title = v } }))
                LabeledContent("Folder") {
                    HStack {
                        Text((model.workspaceURL?.path ?? "") as String).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Show in Finder") { model.revealInFinder() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { specialNotes = model.data.settings.specialNotes.joined(separator: "\n") }
    }

    @ViewBuilder
    private func sourceSection(_ source: SourceKind) -> some View {
        let mapping = model.data.mappings[source]
        let f = model.freshness(source)
        Section {
            if let f {
                LabeledContent("File", value: mapping?.originalFilename.isEmpty == false ? mapping!.originalFilename : source.csvPath)
                LabeledContent("Imported") {
                    Text(f.importedAt.map { "\($0.display) (\(Freshness.describe(age: f.age(today: model.today) ?? 0)))" } ?? "Unknown")
                        .foregroundStyle(model.isStale(f) ? Color.orange : Color.primary)
                }
                LabeledContent("Rows", value: "\(f.rows)")
                LabeledContent(source == .catalogue ? "Latest registration" : "Latest allocation",
                               value: f.latestDate?.display ?? "–")
                if let mapping {
                    DisclosureGroup("Columns") {
                        ForEach(source.fields) { field in
                            LabeledContent(field.title, value: mapping.header(field) ?? "Not mapped")
                        }
                        LabeledContent("Numeric dates", value: mapping.dateOrder.title)
                    }
                }
            } else {
                Text("Not imported yet.").foregroundStyle(.secondary)
            }
            HStack {
                Button(f == nil ? "Import…" : "Import New Export…") { model.beginImport(source) }
                if f != nil {
                    Button("Edit Columns…") { model.editMapping(source) }
                }
            }
        } header: {
            Text(source.title)
        } footer: {
            if let f, model.isStale(f) {
                Text("Imported more than \(model.staleAfterDays) days ago: workload figures may be out of date.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
