# Scrolling Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "Capture Scrolling": pick an area, scroll the content under it, press Done, get one tall PNG through the
normal save pipeline. Phase 1 (manual scrolling) only.

**Architecture:** A pure `Stitcher` in `LunettaCapture` turns BGRA frames into one image: it finds still side columns
and sticky header/footer rows once, then tracks the vertical shift of the moving block frame to frame and appends only
new rows. `ScreenCapturer` streams the area's frames with `SCStream`. `CaptureCoordinator` gets a `.scrolling` mode
that selects an area, runs frames through the stitcher off the main actor, shows a scrolling stage (click-through
outline + controls panel), and hands the result to the existing `save` → `copyIfOn` path.

**Tech Stack:** Swift 6, ScreenCaptureKit, AppKit, Swift Testing, KeyboardShortcuts.

**Spec:** `docs/superpowers/specs/2026-11-28-scrolling-capture-design.md`

## Delivery

Three PRs, in this order, each branched from `main` after the previous one merges:

1. **Tall thumbnails** — Task 6b. Merged in #158.
2. **Tall images in the editor** — Task 6c. Merged in #159 (the tall rule now lives in `LunettaCore` as
   `TallCapture.isTall`).
3. **Scrolling capture** — Tasks 0–6, then 7. Its Task 6 manual check also covers 6b and 6c end to end.

PRs 1 and 2 can be built while Task 0's spike runs (it needs a person scrolling real pages on the Mac).

## Global Constraints

- Runs on macOS only. Package tests: `(cd Packages/LunettaCapture && swift test)`. App tests:
  `xcodegen generate && xcodebuild -scheme Lunetta -destination 'platform=macOS' test`.
- Vertical scrolling only. Area mode only.
- Every window this feature opens is marked with `CaptureChrome.mark`.
- Manual scrolling needs no new permission. No Accessibility code in this plan.
- No number goes into code without a receipt: every tuning value lives in `StitchTuning` or next to its measurement,
  with a one-line comment citing the measurement (which page, which machine, which result). Tests pass explicit
  values and never depend on the measured defaults.
- Hitting a limit is visible: the height limit shows on the stage as `Height limit <N> px reached`.
- Nothing streams or runs unless the scrolling stage is up.
- Zero code comments beyond why-comments and receipts (repo rule).
- Commit messages: concise, conventional, no agent credit lines.

## Review Focus

1. **Repeating content** (a list of identical rows, a blank stretch): several shifts match equally. Expect the shift
   nearest the previous frame's shift, so the image never jumps. → test in Task 2.
2. **Tiny change in a matched frame** (blinking caret, hover in a sidebar, unread badge): must not raise the overlap
   warning or count as a scroll. → test in Task 2.
3. **Done without scrolling**: the result equals a plain area capture of the same area. → tests in Tasks 2 and 5.
4. **Stream fails mid-session** (display sleeps, display unplugged, permission revoked): stage closes, error is
   presented, nothing is saved, stream is stopped. → test in Task 5.
5. **Page with white margins but no sidebar**: blank margins must not be cropped as "still columns". → test in Task 2.

---

## File Structure

| File | Responsibility |
| --- | --- |
| Create `Packages/LunettaCapture/Sources/LunettaCapture/Stitching/Frame.swift` | `Frame`: BGRA8 pixels from a `CGImage` or `CVPixelBuffer`, row/column signatures |
| Create `Packages/LunettaCapture/Sources/LunettaCapture/Stitching/Stitcher.swift` | `Stitcher`, `StitchTuning`, `StitchUpdate`: bands, shift, append, output |
| Create `Packages/LunettaCapture/Sources/LunettaCapture/ScrollingFrames.swift` | `SCStream` on an area → `AsyncThrowingStream<Frame, Error>` |
| Modify `Packages/LunettaCapture/Sources/LunettaCapture/ScreenCapturer.swift` | `scrollingFrames(of:displays:)` |
| Create `Packages/LunettaCapture/Tests/LunettaCaptureTests/StitcherTests.swift` | synthetic-page tests |
| Create `Packages/LunettaCapture/Tests/LunettaCaptureTests/Fixtures/scrolling/` | real-page frame sequences + expected output |
| Modify `App/CaptureCoordinator.swift` | `.scrolling` mode, `ScrollStaging` protocol, `captureScrolling()` |
| Create `App/Overlay/ScrollingStage.swift` | outline window + controls panel |
| Modify `App/Shortcuts.swift`, `App/LunettaApp.swift`, `App/SystemAdapters.swift` | shortcut, menu item, wiring |
| Modify `AppTests/CaptureCoordinatorTests.swift` | fakes + flow tests |
| Modify `App/ThumbnailPanel.swift` | top-crop + height badge for tall images (Task 6b) |
| Modify `Packages/LunettaEditor/Sources/LunettaEditor/{AnnotationEditor,EditorCanvas}.swift` | fit-to-width + pan for tall images (Task 6c) |
| Create `docs/perf/2026-11-scrolling-capture.md` | row-matching spike, tuning receipts, CPU/memory while the stage is up |

