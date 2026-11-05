import AppKit
import CaseCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Style

enum Style {
    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(.callout, design: .monospaced)

    static func colour(_ name: String) -> Color {
        switch name {
        case "teal": return .teal
        case "orange": return .orange
        case "pink": return .pink
        case "purple": return .purple
        case "brown": return .brown
        case "green": return .green
        case "blue": return .blue
        case "red": return .red
        case "yellow": return .yellow
        default: return .indigo
        }
    }

    /// The heat map's scale, as in the spreadsheet's conditional formatting:
    /// pale to deep teal.
    static let heatStops: [(Double, Double, Double)] = [
        (0.90, 0.97, 0.96), (0.62, 0.87, 0.85), (0.30, 0.70, 0.71), (0.11, 0.49, 0.53), (0.04, 0.29, 0.34),
    ]

    static func heat(_ value: Int, max: Int) -> Color {
        guard value > 0, max > 0 else { return Color.primary.opacity(0.04) }
        let t = min(1, Double(value) / Double(max)) * Double(heatStops.count - 1)
        let i = min(heatStops.count - 2, Int(t))
        let f = t - Double(i)
        let a = heatStops[i], b = heatStops[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }

    static func heatText(_ value: Int, max: Int) -> Color {
        guard max > 0 else { return .primary }
        return Double(value) / Double(max) > 0.55 ? .white : .black
    }

    static func symbol(_ status: CaseStatus) -> String {
        switch status {
        case .awaiting: return "hourglass"
        case .allocated: return "person.fill.checkmark"
        case .refused: return "arrow.uturn.backward.circle"
        case .project: return "folder.fill"
        case .other: return "questionmark.diamond"
        }
    }

    static func tint(_ status: CaseStatus) -> Color {
        switch status {
        case .awaiting: return .orange
        case .allocated: return .green
        case .refused: return .red
        case .project: return .indigo
        case .other: return .gray
        }
    }

    static func symbol(_ note: NoteKind) -> String? {
        switch note {
        case .none: return nil
        case .expertise: return "checkmark.seal"
        case .special: return "star"
        case .unmatched: return "questionmark.circle"
        case .template: return "envelope.arrow.triangle.branch"
        case .unknownTemplate: return "exclamationmark.circle"
        }
    }

    static func tint(_ note: NoteKind) -> Color {
        switch note {
        case .expertise: return .green
        case .special: return .purple
        case .unmatched, .unknownTemplate: return .orange
        default: return .secondary
        }
    }

    static func tint(_ state: PreparedState) -> Color {
        switch state {
        case .pending: return .teal
        case .landed: return .green
        case .landedDifferently: return .orange
        }
    }

    static func symbol(_ state: PreparedState) -> String {
        switch state {
        case .pending: return "doc.on.clipboard"
        case .landed: return "checkmark.circle.fill"
        case .landedDifferently: return "exclamationmark.triangle.fill"
        }
    }

    static func percent(_ v: Double?) -> String {
        guard let v else { return "–" }
        return String(format: "%.1f%%", v * 100)
    }
}

extension LocalDate {
    init(date: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        self = LocalDate(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1) ?? LocalDate(dayNumber: 0)
    }

    var date: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }
}

// MARK: - Preferences

/// App preferences, in the standard defaults domain
/// (`defaults read org.qdvc.case-manager.mac`). Everything shared lives in
/// the workspace instead.
enum Prefs {
    private static let d = UserDefaults.standard

    static var recentWorkspaces: [URL] {
        get { (d.stringArray(forKey: "recentWorkspaces") ?? []).map { URL(fileURLWithPath: $0) } }
        set { d.set(newValue.map(\.path), forKey: "recentWorkspaces") }
    }

    static var showWelcomeAtLaunch: Bool {
        get { d.object(forKey: "showWelcomeAtLaunch") as? Bool ?? true }
        set { d.set(newValue, forKey: "showWelcomeAtLaunch") }
    }

    static var inspectorShown: Bool {
        get { d.object(forKey: "inspectorShown") as? Bool ?? true }
        set { d.set(newValue, forKey: "inspectorShown") }
    }

    /// Written into prepared rows as the allocation supervisor.
    static var supervisorName: String {
        get { d.string(forKey: "supervisorName") ?? "" }
        set { d.set(newValue, forKey: "supervisorName") }
    }

    /// An export older than this many days is flagged as stale.
    static var staleAfterDays: Int {
        get { d.object(forKey: "staleAfterDays") as? Int ?? 7 }
        set { d.set(newValue, forKey: "staleAfterDays") }
    }
}

