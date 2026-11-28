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

## Task 3: measured tuning

Same Mac as Task 0 (Mac16,8, M4 Pro, 24 GB, macOS 27.2.1). Every time is a release build (`swift test -c release`).
The sweeps were throwaway tests, not committed.

### fixtures and ground truth

`realPageStitches` runs on `github-pr` and `notion` only. `google-doc`, `slack-thread` and the chat-bubble page were
never recorded and are dropped; still sidebars and floating widgets stay covered by Task 2's synthetic tests.

No ground-truth PNG. Each fixture covers part of a page, starting wherever the recording started, so a full-page
screenshot of the same URL can't be lined up with the run. Instead the test asserts, with `StitchTuning.measured`:
every append is `.tracking` (no fixture pair is a late-paint pair), height never drops, the floating zone stays 0, and
for every frame, at the top the stitcher placed it, at least `minMatchFraction` of its non-blank moving rows equal the
final image's rows byte for byte.

What the stitcher learns (stride 1):

| page | columns | header rows | frame tops | final height |
| --- | --- | --- | --- | --- |
| `github-pr` | 0..<2200 | 108 | 0, 688, 1164, 1746, 2458, 2916, 3238, 3478, 3594, 3626, 3558, 3526 | 5226 |
| `notion` | 12..<2600 | 0 | 0, 174, 588, 1000, 1288, 1222, 718, 496, 80, -200 | 2888 |

The tops match Task 0's shifts exactly. GitHub's 108 header rows are the sticky file header; Task 0's shares started
at row 300, so the shares below are lower than Task 0's because they include rows 108..<300.

### match margins per pair

At the stitcher's columns and header, stride 1. "True" is the share and the matched-row count at the shift the
stitcher picked. "Worst wrong" is the best share any other shift reaches (with at least 8 compared rows), and the most
rows any other shift matches.

| pair | github-pr true | github-pr worst wrong | notion true | notion worst wrong |
| --- | --- | --- | --- | --- |
| 01→02 | 0.7711 (620) | 0.3470, max 403 rows | 1.0000 (813) | 0.0073, max 6 |
| 02→03 | 0.8278 (841) | 0.4745, max 654 | 1.0000 (859) | 0.0058, max 5 |
| 03→04 | 0.8527 (776) | 0.5658, max 715 | 0.9963 (1075) | 0.0009, max 1 |
| 04→05 | 0.8282 (646) | 0.4543, max 626 | 0.9962 (1050) | 0.0009, max 1 |
| 05→06 | 0.8221 (850) | 0.4056, max 537 | 0.9039 (1007) | 0.0009, max 1 |
| 06→07 | 0.8819 (1001) | 0.3750, max 426 | 0.9959 (976) | 0.0010, max 1 |
| 07→08 | 0.8777 (962) | 0.3037, max 368 | 1.0000 (1120) | 0.0027, max 3 |
| 08→09 | 0.9433 (965) | 0.3081, max 318 | 0.8844 (704) | 0.0062, max 5 |
| 09→10 | 0.8833 (923) | 0.2780, max 293 | 0.9939 (648) | 0.0090, max 6 |
| 10→11 | 0.9018 (918) | 0.2945, max 303 | | |
| 11→12 | 0.8980 (907) | 0.2762, max 282 | | |

GitHub's wrong shifts match hundreds of rows because diffs repeat rows (blank lines, unchanged context), so only the
share tells them apart. At stride 32 the worst wrong share on GitHub rises to 0.6027.

### sampleStride

Pass = every append `.tracking`, floating zone 0, and the same tops and the same image bytes as stride 1. Swept with
`minMatchFraction` 0.5–0.9 and `minDistinctRows` 4–128; the stride result doesn't depend on them in 0.5–0.75. Median
`append` per frame at 0.70 / 32:

