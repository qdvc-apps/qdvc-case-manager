import Foundation

/// Where a case stands, from its latest allocation decision.
public enum CaseStatus: Hashable, Sendable {
    /// In the catalogue, not yet in the control sheet.
    case awaiting
    case allocated
    case refused
    /// Diverted to a project (the outcome code).
    case project(String)
    /// An outcome code the workspace hasn't classified.
    case other(String)

    public var title: String {
        switch self {
        case .awaiting: return "Awaiting allocation"
        case .allocated: return "Allocated"
        case .refused: return "Refused & returned"
        case .project(let code): return code
        case .other(let code): return code.isEmpty ? "No outcome" : code
        }
    }

    /// For sorting: the workflow order.
    public var sortKey: String {
        switch self {
        case .awaiting: return "0"
        case .allocated: return "1"
        case .refused: return "2"
        case .project(let c): return "3" + c
        case .other(let c): return "4" + c
        }
    }
}

/// A field whose value differs between the catalogue and the control sheet.
public struct Discrepancy: Hashable, Sendable {
    public let field: MappedField
    public let catalogue: String
    public let controlSheet: String
    /// The control sheet row it was found on.
    public let row: Int
}

/// Something about a case worth a supervisor's attention.
public enum CaseFlag: Hashable, Sendable {
    /// Title, genre or registration date differ between the exports: the (!).
    case mismatch
    /// In the control sheet but not in the catalogue.
    case notInCatalogue
    /// More than one catalogue row has this case ID.
    case duplicateInCatalogue
    /// The control sheet names an analyst shorthand with no analyst.
    case unknownAnalyst(String)
    /// The outcome code isn't classified.
    case unknownOutcome(String)
    /// A refusal names a template the workspace doesn't list.
    case unknownTemplate(String)
    /// The outcome or note says the case belongs to a project whose
    /// worksheet doesn't list it.
    case missingFromWorksheet(String)

    /// The (!) emblem: a disagreement between sources.
    public var isWarning: Bool {
        switch self {
        case .mismatch, .notInCatalogue, .duplicateInCatalogue, .missingFromWorksheet: return true
        default: return false
        }
    }
}

/// What an allocation note is.
public enum NoteKind: Hashable, Sendable {
    case none
    /// A phrase from the allocated analyst's expertise.
    case expertise
    /// A recognised special note ("As per Protocol 67").
    case special
    /// A note on an allocation that is not in the analyst's expertise.
    case unmatched
    /// A return-to-sender template.
    case template
    case unknownTemplate

    public var title: String {
        switch self {
        case .none: return "No note"
        case .expertise: return "From the analyst's expertise"
        case .special: return "Special note"
        case .unmatched: return "Not in the analyst's expertise"
        case .template: return "Return-to-sender template"
        case .unknownTemplate: return "Template not in the workspace's list"
        }
    }
}

/// One case as the app shows it: the catalogue record joined with its
/// allocation decisions and project worksheets.
public struct CaseRow: Identifiable, Sendable, Equatable {
    public var id: String { caseID }
    public var caseID: String
    public var key: String
    public var record: CaseRecord?
    /// Control sheet rows for this case, oldest first.
    public var allocations: [AllocationRecord]
    public var status: CaseStatus
    public var outcome: OutcomeCode?
    /// The current analyst's canonical shorthand (or the raw one if unknown).
    public var analystKey: String
    public var analystName: String
    public var noteKind: NoteKind
    public var discrepancies: [Discrepancy]
    public var flags: [CaseFlag]
    /// Projects whose worksheet lists this case.
    public var projects: [String]
    /// Projects that claim the case (by outcome or note), listed or not.
    public var claimedBy: [String]
    public var decision: CaseDecision?

    public var latest: AllocationRecord? { allocations.last }
    public var inCatalogue: Bool { record != nil }

    public var title: String { record?.title ?? latest?.title ?? "" }
    public var genre: String { record?.genre ?? latest?.genre ?? "" }
    public var registrationDate: LocalDate? { record?.registrationDate ?? latest?.registrationDate }
    public var registrationText: String { record?.registrationText ?? latest?.registrationText ?? "" }
    public var supervisor: String { latest?.supervisor ?? "" }
    public var allocationDate: LocalDate? { latest?.allocationDate }
    public var note: String { latest?.note ?? "" }

    public var hasWarning: Bool { flags.contains { $0.isWarning } }
    public var needsAttention: Bool { !flags.isEmpty }