---

### Task 0: Spike — do scrolled rows come out pixel-identical?

The stitcher's exact-hash matching assumes a row rendered at one y is byte-identical at another y after a scroll.
Fractional trackpad offsets, smooth-scroll mid-animation frames, or per-frame color processing would break that. This
spike answers it before any stitcher code exists.

**Files:**
- Create (committed): `Packages/LunettaCapture/Tests/LunettaCaptureTests/Fixtures/scrolling/<page>/frame-NN.png` for
  `github-pr` (Safari), `notion` (Chrome), `google-doc` (Chrome), `slack-thread` (Slack app, channel list in the area)
- Create (throwaway, not committed): a recorder script and a row-match script in the scratchpad

- [ ] **Step 1: Record frames the way the feature will.** Throwaway Swift script: `SCStream` on a fixed area (Retina
  display), BGRA, cursor hidden, writing every `.complete` frame to PNG while you scroll by trackpad: slow, normal, one
  fast flick, one scroll back up. Keep ~10 frames per page (drop near-duplicates) as fixtures.
- [ ] **Step 2: Check exact matching.** Throwaway script: for each consecutive pair, brute-force the vertical shift
  that maximizes rows with identical bytes in the content columns, and report per pair: best shift, share of
  non-uniform overlap rows that match exactly.
- [ ] **Step 3: Decide and record it** in `docs/perf/2026-11-scrolling-capture.md` (create it) with the per-pair table:
  - **Exact** (every scrolled pair has ≥ 0.95 exact-matching rows at its best shift): Tasks 1–2 as written.
  - **Tolerant** (otherwise): Tasks 1–2 change as follows, everything else stays:
    - `Frame.rowSignatures` → `func rowProfiles(columns: Range<Int>, stride: Int) -> [[UInt8]]` (luma of each
      sampled pixel); column signatures likewise become `columnProfiles`.
    - Two rows match when their mean absolute luma difference ≤ `StitchTuning.rowTolerance` (new field, measured in
      Task 3 alongside the others). Uniform-row/column rules are unchanged; the shift search uses Task 2's windowed
      fallback instead of voting.
    - Task 1's tests assert on profiles; add `@Test func subpixelShiftedRowsMatchWithinTolerance()` using a fixture
      pair from Step 1.
- [ ] **Step 4: Commit** the fixtures and the perf doc — `git commit -m "test(capture): record scrolling fixtures and check row matching"`

---

### Task 1: `Frame` and signatures

**Files:**
- Create: `Packages/LunettaCapture/Sources/LunettaCapture/Stitching/Frame.swift`
- Test: `Packages/LunettaCapture/Tests/LunettaCaptureTests/StitcherTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct Frame: Sendable {
      public let width: Int, height: Int, bytesPerRow: Int
      public let pixels: [UInt8]                    // BGRA8, premultiplied, top row first
      public init?(_ image: CGImage)
      public init?(_ pixelBuffer: CVPixelBuffer)    // kCVPixelFormatType_32BGRA only
      func rowSignatures(columns: Range<Int>, stride: Int) -> [UInt64]
      func columnSignatures(stride: Int) -> [UInt64]
      func isUniformRow(_ y: Int, columns: Range<Int>) -> Bool
      func isUniformColumn(_ x: Int) -> Bool
      func cropped(columns: Range<Int>, rows: Range<Int>) -> Frame
  }
  ```
  Signature = FNV-1a 64 over the BGRA bytes of every `stride`-th pixel (always including the first and last pixel of
  the range). Uniform = every pixel identical.

- [ ] **Step 1: Write test helpers and failing tests** in `StitcherTests.swift`

  Helpers (reused by Task 2): `page(width:height:)` draws a tall image where every row has distinct content (e.g. a
  pattern seeded by row index, never two equal rows); `viewport(of:top:height:header:footer:sidebar:)` crops a frame at
  `top`, then paints a constant `header` rows at the top, `footer` rows at the bottom, `sidebar` columns at the left,
  each with its own fixed pattern (not uniform).

  ```swift
  @Test func identicalRowsShareASignature()     // two frames cropped at the same top: rowSignatures equal
  @Test func shiftedFrameSignaturesLineUp()     // frame at top 0 vs top 10: a.rowSignatures[10...] == b.rowSignatures[..<(h-10)]
  @Test func strideStillSeesLastPixel()         // rows differing only in the last pixel get different signatures at stride 7
  @Test func frameRoundTripsCGImage()           // Frame(image).cropped(all).pixels equal to drawing the image into BGRA
  ```

- [ ] **Step 2: Run** `(cd Packages/LunettaCapture && swift test --filter StitcherTests)` — expect compile failure (`Frame` undefined).
- [ ] **Step 3: Implement `Frame`** as specified above. `init?(_ image:)` draws into a BGRA8 premultiplied-first, little-endian context.
- [ ] **Step 4: Run the tests** — expect PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(capture): add BGRA frame with row and column signatures"`

