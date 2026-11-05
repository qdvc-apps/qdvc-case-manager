import Foundation

public enum FileError: Error, Equatable, CustomStringConvertible {
    case invalidYAML(String)
    case notAMapping
    case notUTF8
    case invalid(String)

    public var description: String {
        switch self {
        case .invalidYAML(let detail): return "The file is not valid YAML (\(detail))."
        case .notAMapping: return "The file does not hold a YAML mapping."
        case .notUTF8: return "The file is not UTF-8 text."
        case .invalid(let detail): return detail
        }
    }
}

/// A file that could not be read cleanly.
public struct LoadIssue: Identifiable, Equatable, Sendable {
    public var id: String { relativePath + message }
    public let relativePath: String
    public let message: String

    public init(_ relativePath: String, _ message: String) {
        self.relativePath = relativePath
        self.message = message
    }
}

/// Everything read from a workspace folder.
public struct WorkspaceData: Sendable, Equatable {
    public var settings = WorkspaceSettings()
    public var analysts: [Analyst] = []
    public var templates: [ReturnTemplate] = []
    public var mappings: [SourceKind: ColumnMapping] = [:]
    public var tables: [SourceKind: CSVTable] = [:]
    public var projects: [ProjectWorksheet] = []
    public var decisions: [String: CaseDecision] = [:]
    public var issues: [LoadIssue] = []

    public init() {}
}

/// The parts of a workspace that are saved separately.
public enum WorkspacePart: Hashable, Sendable {
    case settings
    case analysts
    case templates
    case decisions
    case mapping(SourceKind)
    case project(String)
}

/// A workspace folder (docs/FILE_FORMAT.md §1). Every write is atomic; the
/// files are meant to be committed to Git.
public final class Workspace {
    public let root: URL
    public static let settingsFile = "case-manager.yml"
    public static let analystsFile = "analysts.yml"
    public static let templatesFile = "templates.yml"
    public static let decisionsFile = "decisions.yml"
    public static let projectsFolder = "projects"

