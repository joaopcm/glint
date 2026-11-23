# Plan 1 QA checklist

Run on a real Mac. This is the only place the UI gets verified. Tick `[x]` on pass. On fail, write what you saw in notes and open an issue before Plan 2 starts.

Hotkeys: area `⇧⌘2`, window `⌃⇧⌘2`, full screen `⇧⌘1`. Captures fire on key down. Default save folder is Desktop, names look like `Glint 2026-11-22 at 15.04.05.png`.

Setup you need: a Retina display (built-in), a 1x external display, and a P3 display (the built-in usually is). Checks marked "2 displays" need the external one.

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