---

### Task 2: `Stitcher`

**Files:**
- Create: `Packages/LunettaCapture/Sources/LunettaCapture/Stitching/Stitcher.swift`
- Test: `Packages/LunettaCapture/Tests/LunettaCaptureTests/StitcherTests.swift`

**Interfaces:**
- Consumes: `Frame` (Task 1).
- Produces:
  ```swift
  public struct StitchTuning: Sendable {
      public var sampleStride: Int           // pixels between sampled pixels in a signature
      public var minMatchFraction: Double    // share of non-uniform overlap rows that must match
      public var minDistinctRows: Int        // non-uniform rows a match must include
      public var maxOutputHeight: Int        // pixels; tripwire
      public var floatingBlockSize: Int      // pixels per side of the blocks checked for floating widgets
      public init(sampleStride: Int, minMatchFraction: Double, minDistinctRows: Int, maxOutputHeight: Int, floatingBlockSize: Int)
      public static let measured: StitchTuning   // filled in Task 3, with receipts
  }
  public struct StitchUpdate: Sendable, Equatable {
      public enum State: Sendable, Equatable { case tracking, lostOverlap, heightLimitReached(limit: Int) }
      public let state: State
      public let height: Int                // image() height right now, pixels
      public let appendedRows: Int          // growth of height in this append
  }
  public final class Stitcher {             // not Sendable: owned by one task
      public init(first: Frame, tuning: StitchTuning)
      public func append(_ frame: Frame) -> StitchUpdate
      public func image() -> CGImage?       // header + committed rows + deepest frame's rows below them, moving-block width
      public func tail(maxRows: Int) -> CGImage?   // last rows of image(), for the preview strip
  }
  ```

