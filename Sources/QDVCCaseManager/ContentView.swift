import CaseCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            DetailView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    ImportMenuItems()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import an export from upstream")
                .disabled(!model.isOpen)
            }
        }
        .sheet(item: $model.sheet) { sheet in
            SheetHost(sheet: sheet).environment(model)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.isOpen && model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Prepared rows have landed", isPresented: Binding(
            get: { model.landedPrompt != nil },
            set: { if !$0 { model.landedPrompt = nil } }
        )) {
            Button("Remove from Batch") {
                model.removeLanded()
                model.landedPrompt = nil
            }
            Button("Keep for Now", role: .cancel) { model.landedPrompt = nil }
        } message: {
            let n = model.landedPrompt ?? 0
            Text("The new control sheet has decisions for \(n) of the cases in your batch. Remove those rows from the batch? (Rows decided differently are flagged in Batch.)")
        }
        .onChange(of: model.workspaceURL) { _, url in
            // Closing the workspace hands back to the welcome window.
            if url == nil {
                openWindow(id: WelcomeWindow.id)
                DispatchQueue.main.async { dismissWindow(id: MainWindowID.main) }
            }
        }
    }
}

/// The items of File › Import and the toolbar's Import menu.
struct ImportMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Case Catalogue…") { model.beginImport(.catalogue) }
        Button("Allocation Control Sheet…") { model.beginImport(.controlSheet) }
        Divider()
        Button("New Project from Worksheet…") { model.beginNewProject() }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding<Page?>(get: { model.page }, set: { if let p = $0 { model.page = p } })) {
            Section("Cases") {
                ForEach(CaseScope.allCases) { scope in
                    Label(scope.title, systemImage: scope.symbol)
                        .badge(model.count(scope))
                        .tag(Page.cases(scope))
                }
            }
            Section("Allocate") {
                Label("Batch", systemImage: "tray.full")
                    .badge(model.pendingCount)
                    .tag(Page.batch)
                    .help("Rows prepared in Decision Support, ready to paste into the Allocation Control Sheet")
            }
            if !model.data.projects.isEmpty {
                Section("Projects") {
                    ForEach(model.data.projects) { p in
                        Label {
                            Text(p.definition.name)
                        } icon: {
                            Image(systemName: "folder.fill").foregroundStyle(Style.colour(p.definition.colour))
                        }
                        .badge(model.book.rows.filter { $0.flags.contains(.missingFromWorksheet(p.id)) }.count)
                        .tag(Page.project(p.id))
                    }
                }
            }
            Section("Insights") {
                Label("Workload", systemImage: "square.grid.3x3.fill").tag(Page.workload)
                Label("Acceptance & Refusal", systemImage: "chart.line.uptrend.xyaxis").tag(Page.rates)
            }
            Section("Workspace") {
                Label("Analysts", systemImage: "person.2")
                    .badge(model.book.unknownShorthands.count)
                    .tag(Page.analysts)
                Label("Return Templates", systemImage: "envelope.arrow.triangle.branch")
                    .badge(model.unknownTemplates.count)
                    .tag(Page.templates)
                Label("Outcome Codes", systemImage: "list.bullet.rectangle")
                    .badge(model.unclassifiedCodes.count)
                    .tag(Page.outcomes)
                Label("Data Sources", systemImage: "externaldrive")
                    .tag(Page.dataSources)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FreshnessFooter()
        }
    }
}

/// How current the two exports are, at the foot of the sidebar.
struct FreshnessFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SourceKind.allCases) { source in
                row(source)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.page = .dataSources }
    }

    @ViewBuilder
    private func row(_ source: SourceKind) -> some View {
        let f = model.freshness(source)
        let stale = f.map(model.isStale) ?? true
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(f == nil ? Color.secondary : (stale ? Color.orange : Color.green))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(source.title).font(.caption.weight(.medium))
                Text(f.map(model.freshnessText) ?? "Not imported yet")
                    .font(.caption2)
                    .foregroundStyle(stale && f != nil ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
        }
        .help(stale && f != nil ? "Imported more than \(model.staleAfterDays) days ago: consider importing a fresh export." : "")
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.isOpen {
            ContentUnavailableView("No Workspace Open", systemImage: "folder",
                                   description: Text("Open a workspace from the File menu."))
        } else {
            switch model.page {
            case .cases: CaseListView()
            case .batch: BatchView()
            case .project(let id): ProjectView(id: id)
            case .workload: WorkloadView()
            case .rates: RatesView()
            case .analysts: AnalystsView()
            case .templates: TemplatesView()
            case .outcomes: OutcomesView()
            case .dataSources: DataSourcesView()
            }
        }
    }
}

struct SheetHost: View {
    var sheet: ActiveSheet

    var body: some View {
        switch sheet {
        case .importSource(let draft): ImportSheet(draft: draft)
        case .project(let draft): ProjectSheet(draft: draft)
        }
    }
}
