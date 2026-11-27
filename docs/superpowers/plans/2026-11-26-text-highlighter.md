# Text-aware Highlighter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Highlighter (H) snaps to OCR'd words: drag from word A to word B marks the words between them in reading order, one rect per line, as one annotation.

**Architecture:** `TextLayout` (new, LunettaEditor) holds word boxes per line from Vision and computes the per-line rects of a word range. `AnnotationDocument` loads it once in the background. `Annotation` gains `lines: [CGRect]`; the renderer fills each. `EditorCanvas` starts a text drag when mouse-down lands on a word, else today's free rect.

**Tech Stack:** Swift 6, AppKit, Vision, swift-testing.

**Spec:** `docs/superpowers/specs/2026-11-26-text-highlighter-design.md`

## Global Constraints

- All geometry in image pixels, top-left origin (same as `Annotation.start/end`).
- Replaces the current Highlighter tool; keeps shortcut `h`, symbol `highlighter`.
- Text highlights have no handles (`handles == []`).
- Off text, or `textLayout == nil` (OCR pending/failed), the highlighter draws a free rect exactly as today.
- No colour work: fill stays `AnnotationRenderer.highlight`.
- Work in `.worktrees/text-highlighter`, branch `feat/text-highlighter`.
- Test cmd: `cd Packages/LunettaEditor && swift test`. Before push: also `xcodebuild -scheme Lunetta -destination 'platform=macOS' -derivedDataPath build test` from repo root (after `xcodegen generate`).

## Review Focus

1. Drag ends past the last line / off text → selection extends to the nearest word, not lost. (Task 1 test `endPointOffTextUsesNearestWord`)
2. Backward drag (B before A) → same rects as forward. (Task 1 test `backwardEqualsForward`)
3. Image with no text → empty layout, highlighter still draws free rect. (Task 2 test `blankImageHasNoLines`, Task 4 test `freeRectWhenNoTextUnderPointer`)
4. Move then undo a text highlight → lines move and come back. (Task 3 test `movingOffsetsLinesAndUndoRestores`)
5. Click on a word without dragging → that word highlighted (no `minimumDrag` gate for text drags). (Task 4 test `clickOnWordHighlightsIt`)

---

### Task 1: TextLayout range selection (pure)

**Files:**
- Create: `Packages/LunettaEditor/Sources/LunettaEditor/TextLayout.swift`
- Test: `Packages/LunettaEditor/Tests/LunettaEditorTests/TextLayoutTests.swift`

**Interfaces:**
- Produces:
  - `public struct TextLayout: Equatable, Sendable { public let lines: [[CGRect]]; public init(lines: [[CGRect]]) }` — words per line, reading order; words left→right.
  - `struct TextLayout.Position: Comparable, Hashable { let line: Int; let word: Int }` (compare line then word)
  - `func position(at point: CGPoint, pad: CGFloat) -> Position?` — word whose rect, inset by `-pad`, contains point.
  - `func nearestPosition(to point: CGPoint) -> Position?` — min distance point→word rect over all words; nil if no words.
  - `func highlight(from a: Position, to b: Position) -> [CGRect]` — order a,b; per line in range: union of word rects from (first line ? a.word : 0) to (last line ? b.word : last); each padded by `0.15 * rect.height` vertically and `0.1 * rect.height` horizontally (start values; tune by eye on real captures).

