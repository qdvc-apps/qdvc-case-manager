# QDVC Case Manager for macOS

Support allocation supervisors in allocating cases to a pool of analysts.

Import the case catalogue and the allocation control sheet exported from
upstream, map their columns once, and see every case with its latest
allocation decision. Mismatches between the two exports are flagged (!).
Open a case in **Decision Support** to search the analysts' expertise,
compare their workload this month and over the past 12 months, shortlist,
and prepare the control sheet row. Work through a batch of a dozen or so,
copy the rows, paste them into the Allocation Control Sheet upstream, then
import the updated sheet: rows that have landed are recognised.

A native SwiftUI and AppKit app for macOS 14 (Sonoma) and later, in the
QDVC suite. See [Build and run](#build-and-run).

**Offline.** The app never connects to the network or the internet, and
building it downloads nothing: the package has no dependencies. See
[docs/MAINTENANCE.md](docs/MAINTENANCE.md#offline).

Each workspace is a plain folder of YAML and CSV files, designed to be kept
in Git. The format is documented in [docs/FILE_FORMAT.md](docs/FILE_FORMAT.md).

## What it does

At launch the app reopens the last workspace you had open. If there is
none (or it has gone), a welcome window, as in Xcode and Keynote, offers to
create or open one and lists recent ones. The main window has a sidebar, the
page, and (on case pages) an inspector. The layout is explained in
[docs/DESIGN.md](docs/DESIGN.md).

**Cases**

- **All Cases, Awaiting Allocation, Allocated, Refused & Returned,
  Special, Projects & Other, Needs Attention**: the case catalogue joined
  with the control sheet, one registration **year** at a time (the Year
  menu in the toolbar, this year by default; each year shows how many cases
  it has and how many are awaiting). Columns: case ID (with the (!) emblem), title, genre, registration
  date, status, analyst, allocation date, supervisor, note (with what kind
  of note it is) and project badges. Search, filter by genre, sort by any
  column; ⌘C copies the selected case IDs. Cases in the control sheet but
  not the catalogue are listed too, flagged.
- The **inspector** shows a case's details, why it needs attention, a
  side-by-side of catalogue and control sheet values where they differ (the
  case ID decides; the catalogue's details are shown), every control sheet
  row for the case, its project worksheet rows and every catalogue column.
- Double-click a case (or ⌘D) for **Decision Support**.

**Decision Support** (a window per case, to sit beside the paperwork)

- Search the analysts' specialisation/expertise: words and "quoted
  phrases", all or any, ignoring case and accents; matches are highlighted.
  Chips offer the notes most often used for the case's genre.
- Each analyst shows cases this month (plus any already in your batch),
  the past 12 months, a 12-month sparkline, how many of this genre they've
  had, and when they were last allocated; figures well above the team
  average are orange. The header says how current the control sheet is.
- Star analysts to shortlist them (kept in the workspace). **Choose** sets
  the analyst and picks the matching expertise phrase as the note.
- Analysts are sorted by the lightest past 12 months by default (or best
  match, lightest this month, name).
- Prepare the row: outcome (a, r, sp, or any other code), analyst, note (a
  phrase from the analyst's expertise, a special note, or a return-to-sender
  template for a refusal), supervisor and date. **Add to Batch & Next
  Case** (⌘↩) moves on to the next case awaiting allocation.

**Batch**: the prepared rows, in order, with checks (no analyst, a note
that isn't a template, …), and the rows exactly as they will be pasted:
every column of the control sheet in its order, dates written the way the
sheet writes them. **Copy Rows** (⇧⌘C) copies them as spreadsheet cells;
also with a header row, as CSV, or saved to a file. After importing the
updated control sheet, landed rows are marked (and those decided
differently flagged) and can be removed.

**Projects**: each imported project worksheet, shown in the sidebar with
its badge; right-click it to edit the project, update its worksheet from a
newer file, show the worksheet in Finder or remove the project (also File ›
Import › Update Project Worksheet, and the buttons on its page; choosing a
newer copy with New Project from Worksheet offers to update instead) (any columns, as long as
one holds the case ID): the worksheet itself, with each case's status; the
project's cases; and **Completeness**: cases the exports put in the project
(by outcome code, e.g. "Operation Waymaker", or a note keyword) that the
worksheet lacks, and worksheet rows matching no case. Badges in the case
list show which cases are on a worksheet (filled) or should be (outlined).

**Insights**

- **Workload**: the familiar pivot, analysts by month, shaded as a heat
  map, with totals, busiest first; click a cell for its cases. Plus this month's total
  and average, the busiest and lightest analysts, a balance index (how
  evenly the work is spread), cases per month, totals per analyst against
  the average, and the balance month by month. Export the pivot as CSV.
- **Acceptance & Refusal**: acceptance rate a/(a+r) and refusal rate
  r/(a+r) month by month (latest first), by supervisor or by genre, with
  charts. Special (sp), neither a nor r, has its own yellow column; project
  and other outcomes are shown separately. Export as CSV.

**Workspace**

- **Analysts**: shorthand (and other shorthands the control sheet uses),
  full name, active or not, the long expertise string, notes, and their
  workload. Shorthands in the control sheet with no analyst are listed for
  adding.
- **Return Templates**: IS_DUPLICATE, INCOMPLETE_FORM…, alphabetically.
  Names used in refusals but not listed are offered for adding.
- **Outcome Codes**: what each code means (allocated, refused, special,
  project, other; a, r and sp are standard), how it counts in the rates, whether it counts as workload, and
  its project. Codes in the control sheet that aren't classified are
  listed and flagged.
- **Data Sources**: each export's file, when it was imported, how far its
  data reaches, its column mapping; re-import or edit the mapping; data
  checks; comparison and special-note settings. The foot of the sidebar
  always shows how fresh both exports are (orange when older than a week,
  adjustable in Settings).

## Requirements

- macOS 14 Sonoma or later.
- Xcode 16 or later (free from the Mac App Store); Xcode 26 or later for the
  Liquid Glass look. Full Xcode is needed, not just the Command Line Tools:
  from Xcode 27, SwiftUI's `@State` is a macro whose compiler plugin
  (SwiftUIMacros) ships only with Xcode, so a Command Line Tools or swift.org
  toolchain fails with "plugin for module 'SwiftUIMacros' not found".
- No paid Apple Developer account.

## Build and run

From the repository root:

```sh
scripts/build-app.sh            # build "build/QDVC Case Manager.app" (release)
scripts/build-app.sh --install  # …and copy it to ~/Applications
```

`scripts/build-app.sh` first checks the app is offline (no package
dependencies, no networking API in the sources). It builds with Xcode's
toolchain even when `xcode-select` points at the Command Line Tools: it
picks the newest Xcode installed, and says which Xcode and macOS SDK it is
using (warning if the SDK predates Liquid Glass). It also records that SDK
in the app's binary, which is what turns on Liquid Glass (`swift build`
alone writes the deployment target there, 14.0, so a `swift run` build
keeps the classic look). Check a build with
`vtool -show-build "build/QDVC Case Manager.app/Contents/MacOS/QDVCCaseManager"`:
`sdk` should be 26.0 or later.

To run or test from the command line, point the tools at Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run                       # build and launch (debug)
swift test                      # run the unit tests
```

The core library (`CaseCore`: CSV and date reading, column mapping, the
YAML workspace, joining the exports, workload, rates, search, the batch) has
no AppKit or SwiftUI and builds and tests on Linux too.

A `sample-workspace/` is included (File › Open Workspace…): about 920 made-up
cases over 18 months, ten analysts (one inactive, one with an alias),
"Operation Waymaker" with its worksheet, deliberate mismatches, an
unclassified outcome code, an unmapped shorthand, a misspelt template, and a
batch in progress.

## Signing without a paid account

`scripts/build-app.sh` signs the app **ad hoc** (`codesign --sign -`). That is
all macOS needs to run an app on the Mac that built it. If you give the app
to someone else, macOS will block the first launch; they can allow it in
**System Settings → Privacy & Security → Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/QDVC Case Manager.app"
```

## App icon

A frosted-glass workload heat map (an avatar dot per analyst, cells from
pale to deep teal) sealed with a teal analyst badge, generated by
`tools/make_icon.py` on Apple's macOS icon template in the same style as the
other QDVC apps, in the "Teal" palette.

## Where things are stored

- Each workspace: only in its folder (docs/FILE_FORMAT.md). Changes are
  written a moment after they are made, when you leave the app, and on quit.
  The app notices files changed by Git or another editor when you come back
  to it; View › Reload from Disk (⌘R) re-reads them.
- Preferences (your name as supervisor, staleness threshold, recent
  workspaces): the standard macOS defaults domain
  (`defaults read org.qdvc.case-manager.mac`).

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N / ⌘O | New / open workspace |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | Import case catalogue / control sheet / project worksheet |
| ⇧⌘1 | Welcome window |
| ⌘D | Decision Support for the selected case |
| ⇧⌘D | Next case awaiting allocation |
| ⌘↩ | Add to batch and go to the next case (Decision Support) |
| ⇧⌘C | Copy the batch rows to paste upstream |
| ⇧⌘E | Export the cases shown as CSV |
| ⌃⌘1 … ⌃⌘8 | All Cases, Awaiting, Needs Attention, Batch, Workload, Acceptance & Refusal, Analysts, Data Sources |
| ⌘C | Copy the selected case IDs |
| ⌘F | Search cases |
| ⌘R | Reload from disk |
