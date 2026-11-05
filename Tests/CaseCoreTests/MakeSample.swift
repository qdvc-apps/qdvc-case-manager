import XCTest
@testable import CaseCore

/// Rebuilds `sample-workspace/`:
///
///     MAKE_SAMPLE=$PWD/sample-workspace swift test --filter MakeSampleTests
///
/// Without MAKE_SAMPLE it builds the sample in a temporary folder and checks
/// it loads cleanly. The data is made up and deterministic.
final class MakeSampleTests: XCTestCase {
    struct Rand {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
        mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
        mutating func weighted<T>(_ xs: [(T, Int)]) -> T {
            var r = int(xs.reduce(0) { $0 + $1.1 })
            for (x, w) in xs { if r < w { return x }; r -= w }
            return xs.last!.0
        }
    }

    static let analysts: [Analyst] = [
        Analyst(shorthand: "AJB", name: "Alice J. Brown",
                expertise: "Forensic accounting; procurement fraud; supplier due diligence; invoice and payment irregularities; Excel and ACL data analytics; interviews with finance staff",
                aliases: ["AB"]),
        Analyst(shorthand: "KM", name: "Kofi Mensah",
                expertise: "Data breaches; cyber incident response; email and device forensics; information governance; GDPR and records management; Team Leader for Operation Waymaker"),
        Analyst(shorthand: "PRS", name: "Priya R. Sharma",
                expertise: "Grant compliance; research funding conditions; public sector grants; financial reconciliations; charity and not-for-profit governance"),
        Analyst(shorthand: "TO", name: "Tomás Ortega",
                expertise: "Workplace conduct; bullying and harassment; witness interviews; HR policy; whistleblowing and protected disclosures; trauma-informed practice"),
        Analyst(shorthand: "HL", name: "Hannah Lindqvist",
                expertise: "Environmental compliance; licensing and permits; site inspections; waste and emissions reporting; regulatory enforcement"),
        Analyst(shorthand: "DW", name: "Daniel Wu",
                expertise: "Procurement processes; contract management; conflicts of interest; supplier due diligence; asset disposal; travel and expenses"),
        Analyst(shorthand: "MO", name: "Mariam Okonjo",
                expertise: "Data analytics; payroll irregularities; duplicate payments; expenses and corporate cards; Power BI dashboards; statistical sampling"),
        Analyst(shorthand: "SF", name: "Sean Fitzgerald",
                expertise: "Licensing and permits; planning and land use; complaints handling; local government; community liaison; Protocol 67 reviews"),
        Analyst(shorthand: "EN", name: "Eleni Nikolaidou",
                expertise: "Cyber incident response; phishing and social engineering; information governance; device forensics; staff awareness training",
                notes: "Joined in March 2026."),
        Analyst(shorthand: "RG", name: "Rachel Green",
                expertise: "Workplace conduct; recruitment irregularities; HR policy; conflicts of interest",
                active: false, notes: "Left in June 2026; kept for history."),
    ]

    static let genres: [(String, [String], [String])] = [
        ("Financial Irregularity", ["Invoice discrepancy at", "Unexplained payments from", "Duplicate supplier payments at", "Petty cash shortfall at"],
         ["AJB", "MO", "DW"]),
        ("Procurement", ["Tender irregularity at", "Contract variation dispute at", "Supplier conflict of interest at", "Single-source award at"],
         ["DW", "AJB"]),
        ("Data Breach", ["Lost laptop at", "Misdirected email from", "Ransomware incident at", "Unauthorised access to records at"],
         ["KM", "EN"]),
        ("Workplace Conduct", ["Bullying complaint at", "Harassment allegation at", "Recruitment concern at", "Protected disclosure from"],
         ["TO", "RG"]),
        ("Grant Compliance", ["Grant milestone shortfall at", "Ineligible expenditure at", "Funding condition breach at"],
         ["PRS", "AJB"]),
        ("Environmental", ["Emissions reporting gap at", "Permit breach at", "Waste disposal complaint at"],
         ["HL", "SF"]),
        ("Licensing", ["Licence condition breach at", "Unlicensed activity at", "Planning complaint about"],
         ["SF", "HL"]),
    ]