- [ ] **Step 1: Write failing tests** with fixture `TextLayout(lines: [[r(0,0,40,20), r(50,0,40,20), r(100,0,40,20)], [r(0,30,40,20), r(50,30,40,20)], [r(0,60,40,20), r(50,60,40,20)]])` (`r(x,y,w,h)` = CGRect) and a local `unpadded` helper reversing the padding:
  - `sameLineRange`: `highlight(from: (0,1), to: (0,2))` unpadded == `[r(50,0,90,20)]`
  - `acrossLines`: `highlight(from: (0,1), to: (2,0))` unpadded == `[r(50,0,90,20), r(0,30,90,20), r(0,60,40,20)]`
  - `backwardEqualsForward`: `highlight(from: (2,0), to: (0,1)) == highlight(from: (0,1), to: (2,0))`
  - `singleWord`: `highlight(from: (1,1), to: (1,1))` unpadded == `[r(50,30,40,20)]`
  - `positionHitsWordWithPad`: `position(at: (45,10), pad: 6) == (0,0)`; `position(at: (45,10), pad: 2) == nil`
  - `endPointOffTextUsesNearestWord`: `nearestPosition(to: (300,200)) == (2,1)`; `nearestPosition(to: (200,5)) == (0,2)`
  - `emptyLayoutHasNoPositions`: `TextLayout(lines: []).nearestPosition(to: .zero) == nil`
- [ ] **Step 2:** `swift test --filter TextLayoutTests` → FAIL (no `TextLayout`).
- [ ] **Step 3:** Implement per Interfaces.
- [ ] **Step 4:** `swift test --filter TextLayoutTests` → PASS.
- [ ] **Step 5:** `git commit -m "feat(editor): text layout word-range selection"`

### Task 2: TextLayout from Vision

**Files:**
- Modify: `Packages/LunettaEditor/Sources/LunettaEditor/TextLayout.swift`
- Modify: `Packages/LunettaEditor/Package.swift` (test target `resources: [.copy("Fixtures")]`)
- Create: `Packages/LunettaEditor/Tests/LunettaEditorTests/Fixtures/two-lines.png` (copy of `Packages/LunettaCapture/Tests/LunettaCaptureTests/Fixtures/two-lines.png`)
- Test: `TextLayoutTests.swift`

**Interfaces:**
- Produces: `static func recognize(in image: CGImage) async -> TextLayout` — `VNRecognizeTextRequest`, `.accurate`, `automaticallyDetectsLanguage = true`; one line per observation in result order; words = `topCandidates(1).first` string enumerated `.byWords`, `boundingBox(for:)` per word range; convert normalized bottom-left → pixels top-left: `x*W, (1 - y - h)*H, w*W, h*H`. Vision failure → `TextLayout(lines: [])` (OCR is best-effort; free rect still works). Run off main actor (`nonisolated`, `Task.detached` not needed if function is nonisolated async).

- [ ] **Step 1: Failing tests:**
  - `recognizesTwoLinesOfWords`: fixture → `lines.count == 2`, every line non-empty, `lines[0][0].minY < lines[1][0].minY`, every rect inside image bounds.
  - `blankImageHasNoLines`: `solidImage(200,100)` → `lines.isEmpty`.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** run → PASS.
- [ ] **Step 5:** `git commit -m "feat(editor): read word boxes with Vision"`

### Task 3: Annotation lines + rendering

**Files:**
- Modify: `Packages/LunettaEditor/Sources/LunettaEditor/Annotation.swift`
- Modify: `Packages/LunettaEditor/Sources/LunettaEditor/AnnotationRenderer.swift` (`.highlighter` case)
- Test: `AnnotationDocumentTests.swift`, `AnnotationRendererTests.swift`

**Interfaces:**
- Produces:
  - `public var lines: [CGRect]` on `Annotation`, init param `lines: [CGRect] = []` (last before `bend`).
  - `public static func textHighlight(_ lines: [CGRect], id: UUID = UUID()) -> Annotation` — kind `.highlighter`, `start`/`end` = min/max corners of `lines` union, `lineWidth: 0`.
  - `handles` → `[]` when `!lines.isEmpty`.
  - `moved(by:)` offsets `lines`.
  - `contains` for text highlight: any line rect inset by `-tolerance` contains point.
  - Renderer: `lines.isEmpty ? fill(bounds) : fill each line`.

