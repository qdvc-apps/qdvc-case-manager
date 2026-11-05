import AppKit
import CaseCore
import SwiftUI

@main
struct CaseManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        // Don't reopen windows from the last session: the welcome window
        // (the first scene) decides what opens at launch.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    var body: some Scene {
        // Shown at launch, like Xcode's and Keynote's welcome windows.
        Window("Welcome to QDVC Case Manager", id: WelcomeWindow.id) {
            WelcomeWindow()
                .environment(model)
                .onAppear { appDelegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // One workspace at a time.
        Window("QDVC Case Manager", id: MainWindowID.main) {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1440, height: 880)
        .commands {
            CaseCommands(model: model)
            InspectorCommands()
            SidebarCommands()
        }

        // Decision Support: one window per case, which can move on through
        // the queue. It sits beside the case paperwork.
        WindowGroup("Decision Support", id: DecisionWindow.id, for: String.self) { $caseID in
            DecisionSupportView(caseID: $caseID)
                .environment(model)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 800)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than
        // from the .app bundle, so the app gets a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.checkForOutsideChanges()
    }

    func applicationDidResignActive(_ notification: Notification) {
        model?.flushSaves()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.flushSaves()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

enum MainWindowID {
    static let main = "main"
}

struct CaseCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Workspace…") { model.newWorkspace() }
                .keyboardShortcut("n")
            Button("Open Workspace…") { model.chooseWorkspace() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(model.recentWorkspaces, id: \.self) { url in
                    Button(url.lastPathComponent) { model.open(url) }
                }
                Divider()
                Button("Clear Menu") { model.clearRecent() }
                    .disabled(model.recentWorkspaces.isEmpty)
            }
            Divider()
            Menu("Import") {
                Button("Case Catalogue…") { model.beginImport(.catalogue) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Allocation Control Sheet…") { model.beginImport(.controlSheet) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Divider()
                Button("New Project from Worksheet…") { model.beginNewProject() }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Menu("Update Project Worksheet") {
                    ForEach(model.data.projects) { p in
                        Button("\(p.definition.name)…") { model.updateWorksheet(p.id) }
                    }
                }
                .disabled(model.data.projects.isEmpty)
            }
            .disabled(!model.isOpen)
            Divider()
            Button("Show in Finder") { model.revealInFinder() }
                .disabled(!model.isOpen)
            Button("Close Workspace") { model.closeWorkspace() }
                .disabled(!model.isOpen)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Copy Batch Rows") { model.copyBatch() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.pendingCount == 0)
            Button("Export Cases Shown as CSV…") { model.exportVisibleCases() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.isOpen)
        }

        CommandMenu("Case") {
            Button("Decision Support…") {
                if let id = model.selectedCaseIDs.first { openWindow(id: DecisionWindow.id, value: id) }
            }
            .keyboardShortcut("d")
            .disabled(model.selectedCaseIDs.count != 1)
            Button("Next Case Awaiting Allocation") {
                if let id = model.nextAwaitingCase(after: model.selectedCaseIDs.first ?? "") {
                    model.reveal(id)
                    openWindow(id: DecisionWindow.id, value: id)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!model.isOpen)
            Divider()
            Button("Copy Case ID") {
                Platform.copy(model.selectedCaseIDs.sorted().joined(separator: "\n"))
            }
            .disabled(model.selectedCaseIDs.isEmpty)
        }

        CommandGroup(before: .sidebar) {
            pageButton("All Cases", .cases(.all), "1")
            pageButton("Awaiting Allocation", .cases(.awaiting), "2")
            pageButton("Needs Attention", .cases(.attention), "3")
            pageButton("Batch", .batch, "4")
            pageButton("Workload", .workload, "5")
            pageButton("Acceptance & Refusal", .rates, "6")
            pageButton("Analysts", .analysts, "7")
            pageButton("Data Sources", .dataSources, "8")
            Divider()
            Button("Reload from Disk") { model.reload() }
                .keyboardShortcut("r")
                .disabled(!model.isOpen)
            Divider()
        }

        CommandGroup(after: .windowArrangement) {
            Button("Welcome to QDVC Case Manager") {
                model.welcomeRequested = true
                openWindow(id: WelcomeWindow.id)
            }
            .keyboardShortcut("1", modifiers: [.command, .shift])
        }
    }

    private func pageButton(_ title: String, _ page: Page, _ key: KeyEquivalent) -> some View {
        Button(title) {
            model.page = page
            openWindow(id: MainWindowID.main)
        }
        .keyboardShortcut(key, modifiers: [.command, .control])
        .disabled(!model.isOpen)
    }
}

// MARK: - Welcome window

/// The window shown at launch, as in Xcode and Keynote: the app on the
/// left with New and Open, recent workspaces on the right.
struct WelcomeWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selection: URL?

    static let id = "welcome"

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Spacer(minLength: 28)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                Text("QDVC Case Manager")
                    .font(.system(size: 26, weight: .semibold))
                    .padding(.top, 6)
                Text("Version \(version)")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Spacer(minLength: 28)
                VStack(alignment: .leading, spacing: 6) {
                    WelcomeAction(symbol: "plus.square", title: "Create a New Workspace…",
                                  detail: "Choose an empty folder; track it with Git") {
                        model.newWorkspace()
                        if model.isOpen { proceed() }
                    }
                    WelcomeAction(symbol: "folder", title: "Open an Existing Workspace…",
                                  detail: "Choose a workspace folder") {
                        model.chooseWorkspace()
                        if model.isOpen { proceed() }
                    }
                }
                .frame(width: 330)
                Spacer(minLength: 28)
                Text("Your last workspace reopens when the app starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
            }
            .frame(width: 440)

            Divider()

            VStack(spacing: 0) {
                if model.recentWorkspaces.isEmpty {
                    ContentUnavailableView("No Recent Workspaces", systemImage: "clock",
                                           description: Text("Workspaces you open appear here."))
                } else {
                    List(selection: $selection) {
                        ForEach(model.recentWorkspaces, id: \.self) { url in
                            RecentRow(url: url).tag(url)
                        }
                    }
                    .listStyle(.sidebar)
                    .contextMenu(forSelectionType: URL.self) { urls in
                        if let url = urls.first {
                            Button("Open") { openRecent(url) }
                            Button("Show in Finder") { Platform.reveal(url) }
                            Divider()
                            Button("Remove from List") { model.removeRecent(url) }
                        }
                    } primaryAction: { urls in
                        if let url = urls.first { openRecent(url) }
                    }
                }
                Divider()
                HStack {
                    Text(model.recentWorkspaces.isEmpty ? "" : "Double-click to open")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Clear Recent List") {
                        model.clearRecent()
                        selection = nil
                    }
                    .disabled(model.recentWorkspaces.isEmpty)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(width: 340)
        }
        .frame(height: 460)
        .ignoresSafeArea()
        .alert("Something went wrong", isPresented: Binding(
            get: { !model.isOpen && model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            model.startUp()
            if model.isOpen && !model.welcomeRequested { proceed() }
            model.welcomeRequested = false
        }
        .onChange(of: model.workspaceURL) { _, url in
            if url != nil { proceed() }
        }
    }

    private func openRecent(_ url: URL) {
        model.open(url)
        if model.isOpen { proceed() }
    }

    /// Hands over to the main window.
    private func proceed() {
        openWindow(id: MainWindowID.main)
        // Close this one a moment later, so the app never has no window
        // (which would quit it).
        DispatchQueue.main.async { dismissWindow(id: Self.id) }
    }
}

/// A big row on the left of the welcome window.
struct WelcomeAction: View {
    var symbol: String
    var title: String
    var detail: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A recent workspace: its title and where it is.
struct RecentRow: View {
    var url: URL

    var body: some View {
        let summary = Workspace.summary(url)
        HStack(spacing: 10) {
            Image(systemName: summary == nil ? "questionmark.folder" : "folder.fill")
                .font(.system(size: 22))
                .foregroundStyle(summary == nil ? Color.secondary : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                Text(summary == nil ? "Not found" : (url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
        .help(url.path)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Your name", text: $model.supervisorName, prompt: Text("as written in the control sheet"))
            } header: {
                Text("Allocation Supervisor")
            } footer: {
                Text("Written into the rows you prepare in Decision Support. Kept on this Mac, not in the workspace.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data Freshness") {
                Stepper("Flag an export as stale after \(model.staleAfterDays) day\(model.staleAfterDays == 1 ? "" : "s")",
                        value: $model.staleAfterDays, in: 1...60)
            }
            Section("Launch") {
                Text("The last workspace you had open reopens when the app starts; if it can't be found, the welcome window appears instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("QDVC Case Manager works entirely offline: it never connects to the network or the internet. Everything it reads and writes is in the workspace folder you choose.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 400)
    }
}
