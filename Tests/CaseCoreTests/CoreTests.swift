import XCTest
@testable import CaseCore

final class DateTests: XCTestCase {
    func d(_ y: Int, _ m: Int, _ day: Int) -> LocalDate { LocalDate(year: y, month: m, day: day)! }

    func testFormats() {
        XCTAssertEqual(DateParser.parse("2026-11-05"), d(2026, 11, 5))
        XCTAssertEqual(DateParser.parse("2026-11-05T14:30:00Z"), d(2026, 11, 5))
        XCTAssertEqual(DateParser.parse("2026-11-05 14:30"), d(2026, 11, 5))
        XCTAssertEqual(DateParser.parse("05/11/2026"), d(2026, 11, 5))
        XCTAssertEqual(DateParser.parse("05/11/2026", order: .monthFirst), d(2026, 5, 11))
        XCTAssertEqual(DateParser.parse("25/12/2026", order: .monthFirst), d(2026, 12, 25), "a day over 12 wins")
        XCTAssertEqual(DateParser.parse("5-Nov-26"), d(2026, 11, 5))
        XCTAssertEqual(DateParser.parse("November 5th, 2026"), d(2026, 11, 5))
        XCTAssertEqual(DateParser.parse("5 Sept 2026"), d(2026, 9, 5))
        XCTAssertEqual(DateParser.parse("20261105"), d(2026, 11, 5))
        XCTAssertEqual(DateParser.parse("46331"), d(2026, 11, 5), "Excel serial")
        XCTAssertEqual(DateParser.parse("26/11/05", order: .yearFirst), d(2026, 11, 5))
        XCTAssertNil(DateParser.parse(""))
        XCTAssertNil(DateParser.parse("not a date"))
        XCTAssertNil(DateParser.parse("31/02/2026"))
    }

    func testMonthArithmetic() {
        let nov = MonthKey(year: 2026, month: 11)
        XCTAssertEqual(nov.adding(months: 2), MonthKey(year: 2027, month: 1))
        XCTAssertEqual(nov.adding(months: -11), MonthKey(year: 2025, month: 12))
        XCTAssertEqual(nov.trailing(12).count, 12)
        XCTAssertEqual(nov.trailing(12).first, MonthKey(year: 2025, month: 12))
        XCTAssertEqual(d(2026, 3, 1).adding(days: -1), d(2026, 2, 28))
        XCTAssertEqual(LocalDate(dayNumber: d(2024, 2, 29).dayNumber), d(2024, 2, 29))
    }
}

final class CSVTests: XCTestCase {
    func testParseQuotedAndSeparators() {
        let t = CSVTable(text: "\u{FEFF}A;B;C\n1;\"x;y\";\"he said \"\"hi\"\"\"\n2;;\n")
        XCTAssertEqual(t.headers, ["A", "B", "C"])
        XCTAssertEqual(t.rows, [["1", "x;y", "he said \"hi\""], ["2", "", ""]])
    }

    func testRaggedRowsAndBlankHeaders() {
        let t = CSVTable(text: "ID,,ID\n1,2\n3,4,5,6\n,,\n")
        XCTAssertEqual(t.headers, ["ID", "Column 2", "ID (2)"])
        XCTAssertEqual(t.rows, [["1", "2", ""], ["3", "4", "5"]])
    }

    func testWindows1252() {
        let bytes = Data([0x49, 0x44, 0x0A, 0x43, 0x61, 0x66, 0xE9, 0x0A])   // "Café" in CP1252
        XCTAssertEqual(CSVTable(data: bytes).rows, [["Café"]])
    }
}

final class MappingTests: XCTestCase {
    func testGuessesUglyHeaders() {
        let headers = ["CSE_REF_NO", "CSE_TTL_TXT", "CSE_GNR_CD", "CSE_REG_DT", "CSE_PRTY"]
        let m = ColumnMapping.guess(headers: headers, for: .catalogue)
        XCTAssertEqual(m.header(.caseID), "CSE_REF_NO")
        XCTAssertEqual(m.header(.title), "CSE_TTL_TXT")
        XCTAssertEqual(m.header(.genre), "CSE_GNR_CD")
        XCTAssertEqual(m.header(.registrationDate), "CSE_REG_DT")
    }

