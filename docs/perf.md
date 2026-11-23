# Performance baseline

No target number exists until CleanShot X is measured. Measure it first, record it here as the receipt, then measure Glint. Targets get set from that receipt, not before.

Two metrics: idle memory and hotkey-to-crosshair latency. Run both for each app on the same Mac, same macOS version, same display setup, nothing else heavy running.

## Idle memory

Footprint is what Activity Monitor calls "Memory" and is the number that counts against the app.

1. Quit and relaunch the app. Do not open its settings window.
2. Wait 60 seconds, hands off.
3. Get the pid and read the footprint:

```sh
pid=$(pgrep -x Glint)
footprint "$pid"
```

For CleanShot X use `pgrep -x "CleanShot X"`. If `pgrep` finds nothing or two pids, check with `pgrep -lf <name>`.

4. Record the `Footprint:` total in MB. Do 3 launches and take the median. 3 is deliberate: idle footprint barely varies between launches, so more runs add time, not information.

## Hotkey-to-crosshair latency

Time from key-down to the first frame where the crosshair overlay is visible.

### Recording method

Use the Mac's own screen recording at 120 fps on a 120 Hz display (built-in MacBook Pro ProMotion display), not a phone filming the screen.

Why: a phone filming a screen adds moire, exposure flicker and its own frame timing, and you still cannot see the key-down on the screen. A screen recording captures what the compositor drew, so the crosshair frame is exact. Key-down has to be visible too: turn on Keyboard Viewer (System Settings > Keyboard > Input Sources > Show Input menu, then Show Keyboard Viewer) and keep it on screen, so the pressed key lights up in the same recording.

Calibrate once before measuring. Press a key with no hotkey bound (for example a letter in a text field) and confirm it lights up in the Keyboard Viewer in the recording. Then press the real hotkey chord and confirm the viewer highlights the modifiers and the key. The viewer's own redraw may add delay, and it may not highlight chords. If it fails either check, use another key-down marker (for example a key-event overlay app) and note it here.

Steps:

1. Set the display to ProMotion: System Settings > Displays > Refresh Rate > ProMotion.
2. Record with QuickTime Player: File > New Screen Recording, pick the area covering the keyboard viewer and the screen center. Confirm the file is 120 fps:

```sh
mdls -name kMDItemVideoFrameRate recording.mov
ffprobe -v error -select_streams v -show_entries stream=avg_frame_rate recording.mov
```

   If it reports 60, the display or the recording is not at 120 Hz. Fix that before measuring.
3. Press the hotkey 10 times in one recording, waiting about 3 seconds between presses and pressing Esc after each. Hotkey: `⇧⌘2` for Glint. For CleanShot X use its area capture hotkey (default `⇧⌘4` collides with the system, check which one you set).
4. Glint fires on key-down. Before measuring CleanShot X, check its trigger edge: hold its chord and see whether the crosshair appears before you release. If it does, it fires on key-down. If it only appears on release, it fires on key-up: measure it from key-up (release frame) and say so in its results row. Record the exact hotkey and trigger edge for each app in the results table.

### Counting frames

1. Open the recording in QuickTime and step frame by frame with the left and right arrow keys, or extract frames:

```sh
mkdir frames && ffmpeg -i recording.mov -vsync 0 frames/%05d.png
```

2. For each press, find frame A: the first frame where the key is shown pressed in the keyboard viewer.
3. Find frame B: the first frame where the crosshair or dim overlay is visible.
4. latency_ms = (B - A) * 1000 / 120. At 120 fps one frame is 8.33 ms.
5. Write the 10 values down, sort them, take the median (average of the 5th and 6th). Report the median and the min and max.

If the recording is 60 fps, one frame is 16.7 ms. Do not report finer than the frame time.

### Window mode

Window mode is a separate measurement. Before its overlay appears, Glint waits for ScreenCaptureKit to list the shareable windows, so its latency can be much higher than area mode and can grow with the number of open windows.

1. Open the same set of windows for both apps, at least 20 across 3 or more apps (for example Safari with several windows, Finder, Terminal). Count them and record the count in the results.
2. Follow the area mode steps above with `⌃⇧⌘2` for Glint. For CleanShot X use its window capture hotkey, or its area hotkey followed by Space if it has no separate one, and say which in its results row.
3. Frame B is the first frame where the overlay or the window highlight is visible.
4. Repeat once with only 2 or 3 windows open, to see whether the window count matters.

## Results

Memory is the median of 3 launches. Latency is the median of 10 runs.

| App | Idle memory (MB) | Hotkey used | Trigger edge (down/up) | Key-down marker | Hotkey to crosshair (ms) | Date | Mac model | macOS version |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CleanShot X | | | | | | | | |
| Glint | | | | | | | | |

Key-down marker: Keyboard Viewer, or the other marker you used if calibration failed.

Window mode (median of 10 runs):

| App | Hotkey used | Trigger edge (down/up) | Open windows | Hotkey to overlay (ms) | Min (ms) | Max (ms) | Recording fps |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CleanShot X | | | | | | | |
| Glint | | | | | | | |
| Glint (few windows) | | | | | | | |

Latency details (min / max, frame rate of the recording):

| App | Min (ms) | Max (ms) | Recording fps |
| --- | --- | --- | --- |
| CleanShot X | | | |
| Glint | | | |

## After measuring

Open an issue per metric where Glint is worse than CleanShot X. Set target numbers only from this table.
