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
`minMatchFraction` 0.5–0.8 and `minDistinctRows` 4–128. Median `append` per frame at 0.70 / 32, after still columns are
learned from every pixel (below):

| stride | 1 | 2 | 3 | 4 | 6 | 8 | 12 | 16 | 24 | 32 | 48 | 64 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| both pages | pass | pass | pass | pass | pass | pass | pass | pass | pass | pass | pass | pass |
| github-pr ms | 15.91 | 8.58 | 6.31 | 5.62 | 4.22 | 4.36 | 3.13 | 2.78 | 2.68 | 2.32 | 2.47 | 2.38 |
| notion ms | 19.18 | 11.48 | 9.09 | 7.68 | 6.37 | 5.80 | 5.17 | 4.84 | 4.48 | 5.63 | 4.47 | 4.68 |

Wrong shifts get closer as the stride grows, because sampled rows look alike more often:

| stride | github-pr worst wrong share | github-pr most rows a wrong shift matches | notion worst wrong share | notion most rows |
| --- | --- | --- | --- | --- |
| 1 | 0.5658 | 715 | 0.0090 | 6 |
| 8 | 0.5721 | 724 | 0.0359 | 24 |
| 16 | 0.5793 | 740 | 0.0732 | 49 |
| 32 | 0.6027 | 776 | 0.1151 | 77 |

The worst true share stays 0.7711 (GitHub) at every stride. Chosen: **8**, 3.6x faster than stride 1 on GitHub and 3.3x
on Notion. Past 8 the gain is about 1 ms per frame while the wrong shifts keep closing in on `minMatchFraction`.

First run, before the fix: `learnBands` compared column signatures sampled every `sampleStride` rows. On Notion, strides
3, 6 and 8–64 learned columns 1031..<2439 instead of 12..<2600 and cropped both sides of the page. The only content
outside 1031..<2439 is a 2-row divider, and when the samples missed it those columns looked still. Strides 2 and 4
passed only because their samples landed on it. Still columns and the header are now always learned from every pixel;
it runs once per capture. `stillSidebarIsFoundWhenContentColumnsDifferOnlyBetweenSamples` covers columns at stride 6,
`sparseTopRowsAreNotAHeader` covers the header at stride 8 (top rows that differ only between samples used to become a
4-row header).

### minMatchFraction

Real fixtures: every value 0.50–0.75 passes, 0.80+ fails (GitHub 01→02 matches 0.7711).