    func testGuessesControlSheet() {
        let headers = ["Case Ref", "Title (as entered)", "Genre", "Reg. Date", "Alloc Supervisor", "Date Allocated",
                       "Outcome", "Alloc Note", "Analyst (SH)", "Batch"]
        let m = ColumnMapping.guess(headers: headers, for: .controlSheet)
        XCTAssertEqual(m.header(.caseID), "Case Ref")
        XCTAssertEqual(m.header(.supervisor), "Alloc Supervisor")
        XCTAssertEqual(m.header(.allocationDate), "Date Allocated")
        XCTAssertEqual(m.header(.outcome), "Outcome")
        XCTAssertEqual(m.header(.note), "Alloc Note")
        XCTAssertEqual(m.header(.analyst), "Analyst (SH)")
        XCTAssertEqual(m.header(.registrationDate), "Reg. Date")
        XCTAssertTrue(m.fits(headers, for: .controlSheet))
        XCTAssertFalse(m.fits(["Case Ref"], for: .controlSheet))
    }

    func testRoundTrip() throws {
        let m = ColumnMapping(columns: [.caseID: "ID", .title: "Title: long"], dateOrder: .monthFirst,
                              originalFilename: "export.csv", importedAt: "2026-11-05")
        XCTAssertEqual(try MappingFile.parse(MappingFile.render(m, source: .catalogue)), m)
    }
}

final class FileTests: XCTestCase {
    func testSettingsRoundTripKeepsUnknownKeys() throws {
        var s = WorkspaceSettings(title: "Directorate", specialNotes: ["As per Protocol 67"])
        s.outcomes.append(OutcomeCode(code: "Operation Waymaker", kind: .project, label: "Waymaker",
                                      project: "operation-waymaker"))
        s.outcomes.append(OutcomeCode(code: "h", kind: .other, rates: .refused, countsAsWorkload: false))
        s.extra = [YAMLPair("custom", .str("value"))]
        let text = SettingsFile.render(s)
        XCTAssertEqual(try SettingsFile.parse(text), s)
        XCTAssertTrue(text.contains("custom: value"))
    }

    func testStandardCodesAreAlwaysPresent() throws {
        let s = try SettingsFile.parse("outcomes:\n- code: a\n  kind: allocated\n- code: r\n  kind: refused\n- code: X\n  kind: other\n")
        XCTAssertEqual(s.outcomes.map(\.code), ["a", "r", "sp", "X"], "sp is added to older workspaces, after a and r")
        XCTAssertEqual(s.outcome(for: "sp")?.kind, .special)
        XCTAssertEqual(s.outcome(for: "sp")?.rates, .special)
        XCTAssertEqual(try SettingsFile.parse("").outcomes.map(\.code), ["a", "r", "sp"])
    }

    func testAnalystsAndTemplatesRoundTrip() throws {
        let a = [Analyst(shorthand: "AJB", name: "Alice Brown", expertise: "Fraud; procurement: public sector",
                         aliases: ["AB"], active: false, notes: "Part time")]
        let parsed = try AnalystsFile.parse(AnalystsFile.render(a))
        XCTAssertEqual(parsed.map(\.shorthand), ["AJB"])
        XCTAssertEqual(parsed[0].expertise, a[0].expertise)
        XCTAssertEqual(parsed[0].aliases, ["AB"])
        XCTAssertFalse(parsed[0].active)
        let t = [ReturnTemplate(name: "OUT_OF_SCOPE"), ReturnTemplate(name: "IS_DUPLICATE", description: "Already registered"),
                 ReturnTemplate(name: "codename_juno")]
        let back = try TemplatesFile.parse(TemplatesFile.render(t))
        XCTAssertEqual(back.map(\.name), ["codename_juno", "IS_DUPLICATE", "OUT_OF_SCOPE"], "written alphabetically")
        XCTAssertEqual(back[1].description, "Already registered")
        XCTAssertEqual(try TemplatesFile.parse("templates:\n- OUT_OF_SCOPE\n").map(\.name), ["OUT_OF_SCOPE"])
    }

