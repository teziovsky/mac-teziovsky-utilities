# Replace Converted Originals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In Organize Local Media's Convert step, list every original with a verified converted twin and let the owner replace the originals in one confirmed action. The originals go to the Trash and each copy takes over the original's name.

**Architecture:** The scanner finds pairs from the existing conversion marker. A pure engine (`LocalMediaReplacer`) does verify → trash → no-overwrite rename for each pair. `LocalPhotosService` runs it with progress, cancel, rescan and a summary. A new section in the Convert card reuses `LocalMediaTreeList`.

**Tech Stack:** Swift 5.9, SwiftUI, AVFoundation, ImageIO, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-26-replace-converted-originals-design.md`

## Global Constraints

- `AGENTS.md` applies in full:
  - Long work goes into `busyReason()` via `activityTitle`.
  - Actions that change files use a `confirmationDialog` with Cancel as the default, and the button label ends with "…".
  - The action row sits above its list. UI text is English. Work is test-first.
- Work on `main` only. End commits with:
  - `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01Y29YBRturbhCdDn9NY6E7i`
- Never install, launch, quit or kill the app. Never touch `/Volumes/MEDIA` or the owner's Pictures folder.
- `swift test` passes. `pnpm build` has no compiler warnings. `pnpm lint` stays at or below the baseline, with no new violations in touched files. Use pnpm, never npm.
- Register new app files in the pbxproj (4 entries). Use the Edit tool, not `sed -i`, and leave `git status` clean.
- Originals go to the Trash and are never removed permanently. The rename never overwrites a file.
- Exact copy:
  - Section title: "Converted copies ready to replace originals (N)"
  - Button: "Replace N Originals…"
  - Partial result: "Original trashed; copy kept as X because Y exists"

## Review Focus

1. **The marker points to a missing file:** no pair is listed. Test: `testMarkerWithoutTwinIsNotAPair` (Task 1).
2. **The target name is taken by an unrelated file:** the original is trashed, the copy keeps its name, and the outcome uses the partial-result message. Test: `testRenameNeverOverwrites` (Task 2).
3. **The copy fails verification** (corrupt or truncated video): the original stays, nothing is renamed, and the outcome is failed. Test: `testFailedVerificationKeepsOriginal` (Task 2).
4. **The original was already trashed by hand:** no pair is listed. If it vanishes between scan and apply, the outcome is failed with "Original no longer exists". Test: `testOriginalGoneAtApplyFails` (Task 2).
5. **Commands while running:** Esc, Back and Home show the busy banner. Test: an `AppCommandTests` case using the existing local-photos busy seam pattern (Task 3).

---

### Task 1: Detect replaceable pairs during the scan

**Files:** `TeziovskyUtilities/Services/LocalMediaConversion.swift` (marker read helper), `TeziovskyUtilities/Services/FileDateRepairService.swift` (scanner output + result + `LocalPhotosService.replaceablePairs`), a new `TeziovskyUtilities/Models/LocalMediaReplacement.swift` (+ pbxproj), and the test file `Tests/TeziovskyUtilitiesTests/LocalMediaReplacementTests.swift`.

**Interfaces (produces):**
- `struct LocalMediaReplaceablePair: Identifiable, Sendable, Equatable { var id: String { originalRelativePath }; let originalURL: URL; let originalRelativePath: String; let copyURL: URL; let copyRelativePath: String; let finalName: String; let isVideo: Bool }`. `finalName` is the original's base name plus the copy's extension.
- `static func LocalMediaConverter.convertedTwinName(of url: URL) -> String?` reads the marker value as UTF-8.
- `LocalMediaStep.replacement` (new case).
- `FileDateScanResult.replaceablePairs` and `LocalPhotosService.replaceablePairs` are `@Published private(set)` and sorted.

**Steps:**
- [ ] Write the failing tests:
  - `testMarkedOriginalWithTwinIsAPair`: `Mia_32.mp4` with marker "Mia_32-converted.mp4" plus that file present → a pair with `finalName == "Mia_32.mp4"`.
  - `testHEICPairKeepsJPGName`: `finalName == "IMG.jpg"`.
  - `testMarkerWithoutTwinIsNotAPair`.
  - `testUnmarkedFilesAreNotPairs`.
  - Use files the scanner enumerates (supported extensions).
- [ ] Run the tests and confirm they fail. Implement. Run `swift test`. Commit `feat(local): detect originals ready to be replaced by their converted copies`.

### Task 2: Replacement engine

**Files:** a new `TeziovskyUtilities/Services/LocalMediaReplacer.swift` (+ pbxproj) and the test file `LocalMediaReplacementTests.swift`.

**Interfaces (produces):**
- `enum LocalMediaReplacementOutcome: Equatable, Sendable { case replaced; case replacedKeptCopyName(String); case failed(String) }`
- `struct LocalMediaReplacer { init(trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }, verify: @Sendable (LocalMediaReplaceablePair) async throws -> Void = LocalMediaReplacer.defaultVerify); func replace(_ pair: LocalMediaReplaceablePair) async -> LocalMediaReplacementOutcome }`
- `defaultVerify`:
  - Images: CGImageSource decodes the copy, and its pixel width and height equal the original's.
  - Videos: reuse the conversion's verification (playable, a frame decodes, duration within the existing tolerance). Reuse the existing helpers rather than duplicating them.

**Order:** check that both files exist → verify → trash the original → if `finalName` ≠ the copy's name, rename with `renamex_np(RENAME_EXCL)`. On EEXIST, return `.replacedKeptCopyName(message)` using the exact partial-result copy. Trash failure → `.failed`, and nothing is renamed.

**Steps:**
- [ ] Write the failing tests with a fake trash and an injected verify:
  - happy path: the video is renamed to the original name and the original is in the fake trash;
  - HEIC/JPG: no rename;
  - `testRenameNeverOverwrites`;
  - `testFailedVerificationKeepsOriginal`;
  - `testOriginalGoneAtApplyFails`;
  - trash failure → `.failed`, and the copy keeps its name;
  - real `defaultVerify` on an image pair with the right size, and with a mismatched size.
- [ ] Run the tests and confirm they fail. Implement. Run `swift test`. Commit `feat(local): replace originals with verified converted copies`.

### Task 3: Service run + Convert step UI

**Files:** `FileDateRepairService.swift` (or a new extension file if it's over the size limit) and `TeziovskyUtilities/Views/` (a new `LocalMediaReplacementSection.swift` + pbxproj, plus its call in `FileDateRepairModeView.swift`).

**Interfaces:**
- `LocalPhotosService.replaceOriginals()`:
  - runs the included pairs (`excludedPaths[.replacement]`) sequentially;
  - sets `isReplacing`, with progress in `replacementProgress`;
  - can be cancelled with `cancel()`;
  - when finished, sets `replacementSummary` and rescans the folder, as after a conversion.
- `isRunning` includes `isReplacing`, and `activityTitle` returns "Replacing originals" while it runs.

**UI:** the section titled "Converted copies ready to replace originals (N)" sits in the Convert card after the conversion list.
- Its action row comes first: "Replace N Originals…" opens a `confirmationDialog` whose message says the originals go to the Trash, with Cancel as the default action.
- Then the tree list (`LocalMediaTreeList` with step `.replacement`). Rows show "original → copy (will be named X)".
- While running, it shows progress and a Cancel button.
- After the run, a summary line plus a list of the non-replaced items with their reasons.

**Steps:**
- [ ] Write the failing tests:
  - a service test on a temp folder with an injected replacer: `replaceOriginals` replaces the included pairs, skips excluded ones, and rescans;
  - the AppCommand busy-banner test (Review Focus 5).
- [ ] Implement. Run `swift test` and `pnpm build`.
- [ ] Update the README section on Organize Local Media's conversion.
- [ ] Commit `feat(local): replace converted originals from the Convert step`.
