import CaseCore
import SwiftUI

// MARK: - Analysts

struct AnalystsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var filter = ""

    private var filtered: [Analyst] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        let all = model.data.analysts
        guard !q.isEmpty else { return all }
        return all.filter { a in
            [a.shorthand, a.name, a.expertise, a.aliases.joined(separator: " ")]
                .contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Filter analysts", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                if !model.book.unknownShorthands.isEmpty { unknownBanner }
                List(selection: $selection) {
                    ForEach(filtered) { a in
                        HStack(spacing: 8) {
                            Text(a.shorthand).font(Style.monoSmall).frame(width: 44, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.displayName).lineLimit(1)
                                Text("\(model.metrics[a.shorthand]?.thisMonth ?? 0) this month · \(model.metrics[a.shorthand]?.past12 ?? 0) in 12 months")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(a.active ? Color.primary : Color.secondary)
                        .tag(a.id)
                    }
                }
                .listStyle(.inset)
                Divider()
                HStack(spacing: 2) {
                    Button { selection = model.addAnalyst() } label: { Image(systemName: "plus") }
                        .help("Add an analyst")
                    Button { if let id = selection { model.deleteAnalyst(id); selection = nil } } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection == nil)
                    .help("Delete the selected analyst")
                    Spacer()
                    Text("\(model.data.analysts.filter(\.active).count) active").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 290)
            Divider()
            if let id = selection, model.analyst(id) != nil {
                AnalystEditor(id: id).id(id)
            } else {
                ContentUnavailableView("Select an Analyst", systemImage: "person.crop.circle",
                                       description: Text("Each analyst's shorthand is what the control sheet writes; the expertise is what Decision Support searches and where allocation notes come from."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var unknownBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Shorthands in the control sheet with no analyst", systemImage: "questionmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            ForEach(model.book.unknownShorthands.keys.sorted(), id: \.self) { short in
                let n = model.book.unknownShorthands[short] ?? 0
                HStack {
                    Text(short).font(Style.monoSmall)
                    Text("\(n) case\(n == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add") { selection = model.addAnalyst(shorthand: short) }.controlSize(.small)
                }
            }
            Text("Or add it to an existing analyst's other shorthands.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

struct AnalystEditor: View {
    var id: UUID
    @Environment(AppModel.self) private var model
    @State private var aliasText = ""

    var body: some View {
        let a = model.analyst(id) ?? Analyst(shorthand: "")
        let m = model.metrics[a.shorthand]
        let clash = model.data.analysts.contains { $0.id != id && !Set($0.keys).isDisjoint(with: a.keys) }
        Form {
            Section("Analyst") {
                TextField("Shorthand", text: model.analystBinding(id, \.shorthand, default: ""))
                    .font(Style.mono)
                if clash {
                    Text("Another analyst already uses this shorthand or alias.").font(.caption).foregroundStyle(.red)
                }
                TextField("Full name", text: model.analystBinding(id, \.name, default: ""))
                TextField("Other shorthands", text: $aliasText, prompt: Text("comma-separated, e.g. AB, A.B."))
                    .onChange(of: aliasText) { _, text in
                        let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        if list != a.aliases { model.updateAnalyst(id) { $0.aliases = list } }
                    }
                Toggle("Active in the pool", isOn: model.analystBinding(id, \.active, default: true))
            }
            Section {
                TextEditor(text: model.analystBinding(id, \.expertise, default: ""))
                    .font(.body)
                    .frame(minHeight: 120)
                let phrases = ExpertisePhrases.split(a.expertise)
                if !phrases.isEmpty {
                    Text(phrases.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Specialisation / Expertise")
            } footer: {
                Text("Allocation notes are phrases from this text. Separating areas with semicolons lets Decision Support offer each as a note.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notes") {
                TextEditor(text: model.analystBinding(id, \.notes, default: ""))
                    .font(.body)
                    .frame(minHeight: 50)
            }
            Section("Workload") {
                LabeledContent("This month", value: "\(m?.thisMonth ?? 0)")
                LabeledContent("Last month", value: "\(m?.lastMonth ?? 0)")
                LabeledContent("Past 12 months", value: "\(m?.past12 ?? 0)")
                if let pending = model.pendingLoad[a.shorthand], pending > 0 {
                    LabeledContent("In the batch", value: "\(pending)")
                }
                LabeledContent("Last allocated", value: m?.lastAllocation?.display ?? "–")
                if let monthly = m?.monthly { LabeledContent("Past 12 months") { Sparkline(values: monthly) } }
                if let genres = m?.genres, !genres.isEmpty {
                    LabeledContent("Genres") {
                        Text(genres.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { aliasText = a.aliases.joined(separator: ", ") }
    }
}

// MARK: - Return templates

struct TemplatesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.data.templates) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        TextField("Name", text: model.templateBinding(t.id, \.name))
                            .font(Style.mono)
                            .frame(width: 280)
                        TextField("What it says", text: model.templateBinding(t.id, \.description))
                        Text("\(model.book.templateCounts[t.name] ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                            .help("Refusals using this template")
                        Button { model.deleteTemplate(t.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                    .labelsHidden()
                }
                Button("Add Template") { model.addTemplate() }
            } header: {
                Text("Return-to-Sender Templates")
            } footer: {
                Text("A refused case's allocation note names one of these. Decision Support offers them when preparing a refusal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.unknownTemplates.isEmpty {
                Section("Named in Refusals but Not Listed") {
                    ForEach(model.unknownTemplates, id: \.self) { name in
                        HStack {
                            Text(name).font(Style.mono)
                            Text("\(model.book.templateCounts[name] ?? 0) case(s)").foregroundStyle(.secondary)
                            Spacer()
                            Button("Add") { model.addTemplate(name) }
                            Button("Show Cases") { model.page = .cases(.refused); model.searchText = name }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Outcome codes

struct OutcomesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(model.data.settings.outcomes) { o in outcomeSection(o) }
            if !model.unclassifiedCodes.isEmpty {
                Section {
                    ForEach(model.unclassifiedCodes, id: \.self) { code in
                        HStack {
                            Text(code.isEmpty ? "(blank)" : code).font(Style.mono)
                            Text("\(model.book.outcomeCounts[code] ?? 0) case(s)").foregroundStyle(.secondary)
                            Spacer()
                            Button("Classify") { model.updateOutcome(code) { _ in } }
                        }
                    }
                } header: {
                    Text("Seen in the Control Sheet but Not Classified")
                } footer: {
                    Text("Until classified, these cases are flagged and shown separately in the rates.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func outcomeSection(_ o: OutcomeCode) -> some View {
        Section {
            Picker("Meaning", selection: Binding(get: { o.kind }, set: { kind in
                model.updateOutcome(o.code) { x in
                    x.kind = kind
                    x.rates = OutcomeCode.defaultRates(kind)
                    x.countsAsWorkload = OutcomeCode.defaultWorkload(kind)
                }
            })) {
                ForEach(OutcomeKind.allCases) { Text($0.title).tag($0) }
            }
            TextField("Label", text: model.outcomeBinding(o.code, \.label, default: ""), prompt: Text(o.kind.title))
            Picker("In the rates", selection: model.outcomeBinding(o.code, \.rates, default: .excluded)) {
                ForEach(RateTreatment.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Counts towards the analyst's workload", isOn: model.outcomeBinding(o.code, \.countsAsWorkload, default: true))
            if o.kind == .project {
                Picker("Project", selection: model.outcomeBinding(o.code, \.project, default: "")) {
                    Text("None").tag("")
                    ForEach(model.data.projects) { p in Text(p.definition.name).tag(p.id) }
                }
            }
        } header: {
            HStack {
                Text(o.code).font(Style.mono)
                Text("\(model.book.outcomeCounts[o.code] ?? 0) case(s)").foregroundStyle(.secondary)
                Spacer()
                if o.code != "a" && o.code != "r" {
                    Button("Remove") { model.removeOutcome(o.code) }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }
}