    func testDecisionsRoundTrip() throws {
        let d = ["26-0001": CaseDecision(shortlist: ["AJB", "KM"], outcome: "a", analyst: "AJB", note: "fraud",
                                         supervisor: "M. Okafor", date: "2026-11-05", order: 3, updated: "2026-11-05"),
                 "0042": CaseDecision(shortlist: ["KM"]),
                 "EMPTY": CaseDecision()]
        let parsed = try DecisionsFile.parse(DecisionsFile.render(d))
        XCTAssertEqual(parsed, ["26-0001": d["26-0001"]!, "0042": d["0042"]!], "IDs stay strings: 0042 is not 42")
        XCTAssertEqual(try DecisionsFile.parse(DecisionsFile.render([:])), [:])
    }

    func testProjectRoundTrip() throws {
        let p = ProjectDefinition(id: "operation-waymaker", name: "Operation Waymaker", badge: "WAY", leader: "KM",
                                  leaderTitle: "Captain", caseIDColumn: "Case", outcomeCodes: ["Operation Waymaker"],
                                  noteKeywords: ["Waymaker"])
        XCTAssertEqual(try ProjectFile.parse(ProjectFile.render(p), id: p.id), p)
        XCTAssertEqual(ProjectDefinition.slug("Operation  Waymaker!"), "operation-waymaker")
    }
}

/// A small workspace in memory for the join, workload and rates tests.
func makeData() -> WorkspaceData {
    var data = WorkspaceData()
    data.settings.outcomes.append(OutcomeCode(code: "Operation Waymaker", kind: .project, project: "way"))
    data.settings.specialNotes = ["As per Protocol 67"]
    data.analysts = [
        Analyst(shorthand: "AJB", name: "Alice Brown", expertise: "Forensic accounting; procurement fraud", aliases: ["AB"]),
        Analyst(shorthand: "KM", name: "Kofi Mensah", expertise: "Data breaches; cyber incident response"),
    ]
    data.templates = [ReturnTemplate(name: "IS_DUPLICATE")]
    data.tables[.catalogue] = CSVTable(headers: ["ID", "T", "G", "R"], rows: [
        ["C1", "Invoice fraud", "Finance", "01/10/2026"],
        ["C2", "Laptop stolen", "Data", "02/10/2026"],
        ["C3", "Duplicate claim", "Finance", "03/10/2026"],
        ["C4", "Waymaker lead", "Data", "04/10/2026"],
        ["C5", "New case", "Finance", "01/11/2026"],
        ["C5", "Duplicate row", "Finance", "01/11/2026"],
        ["00123", "Leading zeros", "Data", "01/11/2026"],
        ["C6", "Special one", "Data", "02/11/2026"],
    ])
    data.mappings[.catalogue] = ColumnMapping(columns: [.caseID: "ID", .title: "T", .genre: "G", .registrationDate: "R"])
    data.tables[.controlSheet] = CSVTable(
        headers: ["ID", "T", "G", "R", "S", "D", "O", "N", "A"], rows: [
            ["C1", "Invoice  FRAUD", "Finance", "2026-10-01", "Sup1", "2026-10-02", "a", "procurement fraud", "ab"],
            ["C2", "Laptop stolen (old)", "Data", "2026-10-05", "Sup1", "2026-10-06", "a", "As per Protocol 67", "KM"],
            ["C3", "Duplicate claim", "Finance", "2026-10-03", "Sup2", "2026-11-01", "r", "IS_DUPLICATE", ""],
            ["C4", "Waymaker lead", "Data", "2026-10-04", "Sup2", "2026-11-02", "Operation Waymaker", "", "KM"],
            ["C9", "Ghost", "Data", "", "Sup2", "2026-11-03", "a", "cyber", "ZZ"],
            ["C1", "Invoice fraud", "Finance", "2026-10-01", "Sup2", "2026-09-30", "r", "IS_DUPLICATE", ""],
            ["123", "Not the same case", "Data", "", "Sup2", "2026-11-03", "r", "IS_DUPLICATE", ""],
            ["C6", "Special one", "Data", "", "Sup2", "2026-11-04", "sp", "Joint review with Legal", ""],
        ])
    data.mappings[.controlSheet] = ColumnMapping(columns: [.caseID: "ID", .title: "T", .genre: "G", .registrationDate: "R",
                                                           .supervisor: "S", .allocationDate: "D", .outcome: "O",
                                                           .note: "N", .analyst: "A"])
    data.projects = [ProjectWorksheet(
        definition: ProjectDefinition(id: "way", name: "Operation Waymaker", leader: "KM", caseIDColumn: "Case",
                                      outcomeCodes: ["Operation Waymaker"]),
        table: CSVTable(headers: ["Case", "Workstream"], rows: [["C2", "Alpha"], ["W-99", "Beta"]]))]
    data.decisions = [
        "C5": CaseDecision(shortlist: ["AJB"], outcome: "a", analyst: "AB", note: "procurement fraud",
                           supervisor: "Sup1", date: "2026-11-05", order: 2),
        "00123": CaseDecision(outcome: "r", note: "NOT_A_TEMPLATE", supervisor: "Sup1", date: "2026-11-05", order: 1),
        "C1": CaseDecision(outcome: "a", analyst: "AJB", note: "x", supervisor: "Sup1", date: "2026-10-02", order: 3),
        "C2": CaseDecision(outcome: "a", analyst: "AJB", note: "x", supervisor: "Sup1", date: "2026-10-06", order: 4),
    ]
    return data
}

