# QDVC Case Manager for macOS — Maintenance Guide

The rule that matters most: **the workspace is the contract.** The files the
app writes are documented in [FILE_FORMAT.md](FILE_FORMAT.md) and checked
by the unit tests. Any change to a file name or to the bytes of a file is a
format change: update FILE_FORMAT.md and the tests with it.

## 1. Layout

```
Package.swift                 SwiftPM manifest (no Xcode project, no dependencies)
Sources/CaseCore/             the model: Foundation only, no AppKit/SwiftUI
Sources/QDVCCaseManager/      the SwiftUI/AppKit app
Tests/CaseCoreTests/          unit tests, the offline check, the sample generator
tools/make_icon.py            regenerates Resources/AppIcon.{svg,icns}
scripts/build-app.sh          checks it's offline, builds with the newest Xcode, ad-hoc signs
Resources/Info.plist          bundle id org.qdvc.case-manager.mac
sample-workspace/             a worked example (regenerate, below)
docs/                         DESIGN, FILE_FORMAT, this guide
```

`CaseCore` builds and tests on Linux (Swift 5.10 or later), which is how it
was developed; the app target is declared on macOS only.

### 1.0 Toolchain

Build with full Xcode. From Xcode 27, SwiftUI's `@State` is a macro whose
implementation (the SwiftUIMacros compiler plugin) ships with Xcode, so the
Command Line Tools or a swift.org toolchain fail with "plugin for module
'SwiftUIMacros' not found". `scripts/build-app.sh` therefore sets
`DEVELOPER_DIR` to the newest installed Xcode when `xcode-select` points at
the Command Line Tools, runs `xcrun swift`, prints the compiler and SDK
versions, and warns when the SDK is older than 26 (no Liquid Glass). An
explicit `DEVELOPER_DIR` is respected. The same block is used in the other
QDVC macOS apps; keep them in step.

AppKit decides on Liquid Glass from the SDK version recorded in the
executable's `LC_BUILD_VERSION`. `swift build` records the deployment target
there (`sdk 14.0`), so after copying the executable into the bundle the
script rewrites that field with `vtool -set-build-version macos <minos>
<sdk> -replace`, before signing. Check with `vtool -show-build`.

### 1.1 Offline

QDVC Case Manager must never access the network or the internet, and
neither may its build.

- **No package dependencies.** The YAML reader and writer
  (`Sources/CaseCore/YAML.swift`) is the suite's own, from QDVC Response
  Letter, rather than Yams, so `swift build` resolves nothing and
  downloads nothing. There is no `Package.resolved`.
- **No networking APIs** anywhere in `Sources/`: no URLSession,
  URLRequest, Network framework, WebKit, `openURL`, SwiftUI `Link`,
  `AsyncImage`, sockets or streams, Bonjour, CloudKit, and no `http://` or
  `https://` strings. `OfflineTests` (in `swift test`) and
  `scripts/build-app.sh` both enforce this; extend their lists together.
- Files are only read from and written to places the user picks (the
  workspace, an import, an export); Finder is used only to reveal folders.
- `tools/make_icon.py` and the sample generator are local too.

If the policy ever needs an operating-system guarantee as well, the app
could adopt the App Sandbox without the `network.client` entitlement; that
needs security-scoped bookmarks for the recent-workspaces list.

### 1.2 App icon

`tools/make_icon.py` writes `Resources/AppIcon.svg` and
`Resources/AppIcon.icns` (needs `rsvg-convert`). "Teal" palette, Apple's
template geometry, matching the other QDVC apps. `--preview` also writes
`build/icon-preview.png`.

### 1.3 Sample workspace

`MAKE_SAMPLE=$PWD/sample-workspace swift test --filter MakeSampleTests`
rebuilds it through the core API (so it is always valid). The data is made
up and deterministic.

## 2. Modules

`CaseCore`:

| File | Responsibility |
| --- | --- |
| `Dates.swift` | `LocalDate`, `MonthKey`, `DateOrder`, `DateParser` (the many date formats of legacy exports) |
| `CSV.swift` | RFC 4180 parsing, separator and encoding detection, `CSVTable` |
| `YAML.swift` | the YAML subset (shared with QDVC Response Letter) |
| `Mapping.swift` | `SourceKind`, `MappedField`, `ColumnMapping` (with guessing from headers) |
| `Model.swift` | records, `OutcomeCode`, `Analyst`, `ReturnTemplate`, `ProjectDefinition`, `CaseDecision`, `WorkspaceSettings`, `CaseKey` |
| `WorkspaceFiles.swift` | reading and writing each YAML file |
| `Workspace.swift` | loading, saving by `WorkspacePart`, imports, change detection |
| `CaseBook.swift` | the join: `CaseRow`, status, flags, discrepancies, note kinds, project membership |
| `Workload.swift` | workload events, pivot, metrics, rates, `ExpertiseQuery`, `ExpertisePhrases` |
| `Batch.swift` | `DateStyle`, `PreparedRow`, `Batch` (rows to paste, landed state), `Freshness` |
| `Export.swift` | CSV exports |

The app (`QDVCCaseManager`): `CaseManagerApp` (scenes, delegate, menus,
welcome window, Settings), `AppModel` (state, opening and saving, every
operation; `@Observable`, main actor), `ContentView` (split view, sidebar,
freshness footer, routing), `CaseListView` (the case table and inspector),
`DecisionSupportView`, `BatchView`, `InsightsViews` (Workload, Acceptance &
Refusal), `ProjectsAndImports` (project pages, the import and project
sheets, Data Sources), `ReferenceViews` (Analysts, Return Templates, Outcome
Codes), `Support` (style, preferences, AppKit helpers, small shared views).

