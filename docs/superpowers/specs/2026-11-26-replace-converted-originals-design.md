# Replace originals with their converted copies — design

Date: 2026-11-26 · Status: approved by the owner in conversation

## Intent

Organize Local Media keeps originals after converting them, which is the default. The
converted copy sits next to the original:

- `Mia_32.mp4` → `Mia_32-converted.mp4` when the container stays the same;
- `IMG.heic` → `IMG.jpg` and `Video.3gp` → `Video.mp4` when it changes.

The original carries the xattr `com.teziovsky.utilities.converted-media`, whose value is the
copy's file name.

The owner checks the new files later, possibly in another session. After that, they want one
action that trashes the originals and gives each copy the original's name, so they don't have
to do it by hand.

## Behaviour

- **Detection (during the scan).** A pair is an original that has the conversion marker and
  whose marked twin (the file name stored in the marker) exists in the same folder.
  - The marker's file name is the only source of truth. No guessing from names.
  - If the marker points to a file that is missing, there is no pair. The original is
    treated as before.
- **Where it shows:** the Convert step gets a section "Converted copies ready to replace
  originals (N)".
  - It uses the folder tree list with checkboxes. Exclusions work per step, using a new
    `LocalMediaStep.replacement`.
  - Each row reads `Mia_32.mp4 → Mia_32-converted.mp4`, plus the final name if it differs,
    e.g. "will be named Mia_32.mp4".
  - Each row has Reveal in Finder in its context menu.
- **Action:** "Replace N Originals…" asks for confirmation first, with Cancel as the default.
  It has progress and Cancel, like the other steps. For each ticked pair, in order:
  1. **Re-verify the copy.**
     - Images: the copy decodes to an image of the same pixel size as the original.
     - Videos: the copy is playable, its video track decodes at least one frame, and its
       duration is within the existing conversion tolerance of the original.
     - If verification fails, the pair is untouched and the failure is reported with a
       reason.
  2. **Move the original to the Trash** (`FileManager.trashItem`). Never delete it
     permanently.
  3. **Rename the copy** to the original's base name with the copy's own extension:
     - `Mia_32-converted.mp4` → `Mia_32.mp4`;
     - `IMG.jpg` and `Video.mp4` already have the right name, so nothing is renamed.

     The rename never overwrites anything. If the target name is taken by another file, the
     copy keeps its name and the pair is reported as "Original trashed; copy kept as X
     because Y exists".
  4. The copy's Finder dates were set at conversion time and the rename keeps them. No date
     changes.
- **Live Photo pairs** (HEIC + MOV) keep their base name, so they stay a pair.
- **Afterwards:** a rescan, like after a conversion, plus a summary: replaced, failed (with
  reason), cancelled.
- **Long-running work:** the run counts as busy (`activityTitle`), so ⇧⌘H, Back and Esc show
  the busy banner, as AGENTS.md requires.

## Approaches considered

- **Scan-based pairs in the Convert step — chosen by the owner.** It works across sessions,
  after the owner has checked the files.
- An "after converting, replace originals right away" toggle — rejected. The owner wants to
  check the copies first.

## Non-goals

- Changing the conversion itself or the "keep originals" setting. With keep-originals off,
  the original is still deleted after conversion, as today.
- Pairs that have no marker (e.g. copies made by other tools).

## Left to the builder

- The exact image and video comparison helpers. Reuse the conversion's `verify` /
  `LocalMediaRemuxVerifier` where possible.
- Section placement inside the Convert card. It goes after the conversion list, and its
  action row sits above its own list, per AGENTS.md.