final class CaseBookTests: XCTestCase {
    func testJoin() {
        let book = CaseBook.build(makeData())
        XCTAssertEqual(book.rows.map(\.caseID), ["C1", "C2", "C3", "C4", "C5", "00123", "C6", "C9", "123"])
        XCTAssertEqual(book.row("C6")!.status, .special("sp"))
        XCTAssertEqual(book.row("C6")!.noteKind, .special)
        XCTAssertNil(book.row("c1"), "case IDs are verbatim")
        XCTAssertEqual(book.row("00123")!.status, .awaiting)
        XCTAssertEqual(book.row(" 123 ")!.status, .refused, "only surrounding space is ignored")

        let c1 = book.row("C1")!
        XCTAssertEqual(c1.allocations.count, 2)
        XCTAssertEqual(c1.status, .allocated, "the latest decision by date wins")
        XCTAssertEqual(c1.analystKey, "AJB", "aliases resolve")
        XCTAssertEqual(c1.noteKind, .expertise)
        XCTAssertTrue(c1.discrepancies.isEmpty, "case and spacing are ignored by default")

        let c2 = book.row("C2")!
        XCTAssertEqual(c2.discrepancies.map(\.field), [.title, .registrationDate])
        XCTAssertTrue(c2.hasWarning)
        XCTAssertEqual(c2.noteKind, .special)
        XCTAssertEqual(c2.projects, ["way"])

        XCTAssertEqual(book.row("C3")!.status, .refused)
        XCTAssertEqual(book.row("C3")!.noteKind, .template)

        let c4 = book.row("C4")!
        XCTAssertEqual(c4.status, .project("Operation Waymaker"))
        XCTAssertTrue(c4.flags.contains(.missingFromWorksheet("way")))

        let c5 = book.row("C5")!
        XCTAssertEqual(c5.status, .awaiting)
        XCTAssertTrue(c5.flags.contains(.duplicateInCatalogue))
        XCTAssertEqual(c5.openProposal, "AB")
        XCTAssertTrue(c5.isInBatch)

        let c9 = book.row("C9")!
        XCTAssertFalse(c9.inCatalogue)
        XCTAssertTrue(c9.flags.contains(.notInCatalogue))
        XCTAssertTrue(c9.flags.contains(.unknownAnalyst("ZZ")))
        XCTAssertEqual(book.unknownShorthands, ["ZZ": 1])
        XCTAssertEqual(book.worksheetOrphans["way"], ["W-99"])
        XCTAssertEqual(book.genres, ["Data", "Finance"])
    }

    func testStrictComparison() {
        var data = makeData()
        data.settings.lenientComparison = false
        XCTAssertEqual(CaseBook.build(data).row("C1")!.discrepancies.map(\.field), [.title])
    }

    func testUnclassifiedOutcome() {
        var data = makeData()
        data.settings.outcomes.removeAll { $0.kind == .project }
        let c4 = CaseBook.build(data).row("C4")!
        XCTAssertEqual(c4.status, .other("Operation Waymaker"))
        XCTAssertTrue(c4.flags.contains(.unknownOutcome("Operation Waymaker")))
    }
}