    /// Whether a row for this case is prepared in the batch and the
    /// control sheet hasn't caught up with it yet.
    public var isInBatch: Bool { status == .awaiting && decision?.isPrepared == true }

    /// The analyst of a prepared row still waiting to land.
    public var openProposal: String? {
        guard isInBatch, let a = decision?.analyst, !a.isEmpty else { return nil }
        return a
    }

    // Sort keys (Table columns need non-optional Comparable values).
    public var registrationSort: String { registrationDate?.iso ?? "" }
    public var allocationSort: String { allocationDate?.iso ?? "" }
    public var statusSort: String { status.sortKey }
    public var projectsSort: String { projects.joined(separator: ",") }
    public var flagSort: Int { hasWarning ? 0 : (needsAttention ? 1 : 2) }
}

/// The joined view of the whole workspace, rebuilt whenever its data changes.
public struct CaseBook: Sendable {
    public var rows: [CaseRow] = []
    public var index: [String: Int] = [:]
    public var genres: [String] = []
    public var supervisors: [String] = []
    /// Outcome codes seen in the control sheet, with how many cases each.
    public var outcomeCounts: [String: Int] = [:]
    /// Analyst shorthands seen that match no analyst, with counts.
    public var unknownShorthands: [String: Int] = [:]
    /// Template names used in refusals, with counts.
    public var templateCounts: [String: Int] = [:]
    /// Problems reading the exports (bad dates, rows without IDs…).
    public var dataIssues: [String] = []
    /// The analyst for each normalised shorthand or alias.
    public var analystByKey: [String: Analyst] = [:]
    /// Rows per project worksheet that aren't in the catalogue or control sheet.
    public var worksheetOrphans: [String: [String]] = [:]
    /// The latest registration date in the catalogue and allocation date in
    /// the control sheet: how far each export reaches.
    public var latestRegistration: LocalDate?
    public var latestAllocation: LocalDate?

    public init() {}

    public func row(_ caseID: String) -> CaseRow? {
        index[CaseKey.normalise(caseID)].map { rows[$0] }
    }

    public func analyst(for shorthand: String) -> Analyst? {
        analystByKey[Analyst.normalise(shorthand)]
    }

    /// The canonical shorthand for any shorthand or alias (the raw one,
    /// normalised, if no analyst has it).
    public func canonical(_ shorthand: String) -> String {
        analyst(for: shorthand)?.shorthand ?? Analyst.normalise(shorthand)
    }

    // MARK: Building

