# Year-Folder Trust, New Year Window and Tree Lists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Organize Local Media from moving files out of the owner's year folders on file-system dates, keep New Year's Eve shoots in one year, ignore the GPS-epoch date, and show the three step lists as a folder tree with folder-level checkboxes.

**Architecture:** The rules live in the pure `LocalMediaOrganizationPlanner` (new `.kept` outcome, injectable time zone). The scanner and `LocalPhotosService` carry kept items to a new collapsed section. A pure `LocalMediaTree` turns paths into header/file rows. A new `LocalMediaTreeList` view replaces `LocalMediaFilteredList` in the three Organize Local Media steps.

**Tech Stack:** Swift 5.9 package / Xcode project, SwiftUI, macOS 14, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-26-year-folder-trust-and-tree-lists-design.md`

## Global Constraints

- `AGENTS.md` applies in full. The conventions most relevant here: step state lives in the service, the checkbox is aligned with `.localMediaRowAnchor()`, UI text is English, and work is test-first.
- Work directly on `main` (the owner allows no branches). End commit messages with:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01Y29YBRturbhCdDn9NY6E7i`.
- Never install, launch, quit or kill the app. Never touch `/Volumes/MEDIA` or the owner's Pictures folder. `swift test` and `pnpm build` are allowed.
- `swift test` must pass. `pnpm build` must show no compiler warnings. `pnpm lint` must stay at ≤ 61 violations with none in touched files, and files must stay within 500 lines. Use pnpm, never npm.
- Register new app Swift files in `TeziovskyUtilities.xcodeproj/project.pbxproj` (4 entries). Test files are not registered.
- New Year window W(Y) runs from 31 Dec Y 12:00 to 1 Jan Y+1 12:00, local time. The night rule covers 1 Jan 00:00–05:59 local and assigns those files to the previous year. The GPS epoch is 6 Jan 1980, matched at ±14 h.
- Exact copy for the kept section title: "Kept in year folder — only file-system date disagrees (N)".

## Review Focus

1. **Time zones:** the window and night rules use the planner's time zone, not UTC. Test: `testNewYearWindowUsesLocalTimeZone` (Task 1). Example: 31 Dec 2022 23:30 in Europe/Warsaw is 22:30 UTC.
2. **Live Photo pair:** the still (EXIF date) and its `.MOV` (container date) must reach the same keep/move decision on New Year's night. Test: `testLivePhotoPairOnNewYearNightStaysTogether` (Task 1).
3. **`_Filmy` under a year folder:** the nearest year ancestor counts. Example: `2022/_Filmy/x.mp4` with a container date of June 2023 moves to `2023/_Filmy`. Test: `testVideoInFilmyMovesOnEmbeddedDate` (Task 1).
4. **Filter with a folder checkbox:** a folder's checkbox only changes the files currently shown (those matching the filter). Hidden files keep their state. Test: `testFolderToggleAffectsOnlyVisiblePaths` (Task 3).
5. **Kept files count as organized:** the step's "already organized" count and Move to External Drive readiness include them. Test: `testKeptFileCountsAsAlreadyOrganized` (Task 2).

---

### Task 1: Planner rules (year-folder trust, New Year window, GPS epoch)

**Files:**
- Modify: `TeziovskyUtilities/Models/FileDateRepairModels.swift` (`FileDateRepairPlanner.isSentinel` epoch list, `LocalMediaOrganizationPlan`, `LocalMediaOrganizationPlanner.plan`)
- Test: `Tests/TeziovskyUtilitiesTests/YearFolderTrustTests.swift` (new)