final class WorkloadTests: XCTestCase {
    func testPivotAndMetrics() {
        let book = CaseBook.build(makeData())
        let events = Workload.events(book)
        // C1 (AJB, Oct), C2 (KM, Oct), C4 (KM, Nov, project counts), C9 (ZZ, Nov). C3 refused.
        XCTAssertEqual(events.map(\.caseID).sorted(), ["C1", "C2", "C4", "C9"])
        let oct = MonthKey(year: 2026, month: 10), nov = MonthKey(year: 2026, month: 11)
        let p = Workload.pivot(events, months: [oct, nov], analysts: ["AJB", "KM"])
        XCTAssertEqual(p.analysts, ["AJB", "KM", "ZZ"])
        XCTAssertEqual(p.count("KM", oct), 1)
        XCTAssertEqual(p.columnTotal(nov), 2)
        XCTAssertEqual(p.grandTotal, 4)
        XCTAssertEqual(p.cases("AJB", oct), ["C1"])

        let m = Workload.metrics(events, today: LocalDate(year: 2026, month: 11, day: 5)!)
        XCTAssertEqual(m["KM"]?.thisMonth, 1)
        XCTAssertEqual(m["KM"]?.lastMonth, 1)
        XCTAssertEqual(m["KM"]?.past12, 2)
        XCTAssertEqual(m["KM"]?.monthly.suffix(2), [1, 1])
        XCTAssertEqual(m["KM"]?.genres["Data"], 2)
        XCTAssertEqual(Workload.coefficientOfVariation([2, 2, 2]), 0)
        XCTAssertNil(Workload.coefficientOfVariation([0, 0]))
    }

    func testRates() {
        let book = CaseBook.build(makeData())
        let rows = Rates.rows(book, by: .month)
        XCTAssertEqual(rows.map(\.key), ["2026-10", "2026-11"])
        XCTAssertEqual(rows[0].accepted, 2)
        XCTAssertEqual(rows[1].accepted, 1)
        XCTAssertEqual(rows[1].refused, 2)
        XCTAssertEqual(rows[1].other, 1, "the project outcome is shown separately")
        XCTAssertEqual(rows[1].special, 1, "sp has a column of its own, in neither rate")
        XCTAssertEqual(rows[1].acceptanceRate!, 1.0 / 3, accuracy: 1e-9)
        let total = Rates.overall(rows)
        XCTAssertEqual(total.acceptanceRate!, 0.6, accuracy: 1e-9)
        let bySup = Rates.rows(book, by: .supervisor)
        XCTAssertEqual(bySup.first?.key, "Sup2")
    }
}

final class SearchTests: XCTestCase {
    func testQuery() {
        let q = ExpertiseQuery("fraud \"public sector\", grants")
        XCTAssertEqual(q.terms, ["fraud", "public sector", "grants"])
        let text = "Procurement FRAUD in the Public Sector; fraud"
        XCTAssertEqual(q.matchedTerms(in: text), 2)
        XCTAssertFalse(q.accepts(text))
        XCTAssertTrue(ExpertiseQuery("fraud grants", matchAll: false).accepts(text))
        XCTAssertEqual(q.matches(in: text), [12..<17, 25..<38, 40..<45])
        XCTAssertEqual(q.firstMatch(in: text), "FRAUD")
        XCTAssertEqual(ExpertiseQuery("café").matchedTerms(in: "Cafe culture"), 1)
    }

    func testPhrases() {
        XCTAssertEqual(ExpertisePhrases.split("Fraud; procurement, Fraud\n• grants."), ["Fraud", "procurement", "grants"])
    }
}

final class WorkspaceTests: XCTestCase {
    func testSaveLoadImport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = Workspace(root: dir)
        try ws.ensureLayout(title: "Test")
        XCTAssertTrue(Workspace.looksLikeWorkspace(dir))
        XCTAssertEqual(Workspace.summary(dir), "Test")

        let csv = dir.appendingPathComponent("export.csv")
        try "ID;Title\nX1;One\n".write(to: csv, atomically: true, encoding: .utf8)
        try ws.importSource(.catalogue, from: csv, mapping: ColumnMapping(columns: [.caseID: "ID", .title: "Title"]))
        var data = ws.load()
        XCTAssertEqual(data.tables[.catalogue]?.rows, [["X1", "One"]])
        XCTAssertEqual(data.mappings[.catalogue]?.header(.title), "Title")
        XCTAssertFalse(ws.changedOutside())

        data.analysts = [Analyst(shorthand: "AB")]
        try ws.save(.analysts, from: data)
        XCTAssertEqual(ws.load().analysts.map(\.shorthand), ["AB"])