    public static func build(_ data: WorkspaceData) -> CaseBook {
        var book = CaseBook()
        let settings = data.settings

        for a in data.analysts {
            for k in a.keys where book.analystByKey[k] == nil { book.analystByKey[k] = a }
        }
        let templateNames = Set(data.templates.map { $0.name.trimmingCharacters(in: .whitespaces).uppercased() })
        let specialNotes = settings.specialNotes.map { $0.lowercased() }

        // Catalogue.
        var records: [CaseRecord] = []
        var duplicates = Set<String>()
        if let table = data.tables[.catalogue], let m = data.mappings[.catalogue] {
            let col = { (f: MappedField) in m.header(f).flatMap(table.index(of:)) }
            let id = col(.caseID), title = col(.title), genre = col(.genre), reg = col(.registrationDate)
            var seen = Set<String>()
            var badDates = 0, noID = 0
            for r in table.rows.indices {
                let caseID = table.value(r, id)
                guard !caseID.isEmpty else { noID += 1; continue }
                let k = CaseKey.normalise(caseID)
                if seen.contains(k) { duplicates.insert(k); continue }
                seen.insert(k)
                let regText = table.value(r, reg)
                let regDate = DateParser.parse(regText, order: m.dateOrder)
                if regDate == nil && !regText.isEmpty { badDates += 1 }
                records.append(CaseRecord(caseID: caseID, title: table.value(r, title), genre: table.value(r, genre),
                                          registrationText: regText, registrationDate: regDate, row: r))
            }
            if id == nil { book.dataIssues.append("Case Catalogue: the case ID column is not mapped or is missing from the file.") }
            if noID > 0 { book.dataIssues.append("Case Catalogue: \(noID) row(s) have no case ID and were skipped.") }
            if !duplicates.isEmpty { book.dataIssues.append("Case Catalogue: \(duplicates.count) case ID(s) appear more than once; the first row is used.") }
            if badDates > 0 { book.dataIssues.append("Case Catalogue: \(badDates) registration date(s) could not be read.") }
        }

        // Control sheet.
        var allocationsByKey: [String: [AllocationRecord]] = [:]
        var allocationOrder: [String] = []
        if let table = data.tables[.controlSheet], let m = data.mappings[.controlSheet] {
            let col = { (f: MappedField) in m.header(f).flatMap(table.index(of:)) }
            let c = Dictionary(uniqueKeysWithValues: MappedField.allCases.map { ($0, col($0)) })
            var badDates = 0, noID = 0
            for r in table.rows.indices {
                let caseID = table.value(r, c[.caseID]!)
                guard !caseID.isEmpty else { noID += 1; continue }
                let regText = table.value(r, c[.registrationDate]!)
                let allocText = table.value(r, c[.allocationDate]!)
                let rec = AllocationRecord(
                    caseID: caseID, title: table.value(r, c[.title]!), genre: table.value(r, c[.genre]!),
                    registrationText: regText, registrationDate: DateParser.parse(regText, order: m.dateOrder),
                    supervisor: table.value(r, c[.supervisor]!), allocationText: allocText,
                    allocationDate: DateParser.parse(allocText, order: m.dateOrder),
                    outcome: table.value(r, c[.outcome]!), note: table.value(r, c[.note]!),
                    analyst: table.value(r, c[.analyst]!), row: r)
                if rec.allocationDate == nil && !allocText.isEmpty { badDates += 1 }
                let k = CaseKey.normalise(caseID)
                if allocationsByKey[k] == nil { allocationOrder.append(k) }
                allocationsByKey[k, default: []].append(rec)
            }
            if c[.caseID]! == nil { book.dataIssues.append("Allocation Control Sheet: the case ID column is not mapped or is missing from the file.") }
            if noID > 0 { book.dataIssues.append("Allocation Control Sheet: \(noID) row(s) have no case ID and were skipped.") }
            if badDates > 0 { book.dataIssues.append("Allocation Control Sheet: \(badDates) allocation date(s) could not be read.") }
        }

        // Project worksheets.
        var listedIn: [String: [String]] = [:]
        for p in data.projects {
            if p.caseIDColumnIndex == nil {
                book.dataIssues.append("Project \(p.definition.name): the case ID column \"\(p.definition.caseIDColumn)\" is not in the worksheet.")
            }
            for k in p.caseRows.keys { listedIn[k, default: []].append(p.id) }
        }

        func makeRow(key: String, record: CaseRecord?, allocations unsorted: [AllocationRecord]) -> CaseRow {
            // Oldest first; undated rows keep file order, before dated ones.
            let allocations = unsorted.enumerated().sorted { a, b in
                switch (a.element.allocationDate, b.element.allocationDate) {
                case let (x?, y?): return x == y ? a.offset < b.offset : x < y
                case (nil, _?): return true
                case (_?, nil): return false
                case (nil, nil): return a.offset < b.offset
                }
            }.map(\.element)
            let latest = allocations.last
            var status = CaseStatus.awaiting
            var outcome: OutcomeCode?
            var flags: [CaseFlag] = []
            var analystKey = ""
            var analystName = ""
            var noteKind = NoteKind.none

            if let latest {
                outcome = settings.outcome(for: latest.outcome)
                switch outcome?.kind {
                case .allocated?: status = .allocated
                case .refused?: status = .refused
                case .project?: status = .project(outcome!.code)
                case .other?: status = .other(outcome!.code)
                case nil:
                    status = .other(latest.outcome)
                    flags.append(.unknownOutcome(latest.outcome))
                }
                if !latest.analyst.isEmpty {
                    if let a = book.analyst(for: latest.analyst) {
                        analystKey = a.shorthand
                        analystName = a.displayName
                    } else {
                        analystKey = Analyst.normalise(latest.analyst)
                        analystName = latest.analyst
                        flags.append(.unknownAnalyst(latest.analyst))
                    }
                }
                let note = latest.note
                if !note.isEmpty {
                    if status == .refused {
                        if templateNames.contains(note.uppercased()) { noteKind = .template }
                        else { noteKind = .unknownTemplate; flags.append(.unknownTemplate(note)) }
                    } else if let a = book.analyst(for: latest.analyst),
                              a.expertise.range(of: CaseBook.squashSpaces(note), options: [.caseInsensitive, .diacriticInsensitive]) != nil
                                || CaseBook.squashSpaces(a.expertise).range(of: CaseBook.squashSpaces(note), options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                        noteKind = .expertise
                    } else if specialNotes.contains(where: { note.lowercased().contains($0) }) {
                        noteKind = .special
                    } else if status == .allocated {
                        noteKind = .unmatched
                    } else {
                        noteKind = .special
                    }
                }
            }

            // Compare each control sheet row with the catalogue.
            var discrepancies: [Discrepancy] = []
            if let record {
                for a in allocations {
                    for (field, mine, theirs) in [(MappedField.title, record.title, a.title),
                                                  (MappedField.genre, record.genre, a.genre)] {
                        if !theirs.isEmpty && !CaseBook.same(mine, theirs, lenient: settings.lenientComparison) {
                            discrepancies.append(Discrepancy(field: field, catalogue: mine, controlSheet: theirs, row: a.row))
                        }
                    }
                    if !a.registrationText.isEmpty {
                        let differs: Bool
                        if let x = record.registrationDate, let y = a.registrationDate { differs = x != y }
                        else { differs = !CaseBook.same(record.registrationText, a.registrationText, lenient: true) }
                        if differs {
                            discrepancies.append(Discrepancy(field: .registrationDate, catalogue: record.registrationText,
                                                             controlSheet: a.registrationText, row: a.row))
                        }
                    }
                }
            } else {
                flags.insert(.notInCatalogue, at: 0)
            }
            if !discrepancies.isEmpty { flags.insert(.mismatch, at: 0) }
            if duplicates.contains(key) { flags.append(.duplicateInCatalogue) }

            let projects = listedIn[key] ?? []
            var claimedBy: [String] = []
            for p in data.projects {
                let claims = allocations.contains { p.definition.claims($0) }
                    || (outcome.map { $0.kind == .project && $0.project == p.id } ?? false)
                if claims { claimedBy.append(p.id) }
                if claims && !projects.contains(p.id) { flags.append(.missingFromWorksheet(p.id)) }
            }

            let caseID = record?.caseID ?? latest?.caseID ?? key
            return CaseRow(caseID: caseID, key: key, record: record, allocations: allocations, status: status,
                           outcome: outcome, analystKey: analystKey, analystName: analystName, noteKind: noteKind,
                           discrepancies: discrepancies, flags: flags, projects: projects, claimedBy: claimedBy,
                           decision: data.decisions[caseID] ?? data.decisions.first { CaseKey.normalise($0.key) == key }?.value)
        }

        var rows: [CaseRow] = []
        var done = Set<String>()
        for rec in records {
            let k = CaseKey.normalise(rec.caseID)
            rows.append(makeRow(key: k, record: rec, allocations: allocationsByKey[k] ?? []))
            done.insert(k)
        }
        for k in allocationOrder where !done.contains(k) {
            rows.append(makeRow(key: k, record: nil, allocations: allocationsByKey[k] ?? []))
        }
        book.rows = rows
        book.index = Dictionary(rows.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: { a, _ in a })

        // Summaries.
        var genres = Set<String>(), supervisors = Set<String>()
        for row in rows {
            if !row.genre.isEmpty { genres.insert(row.genre) }
            for a in row.allocations where !a.supervisor.isEmpty { supervisors.insert(a.supervisor) }
            if let latest = row.latest {
                book.outcomeCounts[latest.outcome, default: 0] += 1
                if row.status == .refused, !latest.note.isEmpty { book.templateCounts[latest.note, default: 0] += 1 }
            }
            for f in row.flags { if case .unknownAnalyst(let s) = f { book.unknownShorthands[Analyst.normalise(s), default: 0] += 1 } }
        }
        book.latestRegistration = records.compactMap(\.registrationDate).max()
        book.latestAllocation = allocationsByKey.values.joined().compactMap(\.allocationDate).max()
        book.genres = genres.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        book.supervisors = supervisors.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        for p in data.projects {
            let orphans = p.caseRows.keys.filter { book.index[$0] == nil }.sorted()
            if !orphans.isEmpty { book.worksheetOrphans[p.id] = orphans }
        }
        return book
    }

    /// Collapses runs of white space to one space and trims.
    public static func squashSpaces(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func same(_ a: String, _ b: String, lenient: Bool) -> Bool {
        if !lenient { return a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines) }
        return squashSpaces(a).compare(squashSpaces(b), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
