import AppKit
import CaseCore
import Observation
import SwiftUI

/// Which cases a case list shows.
enum CaseScope: String, CaseIterable, Identifiable, Hashable {
    case all, awaiting, allocated, refused, special, other, attention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Cases"
        case .awaiting: return "Awaiting Allocation"
        case .allocated: return "Allocated"
        case .refused: return "Refused & Returned"
        case .special: return "Special"
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
        case .special: return "star.circle"
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
        case .special:
            if case .special = row.status { return true }
            return false
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

/// Work in progress, for the status bar.
struct Activity: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var started = Date()
}

/// Work done, and how long it took.
struct ActivityRecord: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var finished: Date
    var duration: TimeInterval
    /// Main-thread work holds up the window while it runs.
    var onMainThread: Bool
}

/// A moment the app stopped responding.
struct Stall: Identifiable, Equatable {
    let id = UUID()
    var at: Date
    var duration: TimeInterval
    var context: String
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
    private(set) var today = LocalDate.today()
    /// Everything derived from `data`: the joined cases, the batch,
    /// workload, and each dashboard's figures for every period. Computed in
    /// the background by `rebuild()` whenever the data changes; the pages
    /// only look things up.
    private(set) var derived = Derived()
    /// Whether a newer `derived` is being computed.
    private(set) var isUpdating = false
    /// Sidebar counts for the selected year.
    private(set) var scopeCounts: [CaseScope: Int] = [:]

    var book: CaseBook { derived.book }
    var prepared: [PreparedRow] { derived.prepared }
    var events: [WorkloadEvent] { derived.events }
    var metrics: [String: AnalystMetrics] { derived.metrics }
    var pendingLoad: [String: Int] { derived.pendingLoad }
    /// Years of registration with how many cases (and how many awaiting),
    /// newest first; always includes this year.
    var yearSummaries: [YearSummary] { derived.years }
    /// Cases missing from each project's worksheet (all years).
    var missingCounts: [String: Int] { derived.missingCounts }

    // MARK: View state