// MARK: - AppKit services (all local: no network)

@MainActor
enum Platform {
    static func chooseCSV(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.commaSeparatedText, UTType.tabSeparatedText, UTType.plainText]
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFolder(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks where to save, then writes `text` (UTF-8). Returns false if cancelled.
    @discardableResult
    static func save(_ text: String, suggestedName: String) throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func confirm(_ message: String, _ info: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openSettings() {
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate()
    }
}

// MARK: - Small shared views

/// The (!) emblem: a white symbol on a coloured circle.
struct Emblem: View {
    enum Kind { case warning, info }
    var kind: Kind
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: kind == .warning ? "exclamationmark" : "questionmark")
            .font(.system(size: size * 0.62, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(kind == .warning ? Color.orange : Color.gray))
            .accessibilityLabel(kind == .warning ? "Warning" : "Note")
    }
}

/// Twelve tiny bars: an analyst's last 12 months.
struct Sparkline: View {
    var values: [Int]
    var highlightLast = true

    var body: some View {
        let top = max(1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 1)
                    .fill(highlightLast && i == values.count - 1 ? Color.teal : Color.teal.opacity(0.45))
                    .frame(width: 4, height: max(1.5, 18 * CGFloat(v) / CGFloat(top)))
            }
        }
        .frame(height: 18, alignment: .bottom)
        .help(values.map(String.init).joined(separator: " · "))
    }
}

/// Text with search matches highlighted (ranges are character offsets).
struct HighlightedText: View {
    var text: String
    var ranges: [Range<Int>]

    var body: some View { Text(attributed) }

    private var attributed: AttributedString {
        var a = AttributedString(text)
        let count = text.count
        for r in ranges where r.upperBound <= count && !r.isEmpty {
            let lo = a.index(a.startIndex, offsetByCharacters: r.lowerBound)
            let hi = a.index(a.startIndex, offsetByCharacters: r.upperBound)
            a[lo..<hi].backgroundColor = Color.yellow.opacity(0.45)
            a[lo..<hi].foregroundColor = Color.primary
        }
        return a
    }
}

/// A project's badge, filled when the worksheet lists the case, outlined
/// when the case belongs to the project but the worksheet doesn't list it.
struct ProjectTag: View {
    var definition: ProjectDefinition
    var listed = true

    var body: some View {
        let colour = Style.colour(definition.colour)
        Text(definition.displayBadge)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(listed ? Color.white : colour)
            .background(Capsule().fill(listed ? colour : Color.clear))
            .overlay(Capsule().strokeBorder(colour, style: StrokeStyle(lineWidth: 1, dash: listed ? [] : [2, 2])))
            .help(listed ? "On the \(definition.name) worksheet"
                         : "Belongs to \(definition.name) (by outcome or note) but is missing from its worksheet")
    }
}

/// A row of clickable capsules that scrolls sideways.
struct ChipRow: View {
    var items: [String]
    var action: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Button { action(item) } label: {
                        Text(item).font(.caption).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// A figure with a caption, for the dashboards.
struct StatCard: View {
    var title: String
    var value: String
    var detail: String = ""
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
                .minimumScaleFactor(0.6)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
    }
}

/// A read-only spreadsheet view of any table, with a header that stays put.
struct SheetGrid: View {
    var headers: [String]
    var rows: [[String]]
    var onDoubleClick: ((Int) -> Void)? = nil

    private var widths: [CGFloat] {
        headers.indices.map { c in
            var longest = headers[c].count
            for r in rows.prefix(300) where c < r.count { longest = max(longest, r[c].count) }
            return CGFloat(min(320, max(60, longest * 7 + 16)))
        }
    }

    var body: some View {
        let widths = self.widths
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows.indices, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(headers.indices, id: \.self) { c in
                                Text(c < rows[r].count ? rows[r][c] : "")
                                    .lineLimit(1)
                                    .frame(width: widths[c], alignment: .leading)
                                    .padding(.horizontal, 6)
                            }
                        }
                        .font(.callout)
                        .padding(.vertical, 3)
                        .background(r.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onDoubleClick?(r) }
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(headers.indices, id: \.self) { c in
                            Text(headers[c])
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .frame(width: widths[c], alignment: .leading)
                                .padding(.horizontal, 6)
                        }
                    }
                    .font(.callout)
                    .padding(.vertical, 5)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
            .padding(.bottom, 8)
        }
    }
}