        try "analysts: [unclosed".write(to: ws.url(for: Workspace.analystsFile), atomically: true, encoding: .utf8)
        let broken = ws.load()
        XCTAssertEqual(broken.issues.map(\.relativePath), [Workspace.analystsFile])
        XCTAssertThrowsError(try ws.save(.analysts, from: data), "a file that failed to load is not overwritten")
    }
}

final class BatchTests: XCTestCase {
    func testDateStyles() {
        let nov5 = LocalDate(year: 2026, month: 11, day: 5)!
        XCTAssertEqual(DateStyle.infer(["2026-10-01"], order: .dayFirst).format(nov5), "2026-11-05")
        XCTAssertEqual(DateStyle.infer(["25/10/2026"], order: .dayFirst).format(nov5), "05/11/2026")
        XCTAssertEqual(DateStyle.infer(["10/25/2026"], order: .dayFirst).format(nov5), "11/05/2026")
        XCTAssertEqual(DateStyle.infer(["3/7/26", "12/10/26"], order: .dayFirst).format(nov5), "5/11/26")
        XCTAssertEqual(DateStyle.infer(["01-Oct-2026 09:00"], order: .dayFirst).format(nov5), "05-Nov-2026")
        XCTAssertEqual(DateStyle.infer(["", "junk"], order: .dayFirst), .iso)
    }

    func testPreparedRows() {
        let data = makeData()
        let book = CaseBook.build(data)
        let rows = Batch.rows(data, book: book)
        XCTAssertEqual(rows.map(\.caseID), ["00123", "C5", "C1", "C2"], "in batch order")
        XCTAssertEqual(rows.map(\.state), [.pending, .pending, .landed, .landedDifferently])
        XCTAssertEqual(rows[1].values, ["C5", "New case", "Finance", "2026-11-01", "Sup1", "2026-11-05", "a",
                                        "procurement fraud", "AB"])
        XCTAssertEqual(rows[0].problems, ["The note is not a return-to-sender template."])
        let text = Batch.pasteText(Array(rows.prefix(1)), headers: Batch.headers(data), tabSeparated: true, includeHeader: true)
        XCTAssertEqual(text, "ID\tT\tG\tR\tS\tD\tO\tN\tA\n00123\tLeading zeros\tData\t2026-11-01\tSup1\t2026-11-05\tr\tNOT_A_TEMPLATE\t\n")
        XCTAssertEqual(Batch.pendingLoad(rows, settings: data.settings, book: book), ["AJB": 1])
        XCTAssertEqual(Batch.nextOrder(data), 5)
    }

    func testFreshness() {
        var data = makeData()
        data.mappings[.controlSheet]?.importedAt = "2026-11-01"
        let f = Freshness.of(.controlSheet, data: data, book: CaseBook.build(data))!
        XCTAssertEqual(f.latestDate, LocalDate(year: 2026, month: 11, day: 4))
        XCTAssertEqual(f.age(today: LocalDate(year: 2026, month: 11, day: 5)!), 4)
        XCTAssertEqual(Freshness.describe(age: 1), "yesterday")
    }
}

/// The app must never touch the network (docs/MAINTENANCE.md §Offline):
/// no networking API may appear anywhere in the sources.
final class OfflineTests: XCTestCase {
    func testNoNetworkingAPIs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let forbidden = ["URLSession", "URLRequest", "NSURLConnection", "import Network", "NWConnection", "NWPathMonitor",
                         "NWListener", "WebKit", "WKWebView", "openURL", "Link(", "AsyncImage", "http://", "https://",
                         "CFSocket", "CFStream", "NSStream", "Bonjour", "NetService", "CloudKit", "MultipeerConnectivity"]
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in forbidden {
                XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) mentions \(word)")
            }
        }
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertFalse(manifest.contains(".package("), "no package dependencies: building must not download anything")
    }
}

/// Table cells are hosted one by one and don't reliably inherit the
/// environment: a cell view reading `@Environment(AppModel.self)` crashed
/// the app when the case table first drew rows (docs/MAINTENANCE.md §2.2).
/// No view that reads the model from the environment may be used in a
/// table column.
final class HostingTests: XCTestCase {
    func testTableCellsDoNotReadTheModelFromTheEnvironment() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("Sources/QDVCCaseManager")
        let files = try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let texts = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertFalse(texts.isEmpty)