    static let places = ["Northgate Depot", "Riverside Campus", "Harbour Office", "Elm Street Clinic", "Westfield Library",
                         "the Central Archive", "Kingsway Works", "Marlow House", "the Eastern Laboratory", "Fairview School",
                         "Mill Lane Yard", "the Regional Hub", "Oakfield Station", "St Anne's Hall", "the Port Authority"]
    static let supervisors = ["M. Okafor", "D. Lindqvist", "P. Ramanathan", "S. Whitcombe"]
    static let templates: [(String, String)] = [
        ("IS_DUPLICATE", "The matter is already registered under another case."),
        ("INCOMPLETE_FORM", "The referral form is missing information we need to proceed."),
        ("UNAUTHORISED_ENTITY_REV23", "The referrer is not authorised to refer (revision 23 of the referral rules)."),
        ("INSUFFICIENT_FUNDS", "There is no budget to take the matter on this financial year."),
        ("OUT_OF_SCOPE", "The matter is outside our remit."),
        ("CODENAME_JUNO", "Returned under the Juno arrangement."),
        ("CODENAME_NEPTUNE", "Returned under the Neptune arrangement."),
    ]

    func testMakeSample() throws {
        let target: URL
        let keep = ProcessInfo.processInfo.environment["MAKE_SAMPLE"]
        if let keep {
            target = URL(fileURLWithPath: keep)
            try? FileManager.default.removeItem(at: target)
        } else {
            target = FileManager.default.temporaryDirectory.appendingPathComponent("cm-sample-\(UUID().uuidString)")
        }
        defer { if keep == nil { try? FileManager.default.removeItem(at: target) } }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Self.write(to: target)

        let ws = Workspace(root: target)
        let data = ws.load()
        XCTAssertEqual(data.issues, [])
        let book = CaseBook.build(data)
        XCTAssertTrue(book.dataIssues.isEmpty, "\(book.dataIssues)")
        XCTAssertGreaterThan(book.rows.count, 400)
        XCTAssertTrue(book.rows.contains { $0.status == .awaiting })
        XCTAssertTrue(book.rows.contains { $0.hasWarning })
        XCTAssertTrue(book.rows.contains { if case .other = $0.status { return true }; return false })
        XCTAssertTrue(book.rows.contains { $0.flags.contains(.missingFromWorksheet("operation-waymaker")) })
        XCTAssertEqual(book.unknownShorthands.keys.sorted(), ["JTB"])
        XCTAssertEqual(Batch.rows(data, book: book).map(\.state), [.landed, .pending, .pending])
    }