| stride | github-pr | median ms | notion | median ms |
| --- | --- | --- | --- | --- |
| 1 | pass | 15.05 | pass | 20.21 |
| 2 | pass | 8.34 | pass | 12.21 |
| 3 | pass | 6.19 | **fail** | 4.18 |
| 4 | pass | 5.03 | pass | 8.14 |
| 6 | pass | 4.00 | **fail** | 2.62 |
| 8 | pass | 3.41 | **fail** | 2.25 |
| 16 | pass | 2.64 | **fail** | 2.25 |
| 32 | pass | 2.32 | **fail** | 1.74 |
| 64 | pass | 2.37 | **fail** | 1.58 |

Notion fails the same way at every failing stride: the tops are right but the stitcher learns columns 1031..<2439
instead of 12..<2600, cropping both sides of the page. `learnBands` compares column signatures sampled every
`sampleStride` rows, and the only content outside 1031..<2439 is a 2-row divider (2 rows with ink in columns 12..<1031
in frames 1, 2, 9, 10). When the samples miss it, those columns look still and get cropped. Strides 2 and 4 pass only
because their samples happen to land on the divider. Chosen: **1**, the only stride with margin today. Learning columns
at stride 1 while keeping the tuning stride elsewhere (a one-line change, tried and reverted) makes every stride up to
32 learn 12..<2600; that would let `sampleStride` drop to ~8 (3.4 ms vs 15 ms on GitHub). Left for a follow-up.

### minMatchFraction

Real fixtures: every value 0.50–0.75 passes, 0.80+ fails (GitHub 01→02 matches 0.7711).

Late paint, synthetic: for every downward pair, the newer frame's content columns are painted white from the middle of
the overlap to the bottom (Task 0's worst case: blank rows over half the overlap), inserted before the real frame.
Pass = the painted frame is refused (`.lostOverlap`), every other append is `.tracking`, and the final image equals the
clean run's. 13 pairs (9 GitHub, 4 Notion):

| minMatchFraction | 0.60 | 0.62 | 0.64 | 0.66 | 0.68 | 0.70 | 0.72 | 0.74 | 0.76 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pairs passing | 10 | 12 | 12 | 12 | 13 | 13 | 13 | 13 | 13 |

Below 0.68 a painted frame gets stitched, and the white rows stay in the image. Chosen: **0.72**, between the late-paint
floor (0.68) and the worst real pair (0.7711), 0.04–0.05 from each. It also sits above every wrong shift's share
(0.5658 at stride 1). `latePaintedFrameIsRefusedAndTheNextOneRecovers` locks the floor on GitHub 08→09.

### minDistinctRows

Every value 4–128 passes both fixtures. Wrong shifts on Notion match at most 6 rows; real pairs match at least 620.
GitHub's wrong shifts match up to 715 rows, so there only the share protects. Chosen: **16**, about one line of text
at 8 pt on Retina, 2.7x Notion's worst wrong match and 39x under the smallest real match.

### floatingBlockSize

Pass per scenario: Task 2's widget scenarios (40 px widget, late 20 px footer, scroll back up under a 40 px widget, 30
px sticky footer, vertical rules), a bottom toast of 4–24 px, and both fixtures (`.tracking`, zone 0).

| block | Task 2 widget scenarios | toast 4 | toast 8 | toast 12 | toast 16 | toast 24 | github-pr | notion |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2, 3, 4 | pass | pass | pass | pass | pass | pass | pass | pass |
| 6, 8 | pass | **fail** | pass | pass | pass | pass | pass | pass |
| 12 | pass | **fail** | **fail** | pass | pass | pass | pass | pass |
| 16 | pass | **fail** | **fail** | **fail** | pass | pass | pass | pass |
| 24 | late footer **fails** | **fail** | **fail** | **fail** | **fail** | pass | pass | pass |
| 32 | late footer, sticky footer **fail** | **fail** | **fail** | **fail** | **fail** | **fail** | pass | pass |

A toast shorter than the block is never detected and gets stitched in once per frame (Task 2's open question). With
block 2 that only leaves 1-row toasts. On the real pages, across every scrolled fixture pair, no bottom block forms a
floating block at 2, 4 or 16 px: every still bottom block is blank background (7729 still 2-px blocks on GitHub, 8719
on Notion, all uniform), GitHub's hover **+** included. Median `append` is the same at 2 and 16 (14.49 vs 14.56 ms
GitHub, 19.27 vs 19.36 ms Notion). Chosen: **2**, the smallest value that passes everything. No real floating-widget
fixture exists, so this rests on the synthetic scenarios only. `toastOneBlockTallAppearsOnce` covers blocks 2 and 16.