**Algorithm** (the signatures and tests don't determine it, so here it is):

- State: `reference` (last frame that matched) and its `viewportTop` (where its moving rows start, in output
  coordinates); `deepest` (the matched frame with the largest `viewportTop`) and its `viewportTop`; the committed row
  buffer; `lastShift`; `floatingZone` (rows, starts 0, only grows); and once learned: `columns: Range<Int>` (moving
  block) and `headerRows`.
- Bands are learned on the first `append` whose frame differs from `reference`, then frozen:
  - Columns: leading/trailing runs of columns whose `columnSignatures` are equal in both frames. Then hand inner
    uniform columns back to the moving block (trim uniform columns off each band's inner edge); a band left with no
    non-uniform column is no band. So margins stay, sidebars go.
  - Rows within `columns`: the leading run of equal `rowSignatures` at the same index → `headerRows`, same uniform
    trimming. There's no learned footer: sticky footers, late footers and floating widgets are all the floating zone.
  - Until bands are learned, the output is the first frame unchanged (Done now = plain area capture).
- Shift, every `append`: moving rows `M = headerRows..<height` within `columns`, uniform rows ignored throughout.
  - **Vote** (exact matching, per Task 0): index `reference`'s non-uniform row signatures in a
    `[UInt64: [Int]]`, kept with `reference` so it's built once per matched frame. For each non-uniform row `i` of
    the new frame, every `j` with the same signature votes for `s = j - i`. O(rows) per frame, no nested search.
  - **Fallback** (only if Task 0 chose tolerant matching): score shifts in `lastShift ± StitchTuning.searchWindow`
    first (new field, measured in Task 3), and widen to `-(M.count-1)...(M.count-1)` only when none qualifies.
  - A candidate qualifies when, over the overlap at `s`, matched non-uniform rows ≥ `minDistinctRows` and ≥
    `minMatchFraction` of the non-uniform overlap rows (verify the top-voted candidates this way; votes alone don't
    decide). Pick the qualifying `s` with the most matches; break ties by nearest to `lastShift`.
  - `s == 0`: drop the frame, return `.tracking`, appended 0.
  - None qualifies: keep `reference`, return `.lostOverlap`. The next frames keep matching against the same
    `reference`, so scrolling back recovers.
  - Otherwise: update the floating zone (below), `viewportTop += s`, `reference = frame`, `lastShift = s`; if
    `viewportTop >= deepest.viewportTop`, `deepest = frame`. Then commit (below).
- **Floating zone**, for every matched pair with `s != 0`: split the bottom of the moving block into
  `floatingBlockSize` square blocks. A block is floating when it is non-uniform, has at least two distinct rows (so a
  vertical rule or table border, identical under any vertical shift, never counts), and is byte-identical at the same
  position in both frames. Walk block-rows up from the bottom while each contains a floating block; the rows covered
  are this pair's zone. `floatingZone = max(floatingZone, zone)`.
- **Commit line**, in output coordinates: `viewportTop + M.count - floatingZone`. Rows of `reference` above the line
  and past the committed end are appended to the committed buffer, cropped to `columns`. Rows at or below it are never
  committed from this frame; a later frame commits them once they've scrolled above the line, away from the widget.
  Negative positions (scrolled above the start) commit nothing.
- `image()`: header rows from the first frame, the committed rows, then `deepest`'s moving rows past the committed end,
  all cropped to `columns`. So a footer or widget appears once, at the very bottom, and scrolling back up before Done
  loses nothing.
- Height: `StitchUpdate.height` is `image()`'s height. If committing would push it past `maxOutputHeight`, commit up
  to the limit and return `.heightLimitReached(limit:)` from then on.
- Committed buffer: `[UInt8]` with `reserveCapacity` grown by doubling, never pre-zeroed to `maxOutputHeight`.

- [ ] **Step 1: Write failing tests** (all with an explicit tuning, e.g. `StitchTuning(sampleStride: 1, minMatchFraction: 0.9, minDistinctRows: 8, maxOutputHeight: 100_000, floatingBlockSize: 16)`)

  Extend Task 1's `viewport` helper with `widget: CGRect?` (a fixed non-uniform patch painted at that viewport
  position on every frame) and `widgetFrom: Int` (first frame index that has it, for late footers).

  ```swift
  @Test func noScrollGivesTheFirstFrame()            // first frame only, and first + identical frame: image() pixels == first frame
  @Test func plainScrollRebuildsThePage()            // viewports at top 0, 40, 95, 150 of page; image() == page rows 0..<(150+h)
  @Test func stickyHeaderAppearsOnce()               // header: 30 on every viewport; output == header + page rows, height == 30 + 150 + (h - 30)
  @Test func stickyHeaderAndFooterAppearOnce()       // header 30, footer 20; footer comes from the last frame, once
  @Test func lateFooterAppearsOnce()                 // footer 20 only from the 2nd scrolled frame on; footer pattern occurs exactly once, at the bottom
  @Test func floatingWidgetAppearsOnce()             // 40×40 widget in the bottom-right corner of every frame; widget pattern occurs exactly once, at the bottom; page rows above it intact
  @Test func floatingZoneNeverShrinks()              // widget on frames 1–3, gone on frame 4; rows under the old zone still commit only after scrolling past it, no widget stamped
  @Test func verticalRulesDontMakeAFloatingZone()    // page with a 2-px vertical line down the content; floating zone stays 0, output == page rows
  @Test func scrollingBackUpKeepsTheDeepestTail()    // with a widget: tops 0, 200, 100, then image(); bottom rows equal the frame at top 200's bottom rows
  @Test func stillSidebarIsDropped()                 // sidebar: 60; image().width == w - 60, content == page columns 60...
  @Test func stillSidebarAndHeader()                 // sidebar 60 + header 30; width w - 60, header once
  @Test func whiteMarginsAreKept()                   // page with 40 uniform white columns each side, no sidebar; image().width == w
  @Test func scrollingBackUpAppendsNothing()         // tops 0, 100, 50, 100: height after the 3rd and 4th append unchanged from after the 2nd
  @Test func scrollingAboveTheStartAppendsNothing()  // first frame at top 200, then top 150: appendedRows == 0, height == h
  @Test func gapRaisesLostOverlapAndRecovers()       // tops 0, then h + 50 (no overlap) → .lostOverlap, height unchanged; then top 60 → .tracking, rows appended
  @Test func repeatingContentPicksNearestShift()     // page made of a 20-row period; scroll by 8 each step; every update appends 8 rows
  @Test func smallChangeStillMatches()               // second frame = top 40 with one content row altered → .tracking, not .lostOverlap
  @Test func sidebarHoverIsNotAScroll()              // same top, one sidebar pixel changed, after bands learned → appendedRows 0, .tracking
  @Test func heightLimitStopsAndSays()               // maxOutputHeight: h + 50; scroll by 100 → height == h + 50, state == .heightLimitReached(limit: h + 50), later appends keep that state
  @Test func appendStaysLinear()                     // internal `rowComparisons` counter (@testable): same scroll at frame height h and 2h; comparisons at 2h ≤ 2 × comparisons at h (a quadratic search gives ~4×)
  @Test func tailReturnsLastRows()                   // tail(maxRows: 10).height == 10 and equals the last 10 rows of image()
  ```

- [ ] **Step 2: Run** `(cd Packages/LunettaCapture && swift test --filter StitcherTests)` — expect compile failure.
- [ ] **Step 3: Implement `Stitcher`** per the algorithm. Leave `StitchTuning.measured` out until Task 3.
- [ ] **Step 4: Run the tests** — expect PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(capture): stitch scrolled frames, dropping still sidebars and sticky bands"`

---

### Task 3: Real-page fixtures and measured tuning

Task 0 recorded only `github-pr` and `notion` (Dia instead of Chrome). `google-doc`, `slack-thread` and the chat-bubble
page were skipped: record them before Step 2, or drop them from the test arguments. See `docs/perf/2026-11-scrolling-capture.md`.

**Files:**
- Create: `Packages/LunettaCapture/Tests/LunettaCaptureTests/Fixtures/scrolling/<page>/ground-truth.png`
- Modify: `Stitcher.swift` (add `StitchTuning.measured`), `StitcherTests.swift`
- Modify: `docs/perf/2026-11-scrolling-capture.md` (created in Task 0)

**Interfaces:**
- Produces: `StitchTuning.measured`, used by Task 5.

- [ ] **Step 1: Add ground truth** for Task 0's fixtures: each page's full-page screenshot (browser) or export to PNG,
  cropped to the content column where available.
- [ ] **Step 2: Write `@Test(arguments: ["github-pr", "notion", "google-doc", "slack-thread"]) func realPageStitches(_ page: String)`**
  which appends every frame and asserts: final state `.tracking`, no `.lostOverlap` along the way, Slack output width
  excludes the channel list, and output height within the page's ground-truth height ± header height.
- [ ] **Step 3: Measure `sampleStride`, `minMatchFraction`, `minDistinctRows`, `floatingBlockSize`.** Add a docs page
  with a chat bubble (any site with an Intercom-style widget) to Task 0's fixture set for `floatingBlockSize`. Sweep values over the fixtures; record
  pass/fail and `append` time per frame (median of the fixture run) in the perf doc. Pick the cheapest values that pass
  every fixture with margin.
- [ ] **Step 4: Measure `maxOutputHeight`.** Record decode memory and `PNGWriter` encode time for outputs of 10k, 20k,
  40k, 80k px at the area width of a typical doc (Retina). Record what Slack (upload preview) and a GitHub PR comment
  do with each (displayed, downscaled, rejected, file-size cap). Set the limit as a tripwire past any doc João would
  share, under where encode time or memory gets bad.
- [ ] **Step 5: Add `StitchTuning.measured`** with one receipt comment per value pointing to the perf doc section.
- [ ] **Step 6: Run** `(cd Packages/LunettaCapture && swift test)` — expect PASS.
- [ ] **Step 7: Commit** — `git commit -m "test(capture): stitch real pages and measure stitch tuning"`

---

### Task 4: Area frame stream

**Files:**
- Create: `Packages/LunettaCapture/Sources/LunettaCapture/ScrollingFrames.swift`
- Modify: `Packages/LunettaCapture/Sources/LunettaCapture/ScreenCapturer.swift`
- Test: `Packages/LunettaCapture/Tests/LunettaCaptureTests/ScreenCapturerLogicTests.swift`

**Interfaces:**
- Consumes: `Frame.init?(_ pixelBuffer:)`, existing `DisplayGeometry`, `contentFilter(displayID:hiding:)`.
- Produces:
  ```swift
  public struct ScrollingFrames: Sendable {
      public let frames: AsyncThrowingStream<Frame, any Error>
      public let stop: @Sendable () async -> Void
  }
  extension ScreenCapturer {
      public func scrollingFrames(of selection: CGRect, displays: [DisplayInfo]) async throws -> ScrollingFrames
  }
  ```
  Stream config: `sourceRect` and pixel size from the same `DisplayGeometry` calls `captureArea` uses,
  `pixelFormat = kCVPixelFormatType_32BGRA`, `showsCursor = false`, chrome windows excluded, `queueDepth` and
  `minimumFrameInterval` from Step 4's measurement. Only `.complete` frames (`SCStreamFrameInfo.status`) are yielded;
  idle/blank frames are not. `stream(_:didStopWithError:)` finishes the stream with that error, mapping
  `SCStreamError.userDeclined` to `CaptureError.permissionDenied`. `stop` stops capture and finishes the stream; calling
  it twice is harmless.

- [ ] **Step 1: Write failing test** `@Test func streamConfigurationMatchesAreaCapture()` for a pure
  `static func streamConfiguration(for selection: CGRect, on display: DisplayInfo) -> (sourceRect: CGRect, width: Int, height: Int)?`
  asserting it equals what `captureArea` computes for the same inputs (reuse the display fixtures in that test file),
  and returns nil for a selection off every display.
- [ ] **Step 2: Run** `(cd Packages/LunettaCapture && swift test --filter ScreenCapturerLogicTests)` — expect FAIL.
- [ ] **Step 3: Implement** `streamConfiguration` (have `captureArea` use it too), `ScrollingFrames`, and
  `scrollingFrames(of:displays:)`; throws `CaptureError.emptySelection` like `captureArea`.
- [ ] **Step 4: Measure the frame interval.** Temporary debug harness (not committed): stream a GitHub PR area while
  scrolling by trackpad at a normal and a fast flick, run frames through `Stitcher(tuning: .measured)`, count
  `.lostOverlap` per interval tried. Pick the longest interval with zero `.lostOverlap` at normal speed; record it in the
  perf doc and cite it in a receipt comment.
- [ ] **Step 5: Run the tests** — expect PASS.
- [ ] **Step 6: Commit** — `git commit -m "feat(capture): stream an area's frames for scrolling capture"`

---

### Task 5: Coordinator `.scrolling` mode

**Files:**
- Modify: `App/CaptureCoordinator.swift`, `App/SystemAdapters.swift` (the real `Capturing` conformer forwards to
  `ScreenCapturer.scrollingFrames`)
- Test: `AppTests/CaptureCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ScrollingFrames`, `Stitcher`, `StitchTuning.measured`, `StitchUpdate`.
- Produces:
  ```swift
  enum CaptureMode { case area, window, fullScreen, scrolling }
  protocol Capturing { ...; func scrollingFrames(of selection: CGRect, displays: [DisplayInfo]) async throws -> ScrollingFrames }
  enum ScrollStageDecision: Equatable { case done, cancelled }
  @MainActor protocol ScrollStaging {
      func prepare(_ area: CGRect, on display: DisplayInfo)   // windows on screen, hotkeys registered
      func decision() async -> ScrollStageDecision            // resolves once: Done/Return or Cancel/Esc
      func show(_ update: StitchUpdate, preview: CGImage?)
      func dismiss()                        // for when the stream fails while the stage is up
  }
  ```
  `CaptureCoordinator.init` gains `scrollStager: any ScrollStaging` (after `stager`).
  `ScrollStaging` is where phase 2's driver will plug in; add nothing for it now.

Flow of `selectAndCapture(.scrolling)`:
1. `selector.selectArea(frozen: [])` always (ignores `freezeScreenWhileSelecting`). `.cancelled` → nil.
2. Display via `DisplayGeometry.display(forSelection:in:)`; none → `CoordinatorError.noDisplays`.
3. `scrollStager.prepare(area, on: display)` puts the stage windows on screen first, because
   `CaptureChrome.windowIDs()` is read once when the stream's filter is built; windows created later would end up in
   the frames.
4. `capturer.scrollingFrames(of:displays:)`. Start a detached task that builds the `Stitcher` from the first frame and
   for each next frame calls `append`, sending `(update, tail(maxRows:))` to the main actor → `scrollStager.show`.
   Preview rows = the stage's strip height in pixels (a UI size, not a tuning number).
5. `await scrollStager.decision()`.
6. On `.done`: `await frames.stop()`, await the task, return `stitcher.image()`. On `.cancelled`: stop, return nil.
7. If `scrollingFrames` throws, or the stream throws while staged: `scrollStager.dismiss()`, rethrow, so `takeImage` presents it and nothing saves.

- [ ] **Step 1: Write failing tests** with `FakeCapturer.scrollFrames: [CGImage]` (yields `Frame`s, then waits for
  `stop`) or `scrollError: CaptureError?` (throws after the frames), and `FakeScrollStager` (records `show` calls,
  returns a preset decision after the frames are consumed).

  ```swift
  @MainActor @Test func scrollingDoneWritesOneTallPNG()          // frames at tops 0, 40, 80 of a synthetic page → one PNG, height == h + 80
  @MainActor @Test func scrollingWithoutScrollMatchesAreaCapture() // single frame → PNG pixels equal that frame
  @MainActor @Test func scrollingCancelWritesNothing()            // decision .cancelled → no PNG, stop called once
  @MainActor @Test func scrollingSelectionCancelWritesNothing()   // selector .cancelled → stage never shown, no PNG
  @MainActor @Test func scrollingIgnoresFreezeScreen()            // freezeScreenWhileSelecting on → selector got frozen == []
  @MainActor @Test func scrollingStreamFailureSavesNothing()      // scrollError .permissionDenied → dismiss called, alert presented, no PNG, stop called
  @MainActor @Test func scrollingPreparesStageBeforeStream()     // FakeCapturer records the order: stager.prepare happened before scrollingFrames
  @MainActor @Test func scrollingShowsUpdatesOnStage()            // show called once per appended frame, last update height == h + 80
  ```

- [ ] **Step 2: Run** `xcodegen generate && xcodebuild -scheme Lunetta -destination 'platform=macOS' test -only-testing:LunettaTests/CaptureCoordinatorTests` — expect compile failure.
- [ ] **Step 3: Implement** the flow above; update `Harness` and every existing `CaptureCoordinator(` call site.
- [ ] **Step 4: Run the tests** — expect PASS, existing coordinator tests included.
- [ ] **Step 5: Commit** — `git commit -m "feat(capture): add scrolling capture mode to the coordinator"`

---

### Task 6: Scrolling stage UI and entry points

**Files:**
- Create: `App/Overlay/ScrollingStage.swift`
- Modify: `App/Shortcuts.swift`, `App/LunettaApp.swift`, `App/AccessibilityID.swift`
- Test: `AppTests/ShortcutBindingsTests.swift` (if it asserts the shortcut list), manual check

**Interfaces:**
- Consumes: `ScrollStaging`, `ScrollStageDecision`, `StitchUpdate` (Task 5); `LunettaUI` glass buttons;
  `CaptureChrome.mark`.
- Produces: `final class ScrollingStage: ScrollStaging`; `KeyboardShortcuts.Name.captureScrolling` (default ⌥⇧⌘4,
  after checking it clashes with no macOS default or existing binding); menu item "Capture Scrolling" after
  "Capture Area"; `("Capture Scrolling", .captureScrolling)` after "Capture Area" in `LunettaShortcuts.all` (the
  Settings row comes from that list).

Windows:
- **Outline window**: borderless, clear, `ignoresMouseEvents = true`, level as `StagePanel`, covers the area's screen;
  draws the dim outside the area and the outline just outside it, matching `RecordingStageView`'s look.
- **Controls panel**: `.nonactivatingPanel`, `canBecomeKey = false`, so the keyboard always stays with the app
  underneath (clicking into the page or keyboard-scrolling it never breaks the stage). Placed under the area, or above it when there's no
  room, inside the screen's visible frame. Contents: preview strip (latest `tail`), height label (`"\(points) pt"`
  from pixel height ÷ display scale), Done, Cancel, and a status line: `"Scroll back — lost the overlap"` for
  `.lostOverlap`, `"Height limit \(limit) px reached"` for `.heightLimitReached`. Accessibility IDs for Done, Cancel,
  status.
