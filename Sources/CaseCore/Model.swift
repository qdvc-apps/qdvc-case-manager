import Foundation

// MARK: - Records from the two exports

/// A row of the case catalogue.
public struct CaseRecord: Sendable, Equatable {
    public var caseID: String
    public var title: String
    public var genre: String
    public var registrationText: String
    public var registrationDate: LocalDate?
    /// The row in the catalogue table (0-based, after the header).
    public var row: Int

    public init(caseID: String, title: String, genre: String, registrationText: String,
                registrationDate: LocalDate?, row: Int) {
        self.caseID = caseID
        self.title = title
        self.genre = genre
        self.registrationText = registrationText
        self.registrationDate = registrationDate
        self.row = row
    }
}

/// A row of the allocation control sheet: one allocation decision.
public struct AllocationRecord: Sendable, Equatable, Identifiable {
    public var id: Int { row }
    public var caseID: String
    public var title: String
    public var genre: String
    public var registrationText: String
    public var registrationDate: LocalDate?
    public var supervisor: String
    public var allocationText: String
    public var allocationDate: LocalDate?
    public var outcome: String
    public var note: String
    public var analyst: String
    /// The row in the control sheet table (0-based, after the header).
    public var row: Int

    public init(caseID: String, title: String = "", genre: String = "", registrationText: String = "",
                registrationDate: LocalDate? = nil, supervisor: String = "", allocationText: String = "",
                allocationDate: LocalDate? = nil, outcome: String = "", note: String = "", analyst: String = "",
                row: Int = 0) {
        self.caseID = caseID
        self.title = title
        self.genre = genre
        self.registrationText = registrationText
        self.registrationDate = registrationDate
        self.supervisor = supervisor
        self.allocationText = allocationText
        self.allocationDate = allocationDate
        self.outcome = outcome
        self.note = note
        self.analyst = analyst
        self.row = row
    }
}

// MARK: - Outcome codes

/// What an allocation outcome code means.
public enum OutcomeKind: String, CaseIterable, Sendable, Identifiable {
    /// "a": allocated to an analyst.
    case allocated
    /// "r": refused and returned to sender.
    case refused
    /// Diverted to a project, operation or special event (e.g. "Operation Waymaker").
    case project
    /// Anything else not yet classified.
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .allocated: return "Allocated to analyst"
        case .refused: return "Refused & returned"
        case .project: return "Project / operation"
        case .other: return "Other (unclassified)"
        }
    }
}

/// How an outcome counts in the acceptance and refusal rates.
public enum RateTreatment: String, CaseIterable, Sendable, Identifiable {
    case accepted
    case refused
    case excluded

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .accepted: return "Counts as accepted (a)"
        case .refused: return "Counts as refused (r)"
        case .excluded: return "Shown separately"
        }
    }
}

/// An allocation outcome code and how the app treats it.
public struct OutcomeCode: Sendable, Equatable, Identifiable {
    public var id: String { code }
    public var code: String
    public var kind: OutcomeKind
    public var label: String
    public var rates: RateTreatment
    /// Whether a case with this outcome counts towards the named analyst's
    /// workload.
    public var countsAsWorkload: Bool
    /// The project this outcome sends cases to (`kind == .project`).
    public var project: String

    public init(code: String, kind: OutcomeKind, label: String = "", rates: RateTreatment? = nil,
                countsAsWorkload: Bool? = nil, project: String = "") {
        self.code = code
        self.kind = kind
        self.label = label
        self.rates = rates ?? OutcomeCode.defaultRates(kind)
        self.countsAsWorkload = countsAsWorkload ?? OutcomeCode.defaultWorkload(kind)
        self.project = project
    }

    public static func defaultRates(_ kind: OutcomeKind) -> RateTreatment {
        switch kind {
        case .allocated: return .accepted
        case .refused: return .refused
        case .project, .other: return .excluded
        }
    }

    public static func defaultWorkload(_ kind: OutcomeKind) -> Bool { kind != .refused }

    public var displayLabel: String { label.isEmpty ? kind.title : label }

    public static let standard: [OutcomeCode] = [
        OutcomeCode(code: "a", kind: .allocated, label: "Allocated to analyst"),
        OutcomeCode(code: "r", kind: .refused, label: "Refused & returned"),
    ]
}

// MARK: - Reference data kept in the workspace

