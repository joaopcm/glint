# Native video editor for recordings

Screenshot cards have had Annotate for a while, and video cards still stop at copy, upload, save and open. CleanShot X 5.0 shipped Studio Mode in September: a timeline editor with cuts, auto zooms that follow the cursor, cursor size and smoothing, backgrounds, and camera settings you change after recording ([AlternativeTo](https://alternativeto.net/news/2026/9/cleanshot-x-5-0-introduces-studio-mode-to-turn-a-screen-recording-into-a-polished-video/), [Podfeet](https://www.podfeet.com/blog/2026/09/cleanshot-5/)). This proposes an Edit button on every video card that opens a native editor with all of that, and it changes how Lunetta records so every recording can be edited that way.

I need agreement on the 15 decisions under Proposal, mostly 1 to 6, because they change the recording pipeline everything else builds on. The implementation plan that follows this doc covers slice 1 in detail and outlines slices 2 and 3. Slices 4 to 10 get planned once slice 1 has measured real recordings.

## How it works today

A recording is one ScreenCaptureKit stream writing straight to an MP4. In an area recording everything the viewer sees gets filmed into that file: the cursor (the stream draws it), the click rings, the pressed-keys capsule and the camera bubble, which are ordinary Lunetta windows the stream doesn't leave out. The bubble can be dragged and resized while recording, so the file shows it moving. A window recording captures only that window, so Lunetta's own windows can't reach it: macOS's click circles get filmed in place of the rings, and the toolbar refuses to start a window recording with Camera or Show Pressed Keys on, saying they only work in area recordings. Pausing ends the stream and resuming starts a new one, and at stop the parts are joined back to back without re-encoding.

```
 area recording:
 SCStream (cursor on) ──────────────┐
 click ring window ─── filmed ──────┤
 keys capsule window ── filmed ─────┼──► one .mp4 ──► card (copy, upload, save, open)
 camera bubble window ── filmed ────┘

 window recording:
 SCStream on one window (cursor on, macOS click circles) ──► one .mp4
 camera or pressed keys on ──► refused before recording
```

The card already knows how to wait on a file that isn't final. When Compress after capture is on, it shows a "Compressing" capsule, and copy, upload, drag and save wait until the compressed file replaces the original.

## Problems

The first one is why this is a pipeline change and not just a new window.

1. Nothing filmed into the MP4 can be changed afterwards. The cursor, rings, keys and camera are pixels in the screen video, so an editor can't resize or smooth the cursor, move the camera, or hide either for a stretch. Those are most of what makes Studio Mode recordings look produced.
2. Video cards have no Edit or Annotate. The annotation editor and pinned panels only take still images.
3. Even a trim means leaving Lunetta for QuickTime or another app.
4. A full-screen recording on a 6K display can't be rendered as fast as it plays. On an M4 Pro, the hardware HEVC encoder topped out at about 43 fps at 6016x3384 (3,600 frames in 83 s with nothing else in the loop; spike results in the appendix). So nothing can be re-encoded live at that size while recording, and any render of a full-size recording takes longer than the recording.
5. Window recordings can't have the camera or pressed keys at all. The toolbar refuses them up front, because the window stream has no way to film Lunetta's windows over it.

## Proposal

Record the pieces separately, keep them with a small project file, and make the editor's renderer the only thing that produces the MP4. The card shows up the moment recording stops, the render runs in the background, and the card waits on it the same way it waits on compression today. Opening the editor later edits the project and renders again into the same file.

```
 record:  SCStream (cursor off) ──► screen.mp4 ─┐
          camera, own capture ──► camera.mov ───┤
          pointer, clicks, keys, ───► events ───┼──► project
          bubble and window moves               │
          options in effect ────────────────────┘
                                                     │
 stop:    card appears at once ◄─────────────────────┤
          background render (today's look) ──► recording .mp4 ──► copy, upload, drag unlock
                                                     │
 edit:    Edit on card, history row or Finder ──► editor changes the project ──► render again ──► same .mp4, same link
```

1. Every recording is captured raw. The screen stream records with the cursor off, and the click rings, keys capsule and camera bubble join the windows the stream already leaves out. They still show on screen while recording, so nothing changes for the person recording. This fixes problem 1.
2. The camera records into its own file from the capture session the bubble already runs, at that session's 1280x720 preset. Every move and resize of the bubble during the recording goes into the event log, so the camera's track starts out following the bubble exactly as today's file does.
3. Pointer position, the system cursor image whenever it changes (arrow, I-beam, hand), clicks and key presses go into the event log, timestamped on the same host clock as the screen frames and anchored to the first complete frame. For a window recording the log also keeps the window's frame over time, since the window can move and the pointer, clicks and zooms are placed relative to it. Clicks and pointer moves need no permission. Keys keep needing Input Monitoring and only get logged when Pressed keys is on, same as today. A stored list of keys is easier to read back than pixels, so the log lives with the project and goes when the project goes.
4. A new recording renders with what was turned on and nothing else: no background, no zoom, cursor at system size, rings and keys if they were on, camera following the bubble. That's the file you get today, for area and window recordings alike. Window recordings keep macOS's click circles and keep refusing Camera and Show Pressed Keys in slice 1, so slice 1 changes nothing you can see. Raw capture is what makes problem 5 fixable: the camera slice (7) and the layers slice (8) lift those refusals and render them from the log. "Use as default for new recordings" can come later (out of scope).
5. Any source bigger than 3840x2160 renders scaled down to fit it, area or window, and smaller sources keep their size. A setting turns the cap off. At 4K the render took 40 s per minute of 6K source in the spike, against 83 s at full 6K, and a 1080p area took 16 s per minute. It encodes with the codec from Settings, which still matters: H.264 took 58 s per minute at 4K against HEVC's 40 s.
6. The card appears at stop with a "Rendering" capsule and a percentage, built on the compression capsule. Copy, drag, save and upload wait for the file, and so does Upload after capture. Closing the card doesn't cancel anything, same as closing it today leaves the file alone: the render keeps going and the MP4 lands in the save folder when it's done. If Lunetta quits or crashes mid-render, the project is already on disk and the render starts again at next launch. A render that fails, or trips the memory budget, gets an error that names the reason (and the budget, the limit and the ask), and the card offers Try Again. I don't drop the raw screen file into the save folder as a fallback, because a recording with no cursor and no camera would look like a bug. Rendering only when the file is first needed (approach B in the brainstorm) would make your first copy wait the whole render, so it's not the default.
7. Compress after capture stays what it is, a pass over the finished file. For recordings it now runs after the render. Folding it into the render would save an encode, but it means picking a bitrate without measuring one, so it waits until slice 1 has measured render output sizes against today's files.
8. One renderer drives both preview and export. It takes the project and a time and returns a frame built with Core Image on Metal. The editor plays it through AVFoundation's video composition at window size, and export pulls the same composition through a reader into a writer, so the preview can't drift from what gets saved.
9. Export runs in a separate helper process. The spike's 6K render peaked at 1.4 to 1.56 GB and the 4K one at 596 MB, on 32-bit color frames with no pool limits, and none of that should stay resident in an app that idles at 18 MB ([docs/perf/2026-11-27.md](../../perf/2026-11-27.md)). Slice 1 measures the real renderer with YUV frames and a bounded buffer pool and sets the memory budget from that, as a tripwire.
10. The project is a versioned JSON document next to its media in Lunetta's Application Support folder, one folder per recording. Edits are non-destructive and reference the raw media, and undo works on snapshots of the project value. The MP4 stays in the save folder as today.
11. Paused recordings stay as parts inside the project, and the timeline treats each pause as a cut. The passthrough join goes away for recordings.
12. Saving from the editor renders into the same file. If the recording was uploaded, it uploads again behind the same link, the way saved annotations do today. The upload history already keeps the object key, so this works after the card is gone too.
13. You get back into the editor three ways: Edit on the card, Edit on an Upload History row, and Open With Lunetta on the MP4 in Finder. The MP4 carries an extended attribute with its project's ID, and history rows store the same ID, so moving or renaming the file on the same disk keeps the link. An MP4 whose project is gone opens the way decision 14 describes.
14. Recordings made before this ships, videos copied in from elsewhere, and MP4s whose project expired have no raw media. The editor still opens them, and anything that needs raw media (cursor, camera, clicks, keys, auto zoom) shows as unavailable with the reason.
15. The project model, timeline math, zoom generation from events and cursor smoothing go in LunettaCore as plain value types, so they test on Linux like the rest of that package. Capture changes go in LunettaCapture. The renderer, the helper and the editor window get a new package next to LunettaEditor, built in AppKit like the annotation editor.

### The editor

A window per recording: preview on top, an inspector on the right, the timeline underneath.

```
┌───────────────────────────────────────────────┬──────────────┐
│                                               │ Look         │
│                 preview                       │ Cursor       │
│        (background, frame, cursor, camera)    │ Camera       │
│                                               │ Zoom         │
│                                               │ Audio        │
├───────────────────────────────────────────────┤ Export       │
│ ▶ 00:42 / 02:10        ✂ split   speed   undo │              │
│ clips  ▕████████▏▕█████████████▏▕██████▏      │              │
│ zoom        ▕▓▓▓▏          ▕▓▓▓▓▓▏            │              │
│ camera ▕corner────────────▏▕full▏▕corner─────▏│              │
│ layers        ▕keys▏  ▕text▏                  │              │
│ audio  ▁▂▅▃▂▁▁▃▆▅▂▁▁▂▃▂▁▁▁▂▅▆▃▂▁               │              │
└───────────────────────────────────────────────┴──────────────┘
```

Everything the editor ends up covering, in the order it ships (see Slices):

| Area | What you can do |
|---|---|
| Timeline | play, scrub, trim, split anywhere, delete a stretch, change a stretch's speed, frame strip, waveform, undo and redo, keyboard shortcuts |
| Look | background (wallpaper, gradient, color; reusing the wallpaper composer from screenshots), padding, corner radius, shadow, aspect presets (16:9, 9:16, 1:1, 4:3), crop |
| Cursor | show or hide, size, smoothing, hide when idle, click effect, motion blur |
| Zoom | auto zooms from clicks and typing, a zoom track for adding and dragging zooms by hand, zoom level for one or all, follow the cursor, easing, clear all |
| Camera | position, size, shape, border, and per stretch: hidden, corner or full frame; shrinks during zooms |
| Layers | pressed keys styling, text, arrows and blur over a time range, reusing the annotation renderers |
| Audio | separate microphone and system levels, mute either, noise reduction |
| Export | size, frame rate, codec, GIF, estimated file size, progress on the card |

## Why not keep the filmed MP4 and add the raw pieces next to it

It's the obvious move, since it keeps today's instant file and adds no render at stop. It doesn't work. Getting the screen without the cursor needs a second capture stream with the cursor off, which doubles the encoder load, and the encoder already can't hold 60 fps for one stream at 6K (problem 4). With a single stream the cursor stays filmed in, and then cursor size, smoothing, motion blur and hiding are off the table, which is most of what the editor is for.

## Slices

Each slice ships on its own, leaves recordings working if we stop there, and rolls back without touching the ones before it.

```
 1 raw capture + render ──► 2 editor, trim, export ──► 3 cuts and speed
                                    │
                                    ├──► 4 look      ├──► 7 camera
                                    ├──► 5 cursor    ├──► 8 layers
                                    ├──► 6 zoom      ├──► 9 audio
                                    └──► 10 export options
```

| Slice | Ships | Rolls back by |
|---|---|---|
| 1 | Raw capture, project folder, background render with today's look, Rendering capsule, resume after relaunch, memory budget measured and set | switching recordings back to the filmed path, which stays in the code until slice 2 ships |
| 2 | Edit on the card, Upload History and Finder; editor window, preview, play and scrub, trim, save over the file and re-upload | hiding the entry points |
| 3 | Split, delete, speed, frame strip, waveform, undo | hiding the tools; projects keep the cuts |
| 4 | Look inspector | hiding the inspector section |
| 5 | Cursor inspector | same |
| 6 | Auto zoom and the zoom track | same |
| 7 | Camera inspector and camera track | same |
| 8 | Layers track | same |
| 9 | Audio inspector | same |
| 10 | Export options and GIF | same |

Worth calling out about the order:

- Slice 1 lands first and changes the most, and its visible output is the file you get today. That's the point: if the render doesn't match today's recordings, nothing after it matters. Its acceptance has two halves. Renderer tests feed a known screen clip, camera clip and event log through the renderer and probe the output pixels: the cursor at the logged point, the camera circle where the bubble was (and where it moved to), the keys capsule while it should linger and gone after, the rings at each click. Then the same scripted session gets recorded through the filmed path and the raw path on a real Mac, and we compare them side by side: durations within one frame, overlays at the same times and places. The cursor drawn from the log won't be pixel-identical to the one ScreenCaptureKit draws, so that comparison measures how far apart they are and records it `[TODO: measure logged pointer vs ScreenCaptureKit cursor offset in a scripted session]`.
- Slice 1 also takes the measurements the later slices need: raw size per minute, render times on real recordings, the memory budget, and whether system audio and microphone arrive on separate tracks (slice 9 needs them separate).
- Slices 4 to 10 don't depend on each other and can go in any order after 3.

## Out of scope

- Applying an edited look to every new recording automatically. It's the natural next step, but it needs the editor first and changes what an unedited recording looks like.
- A recordings library window. Upload History and Open With cover getting back into a recording without designing a new screen.
- Captions and transcripts. Not asked for, and on-device speech is its own project.
- Combining several recordings, or importing other clips into one timeline. The editor edits one recording.
- Cursor skins and custom cursor images. The system cursor at any size covers what Studio Mode shows.
- Full editing of any video file. Without raw media there's no cursor or camera to edit (decision 14 covers what still works).
- Running anywhere but macOS. Lunetta is macOS only.

## Open questions

1. Decided on 2026-11-28: a rendered project's raw media is kept 30 days, because fixing a recording you shared last week is the reason decision 13 exists. Settings showing the space used and a clear button can follow once we know the size `[TODO: measure raw media size per minute for a 6K full-screen and a 1080p area recording with camera]`.
2. Today's 6K recordings go through the same encoder that topped out at about 43 fps offline. Are they dropping frames during heavy motion right now? Raw capture doesn't make it worse, but we shouldn't promise 60 fps output before checking a real 6K recording's frame timing. I'll measure it in slice 1.

## Appendix: render spike

Two throwaway runs on 2026-11-28, on an M4 Pro with 24 GB, macOS 27.2.1, main display 6016x3384. The source clips are synthetic 60 s, 60 fps recordings whose content changes every frame, and the camera is a synthetic 1280x720 30 fps clip. "Composite" means a full frame every 1/60 s with a gradient background, padding, rounded corners, a shadow, an animated zoom, a motion-blurred cursor and a round camera with a ring, drawn with Core Image on Metal and encoded through AVAssetWriter. The second run went from AC to battery at some point, which may be why the 6K composite took 107 s there and 83 s in the first run.

| Output | Case | Seconds per 60 s | Peak memory |
|---|---|---|---|
| 1920x1080 | decode only | 1.5 | 8 MB |
| 1920x1080 | encode only, HEVC | 15.8 | 81 MB |
| 1920x1080 | composite, HEVC | 16.0 | 249 to 269 MB |
| 6016x3384 | decode only | 11.8 | 9 MB |
| 6016x3384 | encode only, HEVC | 83.1 | 709 MB (holds 24 frames) |
| 6016x3384 | encode only, H.264 | 141.5 | 855 MB (holds 24 frames) |
| 6016x3384 | composite, HEVC | 82.9 to 107.4 | 1,375 to 1,560 MB |
| 6016x3384 | composite, H.264 | 222.8 | 1,194 MB |
| 3840x2160 | composite, HEVC | 40.3 | 596 MB |
| 3840x2160 | composite, H.264 | 57.8 | 730 MB |
| 2560x1440 | composite, HEVC | 29.5 | 308 MB |

Passthrough (no re-encode, what the pause join does today) took 0.07 s at both sizes. Every 1080p case lands near 231 frames per second whatever the codec, which looks like the spike's own loop and not the hardware, so treat the 1080p numbers as a floor on speed. Asking the encoder to prioritize speed over quality didn't change encode-only time at 6K. A per-frame autoreleasepool didn't change peak memory either, so I'd guess the peak comes from 32-bit color pixel buffers piling up in the writer's pool. Slice 1 has to confirm that.
