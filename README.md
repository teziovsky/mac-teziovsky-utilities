# Teziovsky Utilities

Native macOS app for organizing media. From a home screen you pick a workflow:

- **Export iCloud Photos** — review iCloud Photos albums and export them to a folder.
- **Organize Drone Footage** — finalize a graded project folder (fully native, no external tools).
- **Organize Local Photos** — convert legacy media, repair dates, and organize files into year folders.

> The Xcode target, scheme, and Swift module are all named `TeziovskyUtilities`; the user-facing app name is **Teziovsky Utilities** and the bundle ID is `com.teziovsky.utilities`.

## Features

### Export iCloud Photos

- Browse non-empty albums (hide albums ending with a configurable suffix, default `_zgrane`)
- Lazy thumbnail **views** for large albums (PhotoKit loads item metadata per album; grid rows render on demand)
- Choose an export folder and **Organize** to copy files with progress and cancel
- Files are written byte-for-byte as stored in Photos (no re-encoding, no metadata rewrite); only Finder Created/Modified are set, from the file's own EXIF capture time
- Edited photos export their edited render by default; turn this off in Settings → Photos to export unmodified originals
- Live Photo motion (`.MOV`) and RAW alternates are saved next to the photo with the same base name (Settings → Photos)
- Quick Look preview for the selected item (⌘Y)

### Organize Drone Footage

Point the app at a project folder that contains a `raw/` and an `export/` subfolder (names configurable in Settings → Drone). The finalize action runs fully natively:

1. For every compressed file in `export/` (name ending with the configurable suffix, default `_COMPRESSED`), match its source original, copy the source's creation/modification dates (and, for video, best-effort QuickTime creation date / location via AVFoundation passthrough) onto the compressed file, move the source to the Trash, and rename the compressed file to drop the suffix. A compressed video only replaces its original after it is verified to be playable and as long as the original.
2. Move the remaining images and videos from `export/` up into the project folder (keeping `vertical/` / `horizontal/` unless disabled in Settings).
3. Move `export/` to the Trash once it is empty, and `raw/` only if "Keep raw/ after finalize" is off (it is kept by default). Files that are not part of the delivery (e.g. `.drp`, `.srt`, naming conflicts) are listed in the preview and left in `export/`, which is then kept.

A preview lists every planned action before anything is changed, destructive steps ask for confirmation, and each step can be reverted with **Undo Last Step** (⌘Z). Esc and Go Back only navigate; they never change files.

Compression runs HandBrakeCLI with per-file progress and ETA. Output is written to a hidden `.partial` file and only renamed after HandBrakeCLI succeeds, so a failed, cancelled or interrupted encode never looks like a finished compressed copy. Cancel stops the running encode, and the Mac is kept awake while compressing.

### Organize Local Photos

Choose a folder to scan supported media recursively. Hidden entries, packages, and symbolic links are skipped. Nothing changes during scanning. The workflow separately previews media conversion, date repairs, and file organization, and only applies a step after explicit confirmation.

HEIC/HEIF images can be converted to JPEG at maximum quality. Videos in old containers (M4V, 3GP, MTS, …) that already use modern streams are rewrapped into MP4/MOV without re-encoding; videos with legacy codecs are re-encoded as H.264 + AAC in MP4 by default for widest compatibility. Videos macOS cannot read (e.g. MKV, WMV, FLV, WebM) are listed as unsupported instead of failing mid-conversion, and a file that already has its converted twin next to it is not converted again. Settings → Local Media can disable either conversion, select H.264 or HEVC, select MP4 or QuickTime MOV, and choose whether originals are kept. Converted files are verified and inherit the original filesystem dates before an original is removed; keeping originals is enabled by default.

For date repair, the app compares Finder Created, Finder Modified, and available EXIF, TIFF, or video-container dates. EXIF dates are read together with their `OffsetTime*` fields, so photos taken in another time zone are not shifted. Placeholder timestamps from zeroed fields or reset clocks (1904, 1970 and 1980 epochs, midnight on 1 January 2000/2001) are ignored. Files whose dates do not all match the oldest valid date are listed with the current date, proposed date, and source. Repair synchronizes those dates to the oldest valid date found. Image metadata is rewritten without re-encoding (pixels stay identical) and existing offsets are kept. The original file is backed up during each repair so a failed metadata rewrite can be rolled back.