**Interfaces:**
- Produces:
  - `struct LocalMediaKeptItem: Identifiable, Sendable, Equatable { var id: String { relativePath }; let fileURL: URL; let relativePath: String; let yearFolder: String; let disagreeingDate: Date; let disagreeingSource: FileDateSource }`
  - `LocalMediaOrganizationPlan` gains `case kept(LocalMediaKeptItem)`.
  - `LocalMediaOrganizationPlanner.plan(..., now: Date = Date(), timeZone: TimeZone = .current)`. All existing parameters stay, and every year computation in `plan` uses `timeZone`.
  - `static func placementYear(for date: Date, timeZone: TimeZone) -> Int`: the calendar year, except 1 Jan 00:00–05:59 local, which returns year−1.
  - `static func isInNewYearWindow(_ date: Date, nextToYearFolder year: Int, timeZone: TimeZone) -> Bool`: true if the date is in W(year) or W(year−1).

**Algorithm for `plan`** (the existing `destinationDirectory`, `_Filmy` and Live Photo `groupsWithPhotos` logic is unchanged; only the deciding year changes):
1. If `nearestYearDirectory(parent)` exists and is inside or at the root, the file is in year folder `Y` (Int). In that case:
   - `embedded` = plausible evidence with `source.isEmbeddedCreationDate`.
   - `overall` = `oldestPlausibleEvidence`.
   - If `embedded` is empty, or `year(e) == Y` (local), or `isInNewYearWindow(e, nextToYearFolder: Y)` → it stays. If `overall` exists and its placement year ≠ Y and it is not in the window → `.kept(item with overall date/source)`. Otherwise `.unchanged`.
   - Otherwise the deciding date is `e` and the year is `placementYear(e)`.
2. If the file is not in a year folder: the deciding date is `overall` (none → `.unchanged`) and the year is `placementYear(overall)`.
3. Then the existing destination, root and `.outsideScannedFolder` logic runs. `LocalMediaOrganizationItem.proposedDate/proposedSource` = the deciding evidence.

- [ ] **Step 1: Write failing tests**, all with `timeZone: TimeZone(identifier: "Europe/Warsaw")!` and real temp paths only where `plan` needs URLs. Each test passes `[FileDateEvidence]`.
  - `testFileSystemDateNeverMovesFileOutOfYearFolder`: `_kuba/2014/a.jpeg` with only filesystemCreation 3 Jul 2025 → `.kept` with yearFolder "2014" and source `.filesystemCreation`.
  - `testEmbeddedDateInAnotherYearMovesFile`: `X/2019/a.jpeg` with exifOriginal 2023-02-09 → `.move` to `X/2023/a.jpeg`.
  - `testEmbeddedDateMatchingFolderStaysDespiteOlderFileSystemDate`: `X/2014/a.jpg` with exif 2014-05-01 and fsCreation 2013-01-01 → `.unchanged`.
  - `testNewYearEveShootStaysInEitherYearFolder`: exif 2023-01-01 00:40 local in `DUEL/2022/` → `.unchanged`; exif 2022-12-31 23:10 in `DUEL/2023/` → `.unchanged`; exif 2023-01-01 13:00 in `DUEL/2022/` → `.move` to 2023.
  - `testNightRuleForUnsortedFiles`: `Inbox/a.jpg`, exif 2023-01-01 03:00 → `.move` to `Inbox/2022/a.jpg`; exif 2023-01-01 07:00 → `Inbox/2023/a.jpg`.
  - `testNewYearWindowUsesLocalTimeZone`: 2022-12-31 22:30 UTC (= 23:30 Warsaw) is in the window next to 2022 for Warsaw. 2023-01-01 11:30 UTC (= 12:30 Warsaw) is out.
  - `testGPSEpochIsIgnored`: fsCreation 1980-01-06 10:00 UTC is a sentinel. `_rodzinka/2008/_Filmy/Video_0001.3gp` with only that date → `.unchanged`.
  - `testVideoInFilmyMovesOnEmbeddedDate` (Review Focus 3).
  - `testLivePhotoPairOnNewYearNightStaysTogether` (Review Focus 2): the still's exif and the MOV's containerCreation are both 2023-01-01 00:30, in `2022/`, with the MOV planned with `groupsWithPhotos: true` → both `.unchanged`.