- **Keys**: `KeyboardShortcuts.Name.finishScrollingCapture` (default Return) and `.cancelScrollingCapture` (default
  Esc), registered in `prepare` and removed when the stage closes, like `cancelRecordingCountdown` in
  `RecordingHUD`. Not listed in `LunettaShortcuts.all`. Return is taken system-wide only while the stage is up.
- `decision()` resolves exactly once; `dismiss` closes both windows, removes the hotkeys, and resolves `.cancelled` if
  still pending.

- [ ] **Step 1: Add shortcut, menu item, list entry, and `AppState` wiring** (`capture(.scrolling)` through
  `explainingPickerPromptOnFirstUse`, like the other capture items); pass `ScrollingStage()` to the coordinator.
- [ ] **Step 2: Implement `ScrollingStage`** as above.
- [ ] **Step 3: Run** the full app test suite — expect PASS.
- [ ] **Step 4: Manual check** with `scripts/run-dev.sh` on a GitHub PR, a Notion page, a Slack thread with the sidebar
  in the area: wheel scrolling reaches the page; outline and panel are absent from the PNG; preview and height update;
  a fast flick shows the overlap message and recovers on scrolling back; Esc saves nothing; Return saves; the card,
  editor, copy and upload behave as for an area capture.
- [ ] **Step 5: Commit** — `git commit -m "feat(capture): add the scrolling stage, shortcut and menu item"`