Core type names are checked against SwiftUI, AppKit and Foundation: QDVC
Progress hit a clash with SwiftUI's `GridRow`, QDVC Response Letter with
`Section`. `CaseRow`, not `Row`; `ReturnTemplate`, not `Template`.

### 2.1 Changes and saving

- `mutate(parts…) { data in … }` applies a change, rebuilds `derived`
  and saves the named `WorkspacePart`s 0.6 s later (and when the app is
  left, and on quit).
- **Derived figures are computed off the main thread.** `Derived.compute`
  (CaseCore, pure, `Sendable` in and out) builds the `CaseBook`, batch
  rows, workload metrics, year summaries, missing-from-worksheet counts and
  a `WorkloadSnapshot` / `RatesSnapshot` for every period and option. The
  app's `rebuild()` runs it in a detached task on a copy of the data and
  applies the result on the main actor only if no newer rebuild has
  started (`generation`). Work that needs the new figures (the "rows have
  landed" prompt after an import) goes in `rebuild(then:)`. Views must not
  compute dashboards in `body`: add what they need to `Derived`.
  `DerivedTests.testComputeIsQuick` guards the cost on the sample
  workspace.
- Text is compared folded (`CaseBook.fold`) and byte-wise: Foundation's
  case- and accent-insensitive comparisons per case made the join about
  three times slower. `CSVTable.value` only trims cells whose ends are
  white space, for the same reason.
- **Typing must not rebuild on every keystroke.** Text bindings (analysts,
  templates, outcome labels) pass `deferRebuild: true`: the data changes at
  once, the rebuild runs 0.45 s after the last keystroke. Rebuilding on
  each keystroke made the Analysts page crawl, because every window (the
  sidebar's counts, the case table, Decision Support) recomputed with it.
  The sidebar's counts are computed in the rebuild, not in `body`.
- On returning to the app, file dates are compared and the workspace
  reloaded if Git or another editor changed it.
- Imports copy the file into the workspace and reload.

### 2.1a Activity and the status bar

`AppModel.measure(_:)` times main-thread work (opening, reading from
disk, importing, saving, filtering when over 20 ms) and `begin`/`end`
bracket background work (updating figures); both go to `activityLog`,
which the status bar shows. `StallMonitor` posts a tiny task to the main
thread every 0.2 s from a background queue and reports when it waits
0.4 s or more: each such moment is recorded in `stalls` with the page,
the last user action and the main-thread work that just finished. Modal
panels and alerts aren't counted. "Copy Report" in the Activity popover
puts it all on the clipboard: ask for it with any report of slowness.

### 2.2 Layout notes

- Table column builders take at most 10 columns; the case and batch
  tables use exactly 10.
- Worksheets and the paste preview have arbitrary columns, so they use
  `SheetGrid` (a lazy grid with a pinned header) rather than `Table`. A
  two-way `ScrollView` centres content smaller than itself, so SheetGrid
  gives its content a minimum size of the view's, aligned top-leading.
- Analyst shorthands use `ShorthandText`: one line, room for seven
  characters.
- Don't attach a `.popover` or `.help` to every cell of a large grid:
  each brings AppKit machinery that has to be laid out and tracked. The
  heat map attaches its popover only to the open cell.
- **Table cells are plain values.** They don't read the model (each cell
  would observe it, and hundreds come and go as a filter is applied and
  removed) and carry no tooltips (each `.help` brings AppKit tracking
  along). Work out what a cell shows before the `Table` (as `CaseTable`
  does for project badges and `BatchView` with `Line`). The case table's
  rows are filtered and sorted by the model (`refreshCaseRows`) when the
  search (after a pause in typing), year, page, sort or data change, and
  the table only gets a new array when the rows really changed.
  `HostingTests` enforces all of this.
- **Views in table cells, menus, popovers and the inspector are handed
  the model (`var model: AppModel`); they never read it with
  `@Environment(AppModel.self)`.** Each table cell is hosted separately
  and doesn't reliably inherit the environment: a status cell that read
  the model from it crashed the app (`EXC_BREAKPOINT` in
  `EnvironmentValues.subscript.getter`) as soon as the case table drew its
  first rows. Observation still tracks what such views read. `HostingTests`
  fails if a view that reads the environment is used in a `TableColumn`.
- Text fields bound to lists (aliases, outcome codes) edit a local string
  and parse it, so typing a comma isn't undone mid-word.

## 3. Behaviour to preserve (tests)

- Dates in every supported format; months' arithmetic.
- CSV: quotes, separators, BOMs, ragged rows, blank and repeated headers,
  Windows-1252.
- Mapping guesses from terse upstream headers, and round trips.
- Every YAML file round trips; unknown settings keys are kept; a file that
  failed to load is not overwritten.
- The join: latest decision wins, aliases resolve, lenient and strict
  comparison, (!) for mismatches and missing catalogue rows, note kinds,
  project claims and worksheet orphans, verbatim case IDs (`00123` ≠ `123`).
- Workload pivot and metrics, balance; rates by month and supervisor.
- Expertise search: terms, phrases, all/any, highlight ranges.
- Batch: date styles, rows in control sheet order, pending/landed/decided
  differently, paste text, pending load.
- Derived: every dashboard snapshot is present and correct; the sample
  workspace computes quickly.
- Offline: no networking API in the sources, no package dependencies.
- Hosting: no view that reads `AppModel` from the environment is used in a
  table column.
