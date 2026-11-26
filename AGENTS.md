# AGENTS.md

## Project conventions (all agents)

Follow these rules when changing the app. They keep the four workflows (Export iCloud
Photos, Organize Local Media, Move to External Drive, Organize Drone Footage) behaving the same way.

### Keyboard shortcuts and commands

- **One shortcut set for the whole app.** Shortcuts are menu items in
  `TeziovskyUtilitiesCommands` (`TeziovskyUtilities/App/TeziovskyUtilitiesApp.swift`) that
  call `appState.run(.command)` (exceptions below). Menu items stay **enabled**; never
  use `.disabled` to block a shortcut.
- **Never ignore a key silently.** `AppState.decision(for:)` (`App/AppCommands.swift`)
  returns `.perform` or `.notice("…")`. When a command can't run, the banner says why and
  what to do instead (point to the Cancel button or another shortcut), e.g. "Scanning is
  in progress. Use Cancel, or wait until it finishes."
- **Adding a command:** add an `AppCommand` case, its decision in `decision(for:)`, its
  action in `perform(_:)`, a menu item, and tests in
  `Tests/TeziovskyUtilitiesTests/AppCommandTests.swift`. A command that exists in only one
  workflow must explain itself in the others ("… is only available in …").
- **Shared commands work in every workflow** (or explain why not): ⇧⌘H Home, ⌘[ / Esc
  Back, ⌘O Open folder, ⇧⌘R Reveal in Finder, ⌘R Refresh, ⌥⌘Z Undo Last Finalize Step,
  ↩ the step's primary action. The album sidebar toggles with **⌘S** (owner's choice, not
  the macOS-standard ⌃⌘S).
- **One owner per key.** Don't put `.keyboardShortcut` on toolbar or view buttons that
  duplicate a menu item; toolbar buttons call `appState.run(...)` and mention the key in
  `.help("… (⇧⌘H)")`. Allowed exceptions:
  - window-scoped keys in `Views/MainWindowKeyboardShortcuts.swift` (Esc, the ⌘= alias,
    ⌘↑/⌘↓ bound only while Export iCloud Photos is open);
  - `.defaultAction` on a step's primary button, and `.cancelAction` inside dialogs;
  - `onKeyPress` for in-view navigation (grid arrows, Space for Quick Look, home cards).
- **Don't take keys away from text fields.** Never make ⌘↑/⌘↓/⌘←/⌘→ or other
  text-editing keys menu shortcuts; bind them in a window that has no text fields.
- **Esc and Back only navigate.** They never cancel running work and never change files.
  While work runs they show the "busy" banner, so add every new long-running operation to
  `busyReason()`. Esc in a text field first just leaves the field. No per-view Esc
  handlers (`onExitCommand`, `onKeyPress(.escape)`, extra `.cancelAction` buttons).
- Sheets, dialogs and other windows already block commands centrally
  (`modalUIIsPresented()`); views don't re-check this.
- Keep the **Keyboard shortcuts** table in `README.md` in sync with any change.

### Workflow step screens

- **Buttons above the content.** A step card is: title and summary → action row (Back on
  the left, secondary actions, then the prominent primary action on the right) → the
  long list or details. Never put step navigation below a list. Use the shared
  containers (`DroneStepContainer`, `DroneWorkflowStepContainer`) or the same order in
  Local Photos cards.
- When the step changes, scroll back to the top (`ScrollViewReader`, an `.id` on the
  header, `onChange` of the step) so the new step's buttons are visible.
- The primary button gets `.keyboardShortcut(.defaultAction)` and `.help("… (↩)")`;
  only one per visible step.
- Actions that change files (convert, organize, cleanup, flatten) ask first with a
  `confirmationDialog` whose Cancel is the default action. The button label ends with
  "…" (e.g. "Organize 12 Files…").
- Step state lives in the service or coordinator (`LocalPhotosService.workflowStep`,
  `ExternalDriveTransferService.step`, `DroneWorkflowCoordinator.phase`), not in view `@State`, so commands can drive it.
- Home and Back buttons stay enabled and go through `appState.run(...)`, so a blocked
  click shows the same banner as the shortcut.
- Use `GlassCard` and `pillActionButton(prominent:)` for cards and buttons. Align a file
  row's include checkbox with `.localMediaRowAnchor()` on the row's leading icon, not
  with fixed padding.
- UI text is English.

### Verification before committing

- Logic changes are test-first: write a failing XCTest, then implement.
- `swift test` passes; `pnpm build` (xcodebuild) has no compiler warnings. Use `pnpm`:
  `npm run …` is rejected by the `devEngines` check in `package.json`.
- SwiftLint (`pnpm lint`) adds no new warnings compared with `main`.
- Register new Swift files in `TeziovskyUtilities.xcodeproj/project.pbxproj`, and remove
  deleted ones from it.
- Offscreen snapshots (`NSHostingView` + `cacheDisplay`) only show layout: Liquid Glass,
  materials, SF Symbols, controls and dark mode don't render. Keep such scratch tests out
  of git (`.git/info/exclude`) and delete them afterwards. Check visuals in the running
  app when they matter.

## Cursor Cloud specific instructions

### Platform constraint (important)

Teziovsky Utilities is a **native macOS SwiftUI app** (imports `SwiftUI`, `AppKit`,
`Photos`, `Quartz`, `QuickLookUI`; `Package.swift` targets `macOS 14+` and links
macOS-only frameworks). The Cursor Cloud VM is **Linux (Ubuntu x86_64) with no
Xcode/Swift toolchain**, so the following **cannot** run here and require a macOS
host with Xcode 15+:

- Build: `npm run build` / `npm run run` (`xcodebuild`), and `swift build` (`swift` is absent and the module links macOS-only frameworks)
- Tests: `npm run test` (`swift test`) — the test target links the macOS-only app module
- Running the GUI app itself

Do not attempt these on the cloud VM; they will fail on missing `xcodebuild`/`swift`
or unavailable Apple frameworks. Run build/test/run on macOS + Xcode (see `README.md`).

### What DOES work on the Linux cloud VM

- **Lint:** `npm run lint` (and `npm run lint:fix`) work. They shell out to `swiftlint`,
  which has a Linux binary. SwiftLint lints Swift source as text/AST and does not need
  the macOS frameworks, so this is the primary runnable dev task here.

### Gotchas

- **Do not run `pnpm install` / `npm install` without `--ignore-scripts`.** `package.json`
  defines an `install` script (`bash scripts/install-to-applications.sh`) that npm/pnpm
  execute as a lifecycle hook; it calls `xcodebuild` and fails on Linux. The startup
  update script uses `pnpm install --ignore-scripts`. There are no JS runtime deps
  (`pnpm-lock.yaml` is empty), so this is effectively a no-op.
- `swiftlint` is installed to `$HOME/.local/bin/swiftlint` (already on PATH via `~/.profile`)
  by the startup update script, pinned to the project's SwiftLint version (`0.63.3`).
