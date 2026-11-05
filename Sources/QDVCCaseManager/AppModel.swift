import AppKit
import CaseCore
import Observation
import SwiftUI

/// Which cases a case list shows.
enum CaseScope: String, CaseIterable, Identifiable, Hashable {
    case all, awaiting, allocated, refused, other, attention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Cases"
        case .awaiting: return "Awaiting Allocation"
        case .allocated: return "Allocated"
        case .refused: return "Refused & Returned"
        case .other: return "Projects & Other"
        case .attention: return "Needs Attention"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "tray.2"
        case .awaiting: return "hourglass"
        case .allocated: return "person.fill.checkmark"
        case .refused: return "arrow.uturn.backward.circle"
        case .other: return "folder"
        case .attention: return "exclamationmark.triangle"
        }
    }

    func includes(_ row: CaseRow) -> Bool {
        switch self {
        case .all: return true
        case .awaiting: return row.status == .awaiting
        case .allocated: return row.status == .allocated
        case .refused: return row.status == .refused
        case .other:
            switch row.status {
            case .project, .other: return true
            default: return false
            }
        case .attention: return row.needsAttention
        }
    }
}

/// A page of the main window, chosen in the sidebar.
enum Page: Hashable {
    case cases(CaseScope)
    case batch
    case project(String)
    case workload
    case rates
    case analysts
    case templates
    case outcomes
    case dataSources
}

/// How many months the dashboards cover.
enum Span: String, CaseIterable, Identifiable {
    case six, twelve, twentyFour, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .six: return "6 Months"
        case .twelve: return "12 Months"
        case .twentyFour: return "24 Months"
        case .all: return "All"
        }
    }

    var count: Int? {
        switch self {
        case .six: return 6
        case .twelve: return 12
        case .twentyFour: return 24
        case .all: return nil
        }
    }
}

/// An import waiting for its column mapping to be confirmed.
struct ImportDraft: Identifiable {
    let id = UUID()
    var source: SourceKind
    /// nil when only the mapping of the current file is being edited.
    var fileURL: URL?
    var table: CSVTable
    var mapping: ColumnMapping
}

/// A project being added or edited.
struct ProjectDraft: Identifiable {
    let id = UUID()
    var definition: ProjectDefinition
    var fileURL: URL?
    var table: CSVTable
    var isNew: Bool
}

enum ActiveSheet: Identifiable {
    case importSource(ImportDraft)
    case project(ProjectDraft)

    var id: UUID {
        switch self {
        case .importSource(let d): return d.id
        case .project(let d): return d.id
        }
    }
}

/// All app state and actions. Changes are written to the workspace a moment
/// after they are made, when the app is left, and on quit.
@Observable
@MainActor
final class AppModel {
    // MARK: Workspace contents

    private(set) var workspace: Workspace?
    private(set) var data = WorkspaceData()
    // Derived from `data` by `rebuild()`.
    private(set) var book = CaseBook()
    private(set) var prepared: [PreparedRow] = []
    private(set) var events: [WorkloadEvent] = []
    private(set) var metrics: [String: AnalystMetrics] = [:]
    private(set) var pendingLoad: [String: Int] = [:]
    private(set) var today = LocalDate.today()

    // MARK: View state

    var page: Page = .cases(.all)
    var selectedCaseIDs: Set<String> = []
    var searchText = ""
    /// "" for every genre.
    var genreFilter = ""
    var inspectorShown: Bool = Prefs.inspectorShown {
        didSet { Prefs.inspectorShown = inspectorShown }
    }
    var sheet: ActiveSheet?
    var errorMessage: String?
    /// After importing a control sheet: how many prepared rows have landed.
    var landedPrompt: Int?
    /// Set when the welcome window is asked for while a workspace is open.
    var welcomeRequested = false

    private(set) var recentWorkspaces: [URL] = Prefs.recentWorkspaces
    var showWelcomeAtLaunch: Bool = Prefs.showWelcomeAtLaunch {
        didSet { Prefs.showWelcomeAtLaunch = showWelcomeAtLaunch }
    }
    var supervisorName: String = Prefs.supervisorName {
        didSet { Prefs.supervisorName = supervisorName }
    }
    var staleAfterDays: Int = Prefs.staleAfterDays {
        didSet { Prefs.staleAfterDays = staleAfterDays }
    }

