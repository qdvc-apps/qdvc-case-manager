# QDVC Case Manager — Workspace File Format

Format version 1. A workspace is a folder you can commit to Git. The app's
own files are UTF-8 with `\n` line ends: YAML for settings and reference
data, CSV for the imported exports, which are tables. The app writes each
file atomically, and only when its content changes. A YAML file that fails
to load is reported and never overwritten until it is fixed and the
workspace reloaded.

## 1. Layout

```
my-workspace/
├── case-manager.yml                      settings and outcome codes (§2)
├── analysts.yml                          the analyst pool (§3)
├── templates.yml                         return-to-sender templates (§4)
├── decisions.yml                         shortlists and the batch (§7)
├── imports/
│   ├── case-catalogue.csv                the latest catalogue export, verbatim
│   └── allocation-control-sheet.csv      the latest control sheet export, verbatim
├── mappings/
│   ├── case-catalogue.yml                which column is which (§5)
│   └── allocation-control-sheet.yml
└── projects/
    ├── operation-waymaker.yml            a project (§6)
    └── operation-waymaker.csv            its worksheet, verbatim
```

A folder is a workspace if it holds `case-manager.yml`. Opening an empty
folder makes it one.

Imported exports are copied byte for byte (whatever their encoding or
separator), so `git diff` shows what changed between exports. They are
read as UTF-8, UTF-16 (with a BOM) or Windows-1252, with a comma,
semicolon, tab or pipe separator, detected from the file.

**Case IDs are verbatim strings**: matched exactly, case and leading zeros
included (`00123` and `123` are different cases); only spaces around them
are ignored. In YAML they are quoted where they would otherwise read as
numbers.

## 2. `case-manager.yml`

```yaml
format: 1
title: Sample Directorate
lenient_comparison: true
special_notes:
- As per Protocol 67
outcomes:
- code: a
  kind: allocated
  label: Allocated to analyst
- code: r
  kind: refused
  label: Refused & returned
- code: sp
  kind: special
  label: Special
- code: Operation Waymaker
  kind: project
  label: Operation Waymaker
  project: operation-waymaker
```

| Key | Meaning |
| --- | --- |
| `title` | Shown in the window title and recent list. |
| `lenient_comparison` | Compare titles and genres between the exports ignoring case, accents and repeated spaces (default true). |
| `special_notes` | Allocation notes containing one of these are "special notes", not expertise phrases. |
| `outcomes` | Each code the control sheet uses: `kind` is `allocated`, `refused`, `special`, `project` or `other`. Optional `rates` (`accepted`, `refused`, `special`, `excluded`; default: allocated accepted, refused refused, special special, others excluded), `workload` (default true except for refused), `project` (a project id). The standard codes a, r and sp are always present: one missing (sp, in a workspace made before it existed) is added when the file is read. Codes not listed are flagged as unclassified. |

Unknown keys are kept and written back.

## 3. `analysts.yml`

```yaml
analysts:
- shorthand: AJB
  name: Alice J. Brown
  active: true
  aliases: [AB]
  expertise: Forensic accounting; procurement fraud; supplier due diligence
  notes: Part time
```

`shorthand` is what the control sheet's analyst column writes; `aliases`
are other shorthands for the same analyst (matched ignoring case).
`expertise` is the long specialisation string searched by Decision
Support; allocation notes are phrases from it. Inactive analysts keep
their history but are left out of the pool.

## 4. `templates.yml`

```yaml
templates:
- name: IS_DUPLICATE
  description: The matter is already registered under another case.
```

Written in alphabetical order of name. A bare list of names
(`- OUT_OF_SCOPE`) is also read.

## 5. `mappings/<source>.yml`

```yaml
source: imports/allocation-control-sheet.csv
original_filename: Allocation Control Sheet (export).csv
imported_at: '2026-11-04'
date_order: day-first
columns:
  case_id: Case Ref
  title: Title (as entered)
  genre: Genre
  registration_date: Reg. Date
  supervisor: Alloc Supervisor
  allocation_date: Date Allocated
  outcome: Outcome
  note: Alloc Note
  analyst: Analyst (SH)
```

`columns` maps each field to the export's header. The catalogue uses
`case_id`, `title`, `genre` and `registration_date`. `date_order`
(`day-first`, `month-first`, `year-first`) settles all-numeric dates such
as 03/04/2026; ISO dates, month names, `20261105` and Excel serial numbers
are read regardless. `imported_at` drives the freshness shown in the app.

## 6. `projects/<id>.yml`

```yaml
name: Operation Waymaker
badge: WAY
colour: indigo
leader: KM
leader_title: Team Leader
worksheet: operation-waymaker.csv
case_id_column: Case
outcome_codes: [Operation Waymaker]
note_keywords: [Waymaker]
original_filename: Waymaker tracker v7.csv
imported_at: '2026-11-03'
```

The worksheet (`<id>.csv`) can have any columns; `case_id_column` names the
one with case IDs. A case belongs to the project when its latest outcome is
in `outcome_codes`, or any of its control sheet notes contains a
`note_keywords` word, or an outcome code's `project` names this project;
such cases missing from the worksheet are flagged. `colour` is one of
indigo, teal, orange, pink, purple, brown, green, blue, red, yellow.

## 7. `decisions.yml`

The supervisor's work in Decision Support, keyed by case ID:

```yaml
QD-26-00907:
  shortlist: [KM, EN]
  outcome: a
  analyst: EN
  note: Cyber incident response
  supervisor: M. Okafor
  date: '2026-11-05'
  order: 2
  updated: '2026-11-05'
```

A case with an `outcome` is a **prepared row** in the batch, at position
`order`; `date` is the allocation date to write. A case with only a
`shortlist` (and perhaps a `note`) is work in progress. When an imported
control sheet has a decision for the case, the row has landed and can be
removed from the batch; the shortlist stays until removed.

Prepared rows are pasted into the control sheet with every column of its
last import, in its order: mapped fields filled in (title, genre and
registration date from the catalogue), other columns blank, and dates
written in the style the sheet already uses.
