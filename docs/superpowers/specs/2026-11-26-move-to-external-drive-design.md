# Move to External Drive — design

Date: 2026-11-26
Status: draft, awaiting owner approval (builder check done)

## Intent

Today a Hazel rule watches `~/Pictures/_To_Homelab_Media`. For every photo or video that lands
there it runs a bash script that moves the file through Finder to `/Volumes/MEDIA` under the
same relative path, checks that size, dates, flags and extended attributes did not change, and
then Hazel moves the original to the Trash.

The owner wants this in Teziovsky Utilities because the Hazel flow:

1. **starts on its own**, also when they don't want a move to happen right now;
2. **floods them with notifications**, so when some files fail they can't find which ones;
3. **shows no progress**: they can't tell how much is done and how much is left.

So the goal is **control and transparency**, not speed: nothing moves until they press a
button, a progress view shows where the batch is, and one summary at the end lists every file
that did not move, with the reason.

The owner's workflow is usually: export albums from iCloud Photos into
`_To_Homelab_Media` → clean them up with Organize Local Photos (convert, repair dates, sort into
`YYYY/_Filmy`) → move to `MEDIA`. Sometimes files that did not come from iCloud are dropped into
the same folder too.

## Goals

- A new, separate workflow on the home screen ("Move to External Drive"), started manually.
- **Every file is accounted for.** Each non-hidden file in the source folder ends up in exactly
  one bucket in the review and summary: moved, needs organizing, already on the drive, not
  media, or failed (with reason).
- **Progress:** overall progress in bytes and files, current file, per-file progress for large
  videos, ETA.
- **Metadata is never changed by the move.** Size, Finder Created, Finder Modified, file flags
  and every extended attribute (tags, Finder info, comments, `kMDItemWhereFroms`, …) must be
  identical on the destination; the original goes to the Trash only after that is verified.
- **Structure check before moving.** Only files that Organize Local Photos would leave untouched
  are moved: in the right `…/YYYY/` (videos `…/YYYY/_Filmy/`, Live Photo `.MOV` next to its
  still), with consistent dates and no pending conversion. The rest stay in place and are listed
  as "need organizing" with a way to jump to Organize Local Photos.
- Rename the **Organize Local Photos** workflow to **Organize Local Media** in the UI, because it
  handles videos as well.

## Non-goals

- Watching the folder or running automatically (that is exactly what the owner wants gone).
- Copying to a network share or several destinations; one destination root.
- Undo of a completed move (originals sit in the Trash; that is the safety net, as with Hazel).
- Renaming Swift identifiers (`LocalPhotosService`, `.localPhotos`, …) — UI text only.
- Removing the Hazel rule; the owner disables it themselves once this works.

## Anti-goals (failure even if it "works")

- Any change to a file's dates, flags, xattrs or bytes on the destination.
- An original trashed without a verified copy on the destination.
- A file silently skipped, or a failure only visible in a notification or a log.
- Something moved to `MEDIA` that Organize Local Media would still want to fix.
- A half-copied file on `MEDIA` that looks like a finished one.
- Overwriting a file that already exists on `MEDIA`.

## Facts that constrain the build

- `/Volumes/MEDIA` is currently a **local exFAT** volume (an external SSD), not a network share as
  the old script's comments say. exFAT has no native xattrs: macOS stores them in AppleDouble
  `._name` files next to the file. exFAT stores creation and modification times (10 ms
  resolution). File flags may not all be representable — see verification below.
- The destination tree uses the same layout the organizer produces: category folders
  (`Wakacje/USA`, `Imprezy/Warszawa`, `_kuba`) with year folders as leaves
  (`_kuba/2019/`, `Fotografia/2023/IMG_7633.JPG`).
- `FileDateRepairScanner.scan` (`Services/FileDateRepairService.swift`) already yields, per file,
  a `FileDateScanOutput` with `conversionCandidate`, `repairItem`, `organizationCandidate`,
  `isAlreadyOrganized`, `notices` and `failure`. It only enumerates `supportedExtensions` and
  aggregates the outputs into `FileDateScanResult`.
- Existing helpers: `FileDatePreservation.applyFileDates`, `SleepAssertion`, the `.partial`
  pattern in `HandBrakeCompressor`, `DroneFinalizer`'s injected `trash` closure,
  `OrganizeProgressView`, `GlassCard`, `pillActionButton(prominent:)`, `DroneStepContainer` /
  `DroneWorkflowStepContainer`.
- The project conventions in `AGENTS.md` apply in full (commands via `appState.run`,
  `decision(for:)` banners, `busyReason()`, buttons above content, `.defaultAction` primary
  button, confirmation dialogs with Cancel as default, step state in a service, test-first,
  README shortcut table, pbxproj registration).

## Approaches considered

- **A. Last step of Organize Local Photos.** One scan, structure check for free; but every send
  walks through the earlier steps.