    static func write(to root: URL) throws {
        var rng = Rand(state: 20261105)
        let ws = Workspace(root: root)
        try ws.ensureLayout()

        var settings = WorkspaceSettings(title: "Sample Directorate", specialNotes: ["As per Protocol 67", "Team Leader for Operation"])
        settings.outcomes.append(OutcomeCode(code: "Operation Waymaker", kind: .project, label: "Operation Waymaker",
                                             project: "operation-waymaker"))
        var data = WorkspaceData()
        data.settings = settings
        data.analysts = analysts
        data.templates = templates.map { ReturnTemplate(name: $0.0, description: $0.1) }

        // Cases from May 2025 to early November 2026, a few a working day.
        let start = LocalDate(year: 2025, month: 5, day: 1)!
        let end = LocalDate(year: 2026, month: 11, day: 4)!
        var catalogue: [[String]] = []
        var control: [[String]] = []
        var waymaker: [[String]] = []
        var n = 0
        let waymakerStart = LocalDate(year: 2026, month: 6, day: 1)!

        func ddmmyyyy(_ d: LocalDate) -> String { String(format: "%02d/%02d/%04d", d.day, d.month, d.year) }

        var day = start
        while day <= end {
            let weekday = (day.dayNumber + 4) % 7   // 0 = Sunday
            if weekday != 0 && weekday != 6 {
                let perDay = rng.weighted([(1, 2), (2, 4), (3, 3), (4, 1)])
                for _ in 0..<perDay {
                    n += 1
                    let id = String(format: "QD-%02d-%05d", day.year % 100, n)
                    let (genre, stems, specialists) = rng.pick(genres)
                    let title = "\(rng.pick(stems)) \(rng.pick(places))"
                    catalogue.append([id, title, genre, ddmmyyyy(day), rng.pick(["Web", "Phone", "Email", "Referral"]),
                                      rng.pick(["Low", "Medium", "High"]), rng.pick(["North", "South", "East", "West"]),
                                      ddmmyyyy(day.adding(days: rng.int(20)))])

                    // Recent cases are still waiting.
                    let lag = 2 + rng.int(9)
                    let allocDate = day.adding(days: lag)
                    if allocDate > end || day > end.adding(days: -9) && rng.chance(0.7) { continue }

                    var cTitle = title, cGenre = genre, cReg = day.iso
                    if rng.chance(0.02) { cTitle = title.replacingOccurrences(of: " at ", with: " - ") }
                    if rng.chance(0.006) { cGenre = rng.pick(genres).0 }
                    if rng.chance(0.006) { cReg = day.adding(days: 1).iso }
                    let supervisor = rng.pick(supervisors)
                    let inWaymaker = genre == "Data Breach" && day >= waymakerStart && rng.chance(0.45)

                    var outcome = "a", note = "", analyst = ""
                    if inWaymaker {
                        if rng.chance(0.5) {
                            outcome = "a"; analyst = "KM"; note = "Analyst is Team Leader for Operation Waymaker"
                        } else {
                            outcome = "Operation Waymaker"; analyst = rng.pick(["KM", "EN"])
                        }
                    } else if rng.chance(0.2) {
                        outcome = "r"
                        note = rng.weighted([("IS_DUPLICATE", 5), ("INCOMPLETE_FORM", 6), ("OUT_OF_SCOPE", 5),
                                             ("UNAUTHORISED_ENTITY_REV23", 2), ("INSUFFICIENT_FUNDS", 2),
                                             ("CODENAME_JUNO", 1), ("CODENAME_NEPTUNE", 1)])
                    } else if rng.chance(0.008) {
                        outcome = "h"   // a non-standard code nobody has classified yet
                        note = "On hold pending legal advice"
                    } else {
                        var pool = specialists + (rng.chance(0.25) ? ["MO", "DW", "SF", "TO"] : [])
                        if allocDate >= LocalDate(year: 2026, month: 7, day: 1)! { pool.removeAll { $0 == "RG" } }
                        if allocDate < LocalDate(year: 2026, month: 3, day: 1)! { pool.removeAll { $0 == "EN" } }
                        if pool.isEmpty { pool = ["MO"] }
                        analyst = rng.pick(pool)
                        let a = analysts.first { $0.shorthand == analyst }!
                        if rng.chance(0.04) {
                            note = "As per Protocol 67"
                        } else {
                            note = rng.pick(ExpertisePhrases.split(a.expertise).filter { !$0.contains("Operation") })
                        }
                        if analyst == "AJB" && rng.chance(0.15) { analyst = "AB" }   // an alias
                    }
                    control.append([id, cTitle, cGenre, cReg, supervisor, allocDate.iso, outcome, note, analyst,
                                    "B\(allocDate.year % 100)\(String(format: "%02d", allocDate.month))", String(supervisor.prefix(1)) + "ENTRY"])
                    if inWaymaker {
                        waymaker.append([String(format: "WM-%03d", waymaker.count + 1), id,
                                         rng.pick(["Containment", "Forensics", "Notification", "Lessons learned"]),
                                         analyst.isEmpty ? "KM" : analyst, rng.pick(["Open", "Open", "Closed", "Paused"]),
                                         rng.pick(["Green", "Amber", "Red"]), rng.pick(["Interview IT lead", "Image devices", "Draft ICO notice", "Close out"])])
                    }
                }
            }
            day = day.adding(days: 1)
        }
        // Reallocations: a few cases decided twice.
        for i in stride(from: 40, to: control.count, by: 97) {
            var again = control[i]
            guard again[6] == "a", let d = LocalDate(iso: again[5]) else { continue }
            again[5] = d.adding(days: 14).iso
            again[8] = again[8] == "MO" ? "DW" : "MO"
            again[7] = "As per Protocol 67"
            control.append(again)
        }
        // A case decided in the control sheet that the catalogue export lacks,
        // and one with an analyst shorthand nobody has mapped.
        control.append(["QD-26-99901", "Referral received by post", "Licensing", "2026-10-12", "S. Whitcombe",
                        "2026-10-15", "a", "Licensing and permits", "SF", "B2610", "SENTRY"])
        if let i = control.lastIndex(where: { $0[6] == "a" && $0[8] == "MO" && $0[5] < "2026-11" }) { control[i][8] = "JTB" }
        // A refusal with a misspelt template name.
        if let i = control.lastIndex(where: { $0[7] == "INCOMPLETE_FORM" }) { control[i][7] = "INCOMPLETE_FROM" }
        // The team leader's worksheet has missed a case, and lists one that
        // isn't in either export (a typo in the case ID).
        if waymaker.count > 3 { waymaker.remove(at: 2) }
        waymaker.append(["WM-900", "QD-26-77777", "Forensics", "KM", "Open", "Amber", "Check case ID with registry"])

        // Write the exports as the upstream systems would.
        let catalogueHeaders = ["CSE_REF_NO", "CSE_TTL_TXT", "CSE_GNR_CD", "CSE_REG_DT", "CSE_SRC_SYS", "CSE_PRTY",
                                "CSE_REGION", "LST_UPD_TS"]
        let controlHeaders = ["Case Ref", "Title (as entered)", "Genre", "Reg. Date", "Alloc Supervisor", "Date Allocated",
                              "Outcome", "Alloc Note", "Analyst (SH)", "Batch", "Entered By"]
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cm-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let catFile = tmp.appendingPathComponent("CASE_EXTRACT_20261104.csv")
        try CSV.render([catalogueHeaders] + catalogue).write(to: catFile, atomically: true, encoding: .utf8)
        let ctlFile = tmp.appendingPathComponent("Allocation Control Sheet (export).csv")
        try CSV.render([controlHeaders] + control).write(to: ctlFile, atomically: true, encoding: .utf8)

        var catMap = ColumnMapping.guess(headers: catalogueHeaders, for: .catalogue)
        catMap.originalFilename = catFile.lastPathComponent
        catMap.importedAt = "2026-11-04"
        try ws.importSource(.catalogue, from: catFile, mapping: catMap)
        var ctlMap = ColumnMapping.guess(headers: controlHeaders, for: .controlSheet)
        ctlMap.originalFilename = ctlFile.lastPathComponent
        ctlMap.importedAt = "2026-11-04"
        try ws.importSource(.controlSheet, from: ctlFile, mapping: ctlMap)

        let wmFile = tmp.appendingPathComponent("Waymaker tracker v7.csv")
        try CSV.render([["Op Ref", "Case", "Workstream", "Lead", "Status", "RAG", "Next Action"]] + waymaker)
            .write(to: wmFile, atomically: true, encoding: .utf8)
        try ws.importWorksheet(ProjectDefinition(
            id: "operation-waymaker", name: "Operation Waymaker", badge: "WAY", colour: "indigo", leader: "KM",
            leaderTitle: "Team Leader", caseIDColumn: "Case", outcomeCodes: ["Operation Waymaker"],
            noteKeywords: ["Waymaker"], originalFilename: wmFile.lastPathComponent, importedAt: "2026-11-03"), from: wmFile)

        // A batch in progress: a shortlist on one waiting case, two rows
        // ready to paste, and one that has since landed in the control sheet.
        let book = CaseBook.build(ws.load())
        let waiting = book.rows.filter { $0.status == .awaiting && $0.inCatalogue }
        if waiting.count >= 3 {
            data.decisions[waiting[0].caseID] = CaseDecision(shortlist: ["AJB", "MO"], note: "Check MO's November load first",
                                                             updated: "2026-11-04")
            data.decisions[waiting[1].caseID] = CaseDecision(shortlist: ["KM", "EN"], outcome: "a", analyst: "EN",
                                                             note: "Cyber incident response", supervisor: "M. Okafor",
                                                             date: "2026-11-05", order: 2, updated: "2026-11-05")
            data.decisions[waiting[2].caseID] = CaseDecision(outcome: "r", note: "OUT_OF_SCOPE", supervisor: "M. Okafor",
                                                             date: "2026-11-05", order: 3, updated: "2026-11-05")
        }
        if let landed = book.rows.last(where: { $0.status == .allocated && $0.inCatalogue }), let l = landed.latest {
            data.decisions[landed.caseID] = CaseDecision(outcome: l.outcome, analyst: l.analyst, note: l.note,
                                                         supervisor: l.supervisor, date: l.allocationDate?.iso ?? "",
                                                         order: 1, updated: l.allocationDate?.iso ?? "")
        }
        try ws.save(.settings, from: data)
        try ws.save(.analysts, from: data)
        try ws.save(.templates, from: data)
        try ws.save(.decisions, from: data)
    }
}