    @ObservationIgnored private var dirty: Set<WorkspacePart> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var startedUp = false

    var isOpen: Bool { workspace != nil }
    var workspaceURL: URL? { workspace?.root }

    var title: String {
        guard let url = workspaceURL else { return "QDVC Case Manager" }
        return data.settings.title.isEmpty ? url.lastPathComponent : data.settings.title
    }

    // MARK: Opening and closing

    /// Called by the welcome window when it first appears.
    func startUp() {
        guard !startedUp else { return }
        startedUp = true
        if !showWelcomeAtLaunch, let last = recentWorkspaces.first, Workspace.looksLikeWorkspace(last) {
            open(last)
        }
    }

    func chooseWorkspace() {
        guard let url = Platform.chooseFolder(title: "Open Workspace", prompt: "Open") else { return }
        open(url)
    }

    func newWorkspace() {
        guard let url = Platform.chooseFolder(title: "Choose an Empty Folder for the New Workspace", prompt: "Create")
        else { return }
        if Workspace.looksLikeWorkspace(url) {
            open(url)
            return
        }
        if !Workspace.isEmptyFolder(url) && !Platform.confirm(
            "“\(url.lastPathComponent)” is not empty.",
            "The workspace files will be added alongside what is already there.", button: "Create Here") {
            return
        }
        do {
            try Workspace(root: url).ensureLayout(title: url.lastPathComponent)
        } catch {
            errorMessage = "The workspace could not be created: \(error)"
            return
        }
        open(url)
    }

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        if !Workspace.looksLikeWorkspace(url) {
            let ok = Workspace.isEmptyFolder(url) || Platform.confirm(
                "“\(url.lastPathComponent)” is not a QDVC Case Manager workspace.",
                "Make it one? The app adds case-manager.yml and a few folders, and leaves everything else alone.",
                button: "Make Workspace")
            guard ok else { return }
            do {
                try Workspace(root: url).ensureLayout(title: url.lastPathComponent)
            } catch {
                errorMessage = "The workspace could not be created: \(error)"
                return
            }
        }
        flushSaves()
        let ws = Workspace(root: url)
        workspace = ws
        data = ws.load()
        today = LocalDate.today()
        selectedCaseIDs = []
        searchText = ""
        genreFilter = ""
        page = .cases(.all)
        rebuild()
        addRecent(url)
        if !data.issues.isEmpty {
            errorMessage = "Some files could not be read and will not be changed until they are fixed:\n"
                + data.issues.map { "• \($0.relativePath): \($0.message)" }.joined(separator: "\n")
        }
    }

    func closeWorkspace() {
        flushSaves()
        workspace = nil
        data = WorkspaceData()
        rebuild()
    }

    func reload() {
        guard let ws = workspace else { return }
        flushSaves()
        data = ws.load()
        today = LocalDate.today()
        rebuild()
    }

    /// When the app comes back to the front: pick up a `git pull` or an edit
    /// made in another editor.
    func checkForOutsideChanges() {
        guard let ws = workspace else { return }
        flushSaves()
        if ws.changedOutside() || today != LocalDate.today() { reload() }
    }

    func revealInFinder() {
        if let url = workspaceURL { Platform.reveal(url) }
    }

    private func addRecent(_ url: URL) {
        recentWorkspaces.removeAll { $0.standardizedFileURL == url }
        recentWorkspaces.insert(url, at: 0)
        recentWorkspaces = Array(recentWorkspaces.prefix(10))
        Prefs.recentWorkspaces = recentWorkspaces
    }

    func removeRecent(_ url: URL) {
        recentWorkspaces.removeAll { $0 == url }
        Prefs.recentWorkspaces = recentWorkspaces
    }

    func clearRecent() {
        recentWorkspaces = []
        Prefs.recentWorkspaces = []
    }

    // MARK: Changes and saving

    private func rebuild() {
        book = CaseBook.build(data)
        prepared = Batch.rows(data, book: book)
        events = Workload.events(book)
        metrics = Workload.metrics(events, today: today)
        pendingLoad = Batch.pendingLoad(prepared, settings: data.settings, book: book)
        let kept = selectedCaseIDs.filter { book.row($0) != nil }
        if kept != selectedCaseIDs { selectedCaseIDs = kept }
    }

    /// Applies a change to the workspace data, rebuilds what depends on it
    /// and saves the parts named shortly afterwards.
    func mutate(_ parts: WorkspacePart..., change: (inout WorkspaceData) -> Void) {
        guard isOpen else { return }
        change(&data)
        rebuild()
        dirty.formUnion(parts)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSaves()
        }
    }

    func flushSaves() {
        saveTask?.cancel()
        saveTask = nil
        guard let ws = workspace, !dirty.isEmpty else { return }
        let parts = dirty
        dirty = []
        for part in parts {
            do {
                try ws.save(part, from: data)
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    // MARK: Lookups

    var visibleRows: [CaseRow] {
        var rows = book.rows
        switch page {
        case .cases(let scope): rows = rows.filter { scope.includes($0) }
        case .project(let id): rows = rows.filter { $0.projects.contains(id) || $0.claimedBy.contains(id) }
        default: break
        }
        if !genreFilter.isEmpty { rows = rows.filter { $0.genre == genreFilter } }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            rows = rows.filter { r in
                [r.caseID, r.title, r.genre, r.analystKey, r.analystName, r.note, r.supervisor, r.status.title]
                    .contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
        return rows
    }

    func count(_ scope: CaseScope) -> Int { book.rows.filter { scope.includes($0) }.count }

    var pendingCount: Int { prepared.filter { $0.state == .pending }.count }
    var landedCount: Int { prepared.filter { $0.state != .pending }.count }

    /// Outcome codes in the control sheet that the workspace hasn't classified.
    var unclassifiedCodes: [String] {
        book.outcomeCounts.keys.filter { data.settings.outcome(for: $0) == nil }.sorted()
    }

    /// Templates named in refusals but not listed.
    var unknownTemplates: [String] {
        let known = Set(data.templates.map { $0.name.uppercased() })
        return book.templateCounts.keys.filter { !known.contains($0.uppercased()) }.sorted()
    }

    func project(_ id: String) -> ProjectWorksheet? { data.projects.first { $0.id == id } }
    func analyst(_ id: UUID) -> Analyst? { data.analysts.first { $0.id == id } }

    /// "Kofi Mensah (KM)" for a shorthand, or the shorthand.
    func analystLabel(_ shorthand: String) -> String {
        guard !shorthand.isEmpty else { return "" }
        if let a = book.analyst(for: shorthand) { return a.name.isEmpty ? a.shorthand : "\(a.name) (\(a.shorthand))" }
        return shorthand
    }

    func freshness(_ source: SourceKind) -> Freshness? { Freshness.of(source, data: data, book: book) }

    func isStale(_ f: Freshness) -> Bool { (f.age(today: today) ?? 0) > staleAfterDays }

    /// "Imported 3 days ago · up to 4 Nov 2026".
    func freshnessText(_ f: Freshness) -> String {
        var parts: [String] = []
        if let age = f.age(today: today) { parts.append("Imported \(Freshness.describe(age: age))") }
        if let latest = f.latestDate { parts.append("up to \(latest.display)") }
        return parts.isEmpty ? "\(f.rows) rows" : parts.joined(separator: " · ")
    }

    /// The months a dashboard covers, ending this month.
    func months(_ span: Span) -> [MonthKey] {
        if let n = span.count { return today.monthKey.trailing(n) }
        return Workload.allMonths(events, today: today)
    }

    func pivot(months: [MonthKey], includeInactive: Bool) -> WorkloadPivot {
        let pool = data.analysts.filter { includeInactive || $0.active }.map(\.shorthand)
        return Workload.pivot(events, months: months, analysts: pool)
    }

    /// Notes most often used for allocations in this genre: good search terms.
    func suggestedTerms(for genre: String) -> [String] {
        var counts: [String: Int] = [:]
        for r in book.rows where r.genre == genre && r.noteKind == .expertise { counts[r.note, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(8).map(\.key)
    }

    /// The next case waiting for a decision (oldest registration first) that
    /// isn't already in the batch.
    func nextAwaitingCase(after caseID: String) -> String? {
        let queue = book.rows.filter { $0.status == .awaiting && $0.inCatalogue && !$0.isInBatch && $0.caseID != caseID }
            .sorted { ($0.registrationSort, $0.caseID) < ($1.registrationSort, $1.caseID) }
        guard let current = book.row(caseID) else { return queue.first?.caseID }
        let key = (current.registrationSort, current.caseID)
        return (queue.first { ($0.registrationSort, $0.caseID) > key } ?? queue.first)?.caseID
    }

    /// Shows one case in the catalogue.
    func reveal(_ caseID: String) {
        page = .cases(.all)
        genreFilter = ""
        searchText = caseID
        selectedCaseIDs = [caseID]
    }

    // MARK: Importing the exports

    private func loadTable(_ url: URL) -> CSVTable? {
        guard let bytes = try? Data(contentsOf: url) else {
            errorMessage = "“\(url.lastPathComponent)” could not be read."
            return nil
        }
        let table = CSVTable(data: bytes)
        guard !table.headers.isEmpty else {
            errorMessage = "“\(url.lastPathComponent)” has no header row."
            return nil
        }
        return table
    }

    func beginImport(_ source: SourceKind) {
        guard isOpen, let url = Platform.chooseCSV(title: "Import \(source.title)"), let table = loadTable(url) else { return }
        var mapping: ColumnMapping
        if let existing = data.mappings[source], existing.fits(table.headers, for: source) {
            mapping = existing
        } else {
            mapping = ColumnMapping.guess(headers: table.headers, for: source)
            if let existing = data.mappings[source] {
                mapping.dateOrder = existing.dateOrder
                for (field, header) in existing.columns where table.index(of: header) != nil {
                    mapping.columns[field] = header
                }
            }
        }
        sheet = .importSource(ImportDraft(source: source, fileURL: url, table: table, mapping: mapping))
    }

    func editMapping(_ source: SourceKind) {
        guard let table = data.tables[source] else { return }
        let mapping = data.mappings[source] ?? ColumnMapping.guess(headers: table.headers, for: source)
        sheet = .importSource(ImportDraft(source: source, fileURL: nil, table: table, mapping: mapping))
    }

    func confirmImport(_ draft: ImportDraft) {
        guard let ws = workspace else { return }
        flushSaves()
        let landedBefore = Set(prepared.filter { $0.state != .pending }.map(\.caseID))
        var mapping = draft.mapping
        do {
            if let file = draft.fileURL {
                mapping.originalFilename = file.lastPathComponent
                mapping.importedAt = LocalDate.today().iso
                try ws.importSource(draft.source, from: file, mapping: mapping)
            } else {
                data.mappings[draft.source] = mapping
                try ws.save(.mapping(draft.source), from: data)
            }
        } catch {
            errorMessage = "The import failed: \(error)"
            return
        }
        sheet = nil
        reload()
        if draft.source == .controlSheet {
            let landed = prepared.filter { $0.state != .pending && !landedBefore.contains($0.caseID) }.count
            if landed > 0 { landedPrompt = landed }
        }
    }

    // MARK: Projects

    func beginNewProject() {
        guard isOpen, let url = Platform.chooseCSV(title: "Import Project Worksheet"), let table = loadTable(url) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        var def = ProjectDefinition(id: uniqueProjectID(ProjectDefinition.slug(name)), name: name)
        def.caseIDColumn = guessCaseIDColumn(table)
        def.colour = ProjectDefinition.colours[data.projects.count % ProjectDefinition.colours.count]
        sheet = .project(ProjectDraft(definition: def, fileURL: url, table: table, isNew: true))
    }

    func editProject(_ id: String) {
        guard let p = project(id) else { return }
        sheet = .project(ProjectDraft(definition: p.definition, fileURL: nil, table: p.table, isNew: false))
    }

    func updateWorksheet(_ id: String) {
        guard let p = project(id), let url = Platform.chooseCSV(title: "Update \(p.definition.name) Worksheet"),
              let table = loadTable(url) else { return }
        var def = p.definition
        if table.index(of: def.caseIDColumn) == nil { def.caseIDColumn = guessCaseIDColumn(table) }
        sheet = .project(ProjectDraft(definition: def, fileURL: url, table: table, isNew: false))
    }

    func confirmProject(_ draft: ProjectDraft) {
        guard let ws = workspace else { return }
        flushSaves()
        var def = draft.definition
        if let file = draft.fileURL {
            def.originalFilename = file.lastPathComponent
            def.importedAt = LocalDate.today().iso
        }
        do {
            try ws.importWorksheet(def, from: draft.fileURL)
        } catch {
            errorMessage = "The project could not be saved: \(error)"
            return
        }
        sheet = nil
        reload()
        page = .project(def.id)
    }

    func deleteProject(_ id: String) {
        guard let ws = workspace, let p = project(id),
              Platform.confirm("Remove the project “\(p.definition.name)”?",
                               "Its worksheet copy and settings are removed from the workspace (Git keeps the history).",
                               button: "Remove") else { return }
        do {
            try ws.deleteProject(id)
        } catch {
            errorMessage = "The project could not be removed: \(error)"
        }
        sheet = nil
        reload()
        page = .cases(.all)
    }

    private func uniqueProjectID(_ base: String) -> String {
        var id = base
        var n = 2
        while data.projects.contains(where: { $0.id == id }) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    /// The worksheet column holding the most known case IDs.
    func guessCaseIDColumn(_ table: CSVTable) -> String {
        var best = (count: 0, header: "")
        for (i, h) in table.headers.enumerated() {
            let n = table.rows.indices.filter { book.index[CaseKey.normalise(table.value($0, i))] != nil }.count
            if n > best.count { best = (n, h) }
        }
        if best.count > 0 { return best.header }
        return ColumnMapping.guess(headers: table.headers, for: .catalogue).header(.caseID) ?? table.headers.first ?? ""
    }

    // MARK: Analysts

    @discardableResult
    func addAnalyst(shorthand: String = "") -> UUID {
        let a = Analyst(shorthand: shorthand.isEmpty ? "NEW" : shorthand)
        mutate(.analysts) { $0.analysts.append(a) }
        return a.id
    }

    func updateAnalyst(_ id: UUID, _ change: (inout Analyst) -> Void) {
        guard let i = data.analysts.firstIndex(where: { $0.id == id }) else { return }
        mutate(.analysts) { change(&$0.analysts[i]) }
    }

    func deleteAnalyst(_ id: UUID) {
        guard let a = analyst(id),
              Platform.confirm("Delete \(a.displayName)?",
                               "Cases allocated to \(a.shorthand) will show the shorthand as unknown. To keep the history, untick “Active in the pool” instead.",
                               button: "Delete") else { return }
        mutate(.analysts) { $0.analysts.removeAll { $0.id == id } }
    }

    func analystBinding<T>(_ id: UUID, _ keyPath: WritableKeyPath<Analyst, T>, default value: T) -> Binding<T> {
        Binding(
            get: { [weak self] in self?.data.analysts.first { $0.id == id }?[keyPath: keyPath] ?? value },
            set: { [weak self] v in self?.updateAnalyst(id) { $0[keyPath: keyPath] = v } })
    }

    // MARK: Templates, outcome codes, settings

    func addTemplate(_ name: String = "NEW_TEMPLATE") {
        mutate(.templates) { $0.templates.append(ReturnTemplate(name: name)) }
    }

    func updateTemplate(_ id: UUID, _ change: (inout ReturnTemplate) -> Void) {
        guard let i = data.templates.firstIndex(where: { $0.id == id }) else { return }
        mutate(.templates) { change(&$0.templates[i]) }
    }

    func deleteTemplate(_ id: UUID) {
        mutate(.templates) { $0.templates.removeAll { $0.id == id } }
    }

    func templateBinding(_ id: UUID, _ keyPath: WritableKeyPath<ReturnTemplate, String>) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.data.templates.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { [weak self] v in self?.updateTemplate(id) { $0[keyPath: keyPath] = v } })
    }

    func updateOutcome(_ code: String, _ change: (inout OutcomeCode) -> Void) {
        mutate(.settings) { d in
            if let i = d.settings.outcomes.firstIndex(where: { $0.code == code }) {
                change(&d.settings.outcomes[i])
            } else {
                var o = OutcomeCode(code: code, kind: .other)
                change(&o)
                d.settings.outcomes.append(o)
            }
        }
    }

    func outcomeBinding<T>(_ code: String, _ keyPath: WritableKeyPath<OutcomeCode, T>, default value: T) -> Binding<T> {
        Binding(
            get: { [weak self] in self?.data.settings.outcomes.first { $0.code == code }?[keyPath: keyPath] ?? value },
            set: { [weak self] v in self?.updateOutcome(code) { $0[keyPath: keyPath] = v } })
    }

    func removeOutcome(_ code: String) {
        mutate(.settings) { $0.settings.outcomes.removeAll { $0.code == code } }
    }

    func updateSettings(_ change: (inout WorkspaceSettings) -> Void) {
        mutate(.settings) { change(&$0.settings) }
    }

    // MARK: Decisions and the batch

    func decision(_ caseID: String) -> CaseDecision { data.decisions[caseID] ?? CaseDecision() }

    func updateDecision(_ caseID: String, _ change: (inout CaseDecision) -> Void) {
        mutate(.decisions) { d in
            var x = d.decisions[caseID] ?? CaseDecision()
            change(&x)
            x.updated = LocalDate.today().iso
            d.decisions[caseID] = x.isEmpty ? nil : x
        }
    }

    func toggleShortlist(_ caseID: String, _ shorthand: String) {
        updateDecision(caseID) { d in
            if let i = d.shortlist.firstIndex(of: shorthand) { d.shortlist.remove(at: i) } else { d.shortlist.append(shorthand) }
        }
    }

    /// Adds (or updates) the prepared row for a case.
    func prepare(_ caseID: String, outcome: String, analyst: String, note: String, supervisor: String, date: LocalDate) {
        let existing = decision(caseID)
        let order = existing.isPrepared ? existing.order : Batch.nextOrder(data)
        if !supervisor.isEmpty && supervisorName.isEmpty { supervisorName = supervisor }
        updateDecision(caseID) { d in
            d.outcome = outcome
            d.analyst = analyst
            d.note = note
            d.supervisor = supervisor
            d.date = date.iso
            d.order = order
        }
    }

    func unprepare(_ caseID: String) {
        updateDecision(caseID) { $0.unprepare() }
    }

    /// Takes rows the control sheet now has out of the batch.
    func removeLanded() {
        let ids = prepared.filter { $0.state != .pending }.map(\.caseID)
        guard !ids.isEmpty else { return }
        mutate(.decisions) { d in
            for id in ids {
                d.decisions[id]?.unprepare()
                if d.decisions[id]?.isEmpty == true { d.decisions[id] = nil }
            }
        }
    }

    func clearBatch() {
        let ids = prepared.map(\.caseID)
        guard !ids.isEmpty, Platform.confirm("Clear the batch?", "All \(ids.count) prepared rows are removed. Shortlists are kept.",
                                             button: "Clear Batch") else { return }
        mutate(.decisions) { d in
            for id in ids {
                d.decisions[id]?.unprepare()
                if d.decisions[id]?.isEmpty == true { d.decisions[id] = nil }
            }
        }
    }

    /// Moves a prepared row up (-1) or down (+1) the batch.
    func moveBatchRow(_ caseID: String, by delta: Int) {
        guard let i = prepared.firstIndex(where: { $0.caseID == caseID }), prepared.indices.contains(i + delta) else { return }
        var order = prepared.map(\.caseID)
        order.swapAt(i, i + delta)
        mutate(.decisions) { d in
            for (n, id) in order.enumerated() { d.decisions[id]?.order = n + 1 }
        }
    }

    var batchHeaders: [String] { Batch.headers(data) }

    /// Copies the rows still to paste (or `only` these) for the upstream sheet.
    func copyBatch(tabSeparated: Bool = true, includeHeader: Bool = false, only: Set<String>? = nil) {
        let rows = prepared.filter { only?.contains($0.caseID) ?? ($0.state == .pending) }
        Platform.copy(Batch.pasteText(rows, headers: batchHeaders, tabSeparated: tabSeparated, includeHeader: includeHeader))
    }

    // MARK: Exports

    func export(_ text: String, name: String) {
        do {
            try Platform.save(text, suggestedName: name)
        } catch {
            errorMessage = "The file could not be saved: \(error)"
        }
    }

    func exportVisibleCases() {
        export(Export.cases(visibleRows, book: book, projects: data.projects.map(\.definition)),
               name: "cases-\(today.iso).csv")
    }
}