- **B. Separate workflow on the home screen** — **chosen by the owner.** Its own scan and
  read-only structure check; misplaced files are listed with "Open in Organize Local Media".
  Fast path when everything is already organized.
- **C. A + home-screen shortcut** that opens Organize Local Media at the first step with work.

B was picked. To avoid two workflows judging the same file differently, B **reuses the scanner
and planner of Organize Local Media** instead of having its own rules.

## Design

### Settings (Settings → External Drive, new section)

- **Source folder** — default `~/Pictures/_To_Homelab_Media`.
- **Destination folder** — suggested `/Volumes/MEDIA`.
- The app is sandboxed (`files.user-selected.read-write`, `bookmarks.app-scope`), so both
  folders are **chosen once in an open panel** (pre-pointed at the suggested path) and stored as
  security-scoped bookmarks, like `ExportDirectoryAccess` does for the export folder. No new
  entitlements, the sandbox stays. A destination bookmark that can't be resolved, or resolves to
  a folder that isn't a mounted volume, means "not connected"; a stale bookmark is refreshed
  when the volume is back. If resolution keeps failing, the step offers "Choose MEDIA Again…".
  *(my call)*
- Display name for the destination is the last path component ("MEDIA"), used in UI text.

### Steps (state in a new `ExternalDriveTransferService`, not in view `@State`)

1. **Check** — runs on entering the workflow and on ⌘R.
   - Preflight: destination exists **and is a mounted volume other than the boot volume**
     (compare `volumeIdentifier` of the destination with `/`; an empty `/Volumes/MEDIA` folder
     must not count). Not mounted → the step says "MEDIA isn't connected. Connect the drive and
     press Refresh (⌘R)." and nothing else runs.
   - Scan the source with `FileDateRepairScanner.scan` using the current Local Media settings
     (extensions, conversion config). Also enumerate **all** non-hidden regular files so
     non-media files can be listed (hidden files, packages and symlinks skipped as the scanner
     already does).
   - Progress view while scanning, Cancel available.
