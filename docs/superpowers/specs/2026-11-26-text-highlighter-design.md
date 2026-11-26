# Text-aware highlighter

## Why

Highlighting text in a capture today means hand-fitting a yellow rectangle over each line. The highlighter should know where the text is: drag from one word to another and it marks the words in between, in reading order, the way you select text in Preview.

## Goals

- Drag from word A to word B: highlight A's line from A to its end, every line between in full, and B's line from its start to B. Same rule backwards.
- Snap to words: a highlight never cuts a word in half.
- A multi-line highlight is one annotation: one undo step, selected, moved and deleted as a unit.
- Starting a drag off any text, or before OCR finishes, still draws today's free rectangle.

## Non-goals

- Resizing a text highlight by its handles (re-drag instead). Text highlights show no handles.
- A separate tool. This replaces the current Highlighter (H).
- Colour. The colour picker work (another branch) owns it; the highlight fill will read `annotation.color` once that lands.

## Approaches

- **A. Text-editor selection (picked):** word boxes from OCR, range from start word to end word in reading order, one rect per line. Familiar; needs reading order.
- **B. Snap a free rectangle to the words it touches:** simpler, but across several lines it marks a block, not the flow of the sentence.
- **C. Click a line to mark it whole:** too coarse to mark one word.

## Design

- **Word boxes:** `TextLayout` in LunettaEditor runs `VNRecognizeTextRequest` on the base image once, off the main thread, when the document opens. Each observation is a line; its words come from `boundingBox(for:)` over word ranges. Lines keep Vision's result order as reading order. Rects are stored in image pixels, top-left origin, like annotations.
- **Model:** `Annotation` gains `lines: [CGRect]`. Empty means a free rectangle drawn from `bounds` (today's behaviour). Non-empty means a text highlight: `start`/`end` hold the union's corners so `bounds`, hit-testing and `moved(by:)` keep working; `moved(by:)` also offsets `lines`.
- **Gesture:** on mouse-down with the highlighter, if the point falls in a word box (with a small hit pad), the drag is a text drag; each drag event recomputes the selected `lines` from the start word to the word nearest the pointer. Otherwise it is a free-rect drag, as today.
- **Render:** each line rect, padded slightly, filled with multiply blend, same as the free highlight.
- **Tests:** range selection (forward, backward, same line, across lines) as pure logic over fake word boxes; one OCR test on a fixture image with two lines of text.

## Constraints

- The colour picker agent is editing `Annotation`, `EditorCanvas` and the renderer in the main checkout right now. This work lives in `.worktrees/text-highlighter` (branch `feat/text-highlighter`) and rebases onto theirs once it merges.

## Left to the builder

- Hit pad and line padding values, measured against real captures.