- [ ] **Step 2: Run** `swift test --filter YearFolderTrustTests` → it fails to compile (missing `.kept`, `timeZone`).
- [ ] **Step 3: Implement** per the Interfaces and the Algorithm. Fix every `switch` over `LocalMediaOrganizationPlan` so it compiles; the scanner is handled in Task 2, so for now treat `.kept` like `.unchanged` there.
- [ ] **Step 4: Run** the focused tests and then `swift test` → all pass. Update existing planner tests only if they encoded the old behaviour that a file-system date moves files out of year folders, and list each changed test in the report.
- [ ] **Step 5: Commit** `fix(local): trust year folders over file-system dates and keep New Year's Eve together`.

---

### Task 2: Carry kept files through scanner, service and views

**Files:**
- Modify: `TeziovskyUtilities/Services/FileDateRepairService.swift` (`FileDateScanOutput`, `FileDateScanResult`, `scanFile`, `scan`, `LocalPhotosService`)
- Modify: `TeziovskyUtilities/Views/FileDateRepairModeView.swift` (Organize preview)
- Test: `Tests/TeziovskyUtilitiesTests/YearFolderTrustTests.swift`

**Interfaces:**
- Consumes: `LocalMediaKeptItem`, `.kept` (Task 1).
- Produces:
  - `FileDateScanOutput.keptItem: LocalMediaKeptItem?`. On `.kept`, `isAlreadyOrganized` is true.
  - `FileDateScanResult.keptItems: [LocalMediaKeptItem]`, sorted by `localizedStandardCompare`.
  - `LocalPhotosService.keptItems` is `@Published private(set)` and is reset with the other results.
- View: under the Organize preview's lists, a `DisclosureGroup`, collapsed by default, titled "Kept in year folder — only file-system date disagrees (\(n))". Rows show the path and "Folder \(yearFolder) kept · \(date) from \(source.label)", with Reveal in the context menu and no checkbox. The section is hidden when n == 0.

- [ ] **Step 1: Write failing tests**:
  - `testKeptFileCountsAsAlreadyOrganized` (Review Focus 5): on a temp dir, `2014/a.jpg` has no EXIF and its Finder dates are set to 2025 via `FileDatePreservation.applyFileDates`. Run `FileDateRepairScanner.scan`. Expect `organizationItems` empty, `keptItems.count == 1`, `organizationSkippedCount == 1`.
  - The same fixture through `scanOutputs` and `ExternalDriveClassifier.classify` (existsOnDestination false) → `.ready`.
- [ ] **Step 2: Run** `swift test --filter YearFolderTrustTests` → fail.
- [ ] **Step 3: Implement** the scanner, the service and the view section.
- [ ] **Step 4: Run** `swift test` → pass. Then `pnpm build` → no warnings.
- [ ] **Step 5: Commit** `feat(local): list files kept in their year folder`.

---

### Task 3: Tree model and folder selection

**Files:**
- Create: `TeziovskyUtilities/Utilities/LocalMediaTree.swift` (+ pbxproj)
- Modify: `TeziovskyUtilities/Services/FileDateRepairService.swift` (`LocalPhotosService` bulk exclusion)
- Test: `Tests/TeziovskyUtilitiesTests/LocalMediaTreeTests.swift` (new)

**Interfaces:**
- Produces:
  - `struct LocalMediaTreeRow: Identifiable, Equatable { enum Kind: Equatable { case folder(path: String, title: String, filePaths: [String]); case file(index: Int) }; let kind: Kind; let depth: Int; var id: String }`. `filePaths` lists every file under the folder, recursively. `index` points into the input `paths`. `id` is `"d:" + path` for folders and `"f:" + paths[index]` for files.
  - `static func LocalMediaTree.rows(paths: [String], collapsed: Set<String>) -> [LocalMediaTreeRow]`:
    - Folders sort with `localizedStandardCompare` before the files at the same level.
    - Files keep their input order within a folder.
    - A folder with no files and exactly one subfolder merges with it into one header. Its `title` is the joined path (`"Festiwale/Audioriver/2023"`), and its `path` is the full deepest path.
    - Files at the root have depth 0 and no header.
    - Collapsed folders emit their header but nothing below it.
  - `enum LocalMediaFolderSelection { case all, some, none }`
  - `LocalPhotosService.setExcluded(_ excluded: Bool, paths: [String], in step: LocalMediaStep)` (bulk)
  - `LocalPhotosService.selection(of paths: [String], in step: LocalMediaStep) -> LocalMediaFolderSelection`

