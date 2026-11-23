# QA checklist: Plan 1 and the quick-access overlay

Run on a real Mac. This is the only place the UI gets verified. Tick `[x]` on pass. On fail, write what you saw in notes and open an issue before Plan 2 starts.

Hotkeys: area `⇧⌘2`, window `⌃⇧⌘2`, full screen `⇧⌘1`. Captures fire on key down. Default save folder is Desktop, names look like `Glint 2026-11-22 at 15.04.05.png`.

Setup you need: a Retina display (built-in), a 1x external display, a P3 display (the built-in usually is), and a trackpad. Checks marked "2 displays" need the external one.

Handy commands:

```sh
sips -g pixelWidth -g pixelHeight "<file>.png"
ls -lt ~/Desktop | head
```

Glint's own menu bar icon is absent from captures. That is expected, not a failure.

## 1. Install

Follow [Install a dev build](../../README.md#install-a-dev-build).

### 1. Install from the CI artifact
Steps: download the `Glint-<short-sha>` artifact from the latest green `ci` run, unzip, unzip `Glint.zip`, move `Glint.app` to `/Applications`, run `xattr -d com.apple.quarantine /Applications/Glint.app`, open it.
Expected: opens with no Gatekeeper block. Menu bar icon appears. No Dock icon.
[ ] pass  notes: ______________________

## 2. First run and permission

Start with Glint removed from System Settings > Privacy & Security > Screen & System Audio Recording (select it, press `-`). Quit Glint.

### 2. First capture without permission
Steps: open Glint, press `⇧⌘2`.
Expected: no overlay and no blank PNG. The macOS prompt and/or an alert appear. The alert names System Settings > Privacy & Security and says to quit and reopen Glint. Buttons: Open System Settings, OK. No file written.
[ ] pass  notes: ______________________

### 3. Same check in window and full screen modes
Steps: with permission still missing, press `⌃⇧⌘2`, then `⇧⌘1`.
Expected: the same alert each time, before any overlay. No file written.
[ ] pass  notes: ______________________

### 4. Open System Settings button
Steps: in the alert from check 2, click Open System Settings.
Expected: Screen Recording pane opens with Glint listed. Pass: Settings opens and at most one prompt is visible. Note if both the system prompt and Settings appear at once.
[ ] pass  notes: ______________________

### 5. Grant and relaunch
Steps: switch Glint on in the pane, quit and reopen Glint, press `⇧⌘1`.
Expected: capture saves a PNG on Desktop. No alert.
[ ] pass  notes: ______________________

### 6. Permission revoked after it worked
Steps: with Glint working, switch Glint off in the Screen Recording pane (or remove it). Press `⇧⌘2`, `⌃⇧⌘2`, `⇧⌘1`.
Expected: an alert each time, never a blank or black PNG. No file written.
[ ] pass  notes: ______________________

### 7. Focus after the alert
Steps: with Safari frontmost, trigger the permission alert, click OK. Repeat, clicking Open System Settings instead.
Expected: OK returns focus to Safari. Open System Settings leaves System Settings frontmost, not pushed behind Safari.
[ ] pass  notes: ______________________

## 3. Menu bar and settings

### 8. Menu contents
Steps: click the menu bar icon.
Expected: Capture Area, Capture Window, Capture Full Screen, Settings..., a greyed out `Glint 0.1.0 (<run number>) <short sha>` line, Quit Glint. Run number and sha match the CI run the artifact came from.
[ ] pass  notes: ______________________

### 9. Settings from the menu
Steps: click Settings... while another app is frontmost.
Expected: the settings window opens in front of that app. Close it and open it again: works every time.
[ ] pass  notes: ______________________

### 10. Settings shortcut
Steps: with the menu open, press `⌘,`. Also press it with the menu closed.
Expected: the settings window comes to front. Note which of the two cases work.
[ ] pass  notes: ______________________

### 11. Default shortcuts shown
Steps: look at the three recorders in Settings.
Expected: `⇧⌘2`, `⌃⇧⌘2`, `⇧⌘1`. None conflicts with the system `⇧⌘3`, `⇧⌘4`, `⇧⌘5`.
[ ] pass  notes: ______________________

### 11a. No conflict with CleanShot X
Steps: with CleanShot X running with its default shortcuts, press `⇧⌘2`, `⌃⇧⌘2` and `⇧⌘1`.
Expected: every Glint hotkey fires its Glint capture. CleanShot X does not react and shows no conflict warning.
[ ] pass  notes: ______________________

### 12. Rebind a shortcut
Steps: change Capture Full Screen to another combo. Press it without relaunching. Quit and reopen Glint, check the recorder, press it again.
Expected: the new combo works at once, the old one stops, and the change survives relaunch.
[ ] pass  notes: ______________________

### 13. Save folder picker
Steps: click Choose..., pick a folder, then create a new folder in the panel and pick it. Capture with `⇧⌘1`. Quit and reopen Glint, check the path.
Expected: path updates, the PNG lands in the new folder (no relaunch needed), and the path persists after relaunch.
[ ] pass  notes: ______________________

### 14. Clipboard toggle persists
Steps: turn "copy to clipboard" on, quit and reopen Glint.
Expected: still on. Same for off.
[ ] pass  notes: ______________________

## 4. Area capture

### 15. Overlay look
Steps: press `⇧⌘2` (2 displays).
Expected: every screen dims, the cursor is a crosshair, a drag shows a clear rectangle with a white border and a `W × H` readout below it (inside it when there is no room).
[ ] pass  notes: ______________________

### 16. Retina pixel size
Steps: drag an area on the Retina display. Note the readout, release, then run `sips` on the new file.
Expected: PNG pixel size equals the readout, which is the selection in points times 2.
[ ] pass  notes: ______________________

### 17. 1x display pixel size
Steps: same on the 1x external display.
Expected: PNG pixel size equals the readout, which equals the selection in points (1x).
[ ] pass  notes: ______________________

### 18. Display arranged left of main
Steps: in System Settings > Displays > Arrange, put the external display left of main. Select a recognizable region on it (text, a window corner).
Expected: the saved PNG shows exactly the selected region.
[ ] pass  notes: ______________________

### 19. Display arranged above main
Steps: put the external display above main and repeat check 18.
Expected: the saved PNG shows exactly the selected region.
[ ] pass  notes: ______________________

### 20. Selection spanning two displays
Steps: drag a rectangle that crosses the edge between two displays.
Expected: the rectangle draws on both screens. The PNG is clipped to the display with the larger share of the selection.
[ ] pass  notes: ______________________

### 21. No Glint UI in the image
Steps: take several area captures. Open them.
Expected: no overlay dim, border, readout or alert in any PNG.
[ ] pass  notes: ______________________

### 22. Front app stays active in the image
Steps: with Safari frontmost, area-capture part of its window including the traffic lights. Repeat with `⇧⌘1`.
Expected: traffic lights are colored in the PNG, and Safari stays active the whole time (title bar never greys out).
[ ] pass  notes: ______________________

### 23. First click on a non-key screen (2 displays)
Steps: press `⇧⌘2` with the pointer on display A, move to display B, drag at once without a preliminary click.
Expected: the first click starts the selection. No click is swallowed.
[ ] pass  notes: ______________________

## 5. Window capture

### 24. Highlight and pick
Steps: press `⌃⇧⌘2`, hover over overlapping windows.
Expected: the front-most window under the pointer gets a blue highlight. Clicking saves that window. Glint's own windows, the menu bar and Dock items are not offered.
[ ] pass  notes: ______________________

### 25. Window on a display above or left of main
Steps: put a window on the displays arranged in checks 18 and 19, hover it.
Expected: the highlight sits exactly on the window.
[ ] pass  notes: ______________________

### 26. Shadow, transparent corners and full resolution
Steps: on the Retina display, capture a Finder or Safari window that shows text. Open the PNG in Preview and put it over a colored background (or view in an editor with a checkerboard). Without moving or resizing the window, capture it with the system tool too: run `screencapture -w ~/Desktop/sc-window.png` and click the same window. It keeps the shadow, like Glint. Compare both files with `sips -g pixelWidth -g pixelHeight`. Open both at 100% (View > Actual Size) side by side and zoom into the text.
Expected: the drop shadow is present and not clipped at any edge. Corners and shadow area are transparent, not black or white. Glint's pixel width and height equal the `screencapture` ones. Text is as sharp as in the `screencapture` PNG, not soft or resampled. If the sizes differ, write both down.
[ ] pass  notes: ______________________

### 27. Click on empty desktop
Steps: in window mode, click a spot with no window.
Expected: nothing happens, overlay stays, no file written.
[ ] pass  notes: ______________________

## 6. Full screen capture

### 28. Display under the cursor
Steps: put the pointer on the external display, press `⇧⌘1`. Repeat on the built-in display.
Expected: the PNG is the display the pointer was on, at native pixel resolution, with no cursor in it.
[ ] pass  notes: ______________________

### 29. Pointer at the menu bar and right edge
Steps: press `⇧⌘1` with the pointer at the very top edge of a display, then at its right edge.
Expected: that display is captured, not a neighbor.
[ ] pass  notes: ______________________

## 7. Cancel and overlay behavior

### 30. Esc cancels area and window
Steps: press `⇧⌘2`, then Esc at once with no click. Repeat with `⌃⇧⌘2`. Repeat with the pointer on the secondary display.
Expected: overlay closes each time, no file written, no alert.
[ ] pass  notes: ______________________

### 30a. Right click cancels area mode
Steps: press `⇧⌘2`, right click without dragging. Repeat mid-drag: start a drag, keep the left button down, right click. Repeat on the secondary display.
Expected: overlay closes each time, no file written, no alert.
[ ] pass  notes: ______________________

### 30b. Right click cancels window mode
Steps: press `⌃⇧⌘2`, right click over a highlighted window, then over empty desktop. Repeat with Safari frontmost and on the secondary display.
Expected: overlay closes each time, no window is captured, no file written, no alert. This is the mouse-only exit when Esc does not reach the overlay.
[ ] pass  notes: ______________________

### 31. Esc and crosshair with another app frontmost
Steps: bring Safari to front, press `⇧⌘2`, check the cursor, then press Esc.
Expected: crosshair shows (not an arrow) while Safari remains the frontmost app. Esc closes the overlay. If the arrow shows, note it: the cursor needs another approach.
[ ] pass  notes: ______________________

### 32. Click without drag
Steps: press `⇧⌘2`, click once without dragging.
Expected: overlay closes, no file written.
[ ] pass  notes: ______________________

### 33. Hotkey while overlay is up
Steps: press `⇧⌘2`, then press `⇧⌘2`, `⌃⇧⌘2` and `⇧⌘1` again.
Expected: no second overlay, no stuck state. Esc still closes it and a new capture starts normally.
[ ] pass  notes: ______________________

### 34. Overlay coverage
Steps: press `⇧⌘2` over a full-screen app, and on another Space.
Expected: the overlay covers the full-screen app, sits above the menu bar and Dock, and shows on every display.
[ ] pass  notes: ______________________

### 35. Focus after capture and cancel
Steps: with Safari frontmost, capture, then cancel another time.
Expected: Safari is still the active app both times and keeps keyboard focus.
[ ] pass  notes: ______________________

## 8. Saving and clipboard

### 36. File name
Steps: capture once.
Expected: PNG in the save folder named like `Glint 2026-11-22 at 15.04.05.png`.
[ ] pass  notes: ______________________

### 37. Two captures in the same second
Steps: with the save folder open in Finder, press `⇧⌘1` twice as fast as you can. Repeat until two files share a second.
Expected: the second file has the `(2)` suffix, e.g. `Glint 2026-11-22 at 15.04.05 (2).png`. Nothing is overwritten.
[ ] pass  notes: ______________________

### 38. Save folder deleted
Steps: in Settings pick a folder, delete that folder in Finder, then press `⇧⌘1`.
Expected: an alert naming the full path and the OS reason. No file elsewhere.
[ ] pass  notes: ______________________

### 39. Save folder read-only
Steps: pick a folder, `chmod a-w` on it, press `⇧⌘1`. Restore with `chmod u+w`.
Expected: an alert naming the full path and the OS reason.
[ ] pass  notes: ______________________

### 40. Clipboard on
Steps: turn on copy to clipboard, capture. Paste in Finder with `⌘V`. Paste in Preview (File > New from Clipboard), Slack and Messages.
Expected: Finder pastes the file. The three apps paste the image.
[ ] pass  notes: ______________________

### 41. Clipboard off
Steps: copy some text, turn clipboard off, capture, paste.
Expected: the text is still on the clipboard.
[ ] pass  notes: ______________________

## 9. Color

### 42. Color matches the screen
Steps: on a P3 display, show a saturated P3 image (or any vivid photo). Capture it with `⇧⌘1`. Capture it again with `screencapture -x ~/Desktop/sc.png`. Open both in Preview, compare, and check Tools > Show Inspector > More Info for the color profile.
Expected: Glint's PNG looks the same as the screen and as the `screencapture` output. Profiles match, or differ only in a way that does not shift color. If Glint's PNG looks washed out or oversaturated, fail.
[ ] pass  notes: ______________________

## 10. Update keeps the permission

### 43. Newer CI build keeps Screen Recording
Steps: with Glint working, download a newer CI artifact, replace `/Applications/Glint.app`, clear quarantine, open it, press `⇧⌘1`.
Expected: capture works with no new permission prompt and no re-grant. This proves the stable signing identity.
[ ] pass  notes: ______________________

## 11. Quick-access overlay

Added in PR #1. Defaults: thumbnails in the bottom right corner, about 240 pt wide, auto-hide off. Reset to these before starting.

Known gaps, not failures (tracked in the follow-ups doc): with auto-hide on, a card can vanish mid drag-out or while Save As is open. Growing the cards while the column is open can push it past the top of the screen. Expanding a pile on one display expands the piles on every display.

### 44. Thumbnail after a capture
Steps: with Safari frontmost, press `⇧⌘1`.
Expected: a thumbnail of the capture appears in the bottom right corner of the display the pointer is on. Safari stays the active app (title bar never greys out) and keeps keyboard focus. The PNG is already in the save folder.
[ ] pass  notes: ______________________

### 45. One thumbnail per saved capture
Steps: close the thumbnail. Capture once with `⇧⌘2` and once with `⌃⇧⌘2`. Then press `⇧⌘2` and Esc.
Expected: a new thumbnail after each saved capture, nothing after the cancel.
[ ] pass  notes: ______________________

### 46. Hover toolbar
Steps: with a single thumbnail and Safari frontmost, hover it, then move the pointer away.
Expected: a toolbar shows Copy, Save As, Annotate, Pin and Close while hovered, and hides when the pointer leaves. Every button works on the first click, with no extra click to focus.
[ ] pass  notes: ______________________

### 47. Copy
Steps: click Copy. Paste in Finder with `⌘V`, then in Slack or Messages.
Expected: the card closes. Finder pastes the file, Slack and Messages paste the image.
[ ] pass  notes: ______________________

### 48. Save As
Steps: click Save As, save to Documents under a new name. On another capture, Save As over an existing file and confirm Replace. On a third, open Save As and cancel.
Expected: the save panel comes to front and starts in the save folder. The copy lands where you chose, the original stays in the save folder, and the card closes. Replace overwrites the existing file. Cancel writes nothing and leaves the card on screen. After the panel closes, the app you were in is frontmost again.
[ ] pass  notes: ______________________

### 49. Annotate and click open Preview
Steps: click Annotate on a thumbnail. On a new capture, click the thumbnail itself without dragging.
Expected: the PNG opens in Preview both times and the card closes.
[ ] pass  notes: ______________________

### 50. Pin
Steps: click Pin. Click into another app. Switch to another Space and back. Drag the pinned window by its body, resize it, take a `⇧⌘1` capture, then close it with its close button.
Expected: a window with the screenshot opens centered, at real size or capped at 60% of the screen. It stays above other apps' windows, follows you across Spaces, keeps its aspect ratio when resized and moves when dragged by the image. It is not in the `⇧⌘1` PNG. The close button closes it.
[ ] pass  notes: ______________________

### 51. Close
Steps: hover a thumbnail, click Close.
Expected: the card goes away. The PNG stays in the save folder.
[ ] pass  notes: ______________________

### 52. Drag out
Steps: drag a thumbnail into a Finder window. Drag a new one into Slack or a browser upload field. Drag a third one and drop it on the menu bar, where nothing accepts it.
Expected: Finder gets a copy of the PNG and Slack or the browser attaches the image. The card closes after each drop that worked. The failed drop leaves the card on screen.
[ ] pass  notes: ______________________

### 53. Pile
Steps: take three captures in a row without touching the thumbnails.
Expected: one card in the corner with a `3` badge and two cards peeking out behind it. The newest capture is on top.
[ ] pass  notes: ______________________

### 54. Expand and fold back
Steps: click the pile. Hover a few cards, then move the pointer away from the column. Expand again and take a capture while it is open.
Expected: the click opens a column growing up from the corner, newest nearest the corner, each card with its own toolbar. Moving between cards does not fold it. About 1 s after the pointer leaves the column, it folds back into the pile. A new capture folds it too.
[ ] pass  notes: ______________________

### 55. Swipe to dismiss (trackpad)
Steps: hover a single card and swipe sideways with two fingers. Do the same on a card in the expanded column. Try it on a folded pile.
Expected: the swiped card closes, and the card that slides under the pointer next is not closed by the leftover momentum. Swiping a folded pile does nothing.
[ ] pass  notes: ______________________

### 56. Resize by dragging an edge
Steps: with the corner at bottom right, hover a card's top edge, then its left edge, then the top left corner, then its middle. Drag each edge both ways, as far as it goes. Take three captures and expand the pile. Quit and reopen Glint and capture again.
Expected: a resize cursor on the top edge, the left edge and their corner, an arrow everywhere else. Cards grow and shrink between about 160 and 480 pt wide, with height at 3:2. The pile and the column use the new width. The width survives the relaunch. If the cursor stays an arrow on the edges, note it: the cursor hint uses a private macOS API, and resizing must still work.
[ ] pass  notes: ______________________

### 57. Pinch to resize (trackpad)
Steps: pinch out and in on a card.
Expected: the cards grow and shrink within the same limits as check 56, and the new width is kept for the next capture.
[ ] pass  notes: ______________________

### 58. Corner setting
Steps: with thumbnails on screen, open Settings and set Thumbnail corner to Bottom left. Capture once. Check which edge resizes. Quit and reopen Glint.
Expected: the thumbnails on screen move to the bottom left at once, new ones appear there, and the resize edge is now the right edge. The setting survives the relaunch. Set it back to Bottom right.
[ ] pass  notes: ______________________

### 59. Auto-hide
Steps: turn on "Hide thumbnail after a few seconds". Capture once and wait. Take three captures about 3 s apart and wait. Capture once, keep the pointer on the card for 10 s, then move away and wait. Turn the setting off and capture.
Expected: a single card hides about 6 s after the capture. Each new capture restarts the countdown, so the pile hides all at once about 6 s after the last capture. Hovering holds it for as long as the pointer stays, then it hides about 6 s after the pointer leaves. With the setting off, cards stay until dismissed.
[ ] pass  notes: ______________________

### 60. Thumbnails never in captures
Steps: with a pile on screen, press `⇧⌘1` on that display, then area-capture a region that covers the corner. Press `⌃⇧⌘2` and hover the pile.
Expected: no thumbnail in either PNG. The window picker does not offer the thumbnails.
[ ] pass  notes: ______________________

### 61. Two displays
Steps: capture with the pointer on display A, then capture with it on display B.
Expected: each thumbnail appears on the display the pointer was on. Each display keeps its own pile.
[ ] pass  notes: ______________________

### 62. More captures than fit
Steps: take captures until the expanded column would not fit on the screen (about 5 on a 13" MacBook Air at the default width). Expand the pile.
Expected: the oldest cards drop off, so the column fits the screen. Their PNGs stay in the save folder.
[ ] pass  notes: ______________________

### 63. Display change
Steps: with thumbnails on the external display, unplug it. Then change the built-in display's resolution in System Settings > Displays.
Expected: the thumbnails move to the corner of a remaining display, and none are left off screen or in the wrong place.
[ ] pass  notes: ______________________

### 64. Look
Steps: view the cards and the toolbar over a light wallpaper and over a dark one.
Expected: on macOS 26 the cards use the Liquid Glass look, on macOS 15 a frosted material. The badge and toolbar icons are readable on both wallpapers. Note your macOS version.
[ ] pass  notes: ______________________