### maxOutputHeight

PNG of a real doc, 2600 px wide (the `notion` area), filled by tiling the Notion frames. One process per row, so
decode memory isn't hidden by pages freed earlier. Peak is `ledger_phys_footprint_peak` over the footprint before the
step.

| height | raw BGRA | PNG | `PNGWriter.encode` (median of 3) | encode peak | decode (cached) | decode peak |
| --- | --- | --- | --- | --- | --- | --- |
| 10,000 | 99 MB | 6.1 MB | 204 ms | 28 MB | 85 ms | 100 MB |
| 20,000 | 198 MB | 11.4 MB | 401 ms | 38 MB | 162 ms | 199 MB |
| 40,000 | 397 MB | 24.0 MB | 813 ms | 99 MB | 332 ms | 397 MB |
| 80,000 | 793 MB | 47.7 MB | 1643 ms | 194 MB | 691 ms | 794 MB |

Through the stitcher, worst case (incompressible content, 2600 px wide, 1600-row frames scrolled 1000 rows at a time).
`image()` copies the committed rows into an array and again into `Data`, so its peak is twice the image on top of the
committed rows:

| height | committed | footprint before `image()` | `image()` | `image()` peak over that | + `PNGWriter.encode` | PNG |
| --- | --- | --- | --- | --- | --- | --- |
| 10,600 | 105 MB | 248 MB | 30 ms | 211 MB | 932 ms | 39 MB |
| 20,600 | 204 MB | 473 MB | 66 ms | 409 MB | 1828 ms | 76 MB |
| 40,600 | 403 MB | 925 MB | 138 ms | 806 MB | 3680 ms | 149 MB |
| 80,600 | 799 MB | 1824 MB | 467 ms | 1600 MB | 7137 ms | 296 MB |

What the places João shares to accept, read 2026-11-28 (nothing uploaded):

- Slack, https://slack.com/help/articles/201330736-Add-files-to-Slack: "Members and guests can add files up to 1GB in
  size." and "the preview will only display inline if it's smaller than 25,000 pixels on the longest side" "and less
  than 45 million pixels total". Nothing about rejecting or downscaling tall images. At 2600 px wide, 45 Mpx is 17,307
  px tall. https://docs.slack.dev/reference/objects/file-object/ lists thumbnails up to `thumb_1024` and no dimension
  limit.
- GitHub, https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files:
  "The maximum file size is:" "10MB for images and gifs". No dimension limit. At the doc rate above (about 0.6 MB per
  1,000 rows), 10 MB is about 16,000 px.

Chosen: **40,000 px**, a tripwire. Anything João would share inline tops out around 16,000–25,000 px, so a good capture
never touches it. At 40,000 px a real doc encodes in under a second, and the stitcher peaks around 1.7 GB in the worst
case; at 80,000 px that doubles to about 3.4 GB and 1.6–7 s to encode. The `image()` double copy is most of that peak
and is worth removing in a follow-up.

The limit is 17x the tallest frame this Mac can produce (the display's backing height is 2338 px). With
`StitchTuning.measured`, Task 2's open case "limit below one frame's height is silent" can't happen; it can only come
from a hand-made `StitchTuning`.

### no-unique-row fallback cost

One 2200x1600 frame whose rows alternate between two different non-blank rows, then the same frame scrolled by 1 row.
No signature is unique in the reference, so every row votes for every matching row.

| case | first `append` (median of 7 fresh stitchers) | `rowComparisons` | later appends (median of 7) |
| --- | --- | --- | --- |
| fully repeated rows | 79.5 ms | 1,284,798 | 23.8 ms |
| `github-pr` real frames | 14.5 ms median per append | | |

About 5x a real append on the first frame of a pathological view, still under 100 ms. No limit needed.
