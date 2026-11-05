import Foundation

/// CSV exports of what the app shows, for spreadsheets and reports.
public enum Export {
    public static func cases(_ rows: [CaseRow], book: CaseBook, projects: [ProjectDefinition]) -> String {
        let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var out: [[String]] = [["Case ID", "Title", "Genre", "Registered", "Status", "Analyst", "Analyst name",
                                "Supervisor", "Allocated", "Outcome", "Note", "Projects", "Issues"]]
        for r in rows {
            out.append([r.caseID, r.title, r.genre, r.registrationDate?.iso ?? r.registrationText, r.status.title,
                        r.analystKey, r.analystName, r.supervisor, r.allocationDate?.iso ?? (r.latest?.allocationText ?? ""),
                        r.latest?.outcome ?? "", r.note, r.projects.map { names[$0] ?? $0 }.joined(separator: "; "),
                        r.flags.map(describe).joined(separator: "; ")])
        }
        return CSV.render(out)
    }

    public static func pivot(_ p: WorkloadPivot, names: [String: String]) -> String {
        var out: [[String]] = [["Analyst", "Name"] + p.months.map(\.iso) + ["Total"]]
        for a in p.analysts {
            out.append([a, names[a] ?? ""] + p.months.map { String(p.count(a, $0)) } + [String(p.rowTotal(a))])
        }
        out.append(["Total", ""] + p.months.map { String(p.columnTotal($0)) } + [String(p.grandTotal)])
        return CSV.render(out)
    }

    public static func rates(_ rows: [RateRow], heading: String) -> String {
        func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "" }
        var out: [[String]] = [[heading, "Accepted (a)", "Refused (r)", "Special (sp)", "Other", "Acceptance rate", "Refusal rate"]]
        for r in rows + [Rates.overall(rows)] {
            out.append([r.label, String(r.accepted), String(r.refused), String(r.special), String(r.other),
                        pct(r.acceptanceRate), pct(r.refusalRate)])
        }
        return CSV.render(out)
    }

    public static func describe(_ flag: CaseFlag) -> String {
        switch flag {
        case .mismatch: return "Details differ between the catalogue and the control sheet"
        case .notInCatalogue: return "Not in the case catalogue"
        case .duplicateInCatalogue: return "Case ID appears more than once in the catalogue"
        case .unknownAnalyst(let s): return "Unknown analyst shorthand \"\(s)\""
        case .unknownOutcome(let s): return s.isEmpty ? "No allocation outcome" : "Unclassified outcome \"\(s)\""
        case .unknownTemplate(let s): return "Unknown return-to-sender template \"\(s)\""
        case .missingFromWorksheet(let p): return "Missing from the \(p) worksheet"
        }
    }
}
