import AppKit
import CaseCore
import SwiftUI

/// The last things the user and the app did, kept where a background
/// thread can read them while the main thread is stuck.
final class Breadcrumbs: @unchecked Sendable {
    static let shared = Breadcrumbs()
    private let lock = NSLock()
    private var items: [(Date, String)] = []

    func add(_ text: String) {
        lock.lock()
        items.append((Date(), text))
        if items.count > 40 { items.removeFirst(items.count - 40) }
        lock.unlock()
    }

    func recent() -> [(Date, String)] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// A hang that may never end is written to
/// `~/Library/Logs/QDVC Case Manager/unresponsive.txt` while it is going on
/// (from the monitor's thread), and removed if the app recovers. If the app
/// had to be force-quit, the next launch finds it.
enum HangFile {
    struct Previous {
        var date: Date
        var seconds: TimeInterval
        var summary: String
        var text: String
    }

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/QDVC Case Manager/unresponsive.txt")
    }

    static func write(seconds: TimeInterval, started: Date) {
        let time = ISO8601DateFormatter()
        var lines = ["seconds: \(Int(seconds))", "started: \(time.string(from: started))", "Last actions (oldest first):"]
        lines += Breadcrumbs.shared.recent().map { "  \(time.string(from: $0.0))  \($0.1)" }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// The previous session's hang, if any; the file is then moved aside.
    static func takePrevious() -> Previous? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        let seconds = lines.first.flatMap { TimeInterval($0.replacingOccurrences(of: "seconds: ", with: "")) } ?? 0
        let date = lines.dropFirst().first.flatMap { ISO8601DateFormatter().date(from: $0.replacingOccurrences(of: "started: ", with: "")) } ?? Date()
        let actions = lines.filter { $0.hasPrefix("  ") }.suffix(4).map { $0.trimmingCharacters(in: .whitespaces) }
        let previous = url.deletingLastPathComponent().appendingPathComponent("unresponsive-previous.txt")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        return Previous(date: date, seconds: seconds,
                        summary: "Last actions: " + actions.joined(separator: " → "), text: text)
    }
}

/// Notices when the main thread stops responding: a background timer
/// sends the main thread a tiny task every 0.2 s and measures how long it
/// takes to run. Longer than `threshold` is reported (on the main thread,
/// once it is free again); longer than 3 s is also written to `HangFile`
/// at once, in case it never ends.
final class StallMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.qdvc.case-manager.stall-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    // Accessed only on `queue`.
    private var waitingSince: UInt64?
    private var lastWritten: TimeInterval = 0
    private let threshold: TimeInterval
    private let report: @Sendable (TimeInterval) -> Void

    init(threshold: TimeInterval, report: @escaping @Sendable (TimeInterval) -> Void) {
        self.threshold = threshold
        self.report = report
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 0.2, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        if let since = waitingSince {
            // Still waiting: write the hang out at 3 s, then every 5 s.
            let waited = TimeInterval(now - since) / 1_000_000_000
            if waited >= 3 && waited - lastWritten >= (lastWritten == 0 ? 0 : 5) {
                lastWritten = waited
                HangFile.write(seconds: waited, started: Date().addingTimeInterval(-waited))
            }
            return
        }
        waitingSince = now
        let threshold = self.threshold
        let report = self.report
        DispatchQueue.main.async { [weak self] in
            let lag = TimeInterval(DispatchTime.now().uptimeNanoseconds - now) / 1_000_000_000
            if lag >= threshold { report(lag) }
            self?.queue.async {
                guard let self else { return }
                if self.lastWritten > 0 { HangFile.remove() }   // it recovered
                self.lastWritten = 0
                self.waitingSince = nil
            }
        }
    }
}

/// The strip along the bottom of the main window: what the app is busy
/// with, what the table shows, and any moments it stopped responding.
struct StatusBar: View {
    var model: AppModel
    @State private var showLog = false

    var body: some View {
        HStack(spacing: 10) {
            if !model.activities.isEmpty {
                ProgressView().controlSize(.mini)
                Text(model.activities.map(\.title).joined(separator: " · ") + "…")
                    .lineLimit(1)
            } else if model.isUpdating {
                ProgressView().controlSize(.mini)
                Text("Updating figures…")
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text(idleText).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if case .cases = model.page {
                Text(shownText).foregroundStyle(.secondary).lineLimit(1)
            }
            if let last = model.stalls.first {
                Button {
                    showLog = true
                } label: {
                    Label("Stopped responding for \(AppModel.duration(last.duration))", systemImage: "tortoise.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .help("The app stopped responding \(model.stalls.count) time\(model.stalls.count == 1 ? "" : "s"). Click for details.")
            }
            Button {
                showLog.toggle()
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .buttonStyle(.borderless)
            .help("Activity: what the app has been doing, and for how long")
            .popover(isPresented: $showLog, arrowEdge: .top) {
                ActivityLogView(model: model)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var idleText: String {
        guard let last = model.activityLog.first(where: { $0.title == "Updating figures" }) else { return "Ready" }
        let time = last.finished.formatted(date: .omitted, time: .shortened)
        return "Up to date · figures updated at \(time) in \(AppModel.duration(last.duration))"
    }

    private var shownText: String {
        let year = model.selectedYear == YearSummary.undated ? "no date" : String(model.selectedYear)
        return "\(model.caseRows.count) case\(model.caseRows.count == 1 ? "" : "s") shown · \(year)"
    }
}

/// The status bar's popover: freezes, then recent work with timings.
struct ActivityLogView: View {
    var model: AppModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Activity").font(.headline)
            Text("Work on the main thread holds up the window while it runs; background work doesn't.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.stalls.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Stopped responding").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                            ForEach(model.stalls) { s in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(s.at.formatted(date: .omitted, time: .standard)).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    Text(AppModel.duration(s.duration)).monospacedDigit().foregroundStyle(.orange)
                                        .frame(width: 56, alignment: .trailing)
                                    Text(s.context).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent work").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if model.activityLog.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                        ForEach(model.activityLog) { r in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(r.finished.formatted(date: .omitted, time: .standard)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(AppModel.duration(r.duration)).monospacedDigit()
                                    .foregroundStyle(r.onMainThread && r.duration > 0.25 ? Color.orange : Color.primary)
                                    .frame(width: 56, alignment: .trailing)
                                Text(r.title)
                                if !r.onMainThread {
                                    Text("background").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)
            HStack {
                Button(copied ? "Copied" : "Copy Report") {
                    Platform.copy(model.activityReport)
                    copied = true
                }
                .help("Copy this log as text, to send with a description of what you were doing")
                Spacer()
                Button("Clear") { model.clearActivityLog() }
            }
        }
        .padding(14)
        .frame(width: 520)
    }
}
