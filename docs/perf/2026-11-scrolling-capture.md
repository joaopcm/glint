# Scrolling capture

## Task 0: do scrolled rows come out pixel-identical?

**Verdict: exact.** Every row that changes between two scrolled frames changed because the page changed it (a hover
control moved, a block painted late, an animation ran). Rendering never did. The rows that stayed the same are
byte-identical at the best shift, odd-pixel shifts included. Tolerant matching would not help with the misses either:
they differ by up to 223 per channel, so they are real content.

| | github-pr (Safari) | notion (Dia) |
| --- | --- | --- |
| scrolled pairs, whole run | 870 | 93 public + 436 private |
| pairs at 1.0000, whole content width | 795 | 83 + 423 |
| pairs at 1.0000, hover gutters left out | 867 | n/a |
| odd-pixel shifts | 0 | 8 + 5, all 1.0000 except one late-paint pair |
| largest shift between consecutive frames | 396 px | 414 px |

### setup

- Mac16,8 (Apple M4 Pro), macOS 27.2.1
- display: built-in, 1800x1169 pt (3600x2338 px backing) @ 120 Hz, the only display
- Safari 27.2, Dia 1.58.2 (Chromium; stands in for Chrome, which the owner doesn't use)
- recorder: throwaway `SCStream` on a fixed area of the main display, BGRA, `showsCursor = false`, 2x the area in
  points, `minimumFrameInterval` 1/60 s, every `.complete` frame written as PNG unless its bytes equal the previous
  frame's. Trackpad scrolling by hand: slow, normal, one fast flick, back the other way.
- row match: a throwaway script hashes each row over the given columns, then for each consecutive pair brute-forces
  every vertical shift with at least 200 rows of overlap. Share = rows whose bytes match exactly / non-uniform rows of
  the newer frame in the overlap. Shift = how far content moved up, in px (negative: scrolled up).

### fixtures

`Packages/LunettaCapture/Tests/LunettaCaptureTests/Fixtures/scrolling/`. Consecutive frames always overlap, so each
page stitches as one run. Each run covers part of the page, not the whole page.

| page | area (pt) | frames | size | frame px | what it holds |
| --- | --- | --- | --- | --- | --- |
| `github-pr` | 140,120 1100x800 | 12 | 4.2 MB | 2200x1600 | public PR, split diff. normal scroll, fast flick, overscroll bounce at the end of the page (the only scroll up) |
| `notion` | 10,129 1300x800 | 10 | 9.3 MB | 2600x1600 | public `notion.site` page, no sidebar. fast flick down, bounce at the bottom, scroll up, bounce at the top |

Not recorded, skipped by the owner: `google-doc`, `slack-thread` (still channel list), `docs-chat-bubble` (for
`floatingBlockSize`). Task 3 has to record them or drop them.

### github-pr, fixture pairs

Rows 300..<1600 (below the page header). "Full" is all columns, 0..<2200. "Left pane" is 120..<1500 and leaves out
both line-number gutters, where GitHub's hover **+** button sits.

| pair | shift | share, full | share, left pane | what didn't match |
| --- | --- | --- | --- | --- |
| 01→02 | 688 | 0.9183 | 1.0000 | hover **+** moved to another line (50 rows) |
| 02→03 | 476 | 1.0000 | 1.0000 | |
| 03→04 | 582 | 1.0000 | 1.0000 | |
| 04→05 | 712 | 1.0000 | 1.0000 | |
| 05→06 | 458 | 0.9406 | 1.0000 | hover **+** |
| 06→07 | 322 | 1.0000 | 1.0000 | |
| 07→08 | 240 | 1.0000 | 1.0000 | |
| 08→09 | 116 | 1.0000 | 1.0000 | |
| 09→10 | 32 | 0.8612 | 0.8605 | hover **+**, and the animated mascot at the end of the page |
| 10→11 | -68 | 0.8826 | 1.0000 | hover **+** (two lines) |
| 11→12 | -32 | 0.8880 | 0.9812 | hover **+**, mascot |

Whole run, 880 pairs: 10 still, 870 scrolled, all shifts even (Safari moves in whole points). Full width, 54 scrolled
pairs fall under 0.95, all of them hover **+**, a diff painted late or the mascot. With the gutters left out, 2 fall
under 0.95: a frame caught while the next file's diff was still blank at the bottom edge (during the flick), and the
bounce at the end with the mascot.

### notion, fixture pairs

Rows 120..<1600, columns 40..<2600 (no sidebar on a public page).

| pair | shift | share | what didn't match |
| --- | --- | --- | --- |
| 01→02 | 174 | 1.0000 | |
| 02→03 | 414 | 1.0000 | |
| 03→04 | 412 | 1.0000 | |
| 04→05 | 288 | 1.0000 | |
| 05→06 | -66 | 0.8964 | link-hover popup fading out (103 rows) |
| 06→07 | -504 | 1.0000 | |
| 07→08 | -222 | 1.0000 | |
| 08→09 | -416 | 0.8781 | the image's hover **•••** button appeared (90 rows) |
| 09→10 | -280 | 1.0000 | |

Whole public run, 212 pairs: 119 still, 93 scrolled. 83 at 1.0000. The 10 under 0.95 are all scrolling up past the
link popup and the image hover button. 8 odd-pixel shifts (27, 41, 3, -11, -5, -1, -1, -1), all at 1.0000: Chromium
scrolls in half points, but each frame still lands on whole device pixels.

An earlier run on a private Notion page (frames deleted, numbers kept) had the workspace sidebar in the area. With
columns from x = 560 px (the sidebar ends at 545), 436 scrolled pairs: 423 at 1.0000, 3 under 0.95. Those 3 are fast
flicks where Notion hadn't painted some blocks yet, leaving blank rows (worst 0.4765). 5 odd shifts (77, -29, -5, -3
at 1.0000; 369 is a late-paint pair). With the column start guessed at 400 px, which put part of the sidebar in the
content columns, every scrolled pair fell to 0.60–0.86, all from the still sidebar. That's the case the still-column
detection exists for.

### what this means for Tasks 1–3

- Exact row hashes hold. Tasks 1–2 as written.
- Review Focus #2 shows up on real pages. GitHub's hover **+** changes 50–100 rows in 54 of 870 scrolled pairs (6%)
  while the pointer rests on the diff. Notion's link popup and image hover button change about 100. The shift vote has
  to win with 8–14% of rows not matching.
- Late painting during flicks (Notion blocks, GitHub's next file) can leave a frame with blank rows where content will
  be. Worst seen: half the overlap. Task 3's `minMatchFraction` sweep should include such a pair.
- The overscroll bounce shows up as ordinary small shifts (-2 to -16 px, matching exactly), not as a special case.
