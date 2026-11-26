# Move to External Drive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A manually started "Move to External Drive" workflow that checks the source folder with the Organize Local Media scanner, moves only ready files to the drive with verified-identical metadata, and reports every file in one summary.

**Architecture:** A pure classifier turns per-file scanner outputs into buckets and transfer units. A mover engine copies one unit at a time (`copyfile` → `.partial` → rename → reapply dates → verify fingerprint → trash originals, or roll back). An `@MainActor` service owns the step state, progress and summary. Views and commands follow `AGENTS.md`.

**Tech Stack:** Swift 5.9 package / Xcode project, SwiftUI + AppKit, macOS 14, XCTest, Darwin `copyfile`/`stat`/`xattr`, CryptoKit, UserNotifications.

**Spec:** `docs/superpowers/specs/2026-11-26-move-to-external-drive-design.md`

## Global Constraints

- Follow `AGENTS.md` fully: commands go through `appState.run(...)`; `decision(for:)` returns `.perform` or `.notice("…")`; menu items never `.disabled`; no `.keyboardShortcut` on toolbar/view buttons except `.defaultAction` on the one primary button and `.cancelAction` in dialogs; no per-view Esc handlers; long work is added to `busyReason()`.
- Step card order: title + summary → action row (Back left, secondary, prominent primary right) → lists. Scroll to top on step change.
- File-changing actions use `confirmationDialog` with Cancel as default; labels end with "…".
- Step state lives in the service (`ExternalDriveTransferService.step`), not view `@State`.
- UI text is English. User-visible name: **"Move to External Drive"**; the destination is named by its folder's last path component (e.g. "MEDIA").
- Organize Local Photos is renamed **"Organize Local Media"** in UI text only; Swift identifiers keep their names.
- App stays sandboxed; no new entitlements. Folders come from `NSOpenPanel` and are stored as security-scoped bookmarks.
- Never overwrite a destination file. Never trash an original before its unit verifies. A unit is either fully moved or leaves no copies.
- Verification: size; Finder Created and Modified at destination resolution (exFAT 0.01 s, APFS/HFS 1 µs, anything else 1 s); `st_flags` excluding `UF_COMPRESSED`; every source xattr identical by SHA-256 (including `com.apple.quarantine`); destination-only xattrs fail except `com.apple.provenance`, which is removed and, if removal fails, ignored and logged; content SHA-256.
- Units run sequentially. Empty source folders stay.
- `UNUserNotificationCenter` is never touched when `Bundle.main.bundleIdentifier == nil` (it crashes under `swift test`); the service takes an injected notifier.
- Logic is test-first. `swift test` passes; `pnpm build` has no compiler warnings; `pnpm lint` adds no warnings vs `main`. Use `pnpm`, never `npm`.
- Every new **app** Swift file is registered in `TeziovskyUtilities.xcodeproj/project.pbxproj` (PBXFileReference, PBXBuildFile, group, Sources phase), mirroring an existing file in the same folder. Test files are SPM-only and are not registered.
- Work on branch `feature/move-to-external-drive` in this checkout (no worktree, the owner's choice). Commit after each task, messages in the repo's `type(scope): …` style, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Source changed or deleted between Check and Move:** the unit fails with "Changed since the check. Check again (⌘R).", no copy is left behind and nothing is trashed. Test: `testSourceModifiedAfterCheckFailsWithoutTrashing` (Task 4).
2. **Destination file appears between Check and Move:** never overwritten; the unit ends as `alreadyOnDestination`. Test: `testDestinationCreatedAfterCheckIsNotOverwritten` (Task 4).
3. **Drive disconnected mid-run:** the current unit's partial is cleaned when possible, the source is untouched, and the run stops with one "MEDIA was disconnected" outcome instead of failing every remaining file. Test: `testRunStopsWhenDestinationDisappears` (Task 6).
4. **Polish/Unicode and space-containing names** (`Święta/Wigilia 2025/żółw.jpg`) move and verify like ASCII names. Test: `testUnicodePathsRoundTrip` (Task 4).
5. **Nothing ready** (empty source, everything needs organizing): the primary action becomes "Check Again", and ↩ never starts an empty run. Test: `testMoveWithNothingReadyDoesNotStartARun` (Task 6).

---

### Task 1: Branch, and scanner exposes per-file outputs

**Files:**
- Modify: `TeziovskyUtilities/Services/FileDateRepairService.swift` (`FileDateScanOutput`, `FileDateRepairScanner.scan`, `scanFile`)
- Test: `Tests/TeziovskyUtilitiesTests/FileDateRepairTests.swift`

**Interfaces:**
- Produces:
  - `FileDateScanOutput` gains `let hasUsableDate: Bool` (false when `FileDateRepairPlanner.oldestPlausibleEvidence` is nil, or on read failure) and `let outsideScannedFolderYear: String?` (set from `.outsideScannedFolder(year)`; the existing notice stays).
  - `struct FileDateScanOutputs: Sendable { let outputs: [FileDateScanOutput]; let enumerationFailures: [FileDateRepairFailure]; let livePhotoCompanions: [String: String] }`
  - `static func FileDateRepairScanner.scanOutputs(directory: URL, supportedExtensions: Set<String>, conversionConfig: LocalMediaConversionConfig = .default, progress: @escaping @Sendable (FileDateRepairProgress) async -> Void) async throws -> FileDateScanOutputs` — the existing task-group loop; `scan(...)` becomes "call `scanOutputs`, then aggregate" with unchanged results.

- [ ] **Step 1: Create the branch and commit the spec and plan**

```bash
git switch -c feature/move-to-external-drive
git add docs/superpowers
git commit -m "docs(external-drive): design and implementation plan"
```

- [ ] **Step 2: Write the failing tests** in `FileDateRepairTests.swift`, using the file's existing temp-dir/JPEG helpers:
  - `testScanOutputsReportsUndatedFileAsHavingNoUsableDate`: a JPEG without EXIF whose Finder dates are set to 1 Jan 1970 (sentinel, see `FileDateSentinelTests`) → its output has `hasUsableDate == false` and `isAlreadyOrganized == true`.
  - `testScanOutputsReportsOutsideYear`: scan `root/2025` holding a file dated 2024 → `outsideScannedFolderYear == "2024"`.
  - `testScanAggregatesTheSameAsBefore`: on a fixture with one file to organize and one already organized, `scan(...)`'s `organizationItems.count == 1` and `organizationSkippedCount == 1`.

- [ ] **Step 3: Run them** — `swift test --filter FileDateRepairTests` → the first two fail to compile (missing members).

- [ ] **Step 4: Implement** the fields and `scanOutputs` as in Interfaces. `scan` keeps `resolveCollisions` and the sorting.

- [ ] **Step 5: Run** `swift test` → all pass (whole suite, the scanner is shared).

- [ ] **Step 6: Commit** `refactor(local): expose per-file scan outputs`.

---

### Task 2: Metadata fingerprint and comparison

**Files:**
- Create: `TeziovskyUtilities/Services/FileMetadataFingerprint.swift` (+ pbxproj)
- Test: `Tests/TeziovskyUtilitiesTests/FileMetadataFingerprintTests.swift`

**Interfaces:**
- Produces:
  - `struct FileMetadataFingerprint: Equatable, Sendable { let size: UInt64; let creationDate: Date; let modificationDate: Date; let flags: UInt32; let xattrDigests: [String: Data]; let contentDigest: Data? }`
  - `static func FileMetadataFingerprint.read(_ url: URL, includeContent: Bool) throws -> FileMetadataFingerprint`: `lstat` (`st_birthtimespec`, `st_mtimespec`, `st_flags`, `st_size`), `listxattr`/`getxattr` with `XATTR_NOFOLLOW`, SHA-256 per value; content SHA-256 streamed in 4 MiB chunks via CryptoKit.
  - `struct MetadataDifference: Equatable, Sendable { let field: String; let before: String; let after: String }` (`field` e.g. `"size"`, `"created"`, `"modified"`, `"flags"`, `"xattr com.apple.metadata:_kMDItemUserTags"`, `"content"`).
  - `static func FileMetadataFingerprint.differences(source: Self, destination: Self, timeResolution: TimeInterval, ignoredDestinationOnlyXattrs: Set<String> = [provenanceXattr]) -> [MetadataDifference]`. Dates are equal when `floor(t / resolution)` is equal. Flags compare with `UF_COMPRESSED` masked out.
  - `static let provenanceXattr = "com.apple.provenance"`
  - `static func timeResolution(forVolumeOf url: URL) -> TimeInterval`: `statfs` `f_fstypename` `"exfat"` → 0.01, `"apfs"`/`"hfs"` → 0.000_001, otherwise 1.

- [ ] **Step 1: Write the failing tests** (temp dir per test):
  - `testIdenticalCopyHasNoDifferences`: write a file, add xattr `com.apple.metadata:_kMDItemUserTags` and `com.apple.quarantine`, `copyfile(..., COPYFILE_ALL)` → `differences(...) == []` with content.
  - `testModificationDateChangeIsReported`: set the copy's mtime +5 s → one difference with `field == "modified"`.
  - `testMissingSourceXattrIsReported` and `testChangedXattrValueIsReported`.
  - `testDestinationOnlyXattrIsReportedExceptProvenance`: an extra `com.example.x` → reported; an extra `com.apple.provenance` → not reported.
  - `testDatesWithinResolutionAreEqual`: two fingerprints 4 ms apart → equal at 0.01, different at 0.000_001.
  - `testContentDifferenceIsReported`: same size, one byte changed → `field == "content"`.

- [ ] **Step 2: Run** `swift test --filter FileMetadataFingerprintTests` → fails (type missing).
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run** → pass.
- [ ] **Step 5: Commit** `feat(external-drive): metadata fingerprint and comparison`.

---

### Task 3: Classifier — buckets and transfer units

**Files:**
- Create: `TeziovskyUtilities/Models/ExternalDriveModels.swift` (+ pbxproj)
- Create: `TeziovskyUtilities/Utilities/ExternalDriveClassifier.swift` (+ pbxproj)
- Test: `Tests/TeziovskyUtilitiesTests/ExternalDriveClassifierTests.swift`

**Interfaces:**
- Consumes: `FileDateScanOutputs` (Task 1).
- Produces (in `ExternalDriveModels.swift`):
  - `enum ExternalDriveBucket: Sendable, Equatable { case ready, needsOrganizing, alreadyOnDestination, notMedia, problem }`
  - `struct ExternalDriveEntry: Identifiable, Sendable, Equatable { var id: String { relativePath }; let relativePath: String; let bucket: ExternalDriveBucket; let reason: String?; let note: String?; let byteCount: Int64 }`
  - `struct ExternalDriveUnit: Identifiable, Sendable, Equatable { var id: String { relativePaths[0] }; let relativePaths: [String]; let byteCount: Int64 }` (still first, then motion).
  - `struct ExternalDriveReview: Sendable, Equatable { let entries: [ExternalDriveEntry]; let readyUnits: [ExternalDriveUnit]; let existingUnits: [ExternalDriveUnit]; func entries(in: ExternalDriveBucket) -> [ExternalDriveEntry]; var readyByteCount: Int64 }`
- Produces (in `ExternalDriveClassifier.swift`):
  - `static func ExternalDriveClassifier.classify(_ scan: FileDateScanOutputs, otherFiles: [String], byteCount: (String) -> Int64, existsOnDestination: (String) -> Bool) -> ExternalDriveReview`
  - `static func ExternalDriveClassifier.otherFiles(in root: URL, supportedExtensions: Set<String>) -> [String]`: relative paths of non-hidden regular files that are not supported media; skips hidden entries, packages and symlinks like the scanner.

Per-file rule, first match wins (reason strings are exact copy):
1. `failure` → `.needsOrganizing`, reason = `failure.message`
2. `conversionCandidate` → `"Conversion pending: \(kind.title)"`
3. `repairItem` → `"Dates don't match"`
4. `organizationCandidate` → `"Wrong folder (→ \(destination directory relative path))"`
5. `outsideScannedFolderYear` → `"Belongs in a “\(year)” folder outside the source folder"`
6. `!hasUsableDate` → `"No usable date"`
7. otherwise `.ready`; any remaining `notices` go into `note` (e.g. an unsupported-conversion message).

Units: Live Photo motion paths join their still (`livePhotoCompanions`). If any member is not ready, the ready members become `.needsOrganizing` with reason `"Its Live Photo pair “\(name)” needs organizing"`. For a ready unit: all members exist on the destination → all `.alreadyOnDestination` (goes into `existingUnits`); some exist → all `.problem` with reason `"Part of this Live Photo is already on the drive"`; none → `.ready` (`readyUnits`). `enumerationFailures` → `.problem` with their message. `otherFiles` → `.notMedia`. Entries sorted with `localizedStandardCompare`.

- [ ] **Step 1: Write the failing tests** building `FileDateScanOutput` values directly (no disk):
  - one test per rule 1–7 asserting `bucket` and exact `reason`;
  - `testUnsupportedConversionNoticeDoesNotBlock` → `.ready` with that `note`;
  - `testLivePhotoPairMovesAsOneUnit`, `testLivePhotoWithNonReadyMemberHoldsBothBack`;
  - `testExistingDestinationGoesToAlreadyOnDestination`, `testPartlyExistingLivePhotoIsAProblem`;
  - `testOtherFilesAreNotMedia`, `testEnumerationFailureIsAProblem`;
  - `testOtherFilesSkipsHiddenAndSupported` (temp dir: `.DS_Store`, `a.jpg`, `notes.txt`, `b.jpg.xmp` → `["b.jpg.xmp", "notes.txt"]` with `jpg` supported).
- [ ] **Step 2: Run** `swift test --filter ExternalDriveClassifierTests` → fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → pass.
- [ ] **Step 5: Commit** `feat(external-drive): classify scan results into buckets and units`.

---

### Task 4: Mover engine

**Files:**
- Create: `TeziovskyUtilities/Services/ExternalDriveMover.swift` (+ pbxproj)
- Test: `Tests/TeziovskyUtilitiesTests/ExternalDriveMoverTests.swift`

**Interfaces:**
- Consumes: `FileMetadataFingerprint` (Task 2), `ExternalDriveUnit` (Task 3), `FileDatePreservation.applyFileDates(to:created:modified:)`.
- Produces:
  - `protocol ExternalDriveCopying: Sendable { func copy(from: URL, to: URL, progress: (Int64) -> Bool) throws }`. The closure gets bytes copied so far for this file and returns `false` to stop. Default `CopyfileCopier` uses `copyfile(src, dst, state, COPYFILE_ALL | COPYFILE_EXCL)` with `COPYFILE_STATE_STATUS_CB`/`_CTX`, reports on `COPYFILE_PROGRESS`, and returns `COPYFILE_QUIT` when the closure says stop (then throws `CancellationError`).
  - `enum ExternalDriveUnitOutcome: Sendable, Equatable { case moved, alreadyOnDestination, cancelled, failed(String), verifiedButNotTrashed(String), trashedOriginal, differentFileOnDestination(String), destinationUnavailable }`
  - `struct ExternalDriveMover: Sendable { init(copier: ExternalDriveCopying = CopyfileCopier(), trash: @Sendable (URL) throws -> Void = defaultTrash, log: @Sendable (String) -> Void = { _ in }) }`
  - `func move(_ unit: ExternalDriveUnit, sourceRoot: URL, destinationRoot: URL, checkedFingerprints: [String: FileMetadataFingerprint], progress: @Sendable (Int64) -> Bool) -> ExternalDriveUnitOutcome`. `progress` gets the unit's cumulative bytes and returns `false` to cancel.
  - `func trashOriginalIfIdentical(_ unit: ExternalDriveUnit, sourceRoot: URL, destinationRoot: URL) -> ExternalDriveUnitOutcome` (`.trashedOriginal` or `.differentFileOnDestination(summary)` / `.failed`)

`checkedFingerprints` are the source fingerprints without content, taken at Check time. The service records them (Task 6).

`move` algorithm per unit:
1. For each member: the source still matches its checked fingerprint (size, dates, flags, xattrs) or the unit fails with `"Changed since the check. Check again (⌘R)."`. If the destination exists → `.alreadyOnDestination` for the unit, nothing copied.
2. If the destination's parent is missing and the destination root itself is unreachable → `.destinationUnavailable`. Otherwise create the parent folders.
3. For each member: remove a stale `.<name>.partial` in the destination folder; copy to it; `rename` partial → final with `renamex_np(RENAME_EXCL)` (if it now exists → roll back the unit, `.alreadyOnDestination`). Remove `com.apple.provenance` if it is on the destination only; if removal fails, log it. Reapply the source's created/modified dates.
4. Verify each member (`includeContent: true` on both sides, resolution from `timeResolution(forVolumeOf: destinationRoot)`). Any difference → roll back and `.failed("Copied, but \(field) differs: \(before) → \(after)")`. All differences are logged.
5. Trash every source member. If one fails → `.verifiedButNotTrashed("Copied and verified, but the original couldn't be moved to the Trash: …")` (copies are kept: they are verified).
6. Rollback = remove only the destination files and partials this call created. A cancel at any point before step 5 → rollback, `.cancelled`.

- [ ] **Step 1: Write the failing tests** (temp `src`/`dst` roots, a `FakeTrash` that moves into a temp "Trash" folder and records URLs, and a `FailingCopier` / `StoppingCopier` where needed):
  - `testMovesFileKeepingDatesFlagsXattrsAndTrashesOriginal`: file with tags xattr, `UF_HIDDEN` off/on, created 2019-03-07, modified 2019-03-08 → `.moved`; destination fingerprint equals source; the source is in FakeTrash.
  - `testDestinationExistsIsNeverOverwritten` → `.alreadyOnDestination`, destination bytes unchanged, nothing trashed.
  - `testDestinationCreatedAfterCheckIsNotOverwritten` (Review Focus 2): the destination is created by the copier stub just before rename → `.alreadyOnDestination`, the pre-existing file is unchanged, no partial left.
  - `testSourceModifiedAfterCheckFailsWithoutTrashing` (Review Focus 1): mtime changed after fingerprinting → `.failed` containing "Changed since the check"; no destination file.
  - `testVerificationFailureRollsBackTheWholeUnit`: a two-member unit, where a copier stub corrupts member 2 → `.failed`; neither destination file exists; both sources are in place.
  - `testCancelMidCopyLeavesNoPartialAndKeepsSource`: `progress` returns false → `.cancelled`; no `.partial`; the source is in place.
  - `testStalePartialIsReplaced`.
  - `testTrashFailureKeepsVerifiedCopy` → `.verifiedButNotTrashed`.
  - `testTrashOriginalIfIdenticalTrashesOnlyWhenIdentical` (identical → trashed; different content → `.differentFileOnDestination`, source kept).
  - `testUnicodePathsRoundTrip` (Review Focus 4): `Święta/Wigilia 2025/żółw.jpg` → `.moved`.
- [ ] **Step 2: Run** `swift test --filter ExternalDriveMoverTests` → fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → pass. Then `swift test` → pass.
- [ ] **Step 5: Commit** `feat(external-drive): verified move engine with rollback`.

---

### Task 5: Folder settings, preflight and log

**Files:**
- Modify: `TeziovskyUtilities/Utilities/AppSettings.swift`
- Create: `TeziovskyUtilities/Utilities/ExternalDriveLocations.swift` (+ pbxproj)
- Test: `Tests/TeziovskyUtilitiesTests/ExternalDriveLocationsTests.swift`

**Interfaces:**
- Produces:
  - `enum ExternalDriveFolderRole: String, Sendable { case source, destination }`, with `suggestedPath`: `~/Pictures/_To_Homelab_Media` (the real home from `getpwuid(getuid())`, not the sandbox container's home) / `/Volumes/MEDIA`.
  - `static func AppSettings.storeExternalDriveFolder(_ url: URL, role: ExternalDriveFolderRole)`: security-scoped bookmark under keys `externalDriveSourceBookmark` / `externalDriveDestinationBookmark`, plus the path under `…Path`.
  - `enum ExternalDriveFolderResolution: Equatable { case notChosen, unavailable(path: String), resolved(URL) }` and `static func AppSettings.resolveExternalDriveFolder(_ role:) -> ExternalDriveFolderResolution` (re-stores a stale bookmark).
  - `enum ExternalDrivePreflight: Equatable { case ready(freeBytes: Int64), notConnected(String), notChosen }` and `static func ExternalDriveLocations.preflight(destination: ExternalDriveFolderResolution, bootVolume: URL = URL(fileURLWithPath: "/")) -> ExternalDrivePreflight`. `.resolved` but missing, or the same `volumeIdentifier` as `bootVolume` → `.notConnected("\(name) isn't connected. Connect the drive and press Check Again (⌘R).")`. Free bytes from `volumeAvailableCapacityForImportantUsage` (falls back to `volumeAvailableCapacity`).
  - `struct ExternalDriveLog: Sendable { static let shared; let fileURL: URL /* Library/Logs/external-drive.log in the app's (container) library */; func append(_ line: String) }`: timestamped lines, creates the folder, never throws.

- [ ] **Step 1: Write the failing tests**:
  - `testPreflightOnBootVolumeIsNotConnected`: a temp dir as destination → `.notConnected` containing "isn't connected".
  - `testPreflightWithDifferentVolumeIsReady`: pass `bootVolume:` pointing at a URL whose volume differs. Use a skip guard `XCTSkipUnless` when the machine has no second volume. Search `/Volumes/*` for a mounted volume other than `/`.
  - `testPreflightMissingFolderIsNotConnected`, `testPreflightNotChosen`.
  - `testStoreAndResolveRoundTrip` (temp dir, a test `UserDefaults` suite if `AppSettings` allows; otherwise clean up the keys in `tearDown`).
  - `testLogAppendsLines` (inject a temp `fileURL`).
- [ ] **Step 2: Run** → fails. **Step 3: Implement.** **Step 4: Run** → pass.
- [ ] **Step 5: Commit** `feat(external-drive): folder bookmarks, preflight and log`.

---

### Task 6: Transfer service

**Files:**
- Create: `TeziovskyUtilities/Services/ExternalDriveTransferService.swift` (+ pbxproj)
- Test: `Tests/TeziovskyUtilitiesTests/ExternalDriveTransferServiceTests.swift`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
  - `enum ExternalDriveStep: Equatable { case review, moving, summary }`
  - `struct ExternalDriveProgress: Equatable { var unitIndex = 0; var unitCount = 0; var bytesDone: Int64 = 0; var bytesTotal: Int64 = 0; var currentPath = ""; var currentFileBytesDone: Int64 = 0; var currentFileBytesTotal: Int64 = 0; var startedAt: Date?; var estimatedRemaining: TimeInterval? }`
  - `struct ExternalDriveRunResult: Identifiable, Equatable { var id: String { relativePath }; let relativePath: String; let outcome: ExternalDriveUnitOutcome }`
  - `struct ExternalDriveRunSummary: Equatable { let kind: Kind /* .move, .trashExisting */; let attemptedUnits: Int; let succeededUnits: Int; let results: [ExternalDriveRunResult]; let wasCancelled: Bool; let stoppedReason: String? }`
  - `@MainActor final class ExternalDriveTransferService: ObservableObject` with `init(mover: ExternalDriveMover = .init(...log: ExternalDriveLog.shared.append), preflight: @escaping (ExternalDriveFolderResolution) -> ExternalDrivePreflight = { ExternalDriveLocations.preflight(destination: $0) }, folders: @escaping (ExternalDriveFolderRole) -> ExternalDriveFolderResolution = AppSettings.resolveExternalDriveFolder, notify: @escaping (String, String) -> Void = ExternalDriveNotifier.post)`
    - `@Published private(set)`: `step`, `sourceURL: URL?`, `destination: ExternalDriveFolderResolution`, `preflightState: ExternalDrivePreflight`, `review: ExternalDriveReview?`, `isChecking`, `checkProgress: FileDateRepairProgress`, `isTransferring`, `progress: ExternalDriveProgress`, `summary: ExternalDriveRunSummary?`
    - `var isRunning: Bool` (checking or transferring); `var activityTitle: String?` ("Checking the source folder" / "Moving files to \(name)" / "Moving originals already on \(name) to the Trash")
    - `var destinationName: String` (last path component, `"the drive"` when unknown)
    - `func check()` (resolve folders, preflight, `scanOutputs` + `otherFiles` + `classify`, record source fingerprints without content for ready units, `step = .review`)
    - `func useSource(_ url: URL)` (session override from ⌘O, then `check()`)
    - `func moveReady()` (guard: not running, `review.readyUnits` not empty, `readyByteCount <= freeBytes`; acquire `SleepAssertion`; run units sequentially off-main; after a unit fails, re-run `preflight`; if not `.ready` → stop with `stoppedReason = "\(name) was disconnected. Connect it and press Check Again (⌘R)."`; `step = .moving` → `.summary`; one `notify(title, body)` at the end: "Moved 238 of 240 to MEDIA" / "— 2 need attention")
    - `func trashExistingOriginals()` (same run shape over `review.existingUnits` using `trashOriginalIfIdentical`)
    - `func cancel()`; `func goBack() -> Bool` (summary → review + `check()`, returns true; review → false so the caller goes home); `func reset()`
  - `enum ExternalDriveNotifier { static func post(title: String, body: String) }`: no-op without a bundle identifier; otherwise request `.alert`/`.sound` authorization once, then add the request.

- [ ] **Step 1: Write the failing tests** (temp source/destination; `preflight` stub returns `.ready(freeBytes: .max)`; `folders` stub returns the temp URLs; `notify` spy; FakeTrash):
  - `testCheckBucketsAndMoveMovesOnlyReadyFiles`: source with `2024/a.jpg` (EXIF 2024, consistent Finder dates) and `Psy/b.jpg` (no year folder) → after `check()` one ready and one needs-organizing entry; after `moveReady()` completes (await with an expectation on `$step == .summary`) `2024/a.jpg` is on the destination, `Psy/b.jpg` is still in the source; `summary.succeededUnits == 1`; the notify spy was called once.
  - `testNotConnectedBlocksCheck`: `preflight` → `.notConnected` → `review == nil`, `preflightState` is `.notConnected`.
  - `testMoveWithNothingReadyDoesNotStartARun` (Review Focus 5).
  - `testNotEnoughSpaceDoesNotStart`: `freeBytes: 1` → no run, `isTransferring == false`.
  - `testRunStopsWhenDestinationDisappears` (Review Focus 3): two ready units; the copier stub deletes the destination root during unit 1 and the `preflight` stub flips to `.notConnected` → `summary.stoppedReason` contains "was disconnected"; unit 2 is not attempted; both sources are in place.
  - `testCancelStopsAfterCurrentUnit`.
  - `testTrashExistingOriginalsTrashesIdenticalOnly`.
  - `testGoBackFromSummaryRechecks`.
- [ ] **Step 2: Run** → fails. **Step 3: Implement.** **Step 4: Run** → pass; `swift test` → pass.
- [ ] **Step 5: Commit** `feat(external-drive): transfer service with progress and summary`.

---

### Task 7: Route, commands, menu, home card and rename

**Files:**
- Modify: `TeziovskyUtilities/Models/AppRoute.swift` (`case externalDrive`)
- Modify: `TeziovskyUtilities/App/AppState.swift` (`let externalDriveService = ExternalDriveTransferService()`, `enterExternalDriveMode()` → route + `externalDriveService.check()`, `openSourceInLocalMedia()` → `route = .localPhotos` + `localPhotosService.scan(directory: externalDriveService.sourceURL!)`)
- Modify: `TeziovskyUtilities/App/AppCommands.swift` (every `switch route`)
- Modify: `TeziovskyUtilities/App/TeziovskyUtilitiesApp.swift` (titles only if needed)
- Modify: `TeziovskyUtilities/Utilities/AppBranding.swift`, `TeziovskyUtilities/Views/HomeView.swift`, `TeziovskyUtilities/Views/RootView.swift` (temporary placeholder view until Task 8, or land with Task 8 if preferred)
- Test: `Tests/TeziovskyUtilitiesTests/AppCommandTests.swift`

**Interfaces:**
- `AppBranding.externalDriveModeTitle = "Move to External Drive"`, `externalDriveModeSubtitle = "Check organized photos and videos, then move them to your archive drive with verified metadata."`, `externalDriveModeIcon = "externaldrive.badge.checkmark"`. `localPhotosModeTitle = "Organize Local Media"`.
- Decisions for `.externalDrive` (exact copy):
  - busy (`externalDriveService.activityTitle`) → `"\(activity) is in progress. Use Cancel, or wait until it finishes."` for home/back/escape/openFolder/refresh.
  - back/escape when idle → `.perform` (summary → review; review → home).
  - openFolder → `.perform` (panel "Choose the folder to move from", prompt "Check").
  - refresh: no source → `"Choose the source folder first (⌘O)."`, else `.perform`.
  - reveal: no source → same notice; else reveal the source.
  - `openFolderTitle` → `"Choose Source Folder…"`; `refreshTitle` → `"Check Again"`.
  - undo and Photos-only commands keep their existing banners (no change needed).

- [ ] **Step 1: Write the failing tests** in `AppCommandTests.swift`: `testExternalDriveCommandsExplainThemselvesWhileMoving` (set the service to a running state via a test-only seam, e.g. `#if DEBUG func _setTransferringForTesting(_:)`; assert the banner contains "Use Cancel" for home/back/openFolder/refresh), `testExternalDriveRefreshAndRevealNeedASource`, `testExternalDriveOpenFolderPerforms`, `testHomeWorksFromEveryModeWhenIdle` extended with `.externalDrive`, `testLocalMediaTitleIsRenamed` (`AppBranding.localPhotosModeTitle == "Organize Local Media"`).
- [ ] **Step 2: Run** → fails. **Step 3: Implement**, including the home card (fourth `HomeCardKind`) and a `grep -rn "Local Photos" TeziovskyUtilities` sweep of user-facing strings.
- [ ] **Step 4: Run** `swift test` → pass.
- [ ] **Step 5: Commit** `feat(external-drive): route, commands and home card; rename Organize Local Media`.

---

### Task 8: Views and Settings

**Files:**
- Create: `TeziovskyUtilities/Views/ExternalDriveModeView.swift` (+ pbxproj)
- Modify: `TeziovskyUtilities/Views/RootView.swift`, `TeziovskyUtilities/Views/SettingsView.swift` (new tab "External Drive" with two rows: path + "Choose…", calling `AppSettings.storeExternalDriveFolder`; the panel opens at `suggestedPath`)

UI (exact copy where quoted), all inside `GlassCard`, actions above lists:
- **Review**
  - Not chosen: buttons "Choose Source Folder…" / "Choose Drive Folder…".
  - Not connected: the preflight message and "Check Again" (primary).
  - Checking: progress bar + "Checked 120 of 245 files" + Cancel.
  - Otherwise: the summary line `"\(ready) ready · \(needs) need organizing · \(existing) already on \(name) · \(other) not media"` (zero parts omitted), then `"\(size) to move · \(free) free on \(name)"`.
  - Action row: Back · Reveal · Check Again · secondary "Trash \(n) Originals Already on \(name)…" (only if n > 0, confirm) · secondary "Open in Organize Local Media" (only if needs > 0) · primary "Move \(n) Files to \(name)…" (`.defaultAction`, `.help("Move the ready files (↩)")`, confirm "Move \(n) files to \(name)? Originals go to the Trash after each file is verified.") or "Check Again" when nothing is ready.
  - Collapsible sections per bucket, rows with path, reason/note, size and a Reveal button.
- **Moving**: overall `ProgressView(value: bytesDone, total: bytesTotal)`, `"File \(i) of \(n) · \(done) of \(total) · about \(eta) left"`, current file name with its own bar, Cancel.
- **Summary**: `"Moved \(ok) of \(n) to \(name)"` (or "Moved … originals to the Trash"), `stoppedReason` / "Cancelled" line, a list of every non-success result with reason and Reveal, the review's held-back buckets, "Show Log" (reveals `ExternalDriveLog.shared.fileURL`), primary "Done" (→ Home).
- Scroll to top on `step` change (`ScrollViewReader` + `.id` on header).

- [ ] **Step 1: Build** `pnpm build` → no warnings.
- [ ] **Step 2: Run the app** (`pnpm run run`) with a scratch source and a scratch folder on a second volume. Check each state visually (light/dark), and that ↩, ⌘R, ⇧⌘R, ⌘O, Esc and ⇧⌘H behave per Task 7.
- [ ] **Step 3: Commit** `feat(external-drive): workflow views and settings`.

---

### Task 9: Docs and final verification

**Files:**
- Modify: `README.md` (feature section "Move to External Drive"; the shortcut table gets a column; rename to Organize Local Media), `AGENTS.md` (the three workflows → four, renamed).

- [ ] **Step 1: Update docs.**
- [ ] **Step 2: Verify**: `swift test` (all pass), `pnpm build` (no warnings), `pnpm lint` (compare the warning count with `git stash; pnpm lint` on `main`: no new ones).
- [ ] **Step 3: Real-drive check (ask the owner first; it writes to MEDIA):** move 3 sample files (JPEG with Finder tag + comment, HEIC Live Photo pair, MOV) from a scratch source folder to a scratch folder `MEDIA/_test_external_drive/`. Compare with `stat -f '%z %m %B %f'` and `xattr -l` before/after, then delete the scratch folder.
- [ ] **Step 4: Commit** `docs: document Move to External Drive`.
