# Scrolling capture

## Why

João captures long docs and web pages and shares them in Slack and PRs. Today that means several screenshots or a
browser extension. Scrolling capture turns one selected area plus scrolling into a single tall PNG that goes through
the normal pipeline: card, editor, compression, copy, upload.

## Goals

- New capture mode, "Capture Scrolling": pick an area, scroll the content under it, press Done, get one tall PNG.
- Sticky headers and footers (navbars, Notion's top bar, GitHub's file header) show up once, not once per slice.
- Still side columns (Slack's channel list, Notion/Docs sidebars, GitHub's file tree) are detected and left out, so
  selecting a whole window still gives a clean image of just the content.
- The result is a normal capture: thumbnail card, annotation editor, compress-after-capture, copy, upload all work
  unchanged.
- No new permission for manual scrolling.
- Phase 2: an "Auto" button on the same stage that scrolls for the user, which is the only thing that asks for
  Accessibility. **Phase 2 is out of this plan**: it gets its own plan after phase 1 ships. Phase 1 only leaves the
  stage room for a scroll driver.

## Non-goals

- Horizontal scrolling. Docs and pages scroll vertically; the stitcher assumes vertical-only motion.
- Window-mode or full-screen scrolling capture. Area only; the area can cover a window.
- Reading scroll position through Accessibility (approach C below).
- Stitching content that changes while scrolling (videos, animations, live cursors). It produces what it produces.

## Anti-goals

- A silent bad stitch. If two consecutive frames don't overlap, the user is told on the stage, not handed a PNG with a
  gap.
- A silent limit. Hitting the height limit says so on the stage, naming the limit (see "Numbers").
- Cost while idle. Nothing streams or runs unless the scrolling stage is up; idle numbers in `docs/perf` stay put.

## Constraints

- macOS, Swift, ScreenCaptureKit, as the rest of `LunettaCapture`.
- Lunetta's own chrome must not end up in the frames: every window this feature opens is marked with
  `CaptureChrome.mark` and excluded through `ScreenCapturer.chromeWindowIDs`.
- Scroll events in the area must reach the app underneath. The recording stage's `StagePanel` covers the whole screen
  and sets `ignoresMouseEvents = false` (`App/Overlay/RecordingStage.swift`), so it can't be reused as-is.
- Slack and GitHub shrink very tall images, so output height is bounded (see "Numbers").

## Approaches

- **A. One stage, manual first, auto later (picked).** Area stays outlined, user scrolls, frames stream from
  `SCStream`, row-signature stitcher crops sticky bands. Auto-scroll is later a driver on the same stage. Picked because
  the stitcher is the core, manual exercises it with no new permission, and auto becomes a thin addition.
- **B. Auto first.** Fixed scroll steps and a still grab after each. Predictable overlap, but Accessibility on first
  use, breaks on scroll-jacking or smooth-scroll pages, and loses "scroll only the part I want".
- **C. Accessibility scroll position.** Dropped: browsers and Electron apps report it inconsistently.

## Design

### Flow

```
hotkey / menu ─► area selection (existing selector, live, no freeze)
              ─► scrolling stage: outline + controls panel, scroll passes through
                   │  SCStream frames ─► Stitcher (incremental) ─► preview strip
                   │  Done ─► stitched CGImage ─► coordinator save pipeline (unchanged)
                   └  Cancel / Esc ─► nothing saved
```

### Entry point

- `CaptureMode.scrolling`, a `KeyboardShortcuts.Name.captureScrolling` with its own Settings row and menu item, in
  `LunettaShortcuts.all` after "Capture Area".
- Selection always uses the live overlay, ignoring `freezeScreenWhileSelecting`: a frozen screen can't be scrolled.

### Scrolling stage (new, `App/Overlay/ScrollingStage.swift`)

Two windows instead of one full-screen panel:

- **Frame window**: borderless, transparent, `ignoresMouseEvents = true`, draws the outline just outside the area and
  dims outside it. Everything, scroll wheel included, goes to the app underneath.
