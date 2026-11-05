import CaseCore
import SwiftUI

enum DecisionWindow {
    static let id = "decision"
}

/// How the candidate analysts are ordered.
enum AnalystSort: String, CaseIterable, Identifiable {
    case relevance, lightMonth, lightYear, name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance: return "Best Match"
        case .lightMonth: return "Lightest This Month"
        case .lightYear: return "Lightest Past 12 Months"
        case .name: return "Name"
        }
    }
}

/// An analyst as a candidate for the case in view.
struct Candidate: Identifiable {
    var analyst: Analyst
    var matchedTerms: Int
    var ranges: [Range<Int>]
    var metrics: AnalystMetrics
    var inBatch: Int
    var genreCount: Int
    var shortlisted: Bool
    var id: UUID { analyst.id }
}

/// One window per case (or one that moves through the queue): search the
/// analysts' expertise, compare their workload, shortlist, and prepare the
/// control sheet row.
struct DecisionSupportView: View {
    @Binding var caseID: String?
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var query = ""
    @State private var matchAll = true
    @State private var activeOnly = true
    @State private var sort: AnalystSort = .relevance

    // The row being prepared.
    @State private var outcome = "a"
    @State private var analyst = ""
    @State private var note = ""
    @State private var supervisor = ""
    @State private var date = Date()

    var body: some View {
        Group {
            if let id = caseID, model.isOpen, let row = model.book.row(id) {
                content(row)
            } else {
                ContentUnavailableView("No Case", systemImage: "doc.questionmark",
                                       description: Text(model.isOpen ? "This case is no longer in the workspace." : "Open a workspace first."))
            }
        }
        .navigationTitle(caseID.map { "Decision Support — \($0)" } ?? "Decision Support")
        .onChange(of: caseID, initial: true) { _, _ in load() }
    }