---

### Task 6b: Tall captures on the thumbnail card

Today the card is a fixed 3:2 frame with `.resizeAspect`, and `ThumbnailDownsampler.downsample` scales by the longest
side, so a 1,600 × 20,000 capture is a sliver a few points wide. Applies to any tall image (`height > 3 × width`), not
only scrolling captures.

**Files:**
- Modify: `App/ThumbnailPanel.swift` (`ThumbnailDownsampler` ~line 1217, `ThumbnailView` image layer ~line 829)
- Test: `AppTests/ThumbnailLayoutTests.swift` (or a new `AppTests/ThumbnailDownsamplerTests.swift` if layout tests
  don't touch the downsampler)

**Interfaces:**
- Produces:
  ```swift
  enum ThumbnailDownsampler {
      static func downsample(_ image: CGImage, maxPixelSize: CGFloat) -> CGImage            // unchanged for images within 3:2
      static func isTall(width: Int, height: Int) -> Bool                                     // height > 3 × width (receipt: iPhone screenshots are 2556/1179 ≈ 2.17 and read fine at aspect-fit; "taller than the card" cropped every 4:3 capture)
      static func topCrop(_ image: CGImage, maxPixelWidth: CGFloat) -> CGImage                // crop to card aspect from the top, then scale by width
  }
  ```
  `downsample` calls `topCrop` for tall images: `CGImage.cropping(to:)` the top `width × width·(2/3)` first (no full
  decode of the tall image), then scale. The card's aspect comes from the same constant `ThumbnailPresenter.size`
  uses, not a new literal. Tall cards get a height badge, e.g. `"↕ 12,480 px"` (pixel height, grouped digits), in
  a corner that doesn't collide with the card's existing buttons, styled like them.

- [ ] **Step 1: Write failing tests**
  ```swift
  @Test func tallImageThumbnailShowsTheTop()          // 1600×20000 image, top 100 rows red: thumbnail aspect == card aspect, width == maxPixelWidth, top pixel red
  @Test func normalImageThumbnailIsUnchanged()        // 1600×1000 image: same output as before (longest-side downsample)
  @Test func tallMeansMoreThanThreeTimesTallerThanWide() // (300, 900) false; (300, 901) true; (400, 300) false; (1179, 2556) false
  @Test func phoneScreenshotKeepsTodaysThumbnail()    // 1179×2556: old longest-side output, no badge
  @MainActor @Test func tallCardShowsHeightBadge()    // card for a 1600×12480 file shows "↕ 12,480 px"; a 1600×1000 card shows none
  ```
- [ ] **Step 2: Run** `xcodebuild … test -only-testing:LunettaTests/ThumbnailLayoutTests` — expect FAIL.
- [ ] **Step 3: Implement** the downsampler change and the badge; tall images use `.resizeAspectFill` with top
  alignment on the card's image layer.
- [ ] **Step 4: Run** the full app test suite — expect PASS.
- [ ] **Step 5: Manual check:** a scrolling capture's card shows the readable top of the doc and the badge; a plain area
  capture's card looks as before.
- [ ] **Step 6: Commit** — `git commit -m "feat(thumbnails): show the top of tall captures with a height badge"`

---

### Task 6c: Tall captures in the annotation editor

Today `AnnotationEditor.fit(on:)` keeps the image's aspect and shrinks the window to the screen, and `EditorCanvas`
pans with plain scroll only at `magnification > 1`, so a 1,600 × 20,000 capture opens as a sliver you can't move
through without zooming first.

**Files:**
- Modify: `Packages/LunettaEditor/Sources/LunettaEditor/AnnotationEditor.swift` (`fit(on:)` ~359, `sizeWindow` ~350)
- Modify: `Packages/LunettaEditor/Sources/LunettaEditor/EditorCanvas.swift` (`fitZoom` ~160, `scrollWheel` ~245)
- Test: `Packages/LunettaEditor/Tests/LunettaEditorTests/ZoomTests.swift`, `AnnotationEditorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  extension EditorCanvas {
      public var fitsWidth: Bool { get set }   // fitZoom = min(available.width / imageSize.width, 1 / pixelsPerPoint); setting it resets focus to the image's top edge
  }
  extension AnnotationEditor {
  }
  ```
  "Tall" is the same rule as Task 6b (`height > 3 × width`): move that predicate from `ThumbnailDownsampler` to
  `LunettaCore` (e.g. `public enum TallCapture { public static func isTall(width: Int, height: Int) -> Bool }`, keeping
  its receipt comment) and use it from both. An earlier draft used "more portrait than the screen", which would have
  made every 4:3 window capture open cropped. For tall images,
  `fit(on:)` sets the window width to `min(natural width + insets, visible.width)` (still ≥ `minimumContentSize`),
  height to `visible.height`, and `canvas.fitsWidth = true`. `scrollWheel` pans with plain scroll whenever
  `imageRect` is larger than `availableRect` on either axis, not only at `magnification > 1`; ⌘-scroll and pinch
  still zoom. The zoom button's "fit" returns to magnification 1, which is fit-to-width for tall images. Normal images
  take exactly today's path.

- [ ] **Step 1: Write failing tests**
  ```swift
  @Test func tallRuleIsShared()                         // LunettaCore TallCapture.isTall matches 6b's cases: (300, 900) false, (300, 901) true
  @MainActor @Test func tallImageOpensFitToWidth()      // editor on a 1600×20000 @2x document, screen visible 1512×945: window height == 945, imageRect.width == availableRect.width, imageRect.maxY at the top of availableRect
  @MainActor @Test func tallImagePansAtBaseMagnification() // plain scroll delta 200 at magnification 1 moves imageRect by 200 pt
  @MainActor @Test func zoomFitReturnsToFitWidth()      // zoom in, click fit: imageRect.width == availableRect.width again
  @MainActor @Test func normalImageFitIsUnchanged()     // 1600×1000: window frame and imageRect equal today's values; plain scroll at magnification 1 doesn't pan
  ```
- [ ] **Step 2: Run** `xcodegen generate && xcodebuild -scheme Lunetta -destination 'platform=macOS' test -only-testing:LunettaEditorTests`
  (the editor package's tests are part of the `Lunetta` scheme, `project.yml:79`) — expect FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run** the editor and app test suites — expect PASS, existing `ZoomTests` included.
- [ ] **Step 5: Manual check:** open a scrolling capture's card in the editor: readable at full width, top first, plain
  scroll moves down the doc, annotations land where drawn, saving writes the full-height PNG.
- [ ] **Step 6: Commit** — `git commit -m "feat(editor): open tall captures fit to width and scroll through them"`

---

### Task 7: Perf receipt

**Files:**
- Modify: `docs/perf/2026-11-scrolling-capture.md`

- [ ] **Step 1: Measure** with the same method as `docs/perf` (`proc_pid_rusage`, Release build): footprint and CPU
  idle before the stage, while staged on a still page, while scrolling a GitHub PR for 30 s, and 60 s after Done.
- [ ] **Step 2: Check:** idle numbers before and after match the existing receipt (stream fully torn down); staged-
  still CPU is near idle (unchanged frames skipped). If not, fix before shipping.
- [ ] **Step 3: Commit** — `git commit -m "docs(perf): measure scrolling capture"`