/// An analyst in the pool. The shorthand is what the control sheet writes.
public struct Analyst: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var shorthand: String
    public var name: String
    public var expertise: String
    /// Other shorthands the control sheet has used for this analyst.
    public var aliases: [String]
    public var active: Bool
    public var notes: String

    public init(id: UUID = UUID(), shorthand: String, name: String = "", expertise: String = "",
                aliases: [String] = [], active: Bool = true, notes: String = "") {
        self.id = id
        self.shorthand = shorthand
        self.name = name
        self.expertise = expertise
        self.aliases = aliases
        self.active = active
        self.notes = notes
    }

    public var displayName: String { name.isEmpty ? shorthand : name }

    /// Every shorthand that means this analyst, normalised for matching.
    public var keys: [String] { ([shorthand] + aliases).map(Analyst.normalise).filter { !$0.isEmpty } }

    public static func normalise(_ shorthand: String) -> String {
        shorthand.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

/// A return-to-sender message template, named in the allocation note of a
/// refused case.
public struct ReturnTemplate: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var description: String

    public init(id: UUID = UUID(), name: String, description: String = "") {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// A project, operation or special event with its own worksheet.
public struct ProjectDefinition: Sendable, Equatable, Identifiable {
    /// The file name stem in `projects/` (`operation-waymaker`).
    public var id: String
    public var name: String
    /// A short tag for the case catalogue (`WAY`).
    public var badge: String
    /// One of `ProjectDefinition.colours`.
    public var colour: String
    /// The designated leader's shorthand.
    public var leader: String
    /// What this project calls its leader (Captain, Team Leader, Principal Analyst…).
    public var leaderTitle: String
    /// The worksheet's case ID column header.
    public var caseIDColumn: String
    /// Outcome codes that mean a case belongs to this project.
    public var outcomeCodes: [String]
    /// Words in an allocation note that mean a case belongs to this project.
    public var noteKeywords: [String]
    public var originalFilename: String
    public var importedAt: String
    public var notes: String

    public init(id: String, name: String, badge: String = "", colour: String = "indigo", leader: String = "",
                leaderTitle: String = "Team Leader", caseIDColumn: String = "", outcomeCodes: [String] = [],
                noteKeywords: [String] = [], originalFilename: String = "", importedAt: String = "",
                notes: String = "") {
        self.id = id
        self.name = name
        self.badge = badge
        self.colour = colour
        self.leader = leader
        self.leaderTitle = leaderTitle
        self.caseIDColumn = caseIDColumn
        self.outcomeCodes = outcomeCodes
        self.noteKeywords = noteKeywords
        self.originalFilename = originalFilename
        self.importedAt = importedAt
        self.notes = notes
    }

    public static let colours = ["indigo", "teal", "orange", "pink", "purple", "brown", "green", "blue", "red", "yellow"]

    public var displayBadge: String {
        if !badge.isEmpty { return badge }
        let words = name.split(separator: " ").filter { !["operation", "project", "op"].contains($0.lowercased()) }
        return String((words.last ?? Substring(name)).prefix(4)).uppercased()
    }

    /// A file-name-safe id from a name: "Operation Waymaker" → `operation-waymaker`.
    public static func slug(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "project" : out
    }

    /// Whether an allocation (by its outcome or note) says the case belongs here.
    public func claims(_ allocation: AllocationRecord) -> Bool {
        if outcomeCodes.contains(where: { $0.caseInsensitiveCompare(allocation.outcome.trimmingCharacters(in: .whitespaces)) == .orderedSame }) {
            return true
        }
        return noteKeywords.contains { !$0.isEmpty && allocation.note.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// A project and its imported worksheet.
public struct ProjectWorksheet: Sendable, Equatable, Identifiable {
    public var id: String { definition.id }
    public var definition: ProjectDefinition
    public var table: CSVTable

    public init(definition: ProjectDefinition, table: CSVTable) {
        self.definition = definition
        self.table = table
    }

    public var caseIDColumnIndex: Int? { table.index(of: definition.caseIDColumn) }

    /// The worksheet's case IDs, normalised, with the row each is on.
    public var caseRows: [String: Int] {
        guard let col = caseIDColumnIndex else { return [:] }
        var out: [String: Int] = [:]
        for r in table.rows.indices {
            let id = CaseKey.normalise(table.value(r, col))
            if !id.isEmpty, out[id] == nil { out[id] = r }
        }
        return out
    }
}

/// A supervisor's work on a case in the decision support window: the
/// analysts shortlisted and, once decided, the row prepared for the
/// Allocation Control Sheet (docs/DESIGN.md §Batch).
public struct CaseDecision: Sendable, Equatable {
    public var shortlist: [String]
    /// The outcome code to write ("a", "r", …); empty until decided.
    public var outcome: String
    /// The allocated analyst's shorthand.
    public var analyst: String
    public var note: String
    public var supervisor: String
    /// The allocation date to write (ISO).
    public var date: String
    /// Position in the batch (rows are prepared in this order).
    public var order: Int
    public var updated: String

    public init(shortlist: [String] = [], outcome: String = "", analyst: String = "", note: String = "",
                supervisor: String = "", date: String = "", order: Int = 0, updated: String = "") {
        self.shortlist = shortlist
        self.outcome = outcome
        self.analyst = analyst
        self.note = note
        self.supervisor = supervisor
        self.date = date
        self.order = order
        self.updated = updated
    }

    /// Whether this decision is a prepared row in the batch.
    public var isPrepared: Bool { !outcome.isEmpty }
    public var isEmpty: Bool { shortlist.isEmpty && !isPrepared && note.isEmpty && analyst.isEmpty }

    /// Clears the prepared row, keeping the shortlist.
    public mutating func unprepare() {
        outcome = ""
        analyst = ""
        note = ""
        supervisor = ""
        date = ""
        order = 0
    }
}

/// Workspace-wide settings (`case-manager.yml`).
public struct WorkspaceSettings: Sendable, Equatable {
    public var title: String
    public var outcomes: [OutcomeCode]
    /// Compare titles and genres between the two exports ignoring case and
    /// repeated spaces.
    public var lenientComparison: Bool
    /// Allocation notes recognised as special (not expertise), e.g. "As per Protocol 67".
    public var specialNotes: [String]
    /// Keys we don't know, written back as they were read.
    public var extra: [YAMLPair]

    public init(title: String = "", outcomes: [OutcomeCode] = OutcomeCode.standard, lenientComparison: Bool = true,
                specialNotes: [String] = [], extra: [YAMLPair] = []) {
        self.title = title
        self.outcomes = outcomes
        self.lenientComparison = lenientComparison
        self.specialNotes = specialNotes
        self.extra = extra
    }

    public func outcome(for code: String) -> OutcomeCode? {
        let c = code.trimmingCharacters(in: .whitespaces)
        if let exact = outcomes.first(where: { $0.code == c }) { return exact }
        return outcomes.first { $0.code.caseInsensitiveCompare(c) == .orderedSame }
    }
}

/// Case IDs are verbatim strings: matched exactly (case, leading zeros and
/// all), ignoring only space around them, which exports often pad with.
public enum CaseKey {
    public static func normalise(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