- [ ] **Step 1: Write failing tests**:
  - `testRowsGroupFilesUnderCompressedFolders`: paths `["Imprezy/Festiwale/Audioriver/2023/a.jpg", "Imprezy/Festiwale/Audioriver/2023/b.jpg", "Imprezy/Warszawa/DUEL/2022/c.jpg", "root.jpg"]`. Expected rows: folder "Imprezy" (depth 0) → folder "Festiwale/Audioriver/2023" (depth 1) → files a, b (depth 2) → folder "Warszawa/DUEL/2022" (depth 1) → file c (depth 2) → file root.jpg (depth 0). Assert kinds, titles, depths and `filePaths` of "Imprezy" (3 files).
  - `testCollapsedFolderHidesDescendants`.
  - `testFolderSelectionStates`: none excluded → `.all`, some → `.some`, all → `.none`. Bulk `setExcluded(true, …)` then `(false, …)` round-trips.
  - `testFolderToggleAffectsOnlyVisiblePaths` (Review Focus 4): build rows from a filtered subset and toggle the folder's `filePaths`. Files outside the subset keep their state.
- [ ] **Step 2: Run** `swift test --filter LocalMediaTreeTests` → fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → pass. Then `swift test`.
- [ ] **Step 5: Commit** `feat(local): folder tree model with bulk selection`.

---

### Task 4: Tree list view in the three steps

**Files:**
- Modify: `TeziovskyUtilities/Views/LocalMediaListComponents.swift` (add `LocalMediaTreeList`; keep `LocalMediaFilteredList` for Move to External Drive)
- Modify: `TeziovskyUtilities/Views/FileDateRepairModeView.swift` (the Convert, Dates and Organize lists at ~199, ~405, ~564 use `LocalMediaTreeList`)

**Interfaces:**
- Consumes: Task 3.
- Produces: `struct LocalMediaTreeList<Item: Identifiable, Row: View>: View { @ObservedObject var service: LocalPhotosService; let items: [Item]; let path: (Item) -> String; let filter: String; let step: LocalMediaStep; @ViewBuilder let row: (Item) -> Row }`, with `@State collapsed: Set<String>` and `@State showsAll`.

Behaviour:
- Filter → `LocalMediaTree.rows`.
- **Row limit:** render rows until 300 file rows have been emitted (headers don't count), then show "Show all N files".
- **Folder header:**
  - indent 18 pt × depth;
  - chevron button that toggles collapse;
  - tri-state checkbox: a custom `Button` showing `checkmark.square.fill` / `minus.square.fill` / `square`, with `.help("Include all files in this folder")` or the matching "Exclude …" text. Clicking `.some` or `.none` includes all; clicking `.all` excludes all. It is disabled while `service.isRunning`. Align it with `.localMediaRowAnchor()` so it lines up with the file rows' checkboxes;
  - title in monospaced callout, with "\(n) files" in secondary.
- **File rows:** the existing `row(item)`, indented by depth.

- [ ] **Step 1: Implement** and replace the three call sites.
- [ ] **Step 2: Verify** with `pnpm build` (no warnings), `swift test`, and `pnpm lint` (≤ 61, files ≤ 500 lines; split views into a new file if needed and register it).
- [ ] **Step 3: Commit** `feat(local): show review lists as a folder tree with folder checkboxes`.

---

### Task 5: Docs

**Files:** `README.md`: the Organize Local Media paragraph covers rule 1, the New Year window, the night rule, the GPS epoch, the kept section and the tree lists.

- [ ] **Step 1:** Update the README from the code as built.
- [ ] **Step 2:** Run `swift test` and `pnpm build`.
- [ ] **Step 3: Commit** `docs: year-folder trust, New Year window and folder tree`.