Late paint, synthetic, laid out exactly like `latePaintedFrameIsRefusedAndTheNextOneRecovers`: start a run at frame
*s*, append the real frames up to the one before *i*, then frame *i* with its content columns painted white from the
middle of the overlap to the bottom (Task 0's worst case: blank rows over half the overlap), then the real frame *i*
and the rest. Every downward pair *i* and every start *s* ≤ *i* − 2, so the bands are learned from different first
pairs: 36 GitHub scenarios, 6 Notion. Pass = the painted frame is refused (`.lostOverlap`), every other append is
`.tracking`, and the final image equals a clean run from the same start.

| minMatchFraction | 0.60 | 0.62 | 0.64 | 0.66 | 0.67 | 0.68 | 0.69 | 0.70 | 0.71–0.76 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| github-pr (of 36) | 21 | 22 | 23 | 25 | 29 | 30 | 34 | **36** | 36 |
| notion (of 6) | 3 | 6 | 6 | 6 | 6 | 6 | 6 | 6 | 6 |

Strides 1, 8 and 16 give identical counts. At 0.69 the last failures are GitHub 06→09 and 07→09; the committed test is
07→09 (frame 08→09 painted). Below the floor a painted frame gets stitched, and the white rows stay in the image.

An earlier sweep started every run at frame 01 only and found a floor of 0.68. Runs that start later learn other
bands and need 0.70; that sweep was wrong and is replaced by this one.

Chosen: **0.73**, about midway between the late-paint floor (0.70) and the worst real pair (0.7711): 0.03 above one,
0.041 below the other. It also sits above every wrong shift's share (0.5721 at stride 8).
`latePaintedFrameIsRefusedAndTheNextOneRecovers` fails at 0.69 and passes from 0.70.

### minDistinctRows

Every value 4–128 passes both fixtures at every stride. Real pairs match at least 620 rows. At stride 8, wrong shifts on
Notion match at most 24 rows; GitHub's match up to 724, so there only the share protects. Chosen: **32**, above Notion's
worst wrong match at stride 8, 19x under the smallest real match, about one line of text at 16 pt on Retina.

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

A toast shorter than the block is never detected and gets stitched in once per frame (Task 2's open question). Block 1
can never float: a floating block needs at least two distinct rows, so 2 is the floor, and with block 2 only 1-row toasts
go undetected. `toastOneBlockTallAppearsOnce(block: 2)` covers the 2-row toast. On the real pages, across every scrolled fixture pair, no bottom block forms a
floating block at 2, 4 or 16 px: every still bottom block is blank background (7729 still 2-px blocks on GitHub, 8719
on Notion, all uniform), GitHub's hover **+** included. Median `append` at stride 1 is the same at block 2 and 16 (14.49 vs
14.56 ms GitHub, 19.27 vs 19.36 ms Notion). Chosen: **2**, the smallest value that passes everything. No real floating-widget
fixture exists, so this rests on the synthetic scenarios only.

Open risk: content that repeats with the scroll's period (a striped table scrolled by exactly one stripe) can make a
2-px block at the bottom look still and distinct, which would raise a false floating zone. Neither fixture has such
content, so this is unmeasured.

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
`image()` used to copy the committed rows into an array and again into `Data`. It now writes them once into the buffer
the `CGDataProvider` keeps, so its peak is the image itself.

| height | committed | footprint before `image()` | `image()` before → after | `image()` peak before → after | + `PNGWriter.encode` | encode peak, after | PNG |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 10,600 | 105 MB | 248 MB | 30 → 9 ms | 211 → 106 MB | 924 ms | 148 MB | 39 MB |
| 20,600 | 204 MB | 473 MB | 66 → 20 ms | 409 → 205 MB | 1820 ms | 284 MB | 76 MB |
| 40,600 | 403 MB | 925 MB | 138 → 43 ms | 806 → 403 MB | 3547 ms | 556 MB | 149 MB |
| 80,600 | 799 MB | 1824 MB | 467 → 69 ms | 1600 → 800 MB | 7052 ms | 1100 MB | 296 MB |

The footprint before `image()` is about twice the committed rows because the committed buffer doubles its capacity as
it grows. Peaks are over that footprint.

What the places João shares to accept, read 2026-11-28 (nothing uploaded):

- Slack, https://slack.com/help/articles/201330736-Add-files-to-Slack: "Members and guests can add files up to 1GB in
  size." and "the preview will only display inline if it's smaller than 25,000 pixels on the longest side" "and less
  than 45 million pixels total". Nothing about rejecting or downscaling tall images. At 2600 px wide, 45 Mpx is 17,307
  px tall. https://docs.slack.dev/reference/objects/file-object/ lists thumbnails up to `thumb_1024` and no dimension
  limit.
- GitHub, https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files:
  "The maximum file size is:" "10MB for images and gifs". No dimension limit. At the doc rate above (about 0.6 MB per
  1,000 rows), 10 MB is about 16,000 px.

Chosen: **40,000 px**, a tripwire, kept after the `image()` fix. Anything João would share inline tops out around
16,000–25,000 px, so a good capture never touches it. Slack shows no inline preview past 25,000 px on the longest side
(45 Mpx at this width is already 17,307 px): a capture between 25,000 and 40,000 px uploads to Slack as a file without
an inline preview. At 40,000 px a real doc encodes in under a second, and the worst case peaks around 1.5 GB to stitch
and save (925 MB + 556 MB); at 80,000 px that doubles to about 2.9 GB and 1.6–7 s to encode.

The limit is 17x the tallest frame this Mac can produce (the display's backing height is 2338 px). With
`StitchTuning.measured`, Task 2's open case "limit below one frame's height is silent" can't happen; it can only come
from a hand-made `StitchTuning`.

### no-unique-row fallback cost

One 2200x1600 frame whose rows alternate between two different non-blank rows, then the same frame scrolled by 1 row.
No signature is unique in the reference, so every row votes for every matching row. `StitchTuning.measured`:

| case | first `append` (median of 7 fresh stitchers) | `rowComparisons` | later appends (median of 7) |
| --- | --- | --- | --- |
| fully repeated rows | 24.6 ms (79.5 ms at stride 1) | 1,284,798 | 12.4 ms |
| `github-pr` real frames | 3.4 ms median per append | | |

About 7x a real append on the first frame of a pathological view, still under 30 ms. No limit needed.

## Task 4: area frame stream

### color space

Mac16,8, macOS 27.2.1, one display: Dell S3225QC, 3008x1692 pt @2x, ICC profile "DELL S3225QC" (no `CGColorSpace`
name, so `colorSpaceName` can't name it). Throwaway probe: `SCScreenshotManager.captureSampleBuffer` with the stream's
configuration (BGRA, same `sourceRect`, 2800x1800 px), then `Frame(pixelBuffer)`.

| `colorSpaceName` | buffer attachment | `Frame.colorSpace` |
| --- | --- | --- |
| unset | `CGColorSpace` = DELL S3225QC (the same object `CGDisplayCopyColorSpace` returns) | DELL S3225QC |
| `displayP3` | `CGColorSpace` = Display P3 | Display P3 |
| `sRGB` | `CGColorSpace` = sRGB IEC61966-2.1 | sRGB |

`captureArea`'s `CGImage` carries DELL S3225QC too. Chosen: leave `colorSpaceName` unset, so stitched captures match
area screenshots and the display. On this setup the buffers carry a `CGColorSpace` attachment, not primaries/transfer
attachments; `Frame` reads both (`frameReadsDisplayP3FromPrimariesAndTransferAttachments`). Reading the default
`colorSpaceName` crashes (it is NULL behind a non-optional `CFString`), so the probe never reads it.

### frame interval and queue depth

Mac16,8, macOS 27.2.1, Dell S3225QC 3008x1692 pt @2x, 120 Hz. Safari on
https://github.com/pointfreeco/swift-composable-architecture/pull/3882/files (split diff), page at the top at the start
of each run. Throwaway harness (not committed): `scrollingFrames` on a 1400x900 pt area inside the Safari window (2800x1800
px frames), every frame into `Stitcher(tuning: .measured)` (release build). The stitcher restarts from the refused frame
after each `.lostOverlap`, so a count is breaks, not a stuck tail. João scrolled by trackpad: 12 s at normal reading
speed, then one fast flick (6 s), then ⌘↑. The first 3 breaks per run were saved as PNG pairs.

| interval | queue depth | frames (fps) | breaks, normal | breaks, flick | largest jump between frames | append p50 / p95 ms | frame gap p50 ms | process CPU |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1/120 | 8 | 924 (49) | 0 | 22 | 354 px | 6.3 / 11.1 | 11.8 | 50% |
| 1/60 | 3 | 634 (34) | 0 | 18 | 666 px | 7.0 / 12.0 | 16.7 | 36% |
| 1/60 | 8 | 592 (31) | 0 | 14 | 810 px | 6.8 / 12.4 | 20.8 | 34% |
| 1/30 | 8 | 366 (19) | 0 | 13 | 932 px | 7.8 / 16.8 | 36.2 | 24% |
| 1/20 | 8 | 242 (13) | 0 | 12 | 1696 px | 8.8 / 34.6 | 51.0 | 20% |
| 1/10 | 8 | 131 (7) | 0 | 13 | lost | 10.8 / 82.3 | 107.5 | 15% |

fps counts delivered `.complete` frames only. A still page delivers none, so fps tracks how long the page was moving.

What the flick breaks are: 16 of the 18 saved flick pairs have a frame with 1560–1800 of 1800 rows uniform. The flick
reached a part of the page Safari hadn't painted yet (white), at every interval, so no interval fixes those. Two pairs
have content in both frames. 1/30 s, first break: the earlier frame's bottom ~500 rows were still unpainted, and the
later one has them painted (late paint, refused by design, Task 3). 1/10 s, first break: a true overlap loss. The page
moved more than the whole 1800 px frame in the 107 ms between frames.

Chosen with the owner: **1/30 s**. Every interval passes normal scrolling (the plan's rule alone would pick 1/10 s), but
1/10 s loses the page on a fast flick and 1/20 s came within 104 px of losing it. 1/30 s jumped at most 932 px, half a
frame of margin on a 900 pt area, for 24% CPU against 34% at 1/60 s. An area shorter than about 470 pt could lose
overlap on a flick like this one at 1/30 s.

Queue depth: **3**. At 1/60 s, depth 3 and 8 both had no breaks while scrolling normally, with the same frame gaps
(16.7 vs 20.8 ms median, content-dependent). `Frame` copies the buffer inside the callback, so SCK never waits on us
for a surface, and each surface here is 20 MB (2800x1800 BGRA), so the smaller pool is the cheaper one.

A first sweep the same day is discarded. Its stitcher didn't restart after a break: 5 of its 7 runs broke 0.4–1.6 s
after the first scroll from the top and stayed broken. Before the bands are learned, every refused frame re-learns them
at stride 1 (~65 ms at 2800x1800). The consumer fell behind, and the unbounded frame buffer backed up (1/120 s run: 98%
CPU, 64 ms median append).

Open: the stream's frame buffer is unbounded. In the sweep, process footprint peaked at 1088 MB during the 1/120 s run.
That includes the stitched image (about 270 MB per 24,000 rows at 2800 px, before the buffer doubles) and the harness's
PNG dumps. The backlog itself wasn't measured on its own.