- **Controls panel**: a small non-activating panel next to the area (below it, or above when there's no room), using
  `LunettaUI` glass buttons: Done, Cancel, a live preview strip of the stitched image so far, the current height, and
  the overlap warning. Phase 2 adds Auto.
- Esc cancels, Return finishes, through a global monitor active only while the stage is up (as
  `cancelRecordingCountdown` does).
- Both windows are marked as chrome.

The stage is behind a protocol (like `RecordingStaging`) so `CaptureCoordinator` tests can fake it.

### Frames (`LunettaCapture`)

- `ScreenCapturer` gains a scrolling session: an `SCStream` on the area's display with `sourceRect` = the area,
  chrome excluded, cursor hidden, at the display's backing scale.
- A frame is handed to the stitcher only when it differs from the last one handed over (cheap compare on the row
  signatures it computes anyway), so a still page costs almost nothing.
- The first frame is taken at stage start, so pressing Done with no scrolling gives a normal area capture.

### Stitcher (`LunettaCapture`, pure, no ScreenCaptureKit)

Input: frames of identical size. Output: one tall image, built incrementally.

1. **Still columns**: compare consecutive frames column by column; columns at the left and right edges that are
   unchanged while the rest changed are fixed side bands, learned on the first frame pair that moved and frozen after
   that. Only the moving block between them goes through steps 2–4. Side bands are dropped from the output: the PNG
   is the moving block's width, a clean rectangle of the content. Keeping a sidebar at the first frame's height only
   would leave an L-shaped image, and repeating it would invent content; a plain area capture still gets the
   sidebar.
2. **Sticky bands**: within the moving block, rows at the top and bottom whose signature (hash of the row's pixels in
   that block, downsampled for speed; downsampling is a builder call backed by measurement) is unchanged between
   consecutive frames while the middle moved are fixed bands. Top band is kept from the first frame only, bottom band
   from the last frame only.
3. **Offset**: in the moving middle, find the vertical shift that best aligns the new frame's rows with the previous
   frame's. Shift 0 means no motion: drop the frame. No shift above a match threshold means no overlap: don't append,
   raise the overlap warning, and wait for the user to scroll back until a match is found again.
4. Append only the newly revealed rows, and only above the **commit line**. The floating zone is the run of bottom
   rows holding non-uniform blocks that stayed put on screen while the content moved (chat bubbles, "back to top",
   "new messages" pills, sticky or late footers). It only grows. Rows below it commit once a later frame scrolls them
   above it; at Done the rows still below come from the deepest frame, so a widget or footer appears once, at the
   bottom.
5. Scrolling up re-reveals rows already stitched: match against the stitched image's tail region and append nothing
   until new rows appear below. Scrolling above the starting point extends nothing (top is fixed at the first frame).

Tested with fixture PNGs in `Packages/LunettaCapture/Tests/LunettaCaptureTests/Fixtures`: plain scroll, sticky header,
sticky header + footer, still sidebar, still sidebar + sticky header, scroll back up, fast scroll with a gap, no
scroll.

The stream's "did the frame change" check uses the same signatures, so a sidebar that changes (a hover, an unread
badge) without the content moving doesn't count as a scroll: shift 0 in the moving block means the frame is dropped.

### Finishing

Done hands the stitched `CGImage` to the same save path as `run(_:)` (`save` → `copyIfOn`), so naming, card, shutter
sound, compression, copy and upload behave as for any screenshot.

### Phase 2: Auto-scroll

- Auto button on the controls panel. First press checks `AXIsProcessTrusted()`; if not trusted, the panel shows the
  Accessibility fix the way the recording stage shows `RecordingProblem`s, not a modal alert.
- Driver: move nothing visible; post scroll-wheel `CGEvent`s at the area's center, wait for the frame to settle (no
  change for N frames), repeat. Stops at end of content (two settled frames identical), the height limit, or any user
  input (click, key, real scroll), which hands control back to manual.
- Same stitcher, same stage.

## Numbers (no number without a receipt)

Each of these is measured before it's written into code, then sized as a tripwire:

- **Height limit**: measure decode memory and PNG encode time for tall captures at Retina scale, and what Slack and
  GitHub actually display or accept for tall images. Hitting it stops appending and says on the stage
  "height limit <N> px reached".
- **Row-signature downsampling and match threshold**: measured on the fixtures and on real pages (GitHub PR, Notion,
  Google Docs, a long Slack thread).
- **Auto-scroll step and settle time**: measured on the same pages.
- **Stream frame rate**: lowest rate that never skips content at normal trackpad scroll speed, measured.
- **Perf receipt**: CPU and memory while the stage is up, added to `docs/perf`.

## Left to the builder

- Default shortcut. My call: ⌥⇧⌘4, if it's free and doesn't clash with macOS or the existing bindings.
- Preview strip look and panel placement details, following the recording stage's style.
- Row-hash function and downsampling, given the measurements.
- How the stream is torn down on cancel, display change, or sleep.
