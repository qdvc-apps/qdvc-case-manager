import Foundation

extension YAMLNode {
    /// A scalar's text, trimmed; "" if missing.
    func text(_ key: String) -> String {
        self[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func trimmedStrings(_ key: String) -> [String] {
        (self[key]?.strings ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

enum YamlIO {
    /// The document's top-level mapping (an empty file is an empty mapping).
    static func document(_ text: String) throws -> YAMLNode {
        let node: YAMLNode
        do {
            node = try YAML.parse(text)
        } catch {
            throw FileError.invalidYAML(String(describing: error))
        }
        switch node {
        case .null: return .mapping([])
        case .mapping: return node
        default: throw FileError.notAMapping
        }
    }
}

/// `case-manager.yml` (docs/FILE_FORMAT.md §2).
public enum SettingsFile {
    static let known: Set<String> = ["format", "title", "lenient_comparison", "special_notes", "outcomes"]

    public static func parse(_ text: String) throws -> WorkspaceSettings {
        let doc = try YamlIO.document(text)
        var s = WorkspaceSettings(outcomes: [])
        s.title = doc.text("title")
        s.lenientComparison = doc["lenient_comparison"]?.bool ?? true
        s.specialNotes = doc.trimmedStrings("special_notes")
        for item in doc["outcomes"]?.items ?? [] {
            let code = item.text("code")
            guard !code.isEmpty else { continue }
            s.outcomes.append(OutcomeCode(
                code: code, kind: OutcomeKind(rawValue: item.text("kind")) ?? .other, label: item.text("label"),
                rates: RateTreatment(rawValue: item.text("rates")), countsAsWorkload: item["workload"]?.bool,
                project: item.text("project")))
        }
        // Every workspace has the standard codes; ones added since a
        // workspace was made (such as sp) are added to it.
        for standard in OutcomeCode.standard.reversed() where !s.outcomes.contains(where: { $0.code == standard.code }) {
            let after = OutcomeCode.standard.prefix { $0.code != standard.code }.compactMap { std in
                s.outcomes.firstIndex { $0.code == std.code }
            }.max()
            s.outcomes.insert(standard, at: after.map { $0 + 1 } ?? 0)
        }
        s.extra = doc.pairs.filter { !known.contains($0.key) }
        return s
    }

    public static func render(_ s: WorkspaceSettings) -> String {
        var pairs: [(String, YAMLNode)] = [
            ("format", .num(1)),
            ("title", .str(s.title)),
            ("lenient_comparison", .flag(s.lenientComparison)),
        ]
        if !s.specialNotes.isEmpty { pairs.append(("special_notes", .list(s.specialNotes))) }
        pairs.append(("outcomes", .sequence(s.outcomes.map { o in
            var p: [(String, YAMLNode)] = [("code", .str(o.code)), ("kind", .str(o.kind.rawValue))]
            if !o.label.isEmpty { p.append(("label", .str(o.label))) }
            if o.rates != OutcomeCode.defaultRates(o.kind) { p.append(("rates", .str(o.rates.rawValue))) }
            if o.countsAsWorkload != OutcomeCode.defaultWorkload(o.kind) { p.append(("workload", .flag(o.countsAsWorkload))) }
            if !o.project.isEmpty { p.append(("project", .str(o.project))) }
            return .map(p)
        })))
        var node = YAMLNode.map(pairs)
        if case .mapping(var all) = node {
            all.append(contentsOf: s.extra)
            node = .mapping(all)
        }
        return YAML.emit(node)
    }
}

/// `analysts.yml` (§3).
public enum AnalystsFile {
    public static func parse(_ text: String) throws -> [Analyst] {
        let doc = try YamlIO.document(text)
        return (doc["analysts"]?.items ?? []).compactMap { item in
            let shorthand = item.text("shorthand")
            guard !shorthand.isEmpty else { return nil }
            return Analyst(shorthand: shorthand, name: item.text("name"), expertise: item.text("expertise"),
                           aliases: item.trimmedStrings("aliases"), active: item["active"]?.bool ?? true,
                           notes: item.text("notes"))
        }
    }

    public static func render(_ analysts: [Analyst]) -> String {
        let items = analysts.map { a -> YAMLNode in
            var p: [(String, YAMLNode)] = [("shorthand", .str(a.shorthand)), ("name", .str(a.name)),
                                           ("active", .flag(a.active))]
            if !a.aliases.isEmpty { p.append(("aliases", .list(a.aliases))) }
            p.append(("expertise", .str(a.expertise)))
            if !a.notes.isEmpty { p.append(("notes", .str(a.notes))) }
            return .map(p)
        }
        return YAML.emit(.map([("analysts", .sequence(items))]))
    }
}

/// `templates.yml` (§4).
public enum TemplatesFile {
    public static func parse(_ text: String) throws -> [ReturnTemplate] {
        let doc = try YamlIO.document(text)
        return (doc["templates"]?.items ?? []).compactMap { item in
            if let name = item.string {
                let n = name.trimmingCharacters(in: .whitespaces)
                return n.isEmpty ? nil : ReturnTemplate(name: n)
            }
            let name = item.text("name")
            return name.isEmpty ? nil : ReturnTemplate(name: name, description: item.text("description"))
        }
    }

    /// Written in alphabetical order.
    public static func render(_ templates: [ReturnTemplate]) -> String {
        let items = ReturnTemplate.sorted(templates).map { t -> YAMLNode in
            var p: [(String, YAMLNode)] = [("name", .str(t.name))]
            if !t.description.isEmpty { p.append(("description", .str(t.description))) }
            return .map(p)
        }
        return YAML.emit(.map([("templates", .sequence(items))]))
    }
}

/// `mappings/<source>.yml` (§5).
public enum MappingFile {
    public static func parse(_ text: String) throws -> ColumnMapping {
        let doc = try YamlIO.document(text)
        var m = ColumnMapping()
        m.dateOrder = DateOrder(rawValue: doc.text("date_order")) ?? .dayFirst
        m.originalFilename = doc.text("original_filename")
        m.importedAt = doc.text("imported_at")
        for pair in doc["columns"]?.pairs ?? [] {
            if let field = MappedField(rawValue: pair.key), let header = pair.value.string, !header.isEmpty {
                m.columns[field] = header
            }
        }
        return m
    }

    public static func render(_ m: ColumnMapping, source: SourceKind) -> String {
        let cols = source.fields.compactMap { f in m.header(f).map { (f.rawValue, YAMLNode.str($0)) } }
        return YAML.emit(.map([
            ("source", .str(source.csvPath)),
            ("original_filename", .str(m.originalFilename)),
            ("imported_at", .str(m.importedAt)),
            ("date_order", .str(m.dateOrder.rawValue)),
            ("columns", .map(cols)),
        ]))
    }
}

/// `projects/<id>.yml` (§6).
public enum ProjectFile {
    public static func parse(_ text: String, id: String) throws -> ProjectDefinition {
        let doc = try YamlIO.document(text)
        var d = ProjectDefinition(id: id, name: doc.text("name"))
        if d.name.isEmpty { d.name = id }
        d.badge = doc.text("badge")
        let colour = doc.text("colour")
        d.colour = colour.isEmpty ? "indigo" : colour
        d.leader = doc.text("leader")
        let title = doc.text("leader_title")
        d.leaderTitle = title.isEmpty ? "Team Leader" : title
        d.caseIDColumn = doc.text("case_id_column")
        d.outcomeCodes = doc.trimmedStrings("outcome_codes")
        d.noteKeywords = doc.trimmedStrings("note_keywords")
        d.originalFilename = doc.text("original_filename")
        d.importedAt = doc.text("imported_at")
        d.notes = doc.text("notes")
        return d
    }

    public static func render(_ d: ProjectDefinition) -> String {
        var p: [(String, YAMLNode)] = [
            ("name", .str(d.name)),
            ("badge", .str(d.badge)),
            ("colour", .str(d.colour)),
            ("leader", .str(d.leader)),
            ("leader_title", .str(d.leaderTitle)),
            ("worksheet", .str("\(d.id).csv")),
            ("case_id_column", .str(d.caseIDColumn)),
            ("outcome_codes", .list(d.outcomeCodes)),
            ("note_keywords", .list(d.noteKeywords)),
            ("original_filename", .str(d.originalFilename)),
            ("imported_at", .str(d.importedAt)),
        ]
        if !d.notes.isEmpty { p.append(("notes", .str(d.notes))) }
        return YAML.emit(.map(p))
    }
}

/// `decisions.yml` (§7): shortlists and prepared rows, keyed by case ID.
public enum DecisionsFile {
    public static func parse(_ text: String) throws -> [String: CaseDecision] {
        let doc = try YamlIO.document(text)
        var out: [String: CaseDecision] = [:]
        for pair in doc.pairs {
            let v = pair.value
            let d = CaseDecision(shortlist: v.trimmedStrings("shortlist"), outcome: v.text("outcome"),
                                 analyst: v.text("analyst"), note: v.text("note"), supervisor: v.text("supervisor"),
                                 date: v.text("date"), order: v["order"]?.int ?? 0, updated: v.text("updated"))
            if !d.isEmpty { out[pair.key] = d }
        }
        return out
    }

    public static func render(_ decisions: [String: CaseDecision]) -> String {
        let keys = decisions.keys.filter { !decisions[$0]!.isEmpty }.sorted()
        if keys.isEmpty { return "{}\n" }
        let pairs = keys.map { k -> (String, YAMLNode) in
            let d = decisions[k]!
            var p: [(String, YAMLNode)] = []
            if !d.shortlist.isEmpty { p.append(("shortlist", .list(d.shortlist))) }
            if d.isPrepared {
                p.append(("outcome", .str(d.outcome)))
                p.append(("analyst", .str(d.analyst)))
                p.append(("note", .str(d.note)))
                p.append(("supervisor", .str(d.supervisor)))
                p.append(("date", .str(d.date)))
                p.append(("order", .num(d.order)))
            } else {
                if !d.analyst.isEmpty { p.append(("analyst", .str(d.analyst))) }
                if !d.note.isEmpty { p.append(("note", .str(d.note))) }
            }
            if !d.updated.isEmpty { p.append(("updated", .str(d.updated))) }
            return (k, .map(p))
        }
        return YAML.emit(.map(pairs))
    }
}
