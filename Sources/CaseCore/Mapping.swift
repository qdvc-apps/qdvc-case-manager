import Foundation

/// The two exports the app ingests.
public enum SourceKind: String, CaseIterable, Sendable, Identifiable {
    case catalogue = "case-catalogue"
    case controlSheet = "allocation-control-sheet"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .catalogue: return "Case Catalogue"
        case .controlSheet: return "Allocation Control Sheet"
        }
    }

    public var fields: [MappedField] {
        switch self {
        case .catalogue: return [.caseID, .title, .genre, .registrationDate]
        case .controlSheet: return MappedField.allCases
        }
    }

    /// Where the imported file is kept, relative to the workspace.
    public var csvPath: String { "imports/\(rawValue).csv" }
    /// Where its column mapping is kept, relative to the workspace.
    public var mappingPath: String { "mappings/\(rawValue).yml" }
}

/// A field the app reads from an export.
public enum MappedField: String, CaseIterable, Sendable, Identifiable {
    case caseID = "case_id"
    case title
    case genre
    case registrationDate = "registration_date"
    case supervisor
    case allocationDate = "allocation_date"
    case outcome
    case note
    case analyst

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .caseID: return "Case ID"
        case .title: return "Case title"
        case .genre: return "Case genre"
        case .registrationDate: return "Registration date"
        case .supervisor: return "Allocation supervisor"
        case .allocationDate: return "Allocation date"
        case .outcome: return "Allocation outcome"
        case .note: return "Allocation note"
        case .analyst: return "Allocated analyst"
        }
    }

    public var isRequired: Bool { self == .caseID }
    public var isDate: Bool { self == .registrationDate || self == .allocationDate }

    /// Header names (normalised: lower case, letters and digits only) that
    /// suggest this field, best first. Upstream headers are often terse
    /// codes, so abbreviations are included.
    var synonyms: [String] {
        switch self {
        case .caseID:
            return ["caseid", "caseref", "casereference", "caseno", "casenumber", "casenum", "cseid", "cseref",
                    "csid", "csref", "ref", "reference", "id", "case"]
        case .title:
            return ["casetitle", "title", "csettl", "csttl", "ttl", "subject", "name", "casename", "description"]
        case .genre:
            return ["casegenre", "genre", "gnr", "casetype", "type", "category", "cat", "class", "classification"]
        case .registrationDate:
            return ["registrationdate", "casregistrationdate", "regdate", "regdt", "dateregistered", "registered",
                    "registration", "datereg", "received", "datereceived", "lodged", "created", "reg"]
        case .supervisor:
            return ["allocationsupervisor", "supervisor", "allocsupervisor", "allocsup", "supv", "sup",
                    "allocatedby", "allocator"]
        case .allocationDate:
            return ["allocationdate", "allocdate", "allocdt", "dateallocated", "allocatedon", "decisiondate",
                    "allocationdt"]
        case .outcome:
            return ["allocationoutcome", "outcome", "allocoutcome", "alloutcome", "outcm", "outcd", "outcome code",
                    "result", "decision"]
        case .note:
            return ["allocationnote", "note", "allocnote", "notes", "nt", "comment", "comments", "remarks",
                    "reason"]
        case .analyst:
            return ["allocatedanalyst", "analyst", "allocanalyst", "anl", "anlst", "allocatedto", "assignedto",
                    "assignee", "officer"]
        }
    }
}

/// Which header of an export holds each field, and how its dates are written.
public struct ColumnMapping: Sendable, Equatable {
    public var columns: [MappedField: String]
    public var dateOrder: DateOrder
    public var originalFilename: String
    public var importedAt: String

    public init(columns: [MappedField: String] = [:], dateOrder: DateOrder = .dayFirst,
                originalFilename: String = "", importedAt: String = "") {
        self.columns = columns
        self.dateOrder = dateOrder
        self.originalFilename = originalFilename
        self.importedAt = importedAt
    }

    public func header(_ field: MappedField) -> String? {
        guard let h = columns[field], !h.isEmpty else { return nil }
        return h
    }

    /// Fields this mapping names but whose header is missing from `headers`.
    public func missing(in headers: [String], for source: SourceKind) -> [MappedField] {
        let table = CSVTable(headers: headers, rows: [])
        return source.fields.filter { f in header(f).map { table.index(of: $0) == nil } ?? false }
    }

    /// Whether every field this mapping names is present in `headers`, and
    /// the required ones are named.
    public func fits(_ headers: [String], for source: SourceKind) -> Bool {
        header(.caseID) != nil && missing(in: headers, for: source).isEmpty
    }

    /// Normalised header text, for guessing.
    static func squash(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// A best guess at the mapping from the headers alone.
    public static func guess(headers: [String], for source: SourceKind) -> ColumnMapping {
        let squashed = headers.map(squash)
        var used = Set<Int>()
        var columns: [MappedField: String] = [:]

        // Exact matches first, across all fields, so "analyst" can't be taken
        // by a looser match for another field.
        for pass in 0..<2 {
            for field in source.fields where columns[field] == nil {
                var best: (score: Int, index: Int)?
                for (i, h) in squashed.enumerated() where !used.contains(i) && !h.isEmpty {
                    for (rank, syn) in field.synonyms.enumerated() {
                        let s = squash(syn)
                        let score: Int
                        if h == s {
                            score = 1000 - rank
                        } else if pass == 1 && s.count >= 3 && h.contains(s) {
                            score = 500 - rank - (h.count - s.count)
                        } else {
                            continue
                        }
                        if best == nil || score > best!.score { best = (score, i) }
                    }
                }
                if let best {
                    columns[field] = headers[best.index]
                    used.insert(best.index)
                }
            }
        }
        return ColumnMapping(columns: columns)
    }
}