For organization, each file uses that same oldest valid date. Photos move to `CURRENT_PARENT/YYYY/`; videos move to `CURRENT_PARENT/YYYY/_Filmy/`. The motion part of a Live Photo (a `.MOV` with the same name as a HEIC/JPEG in the same folder) stays next to its still and keeps the still's final name. Files already in the computed destination are skipped. A file under an incorrect year moves to the correct sibling year; if that sibling lies outside the scanned folder, the file is reported instead. Only 4-digit names from 1900 to next year count as year folders. Scans also report backups and temporary files left by an interrupted repair. Existing destination names are preserved by numbering the incoming file, for example `photo (1).jpg`. Empty source folders are left in place. Supported extensions are editable in Settings → Local Media.

### First launch

On first launch (before Photos access is granted) the app shows a short explainer with a button to grant Photos access. Drone and local-media organizing need no Photos permission, so you can continue without granting it.

## Requirements

- macOS 14+
- Xcode 15+
- Photos library access (only for the Export iCloud Photos workflow)

## SwiftLint

Style and conventions are enforced with [SwiftLint](https://realm.github.io/SwiftLint/). Configuration lives in [`.swiftlint.yml`](.swiftlint.yml).

| Command | Description |
|---------|-------------|
| `npm run lint` | Lint `TeziovskyUtilities/` and `Tests/` |
| `npm run lint:fix` | Auto-fix correctable issues, then lint again |

SwiftLint also runs during **Xcode** builds (Run Script phase after compile) and **SPM** builds via the [SwiftLintPlugins](https://github.com/SimplyDanny/SwiftLintPlugins) build-tool plugin (version **0.63.3**). The Xcode script uses the package’s bundled `swiftlint` binary when available, otherwise Homebrew’s.

For CI / unattended `xcodebuild`, pass `-skipPackagePluginValidation` when using the SPM plugin.

## Build & run

### Xcode

```bash
npm run open
```

Select the **TeziovskyUtilities** scheme and press **Run** (⌘R).

### npm scripts (Xcode — full `.app` bundle)

| Script | Description |
|--------|-------------|
| `npm run clean` | Remove `build/`, `dist/`, and run `xcodebuild clean` |
| `npm run build` | Debug build → `build/DerivedData/Build/Products/Debug/TeziovskyUtilities.app` |
| `npm run clean:build` | Clean, then debug build |
| `npm run run` | Debug build and launch the app |
| `npm run build:production` | Release build (optimized) |
| `npm run release` | Release build, copy `.app` to `dist/`, create `dist/TeziovskyUtilities-macOS.zip` |
| `npm run install` | Release build and install to `/Applications/Teziovsky Utilities.app` |
| `npm run install:open` | Same as `install`, then launch the app |

```bash
npm run run
npm run install
```

### Swift Package Manager (compile only)

This repo includes a [`Package.swift`](Package.swift) so you can compile from the CLI:

```bash
swift build          # or: npm run swift:build
swift package clean  # or: npm run swift:clean
```

SPM builds a bare executable in `.build/debug/` — **not** a signed `.app` with icons and Photos entitlements. To run the real app, use **`npm run run`** or Xcode (⌘R).

Set your development team in Xcode for signed release builds outside this repo (scripts use `CODE_SIGNING_ALLOWED=NO` for local CLI builds).

## App identity

- **Bundle ID:** `com.teziovsky.utilities`
- **Icons:** `TeziovskyUtilities/Assets.xcassets/AppIcon.appiconset` (also copied under `TeziovskyUtilities/Resources/AppIcon/`)

## Settings

- **Excluded album suffix** — albums whose names end with this suffix are hidden (default: `_zgrane`); organized items move to `<album><suffix>`, so Organize is disabled while it is empty
- **Omit from Organize** — hide albums from the sidebar and disable Organize for them
- **Export folder** — destination for the Organize action
- **Export edited versions when available** — export the edited render (default) or the unmodified original
- **Include Live Photo videos and RAW originals** — save companion files next to the exported photo (default on)
- **Drone → Compressed suffix** — suffix HandBrake adds to compressed files (default: `_COMPRESSED`)
- **Drone → Raw / Export folder names** — subfolder names used by the drone finalize step (defaults: `raw`, `export`)
- **Local Media → File extensions** — media extensions included by local conversion, date repair, and organization
- **Local Media → Media conversion** — enable each conversion, keep or replace originals, and choose codec/container

## Notes

The previous Raycast extension prototype was removed. This SwiftUI app uses PhotoKit directly for better performance on large holiday albums.