    private func content(_ row: CaseRow) -> some View {
        VStack(spacing: 0) {
            CaseSummaryHeader(row: row)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    searchBar(row)
                    Divider()
                    candidateList(row)
                }
                .frame(minWidth: 460, maxWidth: .infinity)
                Divider()
                decisionPanel(row)
                    .frame(width: 340)
            }
        }
    }

    // MARK: Searching

    private func searchBar(_ row: CaseRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search expertise: words or \"quoted phrases\"", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Picker("", selection: $matchAll) {
                    Text("All terms").tag(true)
                    Text("Any term").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle("Active analysts only", isOn: $activeOnly).toggleStyle(.checkbox)
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(AnalystSort.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 230)
            }
            .controlSize(.small)
            let suggestions = model.suggestedTerms(for: row.genre)
            if !suggestions.isEmpty {
                HStack(spacing: 6) {
                    Text("Often used for \(row.genre):").font(.caption).foregroundStyle(.secondary).fixedSize()
                    ChipRow(items: suggestions) { term in
                        let phrase = term.contains(" ") ? "\"\(term)\"" : term
                        query = query.isEmpty ? phrase : query + " " + phrase
                    }
                }
            }
        }
        .padding(12)
    }

    private func candidates(_ row: CaseRow) -> [Candidate] {
        let q = ExpertiseQuery(query, matchAll: matchAll)
        let shortlist = Set(model.decision(row.caseID).shortlist)
        let list = model.data.analysts.compactMap { a -> Candidate? in
            let pinned = shortlist.contains(a.shorthand)
            guard pinned || ((!activeOnly || a.active) && q.accepts(a.expertise)) else { return nil }
            let m = model.metrics[a.shorthand] ?? {
                var x = AnalystMetrics()
                x.monthly = Array(repeating: 0, count: 12)
                return x
            }()
            return Candidate(analyst: a, matchedTerms: q.matchedTerms(in: a.expertise), ranges: q.matches(in: a.expertise),
                             metrics: m, inBatch: model.pendingLoad[a.shorthand] ?? 0,
                             genreCount: m.genres[row.genre] ?? 0, shortlisted: pinned)
        }
        return list.sorted { a, b in
            let la = a.metrics.thisMonth + a.inBatch, lb = b.metrics.thisMonth + b.inBatch
            switch sort {
            case .relevance:
                if a.matchedTerms != b.matchedTerms { return a.matchedTerms > b.matchedTerms }
                if a.genreCount != b.genreCount { return a.genreCount > b.genreCount }
                return la < lb
            case .lightMonth:
                return la == lb ? a.metrics.past12 < b.metrics.past12 : la < lb
            case .lightYear:
                return a.metrics.past12 == b.metrics.past12 ? la < lb : a.metrics.past12 < b.metrics.past12
            case .name:
                return a.analyst.displayName.localizedStandardCompare(b.analyst.displayName) == .orderedAscending
            }
        }
    }

    @ViewBuilder
    private func candidateList(_ row: CaseRow) -> some View {
        let all = candidates(row)
        let shortlisted = all.filter(\.shortlisted)
        let others = all.filter { !$0.shortlisted }
        let active = model.data.analysts.filter(\.active)
        let avgMonth = active.isEmpty ? 0 : Double(active.reduce(0) { $0 + (model.metrics[$1.shorthand]?.thisMonth ?? 0) }) / Double(active.count)
        let avgYear = active.isEmpty ? 0 : Double(active.reduce(0) { $0 + (model.metrics[$1.shorthand]?.past12 ?? 0) }) / Double(active.count)
        if model.data.analysts.isEmpty {
            ContentUnavailableView("No Analysts", systemImage: "person.2",
                                   description: Text("Add the analysts and their expertise in Analysts (main window)."))
        } else {
            List {
                if !shortlisted.isEmpty {
                    Section("Shortlist") {
                        ForEach(shortlisted) { c in card(c, row: row, avgMonth: avgMonth, avgYear: avgYear) }
                    }
                }
                Section {
                    if others.isEmpty {
                        Text(query.isEmpty ? "No other analysts." : "No other analyst's expertise matches.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(others) { c in card(c, row: row, avgMonth: avgMonth, avgYear: avgYear) }
                } header: {
                    HStack {
                        Text(query.isEmpty ? "Analysts" : "Matching Analysts (\(others.count))")
                        Spacer()
                        Text(String(format: "Team average: %.1f this month · %.0f in 12 months", avgMonth, avgYear))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func card(_ c: Candidate, row: CaseRow, avgMonth: Double, avgYear: Double) -> some View {
        AnalystCard(candidate: c, genre: row.genre, avgMonth: avgMonth, avgYear: avgYear,
                    chosen: analyst == c.analyst.shorthand,
                    toggleShortlist: { model.toggleShortlist(row.caseID, c.analyst.shorthand) },
                    choose: { choose(c.analyst) })
    }

    // MARK: The row being prepared

    private var outcomeCode: OutcomeCode? { model.data.settings.outcome(for: outcome) }
    private var needsAnalyst: Bool { outcomeCode.map { $0.kind == .allocated || $0.kind == .project } ?? true }

    private func noteOptions() -> [String] {
        switch outcomeCode?.kind {
        case .refused?:
            return model.data.templates.map(\.name)
        default:
            var options: [String] = []
            if let a = model.book.analyst(for: analyst) {
                let phrases = ExpertisePhrases.split(a.expertise)
                let q = ExpertiseQuery(query, matchAll: false)
                options = phrases.filter { q.matchedTerms(in: $0) > 0 } + phrases.filter { q.matchedTerms(in: $0) == 0 }
            }
            return options + model.data.settings.specialNotes
        }
    }

    private func decisionPanel(_ row: CaseRow) -> some View {
        let decided = row.status != .awaiting
        let existing = model.decision(row.caseID)
        return VStack(alignment: .leading, spacing: 0) {
            Form {
                if decided {
                    Section {
                        Label("Already decided in the control sheet", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                        LabeledContent("Outcome", value: row.latest?.outcome ?? "")
                        LabeledContent("Analyst", value: model.analystLabel(row.analystKey))
                        LabeledContent("Note", value: row.note)
                        LabeledContent("Date", value: row.allocationDate?.display ?? "")
                    }
                } else {
                    Section(existing.isPrepared ? "Row in the Batch" : "Prepare the Control Sheet Row") {
                        Picker("Outcome", selection: $outcome) {
                            ForEach(model.data.settings.outcomes) { o in
                                Text("\(o.code) — \(o.displayLabel)").tag(o.code)
                            }
                        }
                        if needsAnalyst {
                            Picker("Analyst", selection: $analyst) {
                                Text("None").tag("")
                                ForEach(model.data.analysts.filter { $0.active || $0.shorthand == analyst }) { a in
                                    Text("\(a.shorthand) — \(a.displayName)").tag(a.shorthand)
                                }
                            }
                        }
                        HStack {
                            TextField(outcomeCode?.kind == .refused ? "Template" : "Note", text: $note)
                            Menu {
                                ForEach(noteOptions(), id: \.self) { option in
                                    Button(option) { note = option }
                                }
                            } label: {
                                Image(systemName: "text.badge.plus")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help(outcomeCode?.kind == .refused ? "Choose a return-to-sender template"
                                                                : "Choose a phrase from the analyst's expertise, or a special note")
                        }
                        TextField("Supervisor", text: $supervisor)
                        DatePicker("Allocation date", selection: $date, displayedComponents: .date)
                    }
                    Section("As It Will Be Pasted") {
                        Text(previewText(row))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            if !decided {
                VStack(spacing: 8) {
                    Button {
                        save(row)
                        if let next = model.nextAwaitingCase(after: row.caseID) { caseID = next }
                    } label: {
                        Text(existing.isPrepared ? "Update & Next Case" : "Add to Batch & Next Case").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    HStack {
                        Button(existing.isPrepared ? "Update Row" : "Add to Batch") { save(row) }
                            .disabled(!canSave)
                        Spacer()
                        if existing.isPrepared {
                            Button("Remove from Batch", role: .destructive) { model.unprepare(row.caseID); load() }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            Divider().padding(.top, 10)
            HStack {
                Label("\(model.pendingCount) row\(model.pendingCount == 1 ? "" : "s") in the batch", systemImage: "tray.full")
                    .font(.callout)
                Spacer()
                Button("Skip") {
                    if let next = model.nextAwaitingCase(after: row.caseID) { caseID = next }
                }
                .help("Go to the next case awaiting allocation")
                Button("Show Batch") {
                    model.page = .batch
                    openWindow(id: MainWindowID.main)
                }
            }
            .padding(12)
        }
    }

    private var canSave: Bool {
        !outcome.isEmpty && (!needsAnalyst || !analyst.isEmpty || outcomeCode?.kind == .project)
    }

    private func previewText(_ row: CaseRow) -> String {
        let headers = model.batchHeaders
        let probe = model.prepared.first { $0.caseID == row.caseID }
        // Show what is being edited, not only what is saved.
        let values: [String] = headers.map { h -> String in
            let m = model.data.mappings[.controlSheet] ?? ColumnMapping()
            func isField(_ f: MappedField) -> Bool { m.header(f).map { $0.caseInsensitiveCompare(h) == .orderedSame } ?? (h == f.title) }
            if isField(.outcome) { return outcome }
            if isField(.analyst) { return needsAnalyst ? analyst : "" }
            if isField(.note) { return note }
            if isField(.supervisor) { return supervisor }
            if let p = probe, let i = headers.firstIndex(of: h), i < p.values.count, !isField(.allocationDate) { return p.values[i] }
            if isField(.caseID) { return row.caseID }
            if isField(.title) { return row.title }
            if isField(.genre) { return row.genre }
            if isField(.registrationDate) { return row.registrationDate?.iso ?? row.registrationText }
            if isField(.allocationDate) { return LocalDate(date: date).iso }
            return ""
        }
        return zip(headers, values).map { "\($0): \($1)" }.joined(separator: "\n")
    }

    // MARK: Actions

    private func load() {
        guard let id = caseID else { return }
        let d = model.decision(id)
        if d.isPrepared {
            outcome = d.outcome
            analyst = d.analyst
            note = d.note
            supervisor = d.supervisor.isEmpty ? model.supervisorName : d.supervisor
            date = LocalDate(iso: d.date)?.date ?? Date()
        } else {
            outcome = model.data.settings.outcomes.first { $0.kind == .allocated }?.code ?? "a"
            analyst = ""
            note = ""
            supervisor = model.supervisorName
            date = Date()
        }
    }

    private func choose(_ a: Analyst) {
        if outcomeCode?.kind != .allocated && outcomeCode?.kind != .project {
            outcome = model.data.settings.outcomes.first { $0.kind == .allocated }?.code ?? "a"
        }
        analyst = a.shorthand
        if let match = ExpertiseQuery(query, matchAll: false).firstMatch(in: a.expertise) {
            // The whole phrase the match is in reads better as a note.
            note = ExpertisePhrases.split(a.expertise).first { $0.range(of: match, options: .caseInsensitive) != nil } ?? match
        }
    }

    private func save(_ row: CaseRow) {
        model.prepare(row.caseID, outcome: outcome, analyst: needsAnalyst ? analyst : "", note: note,
                      supervisor: supervisor.trimmingCharacters(in: .whitespaces), date: LocalDate(date: date))
    }
}

/// The case at the top of the window, with how current the data is.
struct CaseSummaryHeader: View {
    @Environment(AppModel.self) private var model
    var row: CaseRow

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if row.hasWarning { Emblem(kind: .warning, size: 16) }
                    Text(row.caseID).font(.system(.title2, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    StatusCell(row: row)
                }
                Text(row.title).font(.title3).lineLimit(2).textSelection(.enabled)
                HStack(spacing: 14) {
                    Label(row.genre.isEmpty ? "No genre" : row.genre, systemImage: "tag")
                    Label("Registered \(row.registrationDate?.display ?? row.registrationText)", systemImage: "calendar")
                    ProjectTags(row: row)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if !row.flags.isEmpty {
                    Text(row.flags.map(Export.describe).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Workload figures from").font(.caption).foregroundStyle(.secondary)
                if let f = model.freshness(.controlSheet) {
                    Label(model.freshnessText(f), systemImage: model.isStale(f) ? "exclamationmark.triangle.fill" : "clock")
                        .font(.caption)
                        .foregroundStyle(model.isStale(f) ? Color.orange : Color.secondary)
                } else {
                    Text("No control sheet imported").font(.caption).foregroundStyle(.orange)
                }
                if model.pendingCount > 0 {
                    Text("plus \(model.pendingCount) prepared in the batch").font(.caption).foregroundStyle(.teal)
                }
            }
        }
        .padding(16)
    }
}

/// One analyst in the candidate list.
struct AnalystCard: View {
    var candidate: Candidate
    var genre: String
    var avgMonth: Double
    var avgYear: Double
    var chosen: Bool
    var toggleShortlist: () -> Void
    var choose: () -> Void
    @State private var expanded = false

    var body: some View {
        let a = candidate.analyst
        let m = candidate.metrics
        HStack(alignment: .top, spacing: 10) {
            Button(action: toggleShortlist) {
                Image(systemName: candidate.shortlisted ? "star.fill" : "star")
                    .foregroundStyle(candidate.shortlisted ? Color.yellow : Color.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help(candidate.shortlisted ? "Remove from the shortlist" : "Add to the shortlist")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(a.displayName).font(.headline)
                    Text(a.shorthand).font(Style.monoSmall).foregroundStyle(.secondary)
                    if !a.active {
                        Text("Inactive").font(.caption2).padding(.horizontal, 5)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                    if chosen {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Chosen for this case")
                    }
                }
                HighlightedText(text: a.expertise.isEmpty ? "No expertise recorded." : a.expertise, ranges: candidate.ranges)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 3)
                    .onTapGesture { expanded.toggle() }
                HStack(spacing: 14) {
                    Sparkline(values: m.monthly)
                    Text("\(candidate.genreCount) \(genre.isEmpty ? "same genre" : genre) in 12 mo")
                    if let last = m.lastAllocation { Text("Last allocated \(last.display)") }
                    Spacer()
                    Button("Choose", action: choose).controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(m.thisMonth)").font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Double(m.thisMonth + candidate.inBatch) > avgMonth * 1.25 && avgMonth > 0 ? Color.orange : Color.primary)
                    if candidate.inBatch > 0 {
                        Text("+\(candidate.inBatch)").font(.callout.weight(.semibold)).foregroundStyle(.teal)
                            .help("\(candidate.inBatch) more in the batch, not yet in the control sheet")
                    }
                }
                Text("this month").font(.caption2).foregroundStyle(.secondary)
                Text("\(m.past12)").font(.title3.weight(.medium)).monospacedDigit()
                    .foregroundStyle(Double(m.past12) > avgYear * 1.25 && avgYear > 0 ? Color.orange : Color.primary)
                    .padding(.top, 4)
                Text("past 12 months").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
