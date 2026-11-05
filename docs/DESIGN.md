# QDVC Case Manager — Design Notes

## Windows

- **Welcome** at launch, as in Xcode and Keynote (and the other QDVC apps):
  New and Open on the left, recent workspaces on the right. It hands over
  to the main window when a workspace opens and comes back when it closes.
- **Main window**: a standard NavigationSplitView (sidebar, page,
  inspector), toolbar and search field, so the app picks up Liquid Glass on
  macOS 26 without custom chrome.
- **Decision Support**: a `WindowGroup` keyed by case ID. The supervisor
  works with the case paperwork on another screen, so this is a window of
  its own that can sit beside it, rather than a sheet over the case list.
  Opening a case that already has a window brings that window forward.
  "Add to Batch & Next Case" moves the same window on, so a batch is worked
  through without opening a window per case.

## Sidebar

Pages, not records: **Cases** (six scopes of one table), **Allocate ›
Batch**, **Projects** (one per worksheet), **Insights** (Workload,
Acceptance & Refusal) and **Workspace** (Analysts, Return Templates, Outcome
Codes, Data Sources). Badges count what needs doing: cases per scope, rows
to paste, cases missing from each worksheet, unknown shorthands, unknown
templates, unclassified codes. The foot shows each export's freshness.

## Joining the exports

The catalogue is the list of cases; the control sheet holds decisions.
Each case's **latest** decision (by allocation date, then file order) sets
its status. Reallocations are out of scope for now: earlier rows are kept
and shown in the inspector, but only the latest counts anywhere.

Where the control sheet's title, genre or registration date differ from
the catalogue's, the case ID decides: the catalogue's values are shown,
and the case gets the **(!)** emblem (amber), as do cases in only the
control sheet, repeated catalogue IDs, and cases missing from a project
worksheet. Softer problems (an unknown shorthand, an unclassified outcome
code, a template name not listed) get a grey (?) and the Needs Attention
scope.

Notes are classified: a phrase from the allocated analyst's expertise
(green seal), a special note (purple star), a note not in the analyst's
expertise (orange ?), a return-to-sender template, or an unknown one.

## Non-standard outcomes

Every code is classified in Outcome Codes: allocated, refused, project or
other, plus how it counts in the rates and whether it is workload.
"Operation Waymaker" is a project outcome: shown separately in the rates
(neither a nor r) and counted as the named analyst's workload. A code
nobody has classified yet is flagged and shown separately, never silently
counted as a or r.

## Workload

One case is one unit, counted against the analyst of its latest decision
in the month of its allocation date, if the outcome counts as workload.
"This month" is the calendar month; "past 12 months" is the 12 calendar
months ending with it. Cases prepared in the batch but not yet in the
control sheet are shown as "+n" beside this month's figure, so a batch of
a dozen doesn't pile onto one analyst unnoticed.

The balance index is the coefficient of variation of cases across the
active pool (standard deviation over mean): 0 is perfectly even.

## The batch

Allocations are made upstream. Decision Support therefore prepares rows
for the Allocation Control Sheet rather than recording decisions itself:
the supervisor works through about a dozen cases, copies the rows (as tab-
separated cells, which paste into a spreadsheet as cells), pastes them
upstream, exports the updated sheet and imports it. Rows whose decision
now appears are marked landed (or "decided differently" if the sheet
records another outcome or analyst), and the app offers to remove them.

The rows follow the control sheet's own columns, in order, so they paste
straight in; columns the app doesn't know are blank. Dates are written as
the sheet writes them (`DateStyle.infer`), so a sheet with 05/11/2026 gets
05/11/2026, not 2026-11-05.

## Data freshness

Workload figures are only as current as the last control sheet export.
The sidebar foot, Decision Support's header and Data Sources show when
each export was imported and the latest date in it, in orange once it is
older than the threshold in Settings (7 days by default).

## Heat map

A SwiftUI Grid of cells shaded pale to deep teal relative to the largest
cell in view, as the spreadsheet's conditional formatting did. Clicking a
cell opens a popover listing its cases; clicking one shows it in the
catalogue.

## Choices worth revisiting

- Case IDs are exact strings, ignoring only surrounding spaces.
- A prepared row's allocation date defaults to the day it is prepared.
- The supervisor's name is a preference on each Mac, not in the shared
  workspace, since several supervisors may share one workspace.
- Analyst shorthands match ignoring case; case IDs don't.