    var page: Page = .cases(.all) {
        didSet {
            guard page != oldValue else { return }
            lastAction = "Opened \(pageTitle)"
            refreshCaseRows()
        }
    }
    var selectedCaseIDs: Set<String> = []
    /// What the case search field holds. The table follows it a moment
    /// after typing pauses, not on every keystroke.
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            lastAction = searchText.isEmpty ? "Cleared the search" : "Searched cases"
            scheduleFilter()
        }
    }
    /// The case table's rows: filtered and sorted when what they depend on
    /// changes, not every time a view is drawn.
    private(set) var caseRows: [CaseRow] = []
    var caseSort: [KeyPathComparator<CaseRow>] = [KeyPathComparator(\CaseRow.registrationSort, order: .reverse)] {
        didSet { refreshCaseRows() }
    }
    /// The case shown in the Decision Support window. There is one such
    /// window, which moves from case to case: a window per case, left
    /// open, each redrawing with every change, slowed the app over a
    /// session.
    var decisionCaseID: String?

    // MARK: Activity (the status bar)

    /// Work in progress, shown in the status bar.
    private(set) var activities: [Activity] = []
    /// Recent work and how long it took, newest first.
    private(set) var activityLog: [ActivityRecord] = []
    /// Moments the app stopped responding, newest first.
    private(set) var stalls: [Stall] = []
    @ObservationIgnored private var lastAction = "Started"
    @ObservationIgnored private var stallMonitor: StallMonitor?
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildActivity: UUID?
    /// The registration year the case tables show (`YearSummary.undated`
    /// for cases without a readable date). There is deliberately no "all
    /// years", to keep the tables manageable.
    var selectedYear: Int = LocalDate.today().year {
        didSet {
            guard selectedYear != oldValue else { return }
            lastAction = "Chose the year \(selectedYear == YearSummary.undated ? "No date" : String(selectedYear))"
            recount()
            refreshCaseRows()
        }
    }
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
    var supervisorName: String = Prefs.supervisorName {
        didSet { Prefs.supervisorName = supervisorName }
    }
    var staleAfterDays: Int = Prefs.staleAfterDays {
        didSet { Prefs.staleAfterDays = staleAfterDays }
    }

    @ObservationIgnored private var dirty: Set<WorkspacePart> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var computeTask: Task<Void, Never>?
    /// Counts rebuilds, so only the newest background result is used.
    @ObservationIgnored private var generation = 0
    /// Run once the rebuild in progress has been applied.
    @ObservationIgnored private var afterRebuild: [() -> Void] = []
    @ObservationIgnored private var startedUp = false

    var isOpen: Bool { workspace != nil }
    var workspaceURL: URL? { workspace?.root }

    var title: String {
        guard let url = workspaceURL else { return "QDVC Case Manager" }
        return data.settings.title.isEmpty ? url.lastPathComponent : data.settings.title
    }

    // MARK: Opening and closing

    /// Called by the welcome window when it first appears: reopens the
    /// last workspace, if it is still there. Otherwise the welcome window
    /// stays up.
    func startUp() {
        guard !startedUp else { return }
        startedUp = true
        startStallMonitor()
        if let last = recentWorkspaces.first, Workspace.looksLikeWorkspace(last) {
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
        data = measure("Opened the workspace") { ws.load() }
        today = LocalDate.today()
        derived = Derived(today: today)
        selectedCaseIDs = []
        searchText = ""
        page = .cases(.all)
        data.templates = ReturnTemplate.sorted(data.templates)
        rebuild()
        selectedYear = today.year
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
        generation += 1
        computeTask?.cancel()
        derived = Derived(today: today)
        isUpdating = false
        if let a = rebuildActivity {
            end(a)
            rebuildActivity = nil
        }
        recount()
        refreshCaseRows()
    }

    func reload(then: (() -> Void)? = nil) {
        guard let ws = workspace else { return }
        flushSaves()
        data = measure("Read the workspace from disk") { ws.load() }
        data.templates = ReturnTemplate.sorted(data.templates)
        today = LocalDate.today()
        rebuild(then: then)
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

    /// Recomputes `derived` from the current data off the main thread, so
    /// the window never stops responding. The data is a value, so the
    /// background work reads a snapshot; if the data changes again first,
    /// the older result is thrown away. `then` runs once the result is in.
    private func rebuild(then: (() -> Void)? = nil) {
        rebuildTask?.cancel()
        rebuildTask = nil
        generation += 1
        let gen = generation
        let snapshot = data
        let day = today
        if let then { afterRebuild.append(then) }
        isUpdating = true
        if rebuildActivity == nil { rebuildActivity = begin("Updating figures") }
        computeTask?.cancel()
        computeTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Derived.compute(snapshot, today: day)
            }.value
            guard let self, gen == self.generation else { return }
            self.apply(result)
        }
    }

    private func apply(_ result: Derived) {
        derived = result
        isUpdating = false
        if let a = rebuildActivity {
            end(a)
            rebuildActivity = nil
        }
        let kept = selectedCaseIDs.filter { result.book.row($0) != nil }
        if kept != selectedCaseIDs { selectedCaseIDs = kept }
        recount()
        refreshCaseRows()
        let pending = afterRebuild
        afterRebuild = []
        for f in pending { f() }
    }

    /// The sidebar counts for the selected year.
    private func recount() {
        var counts: [CaseScope: Int] = [:]
        for r in book.rows where inSelectedYear(r) {
            for scope in CaseScope.allCases where scope.includes(r) { counts[scope, default: 0] += 1 }
        }
        scopeCounts = counts
    }

    func inSelectedYear(_ row: CaseRow) -> Bool {
        (row.registrationDate?.year ?? YearSummary.undated) == selectedYear
    }

    /// Rebuilds a moment after the last of a run of changes (typing), so
    /// each keystroke doesn't recompute every case.
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    /// Applies a change to the workspace data, rebuilds what depends on it
    /// (at once, or with `deferRebuild` once typing pauses) and saves the
    /// parts named shortly afterwards.
    func mutate(_ parts: WorkspacePart..., deferRebuild: Bool = false, change: (inout WorkspaceData) -> Void) {
        guard isOpen else { return }
        change(&data)
        if deferRebuild { scheduleRebuild() } else { rebuild() }
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
        measure("Saved \(parts.count) file\(parts.count == 1 ? "" : "s")") {
            for part in parts {
                do {
                    try ws.save(part, from: data)
                } catch {
                    errorMessage = String(describing: error)
                }
            }
        }
    }

    // MARK: The case table

    private func scheduleFilter() {
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshCaseRows()
        }
    }

    /// Filters and sorts the case table's rows. The table is only given a
    /// new array when the rows really changed.
    func refreshCaseRows() {
        filterTask?.cancel()
        filterTask = nil
        guard case .cases = page else { return }
        let rows = measure("Filtered and sorted the cases", onlyIfOver: 0.02) { visibleRows.sorted(using: caseSort) }
        if rows != caseRows { caseRows = rows }
    }

    func openDecision(_ caseID: String, with openWindow: OpenWindowAction) {
        decisionCaseID = caseID
        lastAction = "Opened \(caseID) in Decision Support"
        openWindow(id: DecisionWindow.id)
    }

    // MARK: Activity

    var pageTitle: String {
        switch page {
        case .cases(let scope): return scope.title
        case .batch: return "Batch"
        case .project(let id): return project(id)?.definition.name ?? "a project"
        case .workload: return "Workload"
        case .rates: return "Acceptance & Refusal"
        case .analysts: return "Analysts"
        case .templates: return "Return Templates"
        case .outcomes: return "Outcome Codes"
        case .dataSources: return "Data Sources"
        }
    }

    func begin(_ title: String) -> UUID {
        let a = Activity(title: title)
        activities.append(a)
        return a.id
    }

    func end(_ id: UUID) {
        guard let i = activities.firstIndex(where: { $0.id == id }) else { return }
        let a = activities.remove(at: i)
        log(a.title, Date().timeIntervalSince(a.started), onMainThread: false)
    }

    /// Runs main-thread work, recording how long it took (always, or only
    /// when longer than `onlyIfOver` seconds).
    func measure<T>(_ title: String, onlyIfOver threshold: TimeInterval = 0, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        defer {
            let d = Date().timeIntervalSince(start)
            if d >= threshold { log(title, d, onMainThread: true) }
        }
        return try body()
    }

    private func log(_ title: String, _ duration: TimeInterval, onMainThread: Bool) {
        activityLog.insert(ActivityRecord(title: title, finished: Date(), duration: duration, onMainThread: onMainThread), at: 0)
        if activityLog.count > 60 { activityLog.removeLast(activityLog.count - 60) }
    }

    func clearActivityLog() {
        activityLog = []
        stalls = []
    }

    /// Watches for moments the app stops responding, and notes what was
    /// going on (docs/MAINTENANCE.md §2.3).
    private func startStallMonitor() {
        guard stallMonitor == nil else { return }
        let monitor = StallMonitor(threshold: 0.4) { [weak self] seconds in
            MainActor.assumeIsolated { self?.recordStall(seconds) }
        }
        monitor.start()
        stallMonitor = monitor
    }

    private func recordStall(_ seconds: TimeInterval) {
        // A modal open panel or alert isn't a freeze.
        guard NSApp.modalWindow == nil, seconds < 120 else { return }
        var context = "On \(pageTitle), after: \(lastAction)"
        if let busy = activityLog.first(where: { $0.onMainThread && Date().timeIntervalSince($0.finished) < seconds + 1 }) {
            context += "; \(busy.title) took \(Self.duration(busy.duration))"
        }
        if !activities.isEmpty { context += "; in progress: \(activities.map(\.title).joined(separator: ", "))" }
        stalls.insert(Stall(at: Date(), duration: seconds, context: context), at: 0)
        if stalls.count > 30 { stalls.removeLast(stalls.count - 30) }
    }

    static func duration(_ t: TimeInterval) -> String {
        t < 1 ? "\(Int((t * 1000).rounded())) ms" : String(format: "%.1f s", t)
    }

    /// The log as text, to send with a bug report.
    var activityReport: String {
        let time = DateFormatter()
        time.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["QDVC Case Manager activity report, \(time.string(from: Date()))",
                     "Workspace: \(book.rows.count) cases, \(data.analysts.count) analysts, \(data.projects.count) projects",
                     "", "Moments the app stopped responding:"]
        lines += stalls.isEmpty ? ["  none"] : stalls.map { "  \(time.string(from: $0.at))  \(Self.duration($0.duration))  \($0.context)" }
        lines += ["", "Recent work:"]
        lines += activityLog.map {
            "  \(time.string(from: $0.finished))  \(Self.duration($0.duration))  \($0.title)\($0.onMainThread ? "" : " (background)")"
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Lookups

    var visibleRows: [CaseRow] {
        var rows = book.rows.filter { inSelectedYear($0) }
        switch page {
        case .cases(let scope): rows = rows.filter { scope.includes($0) }
        case .project(let id): rows = rows.filter { $0.projects.contains(id) || $0.claimedBy.contains(id) }
        default: break
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            rows = rows.filter { r in
                [r.caseID, r.title, r.genre, r.analystKey, r.analystName, r.note, r.supervisor, r.status.title]
                    .contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
        return rows
    }

    func count(_ scope: CaseScope) -> Int { scopeCounts[scope] ?? 0 }

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

    /// The Workload dashboard's figures, computed with everything else.
    func workload(_ span: Span, includeInactive: Bool) -> WorkloadSnapshot? {
        derived.workload[WorkloadKey(months: span.count, includeInactive: includeInactive)]
    }

    func rates(_ grouping: Rates.Grouping, _ span: Span) -> RatesSnapshot? {
        derived.rates[RatesKey(grouping: grouping, months: span.count)]
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

    /// Shows one case in the catalogue (switching to its year).
    func reveal(_ caseID: String) {
        page = .cases(.all)
        if let row = book.row(caseID) { selectedYear = row.registrationDate?.year ?? YearSummary.undated }
        searchText = caseID
        refreshCaseRows()
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
                try measure("Imported the \(draft.source.title)") {
                    try ws.importSource(draft.source, from: file, mapping: mapping)
                }
            } else {
                data.mappings[draft.source] = mapping
                try ws.save(.mapping(draft.source), from: data)
            }
        } catch {
            errorMessage = "The import failed: \(error)"
            return
        }
        sheet = nil
        reload { [weak self] in
            guard let self, draft.source == .controlSheet else { return }
            let landed = self.prepared.filter { $0.state != .pending && !landedBefore.contains($0.caseID) }.count
            if landed > 0 { self.landedPrompt = landed }
        }
    }

    // MARK: Projects

    func beginNewProject() {
        guard isOpen, let url = Platform.chooseCSV(title: "Import Project Worksheet"), let table = loadTable(url) else { return }
        // A newer copy of a worksheet already in the workspace? Offer to update that project.
        if let existing = matchingProject(url: url, table: table) {
            switch Platform.choose("This looks like the “\(existing.definition.name)” worksheet.",
                                   "Update that project with this file, or add it as a new project?",
                                   buttons: ["Update \(existing.definition.name)", "Add as New Project", "Cancel"]) {
            case 0:
                beginWorksheetUpdate(existing, url: url, table: table)
                return
            case 1:
                break
            default:
                return
            }
        }
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

    /// Re-imports a project's worksheet from a newer file.
    func updateWorksheet(_ id: String) {
        guard let p = project(id), let url = Platform.chooseCSV(title: "Update the \(p.definition.name) Worksheet"),
              let table = loadTable(url) else { return }
        beginWorksheetUpdate(p, url: url, table: table)
    }

    private func beginWorksheetUpdate(_ p: ProjectWorksheet, url: URL, table: CSVTable) {
        var def = p.definition
        if table.index(of: def.caseIDColumn) == nil { def.caseIDColumn = guessCaseIDColumn(table) }
        sheet = .project(ProjectDraft(definition: def, fileURL: url, table: table, isNew: false))
    }

    /// The project a newly chosen worksheet probably updates: same file
    /// name stem or same name as the project, or mostly the same case IDs.
    private func matchingProject(url: URL, table: CSVTable) -> ProjectWorksheet? {
        let slug = ProjectDefinition.slug(url.deletingPathExtension().lastPathComponent)
        if let p = data.projects.first(where: {
            $0.id == slug || ProjectDefinition.slug($0.definition.name) == slug
                || ProjectDefinition.slug(($0.definition.originalFilename as NSString).deletingPathExtension) == slug
        }) { return p }
        let col = table.index(of: guessCaseIDColumn(table))
        let ids = Set(table.rows.indices.map { CaseKey.normalise(table.value($0, col)) }.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return nil }
        let best = data.projects.map { p in (p, Set(p.caseRows.keys).intersection(ids).count) }.max { $0.1 < $1.1 }
        if let best, Double(best.1) >= 0.6 * Double(ids.count) { return best.0 }
        return nil
    }

    func revealWorksheet(_ id: String) {
        guard let ws = workspace else { return }
        Platform.reveal(ws.url(for: "\(Workspace.projectsFolder)/\(id).csv"))
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

    func updateAnalyst(_ id: UUID, deferRebuild: Bool = false, _ change: (inout Analyst) -> Void) {
        guard let i = data.analysts.firstIndex(where: { $0.id == id }) else { return }
        mutate(.analysts, deferRebuild: deferRebuild) { change(&$0.analysts[i]) }
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
            set: { [weak self] v in self?.updateAnalyst(id, deferRebuild: true) { $0[keyPath: keyPath] = v } })
    }

    // MARK: Templates, outcome codes, settings

    func addTemplate(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !data.templates.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) else { return }
        mutate(.templates) { d in d.templates = ReturnTemplate.sorted(d.templates + [ReturnTemplate(name: n)]) }
    }

    /// Puts the list back in alphabetical order (after a name is edited).
    func sortTemplates() {
        let sorted = ReturnTemplate.sorted(data.templates)
        guard sorted.map(\.id) != data.templates.map(\.id) else { return }
        mutate(.templates) { $0.templates = sorted }
    }

    func updateTemplate(_ id: UUID, _ change: (inout ReturnTemplate) -> Void) {
        guard let i = data.templates.firstIndex(where: { $0.id == id }) else { return }
        mutate(.templates, deferRebuild: true) { change(&$0.templates[i]) }
    }

    func deleteTemplate(_ id: UUID) {
        mutate(.templates) { $0.templates.removeAll { $0.id == id } }
    }

    func templateBinding(_ id: UUID, _ keyPath: WritableKeyPath<ReturnTemplate, String>) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.data.templates.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { [weak self] v in self?.updateTemplate(id) { $0[keyPath: keyPath] = v } })
    }

    func updateOutcome(_ code: String, deferRebuild: Bool = false, _ change: (inout OutcomeCode) -> Void) {
        mutate(.settings, deferRebuild: deferRebuild) { d in
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
            set: { [weak self] v in self?.updateOutcome(code, deferRebuild: true) { $0[keyPath: keyPath] = v } })
    }

    func removeOutcome(_ code: String) {
        mutate(.settings) { $0.settings.outcomes.removeAll { $0.code == code } }
    }

    func updateSettings(deferRebuild: Bool = false, _ change: (inout WorkspaceSettings) -> Void) {
        mutate(.settings, deferRebuild: deferRebuild) { change(&$0.settings) }
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