        // Views that declare @Environment(AppModel.self).
        var envViews = Set<String>()
        for text in texts {
            var current: String?
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("struct "), t.contains(": View") {
                    current = t.dropFirst(7).split(whereSeparator: { $0 == ":" || $0 == " " }).first.map(String.init)
                }
                if t.contains("@Environment(AppModel.self)"), let name = current { envViews.insert(name) }
            }
        }
        XCTAssertTrue(envViews.contains("CaseTable"), "the scan found the views")

        // Every line of a TableColumn's content (from TableColumn( to its .width).
        // Cells are plain values: they don't read the model at all (each
        // cell would observe it) and carry no tooltips (each brings AppKit
        // tracking along); both slowed the app as rows came and went.
        for (file, text) in zip(files, texts) {
            var inColumn = false
            for line in text.split(separator: "\n") {
                if line.contains("TableColumn(") { inColumn = true }
                if inColumn {
                    for name in envViews where line.contains("\(name)(") {
                        XCTFail("\(file.lastPathComponent): \(name) reads AppModel from the environment but is used in a table column")
                    }
                    if line.contains("model.") { XCTFail("\(file.lastPathComponent): a table cell reads the model: \(line)") }
                    if line.contains(".help(") { XCTFail("\(file.lastPathComponent): a table cell has a tooltip: \(line)") }
                }
                if line.contains(".width(") { inColumn = false }
            }
        }
        // Views used as cells don't read the model or carry tooltips either.
        for cell in ["CaseIDCell", "StatusCell", "NoteCell", "ProjectTags", "ShorthandText"] {
            guard let text = texts.first(where: { $0.contains("struct \(cell): View") }) else {
                XCTFail("\(cell) not found"); continue
            }
            let start = text.range(of: "struct \(cell): View")!.lowerBound
            let rest = text[start...]
            let body = rest[..<(rest.range(of: "\n}\n")?.upperBound ?? rest.endIndex)]
            XCTAssertFalse(body.contains("AppModel"), "\(cell) must not use the model")
            XCTAssertFalse(body.contains(".help("), "\(cell) must not carry a tooltip")
        }
    }
}

final class DerivedTests: XCTestCase {
    func testEverythingIsPrecomputed() {
        let today = LocalDate(year: 2026, month: 11, day: 5)!
        let d = Derived.compute(makeData(), today: today)
        XCTAssertEqual(d.book.rows.count, 9)
        XCTAssertEqual(d.workload.count, Derived.spans.count * 2, "every period, with and without inactive analysts")
        XCTAssertEqual(d.rates.count, Derived.spans.count * Rates.Grouping.allCases.count)

        let w = d.workload[WorkloadKey(months: 12, includeInactive: false)]!
        XCTAssertEqual(w.pivot.months.count, 12)
        XCTAssertEqual(w.analysts(.total), ["KM", "AJB", "ZZ"], "busiest first")
        XCTAssertEqual(w.analysts(.name), ["AJB", "KM", "ZZ"])
        XCTAssertEqual(w.activeMean, 1.5)

        XCTAssertEqual(d.workloadSummary.total, 1, "KM's Waymaker case this month")
        XCTAssertEqual(d.workloadSummary.busiest, AnalystCount(shorthand: "KM", count: 1))
        XCTAssertEqual(d.years.map(\.year), [2026, YearSummary.undated])
        XCTAssertEqual(d.years.first?.awaiting, 2)
        XCTAssertEqual(d.missingCounts, ["way": 1])

        let rates = d.rates[RatesKey(grouping: .month, months: 12)]!
        XCTAssertEqual(rates.rows.count, 12)
        XCTAssertEqual(rates.total.accepted, 3)
    }

    /// A rebuild of a workspace this size must stay well under a second
    /// (it runs off the main thread, but the dashboards wait for it).
    func testComputeIsQuick() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = Workspace(root: root.appendingPathComponent("sample-workspace")).load()
        XCTAssertGreaterThan(data.tables[.catalogue]?.rows.count ?? 0, 800)
        let start = Date()
        _ = Derived.compute(data, today: LocalDate(year: 2026, month: 11, day: 5)!)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "debug build; release is several times faster")
    }
}
