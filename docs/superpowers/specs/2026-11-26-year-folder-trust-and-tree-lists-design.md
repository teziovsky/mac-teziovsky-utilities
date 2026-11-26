# Year-folder trust, New Year window and tree lists — design

Date: 2026-11-26 · Status: approved by the owner in conversation (option (b), window as below, tree variant A)

## Intent

The Organize step of Organize Local Media proposed 1094 moves on the owner's library, and
the sample shown was dominated by false alarms:

- Files without EXIF whose only date is the Finder Created/Modified date, which is usually a
  copy date. Example: `_kuba/2014/Kuba_2014_22.jpeg` → `2025`, and `Sunrise/2019/…` → `2023`.
- A reset GPS clock date, 6 Jan 1980, was taken as real: `Video_0001.3gp` → `1980`.
- New Year's Eve shoots split across two years: `DUEL/2022/…Sylwester_2022_4.jpeg` → `2023`.

The owner also wants to untick a whole folder at once in the review lists.

## Rules (owner chose (b))

1. **A year folder outranks file-system dates.**
   - Applies to a file that already sits under a year folder `Y` (the nearest `YYYY` ancestor,
     same predicate as today).
   - Only **embedded** dates (EXIF Original/Digitized, TIFF, media container) can move it.
     Let `e` be the oldest plausible embedded date:
     - If there is no embedded date, the file stays.
     - If `year(e) == Y`, the file stays.
     - If `e` falls in the New Year window next to `Y` (rule 2), the file stays.
     - Otherwise it moves to `year(e)`, plus `_Filmy` and Live Photo handling as today.
   - When the file stays but the overall oldest plausible date (which may be a file-system
     date) is in another year, the planner reports it as **kept** with that date.
     Organize Local Media lists these in a collapsed section titled
     "Kept in year folder — only file-system date disagrees (N)". Nothing moves for them.
2. **New Year window.**
   - Window W(Y) runs from 31 Dec Y 12:00 to 1 Jan Y+1 12:00, local time.
   - A file already under year folder `Y` or `Y+1` whose deciding date falls in W(Y) is in
     the right year and is not moved.
   - A file **not yet** under a year folder whose deciding date falls on 1 Jan between 00:00
     and 05:59 local time goes to the previous year's folder.
   - Files not under a year folder keep today's deciding date: the oldest plausible date of
     any source. Rule 1 only applies inside year folders.
3. **GPS epoch.** 6 Jan 1980 joins the ignored placeholder dates. It uses the same ±14 h
   match as the existing epoch days.
4. **Move to External Drive** uses the same planner. A "kept" file counts as already
   organized there, so it is Ready if nothing else blocks it.

## Tree lists (owner chose variant A)

- **Where:** the review lists of all three Organize Local Media steps (Convert, Dates,
  Organize). They are built from the file's relative source path.
- **Layout:** a flat, lazily rendered list. Each folder gets a header row with an indent per
  depth, a disclosure chevron, the folder name, a file count and a tri-state checkbox (all /
  some / none).
  - Single-child folder chains are collapsed into one header, e.g.
    `Imprezy/Festiwale/Audioriver/2023`.
  - Files are indented under their folder, and the existing row views are reused.
- **Folder checkbox:** sets or clears the exclusion of every file under it, in that step
  only. A mixed state shows a dash. Clicking a mixed checkbox includes everything.
- **Filter:** the existing filter matches first, and the tree is built from the matching
  files.
- **Collapse state:** kept per step, in view state only (it is not step data).
- **Row limit:** the 300-row "Show all" limit now counts file rows, never cutting a folder
  header off from its files.
- **Unchanged:** step state, exclusion storage (`excludedPaths`), commands and shortcuts.
- **Not converted:** the Move to External Drive lists stay flat.

## Approaches considered

- Folder-trust rule: (a) the folder wins over file-system dates only; **(b) (a) plus a New
  Year window — chosen**; (c) majority vote per folder (rejected: hides genuinely misplaced
  files in small folders).
- Tree: **A — a flat list with folder headers built from paths (chosen)**: reuses the row
  views, stays lazy and fast at thousands of rows. B — native `OutlineGroup`/`List`:
  rejected because it fits poorly with the glass card rows and checkbox alignment, and is
  slower on big trees.

## Non-goals

- Changing the date repair step's logic.
- Persisting exclusions across launches.
- A tree view in Move to External Drive.
- Reading years from filenames.

## Left to the builder

- Header styling within the existing visual language.
- The exact chevron and checkbox controls; a custom tri-state checkbox image is fine.
- The animation on collapse.