- [ ] **Step 1: Failing tests:**
  - `movingOffsetsLinesAndUndoRestores`: add `textHighlight([r(10,10,50,20), r(10,40,30,20)])`, move by (5,5) → lines `[r(15,15,50,20), r(15,45,30,20)]`; `undoManager.undo()` → original lines.
  - `textHighlightHasNoHandles`: `.handles.isEmpty`.
  - `textHighlightHitsOnlyItsLines`: lines above; `contains((70,50), tolerance: 0) == false` (inside union, outside lines); `contains((20,50), tolerance: 0) == true`.
  - Renderer `textHighlightFillsOnlyLines`: flatten white 200×100 with lines above → pixel (20,20) not white, pixel (55,50) white.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` (whole package) → PASS.
- [ ] **Step 5:** `git commit -m "feat(editor): multi-line highlight annotations"`

### Task 4: Document loads layout; canvas text drag

**Files:**
- Modify: `Packages/LunettaEditor/Sources/LunettaEditor/AnnotationDocument.swift`
- Modify: `Packages/LunettaEditor/Sources/LunettaEditor/EditorCanvas.swift`
- Modify: `Packages/LunettaEditor/Sources/LunettaEditor/AnnotationEditor.swift` (init: `Task { await document.loadTextLayout() }`)
- Modify: `Packages/LunettaEditor/Sources/LunettaEditor/AnnotationEditor.swift:34` hint → `"Drag across text to highlight it, or anywhere to highlight an area"`
- Test: `EditorCanvasTests.swift`, `AnnotationDocumentTests.swift`

**Interfaces:**
- Consumes: Task 1–3.
- Produces:
  - `AnnotationDocument`: `public internal(set) var textLayout: TextLayout?`; `public func loadTextLayout() async` (skips if already loaded; sets result).
  - `EditorCanvas.Gesture` new case `highlightingText(TextLayout.Position, Annotation)`.
  - mouseDown, tool `.highlighter`: `if let layout = document.textLayout, let p = layout.position(at: point, pad: Self.hitTolerance / zoom)` → `.highlightingText(p, .textHighlight(layout.highlight(from: p, to: p)))`; else existing free-rect draft.
  - mouseDragged: `nearestPosition(to: point)` → rebuild draft keeping its `id`.
  - mouseUp: `document.add(draft)`, select it — no `minimumDrag` check.
  - `displayedAnnotations`: include the draft. Esc cancels like `.drawing`.

- [ ] **Step 1: Failing tests** (canvas framed at image size, `pixelsPerPoint: 1`, events via `NSEvent.mouseEvent(with:location:...)` in a borderless `NSWindow` holding the canvas; add a small `send(_ type:, at:)` test helper):
  - `loadTextLayoutReadsFixture`: document on fixture, `await loadTextLayout()` → `textLayout?.lines.count == 2`.
  - `dragAcrossWordsAddsOneTextHighlight`: document with injected `textLayout` (Task 1 fixture), tool `.highlighter`, down (60,10) → drag (10,70) → up → one annotation, `lines.count == 3`.
  - `clickOnWordHighlightsIt`: down/up at (60,10) → one annotation, `lines.count == 1`.
  - `freeRectWhenNoTextUnderPointer`: down (300,300)… drag (350,350) on 400×400 base → annotation with `lines.isEmpty`.
  - `freeRectWhileLayoutPending`: `textLayout == nil`, drag over (60,10)→(120,10) → `lines.isEmpty`.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` → PASS.
- [ ] **Step 5:** Manual: `xcodegen generate && xcodebuild ... build`, run app, capture text, H, drag across lines; check fit, tune Task 1 padding if needed.
- [ ] **Step 6:** Full suites: package `swift test` (LunettaEditor, LunettaCore, LunettaCapture) + `xcodebuild -scheme Lunetta -destination 'platform=macOS' -derivedDataPath build test`. All pass.
- [ ] **Step 7:** `git commit -m "feat(editor): highlighter snaps to text"`