2. **Review** — action row above the lists: Back, Refresh, Reveal, and primary
   **"Move N Files to MEDIA…"** (`.defaultAction`, confirmation dialog, Cancel default).
   Summary line: "240 ready · 5 need organizing · 3 already on MEDIA · 1 not media", plus total
   size of ready files and free space on the destination. If ready bytes exceed free space, the
   primary button shows a notice instead of starting.
   Buckets, each a collapsible list with Reveal in Finder per row:
   - **Ready** — no conversion candidate, no repair item, already organized, no failure, has a
     usable date, sits under a year folder, and the destination path does not exist.
     A conversion notice "can't be converted" (`.unsupported`) does **not** block: Organize
     Local Media can't fix it either; the row shows it as information. *(my call)*
   - **Need organizing** — the reason per file: "Wrong folder (→ 2024/_Filmy)",
     "Dates don't match", "HEIC → JPEG pending", "Year folder outside the source",
     "No usable date" (the planner returns `.unchanged` for undated files, so this rule is ours,
     not the planner's — *my call*), scan failure.
     Button **"Open in Organize Local Media"** routes there with the source folder scanned.
   - **Already on MEDIA** — destination path exists; never overwritten. Secondary action
     **"Trash N Originals Already on MEDIA…"** (confirmation dialog, Cancel default): for each
     file it runs the same verification as a move (size, dates, flags, xattrs per the rules
     below, content SHA-256) between the source and the existing destination file and trashes
     the source only when it matches; mismatches stay and are listed as "Different file with the
     same name on MEDIA". Covers files Hazel copied but never trashed. Progress and Cancel as in
     Moving. *(owner's choice)*
   - **Not media** — non-hidden files that are not supported media (including any `.xmp`); left in
     place.
3. **Moving** — progress view: overall bar in bytes, "File 37 of 240", current file name and its
   own bar, ETA. Cancel. Mac kept awake (`SleepAssertion`).
4. **Summary** — "Moved 238 of 240" and a list of every file that did not move in this run,
   with reason and Reveal; the not-moved buckets from Review are shown again. Primary action
   "Done" returns to Home; Refresh rechecks.

### Grouping

A **transfer unit** is moved and verified as a whole; nothing in it is trashed until every
member is verified on the destination:

- a single media file, or
- a Live Photo still plus its motion `.MOV` (use `LocalMediaOrganizationPlanner.livePhotoCompanions`).

A unit is Ready only if every member is Ready. Sidecars (`.xmp`) are not handled specially: the
owner confirmed they don't land in the source folder, so any that do are listed as "Not media".

### Moving one file (the core, a pure-ish engine behind a protocol so tests can inject a fake
trash and file operations)

1. `dest = destinationRoot / relativePath`; create intermediate folders.
2. If `dest` exists → bucket "Already on MEDIA" (re-checked at move time, not only at scan).
3. Remove a stale `.<name>.partial` left by an earlier interrupted run in the same folder
   (only that exact name — it is ours).
4. `copyfile(src, partial, state, COPYFILE_ALL | COPYFILE_EXCL)` with a progress callback for
   bytes. Cancellation is honoured in the callback (`COPYFILE_QUIT`), then the partial is
   removed.
5. Rename partial → `dest` (no overwrite: fail if `dest` appeared meanwhile).
6. Re-apply source Finder Created and Modified with `FileDatePreservation.applyFileDates`
   (copyfile/rename on exFAT is not trusted to keep birth time). *(my call)*
7. **Verify** source vs `dest`:
   - size;
   - Finder Created and Modified, compared at the destination file system's resolution
     (exFAT: 10 ms; compare to whole hundredths, never looser than 1 s);
   - file flags that the destination supports (user flags like `UF_HIDDEN`); a flag that the
     source has but the destination cannot store is a **failure**, not ignored;
   - every xattr on the source must exist on the destination with an identical value
     (SHA-256), including `com.apple.quarantine`; an xattr on the source that is missing or
     different on the destination is a failure;
   - xattrs that exist **only on the destination**: `com.apple.provenance` (added by macOS to
     files a sandboxed app writes) is removed first; if it can't be removed it is ignored and
     logged. Any other destination-only xattr is a failure. *(owner's choice: 1a)*
   - content: streaming SHA-256 of source and destination. *(my call — the original is about
     to be trashed, and reading back from an SSD is cheap. The owner can drop it if it is too
     slow.)*
8. Only after every member of the unit verifies → move the source members to the Trash
   (`FileManager.trashItem`). If any member fails verification, or the run is cancelled in the
   middle of a unit, **delete the destination copies this run made for that unit** (never a file
   that existed before), touch nothing on the source, and report "Copied, but <field> differs:
   before → after" (details in the log). A unit is either fully moved or not moved at all, so no
   half-moved unit ends up stuck in "Already on MEDIA". *(my call)*
9. Trash fails (rare) → report "Copied and verified, but the original couldn't be moved to the
   Trash".

Units are processed sequentially (one drive, large files; parallel copies would not be faster
and would make progress harder to read). Empty source folders are left in place.

### Notifications and log

- One system notification when a run ends ("Moved 238 of 240 to MEDIA — 2 need attention"),
  via `UserNotifications` (request authorization the first time a move starts). *(my call)*
- Append-only log `external-drive.log` in the app's own Logs folder (inside the sandbox
  container), one line per file with outcome and the before/after diff on verification
  failures; the Summary has a "Show Log" button that reveals it. *(my call — replaces the Hazel
  log; the in-app summary stays the primary place.)*

### Commands and shortcuts (per AGENTS.md)

- New `AppRoute.externalDrive` and a home card.
- ⇧⌘H Home, ⌘[ / Esc Back (Summary → Review with a fresh check; Review → Home); blocked with the busy banner while scanning
  or moving — add both to `busyReason()` ("Moving files to MEDIA is in progress. Use Cancel, or
  wait until it finishes.").
- ⌘O — choose a different source folder for this session (defaults to the setting).
- ⇧⌘R — reveal the source folder. ⌘R — re-check. ↩ — the step's primary action.
- ⌥⌘Z — banner "Undo Last Finalize Step is only available in Organize Drone Footage."
  Photos-only commands get their usual "only available in Export iCloud Photos" banner.
- Tests in `AppCommandTests.swift` for every decision; README shortcut table gets a column.

### Rename

"Organize Local Photos" → "Organize Local Media" in the home card, window/step titles,
banners, Settings section, README and `AGENTS.md`.

### Tests (test-first)

- Already on MEDIA: an identical existing copy → source trashed; any difference → source kept
  and reported.
- Bucketing: a scan output → the right bucket and reason (ready / wrong folder / dates /
  conversion / outside folder / failure / exists / not media).
- Grouping: a Live Photo companion follows its still; a unit with one non-ready member is not
  ready; a cancelled or failed unit leaves no copies on the destination.
- Verification: `com.apple.provenance` only on the destination is removed/ignored; any other
  destination-only xattr fails.
- Engine with a temporary directory: copy keeps size, dates, flags, xattrs, content; existing
  destination is never overwritten; cancel leaves no `.partial` and no trashed source;
  verification mismatch leaves the source untouched; trash happens only after verification
  (fake trash closure).
- Preflight: destination missing / same volume as `/` → not connected.
- The real exFAT behaviour (AppleDouble xattrs, birth time after rename) is checked manually on
  the drive before the first real run; unit tests run on APFS temp folders.

## Left to the builder

- Exact view composition and reuse of `OrganizeProgressView` vs a new progress view.
- How to expose per-file `FileDateScanOutput` from the scanner (new API returning the outputs,
  or a classifier built on top) without changing Organize Local Media's behaviour.
- ETA smoothing, list virtualization for large batches, wording of minor UI strings.