    private let fm = FileManager.default
    private var stamps: [String: Date] = [:]
    /// Files that failed to load: not overwritten until fixed and reloaded.
    public private(set) var protectedFiles: Set<String> = []

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static func looksLikeWorkspace(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(settingsFile).path)
    }

    public static func isEmptyFolder(_ url: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return items.filter { !$0.hasPrefix(".") }.isEmpty
    }

    /// The workspace's title, for recent lists; nil if it is not a workspace.
    public static func summary(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url.appendingPathComponent(settingsFile), encoding: .utf8) else {
            return nil
        }
        return (try? SettingsFile.parse(text))?.title ?? ""
    }

    public func url(for relativePath: String) -> URL { root.appendingPathComponent(relativePath) }

    /// Creates the folders and the files that are always present.
    public func ensureLayout(title: String = "") throws {
        for folder in ["imports", "mappings", Workspace.projectsFolder] {
            try fm.createDirectory(at: url(for: folder), withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: url(for: Workspace.settingsFile).path) {
            try write(SettingsFile.render(WorkspaceSettings(title: title)), to: Workspace.settingsFile)
        }
        if !fm.fileExists(atPath: url(for: Workspace.analystsFile).path) {
            try write(AnalystsFile.render([]), to: Workspace.analystsFile)
        }
        if !fm.fileExists(atPath: url(for: Workspace.templatesFile).path) {
            try write(TemplatesFile.render([]), to: Workspace.templatesFile)
        }
    }

    // MARK: Reading

    public func load() -> WorkspaceData {
        var data = WorkspaceData()
        protectedFiles = []
        stamps = [:]

        func read<T>(_ path: String, _ parse: (String) throws -> T) -> T? {
            let u = url(for: path)
            guard fm.fileExists(atPath: u.path) else { return nil }
            stamp(path)
            do {
                let text = try readText(u)
                return try parse(text)
            } catch {
                data.issues.append(LoadIssue(path, String(describing: error)))
                protectedFiles.insert(path)
                return nil
            }
        }

        data.settings = read(Workspace.settingsFile, SettingsFile.parse) ?? WorkspaceSettings()
        data.analysts = read(Workspace.analystsFile, AnalystsFile.parse) ?? []
        data.templates = read(Workspace.templatesFile, TemplatesFile.parse) ?? []
        data.decisions = read(Workspace.decisionsFile, DecisionsFile.parse) ?? [:]

        for source in SourceKind.allCases {
            if let m = read(source.mappingPath, MappingFile.parse) { data.mappings[source] = m }
            let csv = url(for: source.csvPath)
            if fm.fileExists(atPath: csv.path) {
                stamp(source.csvPath)
                if let bytes = try? Data(contentsOf: csv) {
                    data.tables[source] = CSVTable(data: bytes)
                } else {
                    data.issues.append(LoadIssue(source.csvPath, "The file could not be read."))
                }
            }
        }

        let folder = url(for: Workspace.projectsFolder)
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".yml") }.sorted()
        for name in names {
            let id = String(name.dropLast(4))
            let path = "\(Workspace.projectsFolder)/\(name)"
            guard let def = read(path, { try ProjectFile.parse($0, id: id) }) else { continue }
            let csvPath = "\(Workspace.projectsFolder)/\(id).csv"
            var table = CSVTable(headers: [], rows: [])
            if let bytes = try? Data(contentsOf: url(for: csvPath)) {
                stamp(csvPath)
                table = CSVTable(data: bytes)
            } else {
                data.issues.append(LoadIssue(csvPath, "The project's worksheet is missing."))
            }
            data.projects.append(ProjectWorksheet(definition: def, table: table))
        }
        return data
    }

    private func readText(_ u: URL) throws -> String {
        let bytes = try Data(contentsOf: u)
        guard let text = String(data: bytes, encoding: .utf8) else { throw FileError.notUTF8 }
        return text
    }

    // MARK: Writing

    public func save(_ part: WorkspacePart, from data: WorkspaceData) throws {
        switch part {
        case .settings:
            try write(SettingsFile.render(data.settings), to: Workspace.settingsFile)
        case .analysts:
            try write(AnalystsFile.render(data.analysts), to: Workspace.analystsFile)
        case .templates:
            try write(TemplatesFile.render(data.templates), to: Workspace.templatesFile)
        case .decisions:
            try write(DecisionsFile.render(data.decisions), to: Workspace.decisionsFile)
        case .mapping(let source):
            if let m = data.mappings[source] { try write(MappingFile.render(m, source: source), to: source.mappingPath) }
        case .project(let id):
            if let p = data.projects.first(where: { $0.id == id }) {
                try write(ProjectFile.render(p.definition), to: "\(Workspace.projectsFolder)/\(id).yml")
            }
        }
    }

    /// Copies an export into the workspace verbatim (so Git shows what
    /// changed between exports) and records its mapping.
    public func importSource(_ source: SourceKind, from file: URL, mapping: ColumnMapping) throws {
        try fm.createDirectory(at: url(for: "imports"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url(for: "mappings"), withIntermediateDirectories: true)
        try copy(file, to: source.csvPath)
        try write(MappingFile.render(mapping, source: source), to: source.mappingPath)
    }

    /// Adds or replaces a project and its worksheet.
    public func importWorksheet(_ definition: ProjectDefinition, from file: URL?) throws {
        try fm.createDirectory(at: url(for: Workspace.projectsFolder), withIntermediateDirectories: true)
        if let file { try copy(file, to: "\(Workspace.projectsFolder)/\(definition.id).csv") }
        try write(ProjectFile.render(definition), to: "\(Workspace.projectsFolder)/\(definition.id).yml")
    }

    public func deleteProject(_ id: String) throws {
        for ext in ["yml", "csv"] {
            let u = url(for: "\(Workspace.projectsFolder)/\(id).\(ext)")
            if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        }
    }

    private func copy(_ file: URL, to path: String) throws {
        if file.standardizedFileURL == url(for: path).standardizedFileURL { return }
        let bytes = try Data(contentsOf: file)
        try bytes.write(to: url(for: path), options: .atomic)
        stamp(path)
    }

    /// Writes a file atomically, unless it already holds exactly this text
    /// or failed to load (so a hand edit with a typo is never overwritten).
    public func write(_ text: String, to path: String) throws {
        if protectedFiles.contains(path) {
            throw FileError.invalid("\(path) could not be read when the workspace was opened, so it is not being overwritten. Fix the file and choose View › Reload from Disk.")
        }
        let u = url(for: path)
        let bytes = Data(text.utf8)
        if let existing = try? Data(contentsOf: u), existing == bytes { return }
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: u, options: .atomic)
        stamp(path)
    }

    // MARK: Change detection

    private func stamp(_ path: String) {
        stamps[path] = (try? fm.attributesOfItem(atPath: url(for: path).path))?[.modificationDate] as? Date
    }

    /// Whether any file the app read or wrote has changed since, or a new
    /// project file has appeared (a `git pull`, another editor).
    public func changedOutside() -> Bool {
        for (path, date) in stamps {
            let now = (try? fm.attributesOfItem(atPath: url(for: path).path))?[.modificationDate] as? Date
            if now != date { return true }
        }
        let names = (try? fm.contentsOfDirectory(atPath: url(for: Workspace.projectsFolder).path)) ?? []
        return names.contains { !stamps.keys.contains("\(Workspace.projectsFolder)/\($0)") && ($0.hasSuffix(".yml") || $0.hasSuffix(".csv")) }
    }
}
